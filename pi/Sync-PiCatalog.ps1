$ErrorActionPreference='Stop'
$machineRoot=Join-Path $env:LOCALAPPDATA 'StatefulClanker'
$connectionsPath=Join-Path $machineRoot 'connections.json'
$endpointsPath=Join-Path $machineRoot 'endpoints.json'
$piDir=Join-Path $machineRoot 'pi'
New-Item -ItemType Directory -Force -Path $piDir|Out-Null
function Write-AtomicUtf8([string]$Path,[string]$Text){
    $temporary=Join-Path (Split-Path -Parent $Path) ('.'+[IO.Path]::GetFileName($Path)+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
    $backup=Join-Path (Split-Path -Parent $Path) ('.'+[IO.Path]::GetFileName($Path)+'.'+[guid]::NewGuid().ToString('N')+'.bak')
    try{
        [IO.File]::WriteAllText($temporary,$Text,(New-Object Text.UTF8Encoding($false)))
        if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,$backup)}
        else{[IO.File]::Move($temporary,$Path)}
    }finally{
        if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
        if(Test-Path -LiteralPath $backup){Remove-Item -LiteralPath $backup -Force}
    }
}
$settingsPath=Join-Path $piDir 'settings.json'
$settings=if(Test-Path -LiteralPath $settingsPath){
    try{Get-Content -Raw -LiteralPath $settingsPath|ConvertFrom-Json}catch{[pscustomobject]@{}}
}else{[pscustomobject]@{}}
if(-not$settings.PSObject.Properties['compaction']){
    $settings|Add-Member -NotePropertyName compaction -NotePropertyValue ([pscustomobject]@{}) -Force
}
$settings.compaction|Add-Member -NotePropertyName enabled -NotePropertyValue $true -Force
$settings.compaction|Add-Member -NotePropertyName keepRecentTokens -NotePropertyValue 12000 -Force
$settingsJson=$settings|ConvertTo-Json -Depth 30
Write-AtomicUtf8 $settingsPath $settingsJson
if(-not(Test-Path -LiteralPath $connectionsPath)-or-not(Test-Path -LiteralPath $endpointsPath)){exit 0}
$connections=(Get-Content -Raw -LiteralPath $connectionsPath|ConvertFrom-Json).connections
$endpointDoc=Get-Content -Raw -LiteralPath $endpointsPath|ConvertFrom-Json
$credentialScript=Join-Path $PSScriptRoot 'Get-Credential.ps1'
function Safe-Id([string]$Text){return (($Text.ToLowerInvariant()-replace'[^a-z0-9._-]+','-').Trim('-'))}
function Project-SessionId {
    $active=Join-Path $machineRoot 'active-project.txt'
    $root=if(Test-Path -LiteralPath $active){(Get-Content -Raw -LiteralPath $active).Trim()}else{'no-active-project'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$bytes=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant()))}finally{$sha.Dispose()}
    $g=New-Object 'byte[]' 16;[Array]::Copy($bytes,$g,16)
    $g[6]=[byte]((($g[6]-band 0x0f)-bor 0x50));$g[8]=[byte]((($g[8]-band 0x3f)-bor 0x80))
    return ([guid]$g).ToString()
}
$projectSession=Project-SessionId
$groups=@{}
foreach($p in $endpointDoc.entries.PSObject.Properties){
    $e=$p.Value
    if($e.PSObject.Properties['enabled'] -and $null-ne$e.enabled -and -not[bool]$e.enabled){continue}
    $name=[string]$e.connection;if([string]::IsNullOrWhiteSpace($name)){continue}
    if(-not$groups.ContainsKey($name)){$groups[$name]=@()}
    $groups[$name]+=,$e
}
$providers=[ordered]@{}
foreach($connectionName in $groups.Keys){
    $prop=$connections.PSObject.Properties[$connectionName];if($null-eq$prop){continue}
    $c=$prop.Value
    $providerId='sc-'+(Safe-Id $connectionName)
    $protocol=if($c.PSObject.Properties['protocol']-and$c.protocol){[string]$c.protocol}else{'openai-chat'}
    $authKind=if($c.PSObject.Properties['authKind']-and$c.authKind){[string]$c.authKind}elseif($protocol-eq'anthropic-messages'){'x-api-key'}else{'bearer'}
    $hasKey=($c.PSObject.Properties['apiKeyProtected']-and$c.apiKeyProtected)-or($c.PSObject.Properties['apiKeyEnv']-and$c.apiKeyEnv)
    $q=$connectionName.Replace('"','\"')
    $credential="!powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$credentialScript`" -Connection `"$q`""
    $headers=[ordered]@{}
    if($c.PSObject.Properties['headers']-and$c.headers){
        foreach($h in $c.headers.PSObject.Properties){
            $value=[string]$h.Value
            if($h.Name-eq'x-opencode-session'){$value=$projectSession}
            $headers[$h.Name]=$value
        }
    }
    $piApi=switch($protocol){
        'anthropic-messages' {'anthropic-messages'}
        'gemini-native' {'google-generative-ai'}
        default {'openai-completions'}
    }
    $provider=[ordered]@{
        baseUrl=[string]$c.baseUrl
        api=$piApi
        authHeader=$false
        models=@()
    }
    if($authKind-eq'none' -or -not$hasKey){
        # Pi requires an apiKey field when defining custom models even for local/keyless
        # services. This placeholder is never sent as Bearer because authHeader is false.
        $provider.apiKey='statefulclanker-keyless'
    }elseif($protocol-eq'anthropic-messages' -or $protocol-eq'gemini-native'){
        # Pi's native Anthropic/Google transports consume apiKey themselves and emit
        # x-api-key / x-goog-api-key as appropriate.
        $provider.apiKey=$credential
    }elseif($authKind-eq'x-api-key'){
        $provider.apiKey='statefulclanker-header-auth'
        $headers['x-api-key']=$credential
    }elseif($authKind-eq'x-goog-api-key'){
        $provider.apiKey='statefulclanker-header-auth'
        $headers['x-goog-api-key']=$credential
    }else{
        $provider.apiKey=$credential;$provider.authHeader=$true
    }
    if($headers.Count-gt0){$provider.headers=$headers}
    foreach($e in $groups[$connectionName]){
        $ctx=if($e.PSObject.Properties['contextLength']-and$e.contextLength){[long]$e.contextLength}else{128000}
        $provider.models+=,[ordered]@{
            id=[string]$e.model
            name=if($e.PSObject.Properties['displayName']-and$e.displayName){[string]$e.displayName}else{[string]$e.model}
            reasoning=$false
            input=@('text')
            cost=[ordered]@{input=0;output=0;cacheRead=0;cacheWrite=0}
            contextWindow=$ctx
            maxTokens=[Math]::Min(16384,[Math]::Max(4096,[int]($ctx/8)))
        }
    }
    if($provider.models.Count-gt0){$providers[$providerId]=$provider}
}
$out=[ordered]@{providers=$providers}
$json=$out|ConvertTo-Json -Depth 30
Write-AtomicUtf8 (Join-Path $piDir 'models.json') $json

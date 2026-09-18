# Discovers MCP servers already configured in other AI harnesses on this machine, probes them, and lets a human opt a whole server in for worker use.

function Get-SCKnownHarnessConfigCandidates {
    $candidates=@()
    $candidates+=,[pscustomobject]@{harness='claude-desktop';path=(Join-Path $env:APPDATA 'Claude\claude_desktop_config.json');key='mcpServers';shape='keyed';verified=$true}
    $candidates+=,[pscustomobject]@{harness='cursor';path=(Join-Path $env:USERPROFILE '.cursor\mcp.json');key='mcpServers';shape='keyed';verified=$true}
    $candidates+=,[pscustomobject]@{harness='vscode';path=(Join-Path (Get-Location).Path '.vscode\mcp.json');key='servers';shape='keyed';verified=$true}
    $candidates+=,[pscustomobject]@{harness='vscode';path=(Join-Path $env:APPDATA 'Code\User\settings.json');key='mcp.servers';shape='keyed';verified=$true}
    $candidates+=,[pscustomobject]@{harness='opencode';path=(Join-Path $env:USERPROFILE '.config\opencode\opencode.json');key='mcp';shape='opencode';verified=$false}
    $candidates+=,[pscustomobject]@{harness='opencode';path=(Join-Path $env:APPDATA 'opencode\opencode.json');key='mcp';shape='opencode';verified=$false}
    $candidates+=,[pscustomobject]@{harness='claude-code';path=(Join-Path $env:USERPROFILE '.claude.json');key='mcpServers';shape='keyed';verified=$false}
    $candidates+=,[pscustomobject]@{harness='windsurf';path=(Join-Path $env:USERPROFILE '.codeium\windsurf\mcp_config.json');key='mcpServers';shape='keyed';verified=$false}
    $candidates+=,[pscustomobject]@{harness='antigravity';path=(Join-Path $env:APPDATA 'Antigravity\mcp.json');key='mcpServers';shape='keyed';verified=$false}
    return $candidates
}
function Get-SCJsonPropertyByPath($Object,[string]$DottedPath) {
    if($null-eq$Object){return $null};$cur=$Object;foreach($part in ($DottedPath -split '\.')){if($null-eq$cur-or-not($cur.PSObject.Properties[$part])){return $null};$cur=$cur.$part};return $cur
}
function ConvertTo-SCNormalizedMcpEntry([string]$Name,$Entry,[string]$Harness,[bool]$Verified,[string]$Shape,[string]$SourceConfigPath) {
    if($Shape-eq'opencode') {
        $type=if($Entry.PSObject.Properties['type']){[string]$Entry.type}else{'local'}
        if($type-eq'remote'){return [ordered]@{name=$Name;harness=$Harness;verified=$Verified;transport='http';command=$null;args=@();env=@{};url=if($Entry.PSObject.Properties['url']){[string]$Entry.url}else{$null};headers=@{};sourceConfigPath=$SourceConfigPath}}
        $cmdArr=@();if($Entry.PSObject.Properties['command']){$cmdArr=@($Entry.command)}
        $cmd=if($cmdArr.Count-gt0){[string]$cmdArr[0]}else{$null};$rest=if($cmdArr.Count-gt1){$cmdArr[1..($cmdArr.Count-1)]}else{@()}
        return [ordered]@{name=$Name;harness=$Harness;verified=$Verified;transport='stdio';command=$cmd;args=@($rest);env=@{};url=$null;headers=@{};sourceConfigPath=$SourceConfigPath}
    }
    $hasUrl=$Entry.PSObject.Properties['url']-and-not[string]::IsNullOrWhiteSpace([string]$Entry.url)
    if($hasUrl){
        $headers=@{};if($Entry.PSObject.Properties['headers']-and$Entry.headers){foreach($p in $Entry.headers.PSObject.Properties){$headers[$p.Name]=[string]$p.Value}}
        return [ordered]@{name=$Name;harness=$Harness;verified=$Verified;transport='http';command=$null;args=@();env=@{};url=[string]$Entry.url;headers=$headers;sourceConfigPath=$SourceConfigPath}
    }
    $cmd=if($Entry.PSObject.Properties['command']){[string]$Entry.command}else{$null};$args=@();if($Entry.PSObject.Properties['args']-and$Entry.args){$args=@($Entry.args|ForEach-Object{[string]$_})}
    $env=@{};if($Entry.PSObject.Properties['env']-and$Entry.env){foreach($p in $Entry.env.PSObject.Properties){$env[$p.Name]=[string]$p.Value}}
    return [ordered]@{name=$Name;harness=$Harness;verified=$Verified;transport='stdio';command=$cmd;args=$args;env=$env;url=$null;headers=@{};sourceConfigPath=$SourceConfigPath}
}
function Find-SCDiscoverableMcpServers {
    $results=@()
    foreach($candidate in (Get-SCKnownHarnessConfigCandidates)) {
        try{
            if(-not(Test-Path -LiteralPath $candidate.path -PathType Leaf)){continue}
            $raw=$null;try{$raw=Get-Content -Raw -LiteralPath $candidate.path|ConvertFrom-Json}catch{Write-Warning "MCP discovery: could not parse $($candidate.path) as JSON, skipping.";continue}
            $bag=Get-SCJsonPropertyByPath $raw $candidate.key
            if($null-eq$bag){continue}
            foreach($prop in $bag.PSObject.Properties) {
                try{
                    $normalized=ConvertTo-SCNormalizedMcpEntry $prop.Name $prop.Value $candidate.harness $candidate.verified $candidate.shape $candidate.path
                    $results+=,([pscustomobject]$normalized)
                }catch{Write-Warning "MCP discovery: could not normalize entry '$($prop.Name)' from $($candidate.path): $($_.Exception.Message)"}
            }
        }catch{Write-Warning "MCP discovery: skipping harness '$($candidate.harness)' at $($candidate.path): $($_.Exception.Message)"}
    }
    return @($results)
}
function Test-SCMcpServerProbe($Entry,[int]$TimeoutSeconds=15) {
    $probeName="__probe__$([Guid]::NewGuid().ToString('N'))"
    $sourceObj=[pscustomobject]@{transport=$Entry.transport;command=$Entry.command;args=$Entry.args;env=$Entry.env;url=$Entry.url;headers=$Entry.headers;enabled=$true}
    try{
        if($Entry.transport-eq'stdio'){
            Initialize-SCMcpStdioSource $probeName $sourceObj
            $response=Invoke-SCMcpStdioJsonRpc $probeName $sourceObj 'tools/list' ([ordered]@{}) $TimeoutSeconds
        }else{
            Initialize-SCMcpHttpSource $probeName $sourceObj
            $response=Invoke-SCMcpHttpJsonRpc $probeName $sourceObj 'tools/list' ([ordered]@{})
        }
        if($response.PSObject.Properties['error']-and$response.error){return [ordered]@{ok=$false;tools=@();error=[string]$response.error.message}}
        $tools=@();if($response.PSObject.Properties['result']-and$response.result.PSObject.Properties['tools']){foreach($t in @($response.result.tools)){$tools+=,[ordered]@{name=[string]$t.name;description=if($t.PSObject.Properties['description']){[string]$t.description}else{''}}}}
        return [ordered]@{ok=$true;tools=$tools;error=$null}
    }catch{
        return [ordered]@{ok=$false;tools=@();error=$_.Exception.Message}
    }finally{
        if($script:SCWorkerMcpSessions.ContainsKey($probeName)){$script:SCWorkerMcpSessions.Remove($probeName)}
        if($script:SCWorkerMcpStdioProcesses.ContainsKey($probeName)){try{$proc=$script:SCWorkerMcpStdioProcesses[$probeName];if($proc-and-not$proc.HasExited){$proc.Kill()}}catch{};$script:SCWorkerMcpStdioProcesses.Remove($probeName)}
    }
}
function Get-SCMcpDiscoveryCachePath { return Get-SCPath 'mcp-discovery.json' }
function Save-SCMcpDiscoveryCache($Records) {
    Assert-SCInitialized;$path=Get-SCMcpDiscoveryCachePath;$tmp=$path+'.tmp';$payload=[ordered]@{scannedAt=[DateTimeOffset]::UtcNow.ToString('o');servers=$Records}
    $payload|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $tmp -Encoding UTF8;Move-Item -LiteralPath $tmp -Destination $path -Force
}
function Get-SCMcpDiscoveryCache {
    $path=Get-SCMcpDiscoveryCachePath;if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null};try{return Get-Content -Raw -LiteralPath $path|ConvertFrom-Json}catch{return $null}
}
function Test-SCMcpServerImported([string]$Name) {
    $catalog=Get-SCWorkerCapabilityCatalog;return $null-ne$catalog.sources.PSObject.Properties[$Name]
}
function Invoke-SCMcpDiscoveryScan {
    $entries=Find-SCDiscoverableMcpServers;$records=@()
    foreach($entry in $entries) {
        $probe=Test-SCMcpServerProbe $entry
        $records+=,[ordered]@{name=$entry.name;harness=$entry.harness;verified=$entry.verified;transport=$entry.transport;command=$entry.command;args=$entry.args;env=$entry.env;url=$entry.url;headers=$entry.headers;sourceConfigPath=$entry.sourceConfigPath;probeOk=$probe.ok;toolCount=@($probe.tools).Count;probeError=$probe.error;imported=(Test-SCMcpServerImported $entry.name)}
    }
    Save-SCMcpDiscoveryCache $records
    return @($records)
}
function Import-SCDiscoveredMcpServer([string]$Name) {
    if([string]::IsNullOrWhiteSpace($Name)){throw 'name required'}
    $cache=Get-SCMcpDiscoveryCache
    if($null-eq$cache-or-not$cache.PSObject.Properties['servers']){throw "No MCP discovery cache found. Run 'mcp discover' first."}
    $match=$null;foreach($s in @($cache.servers)){if([string]$s.name-eq$Name){$match=$s;break}}
    if($null-eq$match){throw "Discovered MCP server '$Name' not found. Run 'mcp discover' to refresh."}
    if([string]$match.transport-eq'stdio'){
        $source=[ordered]@{transport='stdio';command=[string]$match.command;args=@($match.args);env=([ordered]@{});enabled=$true}
        if($match.PSObject.Properties['env']-and$match.env){foreach($p in $match.env.PSObject.Properties){$source.env[$p.Name]=[string]$p.Value}}
    }else{
        $source=[ordered]@{transport='http';url=[string]$match.url;headers=([ordered]@{});enabled=$true}
        if($match.PSObject.Properties['headers']-and$match.headers){foreach($p in $match.headers.PSObject.Properties){$source.headers[$p.Name]=[string]$p.Value}}
    }
    Set-SCMachineWorkerSource $Name $source|Out-Null
    $tools=@();try{$tools=@(Get-SCMcpSourceTools $Name)}catch{}
    return [ordered]@{name=$Name;source=$source;tools=$tools}
}
function Remove-SCImportedMcpServer([string]$Name) { return Remove-SCMachineWorkerSource $Name }

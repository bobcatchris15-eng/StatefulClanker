# Central capability policy for StatefulClanker-owned workers.
# Machine catalog declares what can exist. Named profiles/project/role/stage/task policy only tighten.

$script:SCWorkerMcpSessions=@{}

function Get-SCWorkerPolicyMachinePath {
    $root=Join-Path $env:LOCALAPPDATA 'StatefulClanker'
    if(-not(Test-Path -LiteralPath $root)){New-Item -ItemType Directory -Force -Path $root|Out-Null}
    return Join-Path $root 'worker-capabilities.json'
}
function Get-SCWorkerPolicyProjectPath { return Get-SCPath 'worker-policy.json' }
function Get-SCDefaultWorkerCapabilityCatalog {
    return [ordered]@{schemaVersion=2;allow=@('builtin.*','intent.human.read','intent.normalized.read');deny=@();profiles=[ordered]@{};sources=[ordered]@{}}
}
function Read-SCWorkerPolicyJson([string]$Path,$Default=$null) {
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $Default}
    try{return Get-Content -Raw -LiteralPath $Path|ConvertFrom-Json}catch{throw "Invalid worker capability policy: $Path`n$($_.Exception.Message)"}
}
function Get-SCWorkerCapabilityCatalog {
    $path=Get-SCWorkerPolicyMachinePath;$catalog=Read-SCWorkerPolicyJson $path $null
    if($null-eq$catalog){return [pscustomobject](Get-SCDefaultWorkerCapabilityCatalog)}
    if(-not$catalog.PSObject.Properties['allow']){Set-SCProperty $catalog 'allow' @('builtin.*','intent.human.read','intent.normalized.read')}
    if(-not$catalog.PSObject.Properties['deny']){Set-SCProperty $catalog 'deny' @()}
    if(-not$catalog.PSObject.Properties['profiles']){Set-SCProperty $catalog 'profiles' ([pscustomobject]@{})}
    if(-not$catalog.PSObject.Properties['sources']){Set-SCProperty $catalog 'sources' ([pscustomobject]@{})}
    Set-SCProperty $catalog 'schemaVersion' 2
    return $catalog
}
function Save-SCWorkerCapabilityCatalog($Catalog) {
    Set-SCProperty $Catalog 'schemaVersion' 2
    if(-not$Catalog.PSObject.Properties['profiles']){Set-SCProperty $Catalog 'profiles' ([pscustomobject]@{})}
    $path=Get-SCWorkerPolicyMachinePath;$tmp=$path+'.tmp';$Catalog|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $tmp -Encoding UTF8;Move-Item -LiteralPath $tmp -Destination $path -Force
}
function Get-SCProjectWorkerPolicy {
    $path=Get-SCWorkerPolicyProjectPath;$policy=Read-SCWorkerPolicyJson $path $null
    if($null-eq$policy){return [pscustomobject]@{schemaVersion=1;allow=$null;deny=@();roles=[pscustomobject]@{};stages=[pscustomobject]@{}}}
    if(-not$policy.PSObject.Properties['deny']){Set-SCProperty $policy 'deny' @()}
    if(-not$policy.PSObject.Properties['roles']){Set-SCProperty $policy 'roles' ([pscustomobject]@{})}
    if(-not$policy.PSObject.Properties['stages']){Set-SCProperty $policy 'stages' ([pscustomobject]@{})}
    return $policy
}
function Save-SCProjectWorkerPolicy($Policy) {
    Assert-SCInitialized;$path=Get-SCWorkerPolicyProjectPath;$tmp=$path+'.tmp';$Policy|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $tmp -Encoding UTF8;Move-Item -LiteralPath $tmp -Destination $path -Force
    Add-SCEvent 'worker.policy_changed' 'Worker capability policy changed.' @{path=$path}
}
function Test-SCCapabilityPattern([string]$Capability,[string]$Pattern) {
    if([string]::IsNullOrWhiteSpace($Pattern)){return $false};if($Pattern-eq'*'){return $true};if($Pattern.EndsWith('*')){return $Capability.StartsWith($Pattern.Substring(0,$Pattern.Length-1),[StringComparison]::OrdinalIgnoreCase)};return $Capability.Equals($Pattern,[StringComparison]::OrdinalIgnoreCase)
}
function Test-SCCapabilityMatchesAny([string]$Capability,$Patterns) {foreach($p in @($Patterns)){if(Test-SCCapabilityPattern $Capability ([string]$p)){return $true}};return $false}
function Test-SCCapabilityAllowedByLayer([string]$Capability,$Allow,$Deny,[bool]$HasExplicitAllow) {if(Test-SCCapabilityMatchesAny $Capability $Deny){return $false};if($HasExplicitAllow -and-not(Test-SCCapabilityMatchesAny $Capability $Allow)){return $false};return $true}
function Get-SCPolicySubrecord($Container,[string]$Name) {if($null-eq$Container-or-not$Container.PSObject.Properties[$Name]){return $null};return $Container.$Name}
function Get-SCTaskCapabilityProfile($Catalog,$Task) {
    if($null-eq$Task-or-not$Task.PSObject.Properties['capabilityProfile']-or[string]::IsNullOrWhiteSpace([string]$Task.capabilityProfile)){return $null}
    $name=[string]$Task.capabilityProfile;$profile=Get-SCPolicySubrecord $Catalog.profiles $name
    if($null-eq$profile){throw "Unknown worker capability profile '$name'. Define it in $(Get-SCWorkerPolicyMachinePath) before dispatch."}
    return [ordered]@{name=$name;policy=$profile}
}
function Test-SCWorkerCapabilityAllowed([string]$Capability,$Task,[string]$Stage='worker') {
    $catalog=Get-SCWorkerCapabilityCatalog;if(-not(Test-SCCapabilityMatchesAny $Capability @($catalog.allow))){return $false};if(Test-SCCapabilityMatchesAny $Capability @($catalog.deny)){return $false}
    $profile=Get-SCTaskCapabilityProfile $catalog $Task
    if($profile){$pp=$profile.policy;$has=$pp.PSObject.Properties['allow'] -and $null-ne$pp.allow;if(-not(Test-SCCapabilityAllowedByLayer $Capability @($pp.allow) @($pp.deny) $has)){return $false}}
    $policy=Get-SCProjectWorkerPolicy;$hasProjectAllow=$policy.PSObject.Properties['allow'] -and $null-ne$policy.allow
    if(-not(Test-SCCapabilityAllowedByLayer $Capability @($policy.allow) @($policy.deny) $hasProjectAllow)){return $false}
    $role=if($Task-and$Task.PSObject.Properties['role']-and$Task.role){[string]$Task.role}else{'worker'};$rolePolicy=Get-SCPolicySubrecord $policy.roles $role
    if($rolePolicy){$has=$rolePolicy.PSObject.Properties['allow'] -and $null-ne$rolePolicy.allow;if(-not(Test-SCCapabilityAllowedByLayer $Capability @($rolePolicy.allow) @($rolePolicy.deny) $has)){return $false}}
    $stagePolicy=Get-SCPolicySubrecord $policy.stages $Stage;if($stagePolicy){$has=$stagePolicy.PSObject.Properties['allow'] -and $null-ne$stagePolicy.allow;if(-not(Test-SCCapabilityAllowedByLayer $Capability @($stagePolicy.allow) @($stagePolicy.deny) $has)){return $false}}
    if($Task-and$Task.PSObject.Properties['toolPolicy']-and$Task.toolPolicy){$tp=$Task.toolPolicy;$has=$tp.PSObject.Properties['allow'] -and $null-ne$tp.allow;if(-not(Test-SCCapabilityAllowedByLayer $Capability @($tp.allow) @($tp.deny) $has)){return $false}}
    return $true
}
function Get-SCWorkerPolicySnapshot($Task=$null,[string]$Stage='worker') {
    $catalog=Get-SCWorkerCapabilityCatalog;$project=Get-SCProjectWorkerPolicy;$profile=$null
    if($Task){$profile=Get-SCTaskCapabilityProfile $catalog $Task}
    return [ordered]@{machinePath=Get-SCWorkerPolicyMachinePath;projectPath=Get-SCWorkerPolicyProjectPath;machine=$catalog;project=$project;capabilityProfile=if($profile){$profile.name}else{$null};taskPolicy=if($Task-and$Task.PSObject.Properties['toolPolicy']){$Task.toolPolicy}else{$null};stage=$Stage;role=if($Task){$Task.role}else{$null}}
}

function Resolve-SCHumanIntentArtifact([string]$SourceRef) {
    if([string]::IsNullOrWhiteSpace($SourceRef)){throw 'sourceRef required'};$resolved=Resolve-SCSourceReference $SourceRef;if($null-eq$resolved){throw "Human source not found: $SourceRef"};return [ordered]@{sourceRef=$SourceRef;content=[string]$resolved.content;authority='direct human/source evidence; read-only'}
}
function Get-SCNormalizedIntentView {$contract=Get-SCIntentContract;$directives=Get-SCCurrentDirectiveSnapshot;return [ordered]@{intent=$contract;intentHash=Get-SCIntentHash $contract;currentDirectives=$directives;authority='orchestrator interpretation reconciled against current human directives; read-only to workers'}}

function ConvertTo-SCMcpHeaders($Source,[string]$SourceName) {
    $headers=@{'Accept'='application/json, text/event-stream';'Content-Type'='application/json';'MCP-Protocol-Version'='2025-06-18'}
    if($script:SCWorkerMcpSessions.ContainsKey($SourceName)-and$script:SCWorkerMcpSessions[$SourceName]){$headers['Mcp-Session-Id']=[string]$script:SCWorkerMcpSessions[$SourceName]}
    if($Source.PSObject.Properties['headers']-and$Source.headers){foreach($p in $Source.headers.PSObject.Properties){$value=[string]$p.Value;if($value -match '^\$\{env:([^}]+)\}$'){$value=[Environment]::GetEnvironmentVariable($Matches[1])};if(-not[string]::IsNullOrWhiteSpace($value)){$headers[$p.Name]=$value}}}
    return $headers
}
function ConvertFrom-SCMcpHttpContent($Content) {
    if($null-eq$Content){return $null};if($Content -isnot [string]){return $Content};$text=[string]$Content;$trim=$text.Trim();if([string]::IsNullOrWhiteSpace($trim)){return $null}
    if($trim.StartsWith('{')-or$trim.StartsWith('[')){return $trim|ConvertFrom-Json}
    $messages=@();foreach($line in ($text-split"`r?`n")){if($line -match '^data:\s*(.+)$'){try{$messages+=,($Matches[1]|ConvertFrom-Json)}catch{}}};if($messages.Count-eq0){throw 'MCP endpoint returned neither JSON nor parseable SSE data.'};return $messages[-1]
}
function Invoke-SCMcpHttpJsonRpc([string]$SourceName,$Source,[string]$Method,$Params=$null) {
    if(-not$Source.PSObject.Properties['url']-or[string]::IsNullOrWhiteSpace([string]$Source.url)){throw 'MCP HTTP source requires url.'}
    $id=[Guid]::NewGuid().ToString('N');$body=[ordered]@{jsonrpc='2.0';id=$id;method=$Method};if($null-ne$Params){$body.params=$Params};$headers=ConvertTo-SCMcpHeaders $Source $SourceName;$json=$body|ConvertTo-Json -Depth 40 -Compress
    try{$response=Invoke-WebRequest -UseBasicParsing -Method Post -Uri ([string]$Source.url) -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json' -TimeoutSec 60}catch{throw "MCP call '$Method' failed for $([string]$Source.url): $($_.Exception.Message)"}
    try{if($response.Headers['Mcp-Session-Id']){$script:SCWorkerMcpSessions[$SourceName]=[string]$response.Headers['Mcp-Session-Id']}}catch{}
    return ConvertFrom-SCMcpHttpContent $response.Content
}
function Initialize-SCMcpHttpSource([string]$SourceName,$Source) {
    if($script:SCWorkerMcpSessions.ContainsKey($SourceName)){return}
    $params=[ordered]@{protocolVersion='2025-06-18';capabilities=[ordered]@{};clientInfo=[ordered]@{name='StatefulClanker-worker';version='1'}}
    try{[void](Invoke-SCMcpHttpJsonRpc $SourceName $Source 'initialize' $params);if(-not$script:SCWorkerMcpSessions.ContainsKey($SourceName)){$script:SCWorkerMcpSessions[$SourceName]='stateless-legacy'}}catch{return}
}
function Get-SCMcpSourceTools([string]$SourceName) {
    $catalog=Get-SCWorkerCapabilityCatalog;$p=$catalog.sources.PSObject.Properties[$SourceName];if($null-eq$p){throw "Unknown worker MCP source '$SourceName'."};$source=$p.Value;$transport=if($source.PSObject.Properties['transport']){[string]$source.transport}else{'http'}
    if(@('http','streamable-http')-notcontains$transport){throw "Worker MCP source '$SourceName' uses unsupported transport '$transport'. Current inherent-worker support is HTTP/Streamable HTTP."}
    Initialize-SCMcpHttpSource $SourceName $source;$response=Invoke-SCMcpHttpJsonRpc $SourceName $source 'tools/list' ([ordered]@{});if($response.PSObject.Properties['error']-and$response.error){throw "MCP tools/list error from '$SourceName': $($response.error.message)"};if(-not$response.PSObject.Properties['result']){return @()};return @($response.result.tools)
}
function Invoke-SCMcpSourceTool([string]$SourceName,[string]$ToolName,$Arguments) {
    $catalog=Get-SCWorkerCapabilityCatalog;$p=$catalog.sources.PSObject.Properties[$SourceName];if($null-eq$p){throw "Unknown worker MCP source '$SourceName'."};$source=$p.Value
    Initialize-SCMcpHttpSource $SourceName $source;$response=Invoke-SCMcpHttpJsonRpc $SourceName $source 'tools/call' ([ordered]@{name=$ToolName;arguments=if($Arguments){$Arguments}else{[ordered]@{}}});if($response.PSObject.Properties['error']-and$response.error){throw "MCP tool '$SourceName/$ToolName' failed: $($response.error.message)"};if(-not$response.PSObject.Properties['result']){return ''}
    $result=$response.result;if($result.PSObject.Properties['content']){$texts=@();foreach($item in @($result.content)){if($item.PSObject.Properties['text']){$texts+=,[string]$item.text}else{$texts+=,($item|ConvertTo-Json -Depth 20 -Compress)}};return ($texts-join"`n")};return ($result|ConvertTo-Json -Depth 30 -Compress)
}
function ConvertTo-SCWorkerMcpToolName([string]$Source,[string]$Tool) {$safeSource=($Source -replace '[^A-Za-z0-9_-]','_');$safeTool=($Tool -replace '[^A-Za-z0-9_-]','_');return "mcp__$safeSource`__$safeTool"}
function Get-SCExternalWorkerToolRecords($Task,[string]$Stage='worker') {
    $catalog=Get-SCWorkerCapabilityCatalog;$out=@();foreach($sourceProp in $catalog.sources.PSObject.Properties){$sourceName=[string]$sourceProp.Name;$source=$sourceProp.Value;if($source.PSObject.Properties['enabled']-and-not[bool]$source.enabled){continue}
        $declared=@();if($source.PSObject.Properties['tools']-and$source.tools){$declared=@($source.tools)}else{try{$declared=@(Get-SCMcpSourceTools $sourceName)}catch{continue}}
        foreach($tool in $declared){$toolName=if($tool -is [string]){[string]$tool}else{[string]$tool.name};if([string]::IsNullOrWhiteSpace($toolName)){continue};$cap="mcp.$sourceName.$toolName";if(-not(Test-SCWorkerCapabilityAllowed $cap $Task $Stage)){continue};$desc=if($tool -is [string]){"External MCP tool $sourceName/$toolName"}elseif($tool.PSObject.Properties['description']){[string]$tool.description}else{"External MCP tool $sourceName/$toolName"};$schema=if($tool -isnot [string]-and$tool.PSObject.Properties['inputSchema']-and$tool.inputSchema){$tool.inputSchema}else{[ordered]@{type='object';properties=[ordered]@{}}};$out+=,[ordered]@{capability=$cap;wireName=(ConvertTo-SCWorkerMcpToolName $sourceName $toolName);source=$sourceName;tool=$toolName;description=$desc;inputSchema=$schema}}
    };return @($out)
}

function Set-SCProjectWorkerPolicyFromObject($Policy) {if($null-eq$Policy){throw 'policy required'};Set-SCProperty $Policy 'schemaVersion' 1;Save-SCProjectWorkerPolicy $Policy;return Get-SCProjectWorkerPolicy}
function Set-SCMachineWorkerSource([string]$Name,$Source) {if([string]::IsNullOrWhiteSpace($Name)-or$Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'){throw 'source name must use letters, numbers, dot, underscore, or hyphen'};if($null-eq$Source){throw 'source configuration required'};$catalog=Get-SCWorkerCapabilityCatalog;if($null-eq$catalog.sources){Set-SCProperty $catalog 'sources' ([pscustomobject]@{})};Set-SCProperty $catalog.sources $Name $Source;Save-SCWorkerCapabilityCatalog $catalog;return $Source}
function Remove-SCMachineWorkerSource([string]$Name) {$catalog=Get-SCWorkerCapabilityCatalog;$prop=$catalog.sources.PSObject.Properties[$Name];if($null-eq$prop){return $false};$catalog.sources.PSObject.Properties.Remove($Name);Save-SCWorkerCapabilityCatalog $catalog;return $true}

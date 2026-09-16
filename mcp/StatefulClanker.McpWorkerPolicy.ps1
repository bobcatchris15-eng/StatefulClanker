# MCP control-plane surface for inherent-worker capability policy.
# Machine catalog may add tool sources; project policy may only narrow effective access.

$script:SCBaseNewExtendedToolsWorkerPolicy=(Get-Item Function:\New-SCExtendedTools).ScriptBlock
$script:SCBaseInvokeExtendedToolWorkerPolicy=(Get-Item Function:\Invoke-SCExtendedTool).ScriptBlock
$script:SCBaseControlInstructionsWorkerPolicy=(Get-Item Function:\Get-SCControlPlaneInstructions).ScriptBlock

function Get-McpWorkerMachinePolicyPath {
    $root=Join-Path $env:LOCALAPPDATA 'StatefulClanker';if(-not(Test-Path -LiteralPath $root)){New-Item -ItemType Directory -Force -Path $root|Out-Null};return Join-Path $root 'worker-capabilities.json'
}
function Get-McpWorkerDefaultCatalog { return [ordered]@{schemaVersion=1;allow=@('builtin.*','intent.human.read','intent.normalized.read');deny=@();sources=[ordered]@{}} }
function Read-McpWorkerJson([string]$Path,$Default=$null) {if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $Default};try{return Get-Content -Raw -LiteralPath $Path|ConvertFrom-Json}catch{throw "Invalid worker policy JSON: $Path"}}
function Write-McpWorkerJson([string]$Path,$Value) {$dir=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $dir)){New-Item -ItemType Directory -Force -Path $dir|Out-Null};$tmp=$Path+'.tmp';$Value|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $tmp -Encoding UTF8;Move-Item -LiteralPath $tmp -Destination $Path -Force}
function Get-McpWorkerCatalog {
    $p=Get-McpWorkerMachinePolicyPath;$c=Read-McpWorkerJson $p $null;if($null-eq$c){return [pscustomobject](Get-McpWorkerDefaultCatalog)}
    if(-not$c.PSObject.Properties['allow']){$c|Add-Member allow @('builtin.*','intent.human.read','intent.normalized.read') -Force};if(-not$c.PSObject.Properties['deny']){$c|Add-Member deny @() -Force};if(-not$c.PSObject.Properties['sources']){$c|Add-Member sources ([pscustomobject]@{}) -Force};return $c
}
function Get-McpWorkerProjectPolicy([string]$Project) {
    $path=Join-Path (Get-McpStateDir $Project) 'worker-policy.json';$p=Read-McpWorkerJson $path $null
    if($null-eq$p){return [pscustomobject]@{schemaVersion=1;allow=$null;deny=@();roles=[pscustomobject]@{};stages=[pscustomobject]@{}}};return $p
}
function Test-McpCapabilityPattern([string]$Capability,[string]$Pattern) {if($Pattern-eq'*'){return $true};if($Pattern.EndsWith('*')){return $Capability.StartsWith($Pattern.Substring(0,$Pattern.Length-1),[StringComparison]::OrdinalIgnoreCase)};return $Capability.Equals($Pattern,[StringComparison]::OrdinalIgnoreCase)}
function Test-McpMachineCanGrantPattern([string]$Pattern,$Catalog) {
    if($Pattern-eq'*'){return (@($Catalog.allow)-contains'*')}
    # A project pattern may be narrower than an allowed machine prefix, but never broader.
    foreach($allowed in @($Catalog.allow)){
        $a=[string]$allowed;if($a-eq'*'){return $true}
        if($a.EndsWith('*')){$prefix=$a.Substring(0,$a.Length-1);if($Pattern.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){return $true}}
        elseif($Pattern-eq$a){return $true}
    }
    return $false
}
function Assert-McpProjectPolicyTightens($Policy,$Catalog) {
    $layers=@($Policy)
    if($Policy.PSObject.Properties['roles']-and$Policy.roles){$layers+=@($Policy.roles.PSObject.Properties|ForEach-Object{$_.Value})}
    if($Policy.PSObject.Properties['stages']-and$Policy.stages){$layers+=@($Policy.stages.PSObject.Properties|ForEach-Object{$_.Value})}
    foreach($layer in $layers){if($layer-and$layer.PSObject.Properties['allow']-and$null-ne$layer.allow){foreach($pattern in @($layer.allow)){if(-not(Test-McpMachineCanGrantPattern ([string]$pattern) $Catalog)){throw "Project policy cannot grant '$pattern'; machine policy does not allow it. Project policy is tighten-only."}}}}
}
function Add-McpWorkerAudit([string]$Action,$Data) {
    $root=Split-Path -Parent (Get-McpWorkerMachinePolicyPath);$path=Join-Path $root 'worker-capability-audit.jsonl';$record=[ordered]@{ts=(Get-Date).ToUniversalTime().ToString('o');action=$Action;data=$Data};(($record|ConvertTo-Json -Depth 20 -Compress))|Add-Content -LiteralPath $path -Encoding UTF8
}
function Resolve-McpHeaderValue([string]$Value) {if($Value -match '^\$\{env:([^}]+)\}$'){return [Environment]::GetEnvironmentVariable($Matches[1])};return $Value}
function Invoke-McpWorkerSourceRpc($Source,[string]$Method,$Params=$null) {
    $headers=@{'Accept'='application/json, text/event-stream'};if($Source.PSObject.Properties['headers']-and$Source.headers){foreach($h in $Source.headers.PSObject.Properties){$v=Resolve-McpHeaderValue ([string]$h.Value);if($v){$headers[$h.Name]=$v}}}
    $body=[ordered]@{jsonrpc='2.0';id=[Guid]::NewGuid().ToString('N');method=$Method};if($null-ne$Params){$body.params=$Params};return Invoke-RestMethod -Method Post -Uri ([string]$Source.url) -Headers $headers -ContentType 'application/json' -Body ($body|ConvertTo-Json -Depth 30 -Compress) -TimeoutSec 60
}
function Get-McpWorkerSourceTools([string]$Name) {
    $catalog=Get-McpWorkerCatalog;$prop=$catalog.sources.PSObject.Properties[$Name];if($null-eq$prop){throw "Unknown worker tool source: $Name"};$source=$prop.Value
    if($source.PSObject.Properties['tools']-and$source.tools){return @($source.tools)}
    try{[void](Invoke-McpWorkerSourceRpc $source 'initialize' ([ordered]@{protocolVersion='2025-06-18';capabilities=[ordered]@{};clientInfo=[ordered]@{name='StatefulClanker-control';version='1'}}))}catch{}
    $r=Invoke-McpWorkerSourceRpc $source 'tools/list' ([ordered]@{});if($r.PSObject.Properties['error']-and$r.error){throw $r.error.message};return @($r.result.tools)
}

function New-SCExtendedTools {
    $base=@(& $script:SCBaseNewExtendedToolsWorkerPolicy)
    $base+=@(
      @{name='worker_policy_get';description='Inspect machine worker capabilities, external MCP tool sources, and the active project tighten-only policy.';inputSchema=@{type='object';properties=@{project=@{type='string'}}}},
      @{name='worker_policy_apply';description='Replace the active project worker capability policy. Project policy may only narrow machine-authorized capabilities. Use deny for tools workers must never see.';inputSchema=@{type='object';properties=@{project=@{type='string'};policy=@{type='object'}};required=@('policy')}},
      @{name='worker_source_set';description='Register/update a machine-local MCP tool source for inherent workers. HTTP/Streamable HTTP only. Headers should use ${env:NAME} for secrets. Optionally add machine allow patterns.';inputSchema=@{type='object';properties=@{name=@{type='string'};source=@{type='object'};allow=@{type='array';items=@{type='string'}}};required=@('name','source')}},
      @{name='worker_source_remove';description='Remove a machine-local inherent-worker MCP tool source and its matching explicit allow entries.';inputSchema=@{type='object';properties=@{name=@{type='string'}};required=@('name')}},
      @{name='worker_source_tools';description='List/discover tools exposed by a configured inherent-worker MCP source. This does not grant them.';inputSchema=@{type='object';properties=@{name=@{type='string'}};required=@('name')}}
    )
    return $base
}
function Invoke-SCExtendedTool([string]$Name,$Arguments) {
    if(@('worker_policy_get','worker_policy_apply','worker_source_set','worker_source_remove','worker_source_tools') -notcontains $Name){return & $script:SCBaseInvokeExtendedToolWorkerPolicy $Name $Arguments}
    $project=Get-McpProject $Arguments;Assert-McpInitialized $project
    switch($Name){
      'worker_policy_get' {return New-McpTextResult ([ordered]@{machinePath=Get-McpWorkerMachinePolicyPath;machine=Get-McpWorkerCatalog;projectPath=Join-Path (Get-McpStateDir $project) 'worker-policy.json';projectPolicy=Get-McpWorkerProjectPolicy $project;inheritance='machine grants; project/role/stage/task may only tighten'})}
      'worker_policy_apply' {
        if(-not$Arguments.PSObject.Properties['policy']-or$null-eq$Arguments.policy){throw 'policy required'};$catalog=Get-McpWorkerCatalog;Assert-McpProjectPolicyTightens $Arguments.policy $catalog
        $policy=$Arguments.policy;if(-not$policy.PSObject.Properties['schemaVersion']){$policy|Add-Member schemaVersion 1 -Force};$path=Join-Path (Get-McpStateDir $project) 'worker-policy.json';Write-McpWorkerJson $path $policy;Add-McpWorkerAudit 'project-policy-apply' @{project=$project;policy=$policy};return New-McpTextResult ([ordered]@{updated=$true;path=$path;policy=$policy})
      }
      'worker_source_set' {
        $sourceName=Get-McpArgRequired $Arguments 'name';if($sourceName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'){throw 'Invalid source name.'};if(-not$Arguments.PSObject.Properties['source']){throw 'source required'};$source=$Arguments.source
        $transport=if($source.PSObject.Properties['transport']){[string]$source.transport}else{'http'};if(@('http','streamable-http')-notcontains$transport){throw 'Inherent worker MCP sources currently support http/streamable-http.'};if(-not$source.PSObject.Properties['url']){throw 'source.url required'}
        $catalog=Get-McpWorkerCatalog;if($null-eq$catalog.sources){$catalog|Add-Member sources ([pscustomobject]@{}) -Force};$catalog.sources|Add-Member -NotePropertyName $sourceName -NotePropertyValue $source -Force
        if($Arguments.PSObject.Properties['allow']-and$Arguments.allow){$a=@($catalog.allow);foreach($pattern in @($Arguments.allow)){if($a -notcontains [string]$pattern){$a+=,[string]$pattern}};$catalog.allow=@($a)}
        Write-McpWorkerJson (Get-McpWorkerMachinePolicyPath) $catalog;Add-McpWorkerAudit 'source-set' @{name=$sourceName;source=$source;allow=@($Arguments.allow)};return New-McpTextResult ([ordered]@{updated=$true;source=$sourceName;machineAllow=@($catalog.allow)})
      }
      'worker_source_remove' {
        $sourceName=Get-McpArgRequired $Arguments 'name';$catalog=Get-McpWorkerCatalog;$prop=$catalog.sources.PSObject.Properties[$sourceName];if($prop){$catalog.sources.PSObject.Properties.Remove($sourceName)};$prefix="mcp.$sourceName.";$catalog.allow=@($catalog.allow|Where-Object{-not([string]$_).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)});$catalog.deny=@($catalog.deny|Where-Object{-not([string]$_).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)});Write-McpWorkerJson (Get-McpWorkerMachinePolicyPath) $catalog;Add-McpWorkerAudit 'source-remove' @{name=$sourceName};return New-McpTextResult ([ordered]@{removed=[bool]$prop;source=$sourceName})
      }
      'worker_source_tools' {$sourceName=Get-McpArgRequired $Arguments 'name';return New-McpTextResult ([ordered]@{source=$sourceName;tools=@(Get-McpWorkerSourceTools $sourceName);note='discovery only; authorization still requires machine allow and project policy'})}
    }
}
function Get-SCControlPlaneInstructions {
    $base=& $script:SCBaseControlInstructionsWorkerPolicy
    return $base+@'

WORKER CAPABILITIES AND EXTERNAL TOOLS

StatefulClanker's inherent/direct-model workers have a runtime capability policy. Treat it as part of deployment authority, separate from project Intent. Machine policy declares capabilities/tool sources that may exist; project/role/stage/task policy can only tighten access. Use worker_policy_get before changing tool exposure. Use worker_policy_apply to deny or narrow capabilities for a project. Do not broaden a project beyond the machine allow-list.

External Toaster/MemPalace-style services should be registered as MCP worker sources with worker_source_set. Prefer HTTP/Streamable HTTP and environment-variable header references for secrets. Discover with worker_source_tools, then explicitly grant only the required mcp.<source>.<tool> capabilities at machine level and leave project policy no broader than necessary. APM-style least privilege is intentional: a package/source existing does not imply every worker should see every tool.

Human authority is deliberately exposed to inherent workers through separate read-only capabilities: intent.human.read reads the preserved direct source artifact, while intent.normalized.read reads the conversational/orchestrator interpretation plus current directive snapshot. Keeping both lets a worker compare interpretation against direct evidence without gaining authority to rewrite either.
'@
}

<# MCP dual-era contract tests. Transport header validation is exercised by the
   Windows HTTP smoke path; this file verifies transport-independent era dispatch. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot;$harness=Join-Path $repo 'StatefulClanker.ps1'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "MCP MODERN TEST FAILED: $Message"}}
function New-ModernMeta { return [pscustomobject]@{'io.modelcontextprotocol/protocolVersion'='2026-07-28';'io.modelcontextprotocol/clientCapabilities'=[pscustomobject]@{};'io.modelcontextprotocol/clientInfo'=[pscustomobject]@{name='statefulclanker-test';version='1'}} }
function Get-ToolPayload($Response){if($Response.result.PSObject.Properties['isError']-and$Response.result.isError){throw "Tool error: $($Response.result.content[0].text)"};return($Response.result.content[0].text|ConvertFrom-Json)}
function Call-Tool([int]$Id,[string]$Name,$Arguments){if($null-eq$Arguments){$Arguments=[pscustomobject]@{}};$params=[pscustomobject]@{name=$Name;arguments=$Arguments;_meta=New-ModernMeta};return Invoke-McpRpc ([pscustomobject]@{jsonrpc='2.0';id=$Id;method='tools/call';params=$params})}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-mcp-modern-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $temp|Out-Null
$oldLocal=$env:LOCALAPPDATA;$env:LOCALAPPDATA=Join-Path $temp 'local';New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA|Out-Null
try {
    Push-Location $temp;& $harness init|Out-Null;& $harness goal -Message 'Exercise dual-era MCP intent and event flow.'|Out-Null;Pop-Location
    . (Join-Path $repo 'mcp\StatefulClanker.McpCore.ps1');. (Join-Path $repo 'mcp\StatefulClanker.McpExtensions.ps1');. (Join-Path $repo 'mcp\StatefulClanker.BackendInstructions.ps1');. (Join-Path $repo 'mcp\StatefulClanker.McpWorkerPolicy.ps1');. (Join-Path $repo 'mcp\StatefulClanker.McpProtocol.ps1');Set-McpDefaultProject $temp

    Write-Host '  MCP MODERN 1: server/discover advertises the modern era without legacy handshake state'
    $discover=Invoke-McpRpc ([pscustomobject]@{jsonrpc='2.0';id='d1';method='server/discover';params=[pscustomobject]@{_meta=New-ModernMeta}})
    Assert-True (@($discover.result.supportedVersions)-contains'2026-07-28') 'server/discover does not advertise 2026-07-28.'
    Assert-True ([bool]$discover.result.capabilities.resources.subscribe) 'Modern discovery should advertise subscription resource updates.'
    Assert-True ([string]$discover.result.instructions-match'Aggressively clarify material ambiguity') 'Control-plane instructions do not emphasize aggressive human clarification.'
    Assert-True ($null-ne$discover.result._meta.'io.modelcontextprotocol/serverInfo') 'Modern discover result lacks serverInfo response metadata.'
    Assert-True (-not$discover.result.PSObject.Properties['serverInfo']) 'Modern discover should not use the legacy/body serverInfo field.'

    Write-Host '  MCP MODERN 2: legacy initialize remains legacy; modern initialize is rejected'
    $legacy=Invoke-McpRpc ([pscustomobject]@{jsonrpc='2.0';id=1;method='initialize';params=[pscustomobject]@{}})
    Assert-True (-not[bool]$legacy.result.capabilities.resources.subscribe) 'Legacy initialize falsely advertises legacy resources/subscribe.'
    $modernInit=Invoke-McpRpc ([pscustomobject]@{jsonrpc='2.0';id='mi';method='initialize';params=[pscustomobject]@{_meta=New-ModernMeta}})
    Assert-True ([int]$modernInit.error.code-eq-32601) 'Modern initialize should fail as an era-mismatched method.'

    Write-Host '  MCP MODERN 3: modern tools/resources carry server identity and capability authoring'
    $tools=Invoke-McpRpc ([pscustomobject]@{jsonrpc='2.0';id=2;method='tools/list';params=[pscustomobject]@{_meta=New-ModernMeta}});$names=@($tools.result.tools|ForEach-Object{[string]$_.name})
    foreach($required in @('directive_set','directive_list','intent_apply','control_events_since','control_snapshot','worker_policy_get','worker_profile_set','autofill_status','autofill_control')){Assert-True ($names-contains$required) "Missing tool $required."}
    Assert-True ($null-ne$tools.result._meta.'io.modelcontextprotocol/serverInfo') 'Modern tools/list lacks serverInfo response metadata.'
    $task=@($tools.result.tools|Where-Object { $_.name -eq 'task_add' }|Select-Object -First 1)[0];Assert-True ($null-ne$task.inputSchema.properties.capabilityProfile) 'task_add lacks capabilityProfile.';Assert-True ($null-ne$task.inputSchema.properties.toolAllow) 'task_add lacks toolAllow.'
    $wp=Get-ToolPayload (Call-Tool 21 'worker_policy_get' ([pscustomobject]@{}));Assert-True ($null-ne$wp.machine) 'worker_policy_get did not return machine policy.'
    $af=Get-ToolPayload (Call-Tool 22 'autofill_status' ([pscustomobject]@{}));Assert-True (-not[bool]$af.running) 'autofill_status unexpectedly showed running in test dir.'
    $ctrl=Get-ToolPayload (Call-Tool 23 'autofill_control' ([pscustomobject]@{action='pause'}));Assert-True ([bool]$ctrl.success) 'autofill_control pause failed.'
    $resources=Invoke-McpRpc ([pscustomobject]@{jsonrpc='2.0';id=3;method='resources/list';params=[pscustomobject]@{_meta=New-ModernMeta}});$uris=@($resources.result.resources|ForEach-Object{[string]$_.uri});Assert-True ($uris-contains'statefulclanker://project/current/control-events') 'Missing control-events resource.'

    Write-Host '  MCP MODERN 4: current directive change blocks until intent_apply reconciles'
    $set=Get-ToolPayload (Call-Tool 4 'directive_set' ([pscustomobject]@{id='ui-project-selection';text='Restore the exact last active project; never silently substitute a different project.';scope='desktop.project-selection';intentRefs=@('REQ-PROJECT-RESTORE')}));Assert-True ([bool]$set.requiresIntentReconciliation) 'directive_set did not report reconciliation requirement.'
    $snapshot=Get-ToolPayload (Call-Tool 5 'control_snapshot' ([pscustomobject]@{}));Assert-True ([bool]$snapshot.directiveReconciliationRequired) 'Snapshot did not show directive reconciliation gate.'
    $contract=[pscustomobject]@{objective='Exercise dual-era MCP intent and event flow.';requirements=@('REQ-PROJECT-RESTORE: restore exact last active project and never silently substitute another.');constraints=@();invariants=@();nonGoals=@();decisions=@();preferences=@();openQuestions=@();successDefinition='Project selection follows current human directive.'}
    $applied=Get-ToolPayload (Call-Tool 6 'intent_apply' ([pscustomobject]@{contract=$contract;reason='Reconciled direct human project-selection directive.'}));Assert-True ([bool]$applied.reconciliationCleared) 'intent_apply did not clear reconciliation gate.'

    Write-Host '  MCP MODERN 5: durable control events resume from a cursor'
    $events=Get-ToolPayload (Call-Tool 8 'control_events_since' ([pscustomobject]@{since=0;limit=200}));Assert-True ([long]$events.cursor-gt0) 'Control cursor did not advance.';Assert-True (@($events.events|Where-Object{$_.type-eq'directive.reconciliation_required'-and$_.level-eq'human_required'}).Count-ge1) 'Missing HUMAN_REQUIRED directive event.'
    $tail=Get-ToolPayload (Call-Tool 9 'control_events_since' ([pscustomobject]@{since=[long]$events.cursor;limit=20}));Assert-True (@($tail.events).Count-eq0) 'Cursor resume returned already-consumed events.'
    Write-Host 'PASS: explicit legacy/modern MCP dispatch, current directives, capability tools, and durable events.'
} finally {if((Get-Location).Path-eq$temp){Pop-Location};$env:LOCALAPPDATA=$oldLocal;Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}

<# MCP 2026-07-28 discovery/resource tests plus directive/control-plane tools.
   Subscription transport itself is exercised on Windows by connecting to
   subscriptions/listen; this test verifies the transport-independent contract. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$harness=Join-Path $repo 'StatefulClanker.ps1'

function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "MCP MODERN TEST FAILED: $Message"}}
function Get-ToolPayload($Response){
    if($Response.result.PSObject.Properties['isError']-and$Response.result.isError){throw "Tool error: $($Response.result.content[0].text)"}
    return ($Response.result.content[0].text|ConvertFrom-Json)
}
function Call-Tool([int]$Id,[string]$Name,$Arguments){
    return Invoke-McpRpc ([pscustomobject]@{jsonrpc='2.0';id=$Id;method='tools/call';params=[pscustomobject]@{name=$Name;arguments=$Arguments}})
}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-mcp-modern-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try {
    Push-Location $temp
    & $harness init|Out-Null
    & $harness goal -Message 'Exercise modern MCP intent and event flow.'|Out-Null
    Pop-Location

    . (Join-Path $repo 'mcp\StatefulClanker.McpCore.ps1')
    . (Join-Path $repo 'mcp\StatefulClanker.McpExtensions.ps1')
    . (Join-Path $repo 'mcp\StatefulClanker.McpProtocol.ps1')
    Set-McpDefaultProject $temp

    Write-Host '  MCP MODERN 1: server/discover advertises modern subscriptions'
    $discover=Invoke-McpRpc ([pscustomobject]@{jsonrpc='2.0';id='d1';method='server/discover';params=[pscustomobject]@{}})
    Assert-True (@($discover.result.supportedVersions) -contains '2026-07-28') 'server/discover does not advertise 2026-07-28.'
    Assert-True ([bool]$discover.result.capabilities.resources.subscribe) 'Modern discovery should advertise subscriptions/listen resource updates.'
    Assert-True ([string]$discover.result.instructions -match 'Aggressively clarify material ambiguity') 'Control-plane instructions do not emphasize aggressive human clarification.'

    Write-Host '  MCP MODERN 2: legacy initialize does not falsely advertise resources/subscribe'
    $legacy=Invoke-McpRpc ([pscustomobject]@{jsonrpc='2.0';id=1;method='initialize';params=[pscustomobject]@{}})
    Assert-True (-not[bool]$legacy.result.capabilities.resources.subscribe) 'Legacy initialize falsely advertises legacy resources/subscribe.'

    Write-Host '  MCP MODERN 3: directive and event tools/resources are present'
    $tools=Invoke-McpRpc ([pscustomobject]@{jsonrpc='2.0';id=2;method='tools/list';params=[pscustomobject]@{}})
    $names=@($tools.result.tools|ForEach-Object{[string]$_.name})
    foreach($required in @('directive_set','directive_list','directive_history','intent_apply','control_events_since','control_snapshot')){Assert-True ($names -contains $required) "Missing tool $required."}
    $resources=Invoke-McpRpc ([pscustomobject]@{jsonrpc='2.0';id=3;method='resources/list';params=[pscustomobject]@{}})
    $uris=@($resources.result.resources|ForEach-Object{[string]$_.uri})
    Assert-True ($uris -contains 'statefulclanker://project/current/control-events') 'Missing control-events resource.'
    Assert-True ($uris -contains 'statefulclanker://project/current/directives') 'Missing current-directives resource.'

    Write-Host '  MCP MODERN 4: current directive change blocks until intent_apply reconciles'
    $set=Get-ToolPayload (Call-Tool 4 'directive_set' ([pscustomobject]@{id='ui-project-selection';text='Restore the exact last active project; never silently substitute a different project.';scope='desktop.project-selection';intentRefs=@('REQ-PROJECT-RESTORE')}))
    Assert-True ([bool]$set.requiresIntentReconciliation) 'directive_set did not report reconciliation requirement.'
    $snapshot=Get-ToolPayload (Call-Tool 5 'control_snapshot' ([pscustomobject]@{}))
    Assert-True ([bool]$snapshot.directiveReconciliationRequired) 'Snapshot did not show directive reconciliation gate.'
    Assert-True (@($snapshot.currentDirectives).Count -eq 1) 'Snapshot should contain one current directive.'

    $contract=[pscustomobject]@{
        objective='Exercise modern MCP intent and event flow.'
        requirements=@('REQ-PROJECT-RESTORE: restore exact last active project and never silently substitute another.')
        constraints=@();invariants=@();nonGoals=@();decisions=@();preferences=@();openQuestions=@();successDefinition='Project selection follows current human directive.'
    }
    $applied=Get-ToolPayload (Call-Tool 6 'intent_apply' ([pscustomobject]@{contract=$contract;reason='Reconciled direct human project-selection directive.'}))
    Assert-True ([bool]$applied.reconciliationCleared) 'intent_apply did not clear reconciliation gate.'
    $snapshot2=Get-ToolPayload (Call-Tool 7 'control_snapshot' ([pscustomobject]@{}))
    Assert-True (-not[bool]$snapshot2.directiveReconciliationRequired) 'Reconciliation gate remained after intent_apply.'
    Assert-True ([int]$snapshot2.intent.directiveRevision -eq [int]$snapshot2.directiveRevision) 'Intent is not bound to current directive revision.'

    Write-Host '  MCP MODERN 5: durable control events can be resumed from a cursor'
    $events=Get-ToolPayload (Call-Tool 8 'control_events_since' ([pscustomobject]@{since=0;limit=200}))
    Assert-True ([long]$events.cursor -gt 0) 'Control cursor did not advance.'
    Assert-True (@($events.events|Where-Object{$_.type-eq'directive.reconciliation_required'-and$_.level-eq'human_required'}).Count -ge 1) 'Missing HUMAN_REQUIRED directive event.'
    $tail=Get-ToolPayload (Call-Tool 9 'control_events_since' ([pscustomobject]@{since=[long]$events.cursor;limit=20}))
    Assert-True (@($tail.events).Count -eq 0) 'Cursor resume returned already-consumed events.'

    Write-Host '  MCP MODERN 6: current-directive resource excludes history by construction'
    $read=Invoke-McpRpc ([pscustomobject]@{jsonrpc='2.0';id=10;method='resources/read';params=[pscustomobject]@{uri='statefulclanker://project/current/directives'}})
    $body=$read.result.contents[0].text|ConvertFrom-Json
    Assert-True (@($body.directives).Count -eq 1) 'Current-directives resource returned unexpected records.'
    Assert-True ([string]$body.authority -match 'current only') 'Resource does not clearly identify current-only authority.'

    Write-Host 'PASS: modern discovery, current directives, intent reconciliation, and durable event cursor.'
}
finally {
    if((Get-Location).Path -eq $temp){Pop-Location}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

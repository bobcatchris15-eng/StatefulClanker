<# Current-directive + control-event tests. No real model/provider required. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$harness=Join-Path $repo 'StatefulClanker.ps1'

function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "DIRECTIVE/EVENT TEST FAILED: $Message"}}
function New-IntentFile([string]$Path,[string]$Objective,[string]$Requirement){
    [ordered]@{objective=$Objective;requirements=@($Requirement);constraints=@();invariants=@();nonGoals=@();decisions=@();preferences=@();openQuestions=@();successDefinition='Directive intent is reconciled.'}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $Path -Encoding UTF8
}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-directives-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
Push-Location $temp
try {
    Write-Host '  DIRECTIVE 1: initialize and establish first current directive'
    & $harness init|Out-Null
    & $harness goal -Message 'Preserve latest human launcher intent.'|Out-Null
    & $harness directive set -DirectiveId launcher-types -Message 'Launcher types are turreted and external racks.' -Scope 'weapons.launchers' -IntentRef 'REQ-LAUNCHER'|Out-Null
    $currentPath=Join-Path $temp '.statefulclanker\directives\current\launcher-types.json'
    $d1=Get-Content -Raw -LiteralPath $currentPath|ConvertFrom-Json
    $oldRef=[string]$d1.sourceRef
    Assert-True ($d1.revision -eq 1) 'First directive revision should be 1.'
    Assert-True ($d1.text -match 'external racks') 'First directive text was not preserved.'
    Assert-True (Test-Path -LiteralPath (Join-Path $temp ('.statefulclanker\input\'+(($oldRef -split ':')[1])+'.txt'))) 'Directive source artifact is missing.'
    $state=Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\state.json')|ConvertFrom-Json
    Assert-True ([bool]$state.directiveReconciliationRequired) 'Directive change must require Intent reconciliation.'

    Write-Host '  DIRECTIVE 2: reconcile normalized Intent and create a governed task'
    $intent1=Join-Path $temp 'intent1.json';New-IntentFile $intent1 'Preserve latest human launcher intent.' 'REQ-LAUNCHER: expose turreted launchers and external racks.'
    & $harness intent replace -Path $intent1 -Reason 'Initial directive reconciliation.'|Out-Null
    $state=Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\state.json')|ConvertFrom-Json
    Assert-True (-not[bool]$state.directiveReconciliationRequired) 'Intent replace should clear reconciliation gate.'
    Assert-True ([int]$state.directiveReconciledRevision -eq [int]$state.directiveRevision) 'Intent did not bind to current directive revision.'
    & $harness task add -TaskId launcher-task -Title 'Implement launchers' -Instruction 'Implement launcher catalog.' -Accept 'Matches current launcher intent' -Source $oldRef -IntentRef 'REQ-LAUNCHER'|Out-Null

    Write-Host '  DIRECTIVE 3: supersede directive; latest word wins and affected task becomes stale'
    & $harness directive set -DirectiveId launcher-types -Message 'Launcher types are turreted and cell or tube arrays. External racks are not a launcher category.' -Scope 'weapons.launchers' -IntentRef 'REQ-LAUNCHER' -Reason 'Human replaced the earlier launcher taxonomy.'|Out-Null
    $d2=Get-Content -Raw -LiteralPath $currentPath|ConvertFrom-Json
    Assert-True ($d2.revision -eq 2) 'Current directive did not advance to revision 2.'
    Assert-True ($d2.text -notmatch '^Launcher types are turreted and external racks') 'Old wording remained current.'
    Assert-True ([string]$d2.sourceRef -ne $oldRef) 'Superseding direct human wording should have a new source artifact.'
    Assert-True (Test-Path -LiteralPath (Join-Path $temp '.statefulclanker\directives\history\launcher-types\revision-0001.json')) 'Superseded revision was not retained as audit history.'
    $task=Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\tasks\launcher-task.json')|ConvertFrom-Json
    Assert-True ($task.status -eq 'stale') 'Task governed by changed Intent ref should be marked stale.'

    Write-Host '  DIRECTIVE 3b: unreconciled authority blocks dispatch before mutating task state'
    $blocked=$false
    try { & $harness run -TaskId launcher-task|Out-Null } catch { $blocked=$true }
    Assert-True $blocked 'Dispatch should fail while current directives await Intent reconciliation.'
    $taskAfter=Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\tasks\launcher-task.json')|ConvertFrom-Json
    Assert-True ($taskAfter.status -eq 'stale') 'Dispatch guard changed task state before rejecting unreconciled authority.'

    Write-Host '  DIRECTIVE 4: control inbox is sequenced and HUMAN_REQUIRED for reconciliation'
    $events=@(Get-Content -LiteralPath (Join-Path $temp '.statefulclanker\control\events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json})
    Assert-True ($events.Count -gt 0) 'Control event inbox is empty.'
    for($i=1;$i-lt$events.Count;$i++){Assert-True ([long]$events[$i].sequence -gt [long]$events[$i-1].sequence) 'Control event sequence is not strictly increasing.'}
    Assert-True (@($events|Where-Object{$_.type-eq'directive.reconciliation_required'-and$_.level-eq'human_required'}).Count -ge 1) 'Directive reconciliation did not produce HUMAN_REQUIRED control event.'

    Write-Host '  DIRECTIVE 5: reconcile again and verify superseded source is excluded from worker packet'
    $intent2=Join-Path $temp 'intent2.json';New-IntentFile $intent2 'Preserve latest human launcher intent.' 'REQ-LAUNCHER: expose turreted and cell/tube array launchers; external racks are not a launcher category.'
    & $harness intent replace -Path $intent2 -Reason 'Reconciled superseding launcher directive.'|Out-Null

    # Load the runtime in this process so retrieval/compilation can be inspected without dispatching a provider.
    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Eventing.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Context.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Plan.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Directives.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Semantics.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Execution.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Routing.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Intent.ps1')
    Set-SCRoots $temp $temp
    $task=Get-SCTask 'launcher-task'
    $retrieval=Get-SCRetrievalPacket $task
    Assert-True (@($retrieval.items|Where-Object{[string]$_.selector-eq$oldRef}).Count -eq 0) 'Superseded directive source leaked into normal retrieval.'
    $comp=New-SCCompilation $task
    Assert-True (@($comp.ir.project.humanDirectives.items).Count -eq 1) 'Worker packet should contain exactly the current launcher directive.'
    Assert-True ([string]$comp.ir.project.humanDirectives.items[0].text -match 'cell or tube arrays') 'Worker packet does not contain latest direct human wording.'
    Assert-True (@($comp.ir.task.sources) -notcontains $oldRef) 'Compiled task metadata still exposes superseded directive source.'
    Assert-True ([int]$comp.readSet.directiveRevision -eq [int](Get-SCDirectiveRevision)) 'Compilation did not fingerprint current directive revision.'

    Write-Host 'PASS: current directives supersede history, Intent reconciliation gates dispatch, and control events persist.'
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

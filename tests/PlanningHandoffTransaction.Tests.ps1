$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$harness=Join-Path $repo 'StatefulClanker.ps1'
$plannerProject=Join-Path $repo 'src\StatefulClanker.Planner\StatefulClanker.Planner.csproj'
$dotnet=Get-Command dotnet -ErrorAction SilentlyContinue
if(-not$dotnet){throw 'dotnet SDK is required for PlanningHandoffTransaction.Tests.ps1'}

function Assert-True([bool]$Condition,[string]$Message){
    if(-not$Condition){throw "PLANNING HANDOFF TRANSACTION TEST FAILED: $Message"}
}
function Read-Json([string]$Path){Get-Content -Raw -LiteralPath $Path|ConvertFrom-Json}
function Write-Json([string]$Path,$Value){
    $parent=Split-Path -Parent $Path;if($parent-and-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
    $Value|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $Path -Encoding UTF8
}
function Invoke-Planner([string[]]$Args){
    $raw=& $dotnet.Source run --project $plannerProject -- @Args 2>&1|Out-String
    if($LASTEXITCODE-ne0){throw "Planner command failed: $raw"}
    $response=$raw|ConvertFrom-Json
    if(-not[bool]$response.ok){throw "Planner returned failure: $($response.error)"}
    return $response.data
}
function Invoke-HarnessJson([string[]]$Args){
    $raw=& $harness @Args 2>&1|Out-String
    if($LASTEXITCODE-ne0){throw "Harness command failed: $raw"}
    $lines=@($raw -split [Environment]::NewLine|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
    if($lines.Count-eq0){throw "Harness command produced no JSON: $($Args -join ' ')"}
    return ($lines[-1]|ConvertFrom-Json)
}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-planning-handoff-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
$stateRoot=Join-Path $temp '.statefulclanker'

try {
    Push-Location $temp
    try {
        Write-Host '  REPLAN TX 1: initialize old accepted reality'
        & $harness init|Out-Null
        & $harness goal -Message 'Exercise transactional replanning.'|Out-Null

        & $harness directive set -DirectiveId 'behavior-selection' -Message 'Use the original behavior.' -Scope 'behavior-selection' -IntentRef 'REQ-CHANGE'|Out-Null

        $oldIntent=[pscustomobject]@{
            objective='Exercise transactional replanning.'
            requirements=@(
                'REQ-KEEP: Preserve the already completed stable behavior.'
                'REQ-CHANGE: Use the original behavior.'
            )
            constraints=@()
            invariants=@()
            nonGoals=@()
            decisions=@()
            preferences=@()
            openQuestions=@()
            successDefinition='Replacement graph accurately represents current intended reality.'
        }
        $oldIntentPath=Join-Path $temp 'intent-old.json'
        Write-Json $oldIntentPath $oldIntent
        & $harness intent replace -Path $oldIntentPath -Reason 'Seed transaction test intent.'|Out-Null

        $oldPlanPath=Join-Path $temp 'old.scplan'
        @'
SCPLAN 1
plan old-plan
summary Seed graph for transactional replan.

task t-keep
title Stable completed task
instruction Establish the stable behavior.
size small
intent REQ-KEEP
accept stable behavior exists
end

task t-change
title Behavior that will be reinterpreted
instruction Implement the behavior selected by current Intent.
size small
intent REQ-CHANGE
depends t-keep
accept selected behavior exists
end

task t-drop
title Obsolete pending task
instruction Implement behavior that the replan will remove.
size small
accept obsolete behavior exists
end
'@|Set-Content -LiteralPath $oldPlanPath -Encoding UTF8
        & $harness plan import -Path $oldPlanPath|Out-Null
        & $harness complete -TaskId 't-keep'|Out-Null

        $oldState=Read-Json (Join-Path $stateRoot 'state.json')
        $oldPlanId=[string]$oldState.activePlanId
        Assert-True (-not[string]::IsNullOrWhiteSpace($oldPlanId)) 'Initial active plan was not created.'
        Assert-True ([string](Read-Json (Join-Path $stateRoot 'tasks\t-keep.json')).status-eq'complete') 'Seed completion failed.'

        Write-Host '  REPLAN TX 2: freeze baseline and stage replacement future'
        $begin=Invoke-Planner @('begin','--project',$temp,'--reason','transaction integration test')
        $settled=Invoke-Planner @('settle','--project',$temp)
        Assert-True ([bool]$settled.settled) 'Planner did not settle.'
        $baselinePath=Join-Path $temp ([string]$settled.baseline).Replace('/',[IO.Path]::DirectorySeparatorChar)
        $baseline=Read-Json $baselinePath
        Assert-True (-not[string]::IsNullOrWhiteSpace([string]$baseline.snapshotPath)) 'Frozen baseline snapshot was not recorded.'

        $cliBlocked=$false
        try{& $harness directive set -DirectiveId 'behavior-selection' -Message 'This must not mutate live planning state.'|Out-Null}catch{$cliBlocked=$_.Exception.Message -match 'planning owns the project'}
        Assert-True $cliBlocked 'Direct CLI semantic mutation bypassed the planning freeze.'

        $newIntent=[pscustomobject]@{
            objective='Exercise transactional replanning.'
            requirements=@(
                'REQ-KEEP: Preserve the already completed stable behavior.'
                'REQ-CHANGE: Use the replacement behavior.'
            )
            constraints=@()
            invariants=@()
            nonGoals=@()
            decisions=@()
            preferences=@()
            openQuestions=@()
            successDefinition='Replacement graph accurately represents current intended reality.'
        }
        $newIntentPath=Join-Path $temp 'intent-new.json'
        Write-Json $newIntentPath $newIntent

        $directiveChangesPath=Join-Path $temp 'directive-changes.json'
        Write-Json $directiveChangesPath ([pscustomobject]@{
            changes=@(
                [pscustomobject]@{
                    action='set'
                    id='behavior-selection'
                    scope='behavior-selection'
                    text='Use the replacement behavior.'
                    intentRefs=@('REQ-CHANGE')
                    reason='Transaction test changes the direct human behavior choice.'
                }
            )
        })

        $newPlanPath=Join-Path $temp 'new.scplan'
        @'
SCPLAN 1
plan replacement-plan
summary Replace active graph while preserving only still-valid completion.

task t-keep
title Stable completed task
instruction Establish the stable behavior.
size small
intent REQ-KEEP
accept stable behavior exists
end

task t-change
title Behavior that will be reinterpreted
instruction Implement the behavior selected by current Intent.
size small
intent REQ-CHANGE
depends t-keep
accept selected behavior exists
end

task t-new
title Newly required task
instruction Implement the newly required behavior.
size small
depends t-keep
accept new behavior exists
end
'@|Set-Content -LiteralPath $newPlanPath -Encoding UTF8

        $candidate=Invoke-Planner @(
            'candidate','--project',$temp,
            '--plan',$newPlanPath,
            '--intent',$newIntentPath,
            '--directives',$directiveChangesPath,
            '--goal','Replacement transaction project goal.',
            '--summary','replacement transaction integration candidate')
        $handoff=Invoke-Planner @('accept','--project',$temp,'--candidate',[string]$candidate.id)
        $handoffPath=Join-Path $stateRoot ("planning\sessions\{0}\handoffs\{1}.json"-f$begin.sessionId,$handoff.id)

        Write-Host '  REPLAN TX 3: refuse stale baseline before touching live graph'
        $keepPath=Join-Path $stateRoot 'tasks\t-keep.json'
        $keepBytes=[IO.File]::ReadAllBytes($keepPath)
        $keep=([Text.Encoding]::UTF8.GetString($keepBytes)|ConvertFrom-Json)
        $keep.blockReason='external drift injected by test'
        Write-Json $keepPath $keep

        $failed=$false
        try{& $harness plan apply-handoff -Path $handoffPath|Out-Null}catch{$failed=$_.Exception.Message -match 'baseline drift'}
        Assert-True $failed 'Handoff apply did not refuse a task-graph change after settle.'
        [IO.File]::WriteAllBytes($keepPath,$keepBytes)

        Write-Host '  REPLAN TX 4: atomically replace graph and classify old work'
        $result=Invoke-HarnessJson @('plan','apply-handoff','-Path',$handoffPath)
        Assert-True ([string]$result.replacedPlanId-eq$oldPlanId) 'Transaction did not identify replaced plan.'
        Assert-True (@($result.preservedComplete)-contains't-keep') 'Still-valid completed task was not preserved.'
        Assert-True (@($result.replacedTasks)-contains't-change') 'Intent-invalidated task was not replaced.'
        Assert-True (@($result.newTasks)-contains't-new') 'New task was not classified as new.'
        Assert-True (@($result.retiredTasks)-contains't-drop') 'Omitted old task was not retired from active graph.'
        Assert-True ([bool]$result.goalChanged) 'Staged project goal was not part of the transaction.'
        Assert-True (@($result.directiveChanges).Count-eq1) 'Staged directive change was not part of the transaction.'

        $newState=Read-Json (Join-Path $stateRoot 'state.json')
        Assert-True ([string]$newState.activePlanId-eq[string]$result.appliedPlanId) 'activePlanId does not match committed transaction.'
        Assert-True ([string]$newState.goal-eq'Replacement transaction project goal.') 'Project goal was not committed transactionally.'
        Assert-True (-not[bool]$newState.directiveReconciliationRequired) 'Transaction left directives awaiting reconciliation.'
        $directiveNow=Read-Json (Join-Path $stateRoot 'directives\current\behavior-selection.json')
        Assert-True ([string]$directiveNow.text-eq'Use the replacement behavior.') 'Staged human directive was not committed.'

        $keepNow=Read-Json (Join-Path $stateRoot 'tasks\t-keep.json')
        $changeNow=Read-Json (Join-Path $stateRoot 'tasks\t-change.json')
        $newNow=Read-Json (Join-Path $stateRoot 'tasks\t-new.json')
        Assert-True ([string]$keepNow.status-eq'complete') 'Preserved completion lost complete status.'
        Assert-True ([string]$changeNow.status-eq'ready') 'Changed task should be ready because preserved prerequisite is complete.'
        Assert-True ([int]$changeNow.attemptCount-eq0) 'Changed task inherited attempts from obsolete execution history.'
        Assert-True ([string]$newNow.status-eq'ready') 'New task should be ready because preserved prerequisite is complete.'
        Assert-True (-not(Test-Path -LiteralPath (Join-Path $stateRoot 'tasks\t-drop.json'))) 'Omitted task remained in active graph.'

        $journal=Read-Json (Join-Path $stateRoot ("transactions\{0}\journal.json"-f$result.transactionId))
        Assert-True ([string]$journal.status-eq'committed') 'Transaction journal did not reach committed.'
        Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot ("transactions\{0}\backup\tasks\t-drop.json"-f$result.transactionId))) 'Retired task was not retained in transaction backup.'

        Write-Host '  REPLAN TX 5: committed handoff is idempotent until Planner release'
        $again=Invoke-HarnessJson @('plan','apply-handoff','-Path',$handoffPath)
        Assert-True ([string]$again.transactionId-eq[string]$result.transactionId) 'Retry created a second transaction for same handoff.'
        Assert-True ([string]$again.appliedPlanId-eq[string]$result.appliedPlanId) 'Retry changed applied plan id.'

        $released=Invoke-Planner @('release','--project',$temp,'--handoff',[string]$handoff.id,'--applied-plan-id',[string]$result.appliedPlanId)
        Assert-True ([string]$released.status-eq'applied') 'Planner did not verify/release committed handoff.'
        Assert-True (-not(Test-Path -LiteralPath (Join-Path $stateRoot 'planning\active.json'))) 'Planning barrier survived release.'

        Write-Host '  REPLAN TX 6: recover a crash that removed state.json mid-commit'
        $crashId='replan-crash-test'
        $crashDir=Join-Path $stateRoot ("transactions\{0}"-f$crashId)
        $crashBackup=Join-Path $crashDir 'backup'
        New-Item -ItemType Directory -Force -Path (Join-Path $crashBackup 'tasks')|Out-Null
        Copy-Item -LiteralPath (Join-Path $stateRoot 'state.json') -Destination (Join-Path $crashBackup 'state.json') -Force
        foreach($taskFile in @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'tasks') -Filter '*.json' -File)){
            Copy-Item -LiteralPath $taskFile.FullName -Destination (Join-Path $crashBackup 'tasks') -Force
        }

        $crashJournal=[pscustomobject]@{
            schemaVersion=1
            id=$crashId
            handoffId='synthetic-crash'
            sessionId='synthetic-crash'
            status='committing'
            targets=@(
                [pscustomobject]@{
                    name='tasks';livePath=(Join-Path $stateRoot 'tasks');stagePath=(Join-Path $crashDir 'stage\tasks')
                    backupPath=(Join-Path $crashBackup 'tasks');existed=$true
                },
                [pscustomobject]@{
                    name='state';livePath=(Join-Path $stateRoot 'state.json');stagePath=(Join-Path $crashDir 'stage\state.json')
                    backupPath=(Join-Path $crashBackup 'state.json');existed=$true
                }
            )
        }
        Write-Json (Join-Path $crashDir 'journal.json') $crashJournal

        Remove-Item -LiteralPath (Join-Path $stateRoot 'state.json') -Force
        Remove-Item -LiteralPath (Join-Path $stateRoot 'tasks') -Recurse -Force
        New-Item -ItemType Directory -Force -Path (Join-Path $stateRoot 'tasks')|Out-Null
        [pscustomobject]@{id='corrupt';status='ready'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $stateRoot 'tasks\corrupt.json') -Encoding UTF8

        & $harness status|Out-Null
        Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot 'state.json')) 'Startup recovery did not restore missing state.json.'
        Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot 'tasks\t-keep.json')) 'Startup recovery did not restore task graph.'
        Assert-True (-not(Test-Path -LiteralPath (Join-Path $stateRoot 'tasks\corrupt.json'))) 'Startup recovery left partially committed task state.'
        $recoveredJournal=Read-Json (Join-Path $crashDir 'journal.json')
        Assert-True ([string]$recoveredJournal.status-eq'rolled_back') 'Interrupted transaction was not marked rolled_back.'

        Write-Host 'PASS: transactional planning handoff preserves valid completion, replaces invalid work, retires obsolete nodes, is idempotent, and rolls back interrupted commits.'
    }
    finally {Pop-Location}
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

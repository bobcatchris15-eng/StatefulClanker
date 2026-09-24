<#
 Recovery evidence tests: checkpoint kinds (validation/repair/merge), the
 Get-SCRunEvidence helper, evidence-based failure classification, and
 stagnation reconciliation against reality.
#>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "RECOVERY EVIDENCE TEST FAILED: $Message"}}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-recovery-evidence-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
Push-Location $temp
try {
    if(-not(Get-Command git -ErrorAction SilentlyContinue)){throw 'git is required for recovery evidence tests.'}
    & git init -q
    & git config user.name 'StatefulClanker Test'
    & git config user.email 'statefulclanker-test@localhost'
    ".statefulclanker/"|Set-Content -LiteralPath '.gitignore' -Encoding UTF8
    "baseline"|Set-Content -LiteralPath 'artifact.txt' -Encoding UTF8
    & git add .gitignore artifact.txt
    & git commit -q -m 'baseline'
    if($LASTEXITCODE-ne0){throw 'Could not create test repository baseline.'}

    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    Set-SCRoots $temp $temp

    $stateDir=Join-Path $temp '.statefulclanker'
    New-Item -ItemType Directory -Force -Path $stateDir|Out-Null
    Write-SCJson (Join-Path $stateDir 'state.json') ([ordered]@{
        schemaVersion=4;revision=0;directionRevision=0;projectId='recovery-evidence-test';
        projectRoot=$temp;goal='';activePlanId=$null;planApproved=$true;
        createdAt=[datetimeoffset]::UtcNow.ToString('o');updatedAt=[datetimeoffset]::UtcNow.ToString('o')
    })
    ''|Set-Content -LiteralPath (Join-Path $stateDir 'events.jsonl') -Encoding UTF8

    function Invoke-SCProvider { throw 'CLI provider should not be called in RecoveryEvidence.Tests.' }
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')

    $task=[pscustomobject]@{id='recovery-task';title='recovery task';role='worker';outputKind='change'}
    $comp=[pscustomobject]@{id='compile-recovery-test';inputFingerprint='fingerprint'}
    $registry=@([pscustomobject]@{wireName='finish';capability='builtin.finish'})
    $sessionId='wsess-recovery'
    $session=New-SCWorkerSession $sessionId $task $comp 'make a material change' 'native' $registry
    Assert-True ([bool]$session.baselineCheckpointId) 'Session has no baseline checkpoint.'

    Write-Host '  RE 1: validation checkpoint records kind + metadata'
    $vcp=New-SCValidationCheckpoint $sessionId 'val-1' 'PASS'
    Assert-True ($null-ne$vcp) 'New-SCValidationCheckpoint returned null.'
    Assert-True ([string]$vcp.kind-eq'validation') 'Validation checkpoint kind mismatch.'
    Assert-True ([string]$vcp.metadata.validationId-eq'val-1') 'Validation checkpoint missing validationId metadata.'
    Assert-True ([string]$vcp.metadata.verdict-eq'PASS') 'Validation checkpoint missing verdict metadata.'

    Write-Host '  RE 2: repair checkpoint records kind + metadata'
    $rcp=New-SCRepairCheckpoint $sessionId 'val-2' 1
    Assert-True ($null-ne$rcp) 'New-SCRepairCheckpoint returned null.'
    Assert-True ([string]$rcp.kind-eq'repair') 'Repair checkpoint kind mismatch.'
    Assert-True ([int]$rcp.metadata.rejectCount-eq1) 'Repair checkpoint missing rejectCount metadata.'

    Write-Host '  RE 3: merge checkpoint records kind + metadata'
    $mcp=New-SCMergeCheckpoint $sessionId 'deadbeef' 'sc/task/recovery-task'
    Assert-True ($null-ne$mcp) 'New-SCMergeCheckpoint returned null.'
    Assert-True ([string]$mcp.kind-eq'merge') 'Merge checkpoint kind mismatch.'
    Assert-True ([string]$mcp.metadata.mergeCommit-eq'deadbeef') 'Merge checkpoint missing mergeCommit metadata.'
    Assert-True ([string]$mcp.metadata.branch-eq'sc/task/recovery-task') 'Merge checkpoint missing branch metadata.'

    $session=Get-SCWorkerSession $sessionId
    Assert-True ((@($session.checkpoints|Where-Object{$_.kind-eq'validation'})).Count-eq1) 'Expected exactly one validation checkpoint.'
    Assert-True ((@($session.checkpoints|Where-Object{$_.kind-eq'repair'})).Count-eq1) 'Expected exactly one repair checkpoint.'
    Assert-True ((@($session.checkpoints|Where-Object{$_.kind-eq'merge'})).Count-eq1) 'Expected exactly one merge checkpoint.'

    # Existing baseline/candidate-submit checkpoint kinds must be untouched.
    Assert-True ((@($session.checkpoints|Where-Object{$_.kind-eq'baseline'})).Count-eq1) 'Baseline checkpoint kind regression.'

    Write-Host '  RE 4: Get-SCRunEvidence counts changed files and lines against session baseline'
    "candidate-two`nsecond line"|Set-Content -LiteralPath 'artifact.txt' -Encoding UTF8
    $run=[pscustomobject]@{startedAt=([datetimeoffset]::UtcNow.AddSeconds(-5)).ToString('o');endedAt=[datetimeoffset]::UtcNow.ToString('o')}
    $evidence=Get-SCRunEvidence $run $sessionId $temp
    Assert-True ($evidence.diffAvailable) 'Evidence did not find a diff against baseline.'
    Assert-True ($evidence.filesChanged-ge1) "Expected at least one changed file, got $($evidence.filesChanged)."
    Assert-True ($evidence.linesChanged-ge1) "Expected at least one changed line, got $($evidence.linesChanged)."
    Assert-True ([bool]$evidence.materialChange) 'Evidence did not flag a material change.'
    Assert-True ($evidence.elapsedSeconds-gt0) 'Evidence did not compute elapsed seconds.'

    Write-Host '  RE 5: Get-SCRunEvidence reports no material change on an untouched tree'
    & git add -A; & git commit -q -m 'apply candidate change'
    $runNoChange=[pscustomobject]@{startedAt=([datetimeoffset]::UtcNow.AddSeconds(-1)).ToString('o');endedAt=[datetimeoffset]::UtcNow.ToString('o')}
    $evidenceNoChange=Get-SCRunEvidence $runNoChange $null $temp
    Assert-True (-not[bool]$evidenceNoChange.materialChange) 'Evidence incorrectly flagged a material change on a clean tree.'

    Write-Host 'All WorkerRuntime recovery-evidence checks passed.'
} finally {
    Pop-Location
    Remove-Item -Recurse -Force -LiteralPath $temp -ErrorAction SilentlyContinue
}

# --- Concurrency.ps1 evidence-based classifier tests (isolated, own git repo) ---
$temp2=Join-Path ([IO.Path]::GetTempPath()) ('sc-recovery-classifier-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp2|Out-Null
Push-Location $temp2
try {
    & git init -q
    & git config user.name 'StatefulClanker Test'
    & git config user.email 'statefulclanker-test@localhost'
    "baseline"|Set-Content -LiteralPath 'artifact.txt' -Encoding UTF8
    & git add artifact.txt
    & git commit -q -m 'baseline'

    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    Set-SCRoots $temp2 $temp2
    $stateDir=Join-Path $temp2 '.statefulclanker'
    New-Item -ItemType Directory -Force -Path $stateDir|Out-Null
    Write-SCJson (Join-Path $stateDir 'state.json') ([ordered]@{
        schemaVersion=4;revision=0;directionRevision=0;projectId='recovery-classifier-test';
        projectRoot=$temp2;goal='';activePlanId=$null;planApproved=$true;
        createdAt=[datetimeoffset]::UtcNow.ToString('o');updatedAt=[datetimeoffset]::UtcNow.ToString('o')
    })
    ''|Set-Content -LiteralPath (Join-Path $stateDir 'events.jsonl') -Encoding UTF8
    function Invoke-SCProvider { throw 'CLI provider should not be called in RecoveryEvidence.Tests classifier section.' }
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')

    Write-Host '  RE 6: classifier evidence -- nonzero exit + material change classifies completed-with-error'
    "changed"|Set-Content -LiteralPath 'artifact.txt' -Encoding UTF8
    $fastRun=[pscustomobject]@{startedAt=([datetimeoffset]::UtcNow.AddSeconds(-25)).ToString('o');endedAt=[datetimeoffset]::UtcNow.ToString('o')}
    $ev=Get-SCRunEvidence $fastRun $null $temp2
    $materialAndCandidate=[bool]$ev.materialChange -and [bool]$ev.candidateSubmitted
    $longRuntimeCoherentDiff=([double]$ev.elapsedSeconds -gt 20) -and [bool]$ev.materialChange
    Assert-True ($longRuntimeCoherentDiff) 'Long-running run with material diff did not classify as completed-with-error input.'

    Write-Host '  RE 7: classifier evidence -- fast failure with zero changes classifies no-op-failure'
    & git checkout -q -- artifact.txt
    $veryFastRun=[pscustomobject]@{startedAt=([datetimeoffset]::UtcNow.AddSeconds(-1)).ToString('o');endedAt=[datetimeoffset]::UtcNow.ToString('o')}
    $ev2=Get-SCRunEvidence $veryFastRun $null $temp2
    $fastNoChange=([double]$ev2.elapsedSeconds -lt 20) -and -not[bool]$ev2.materialChange
    Assert-True ($fastNoChange) 'Fast run with no changes did not classify as no-op-failure input.'

    Write-Host 'All Concurrency classifier evidence checks passed.'
} finally {
    Pop-Location
    Remove-Item -Recurse -Force -LiteralPath $temp2 -ErrorAction SilentlyContinue
}

# --- Execution.ps1 stagnation reconciliation tests ---
$temp3=Join-Path ([IO.Path]::GetTempPath()) ('sc-recovery-stagnation-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp3|Out-Null
Push-Location $temp3
try {
    & git init -q
    & git config user.name 'StatefulClanker Test'
    & git config user.email 'statefulclanker-test@localhost'
    "baseline"|Set-Content -LiteralPath 'artifact.txt' -Encoding UTF8
    & git add artifact.txt
    & git commit -q -m 'baseline'

    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    Set-SCRoots $temp3 $temp3
    $stateDir=Join-Path $temp3 '.statefulclanker'
    New-Item -ItemType Directory -Force -Path $stateDir|Out-Null
    Write-SCJson (Join-Path $stateDir 'state.json') ([ordered]@{
        schemaVersion=4;revision=0;directionRevision=0;projectId='recovery-stagnation-test';
        projectRoot=$temp3;goal='';activePlanId=$null;planApproved=$true;
        createdAt=[datetimeoffset]::UtcNow.ToString('o');updatedAt=[datetimeoffset]::UtcNow.ToString('o')
    })
    ''|Set-Content -LiteralPath (Join-Path $stateDir 'events.jsonl') -Encoding UTF8
    foreach($child in @('tasks','plans','runs','critiques','validations','prompts','compilations','proposals','progress','reviews','worker-sessions')){New-Item -ItemType Directory -Force -Path (Join-Path $stateDir $child)|Out-Null}
    Write-SCJson (Join-Path $stateDir 'config.json') ([ordered]@{routing=[ordered]@{maxRouteAttempts=6};providers=[ordered]@{};maxConcurrent=3;autofillEnabled=$true;autofillIntervalSeconds=300;workingSetBudgetChars=24000;maxFileChars=8000;dependencyResultBudgetChars=8000;recentEventCount=12;recentEventBudgetChars=4000;stagnationWarningThreshold=2;requireHumanApprovalForPlan=$true;validatorEnabled=$true})

    $script:capturedEvents=@()
    function Add-SCEvent { param($Type,$Message,$Data) $script:capturedEvents+=,[pscustomobject]@{type=$Type;message=$Message;data=$Data} }

    . (Join-Path $repo 'lib\StatefulClanker.Execution.ps1')

    function New-TestTask2([string]$Id) {
        $task=New-SCTaskObject $Id 'Stagnation test task' 'instruction' @('a') @() @() @() @() $null 'worker' $false
        Save-SCTask $task
        return Get-SCTask $Id
    }
    $task=New-TestTask2 't-stagnation'
    $comp=[pscustomobject]@{id='compile-stagnation-test';inputFingerprint='fp-1'}

    Write-Host '  RE 8: stagnation warning fires when truly stuck (no validation, no merge)'
    Add-SCProgressRecord $task $comp $false 'attempt-1' 'no progress'|Out-Null
    Add-SCProgressRecord $task $comp $false 'attempt-2' 'still no progress'|Out-Null
    $warnings=@($script:capturedEvents|Where-Object{$_.type-eq'task.stagnation.warning'})
    Assert-True ($warnings.Count-eq1) "Expected one stagnation warning when truly stuck, got $($warnings.Count)."

    Write-Host '  RE 9: stagnation suppressed (reconciled) when latest validation verdict is PASS'
    $script:capturedEvents=@()
    $task2=New-TestTask2 't-stagnation-2'
    $validation=[ordered]@{schemaVersion=1;id='val-stag-2';taskId=$task2.id;verdict='PASS'}
    Write-SCJson (Get-SCPath 'validations/val-stag-2.json') $validation
    Set-SCProperty $task2 'latestValidationId' 'val-stag-2';Save-SCTask $task2
    Add-SCProgressRecord $task2 $comp $false 'attempt-1' 'no progress'|Out-Null
    Add-SCProgressRecord $task2 $comp $false 'attempt-2' 'still no progress'|Out-Null
    $warnings2=@($script:capturedEvents|Where-Object{$_.type-eq'task.stagnation.warning'})
    $reconciled2=@($script:capturedEvents|Where-Object{$_.type-eq'task.stagnation.reconciled'})
    Assert-True ($warnings2.Count-eq0) 'Stagnation warning must be suppressed when latest validation verdict is PASS.'
    Assert-True ($reconciled2.Count-eq1) 'Expected a task.stagnation.reconciled fyi event when validation passed.'

    Write-Host 'All Execution stagnation reconciliation checks passed.'
} finally {
    Pop-Location
    Remove-Item -Recurse -Force -LiteralPath $temp3 -ErrorAction SilentlyContinue
}

Write-Host 'RecoveryEvidence.Tests.ps1: all checks passed.'

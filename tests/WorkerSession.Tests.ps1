<# Durable direct-worker session, candidate materiality, and checkpoint/restore tests. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "WORKER SESSION TEST FAILED: $Message"}}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-worker-session-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
Push-Location $temp
try {
    if(-not(Get-Command git -ErrorAction SilentlyContinue)){throw 'git is required for worker checkpoint tests.'}
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
        schemaVersion=4;revision=0;directionRevision=0;projectId='worker-session-test';
        projectRoot=$temp;goal='';activePlanId=$null;planApproved=$true;
        createdAt=[datetimeoffset]::UtcNow.ToString('o');updatedAt=[datetimeoffset]::UtcNow.ToString('o')
    })
    ''|Set-Content -LiteralPath (Join-Path $stateDir 'events.jsonl') -Encoding UTF8

    function Invoke-SCProvider { throw 'CLI provider should not be called in WorkerSession.Tests.' }
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')

    $task=[pscustomobject]@{id='session-task';title='session task';role='worker';outputKind='change'}
    $comp=[pscustomobject]@{id='compile-session-test';inputFingerprint='fingerprint'}
    $registry=@([pscustomobject]@{wireName='finish';capability='builtin.finish'})
    $sessionId='wsess-test'
    $session=New-SCWorkerSession $sessionId $task $comp 'make a material change' 'native' $registry

    Assert-True ($session.id-eq$sessionId) 'Worker session id was not persisted.'
    Assert-True ([bool]$session.baselineCheckpointId) 'Session has no baseline checkpoint.'
    Assert-True (@($session.checkpoints).Count-ge1) 'Baseline checkpoint was not recorded.'

    Write-Host '  WS 1: unchanged artifact-producing candidate is rejected before critic'
    Set-SCWorkerCandidateClaim $sessionId ([pscustomobject]@{summary='claimed completion';expectedArtifacts=@('artifact.txt');verification=@()}) $null
    $unchanged=Get-SCWorkerCandidatePreflight $sessionId $task
    Assert-True (-not[bool]$unchanged.material) 'Unchanged change-task candidate passed materiality preflight.'
    Assert-True ([string]$unchanged.reason -match 'identical') "Unexpected unchanged-candidate reason: $($unchanged.reason)"
    $count=Add-SCWorkerNoArtifact $sessionId ([string]$unchanged.reason)
    Assert-True ($count-eq1) 'First no-artifact candidate did not increment the session counter to one.'

    Write-Host '  WS 2: changed artifact-producing candidate passes and records claims'
    "candidate-two"|Set-Content -LiteralPath 'artifact.txt' -Encoding UTF8
    Set-SCWorkerCandidateClaim $sessionId ([pscustomobject]@{summary='changed artifact';expectedArtifacts=@('artifact.txt');verification=@('manual test receipt')}) $null
    $changed=Get-SCWorkerCandidatePreflight $sessionId $task
    Assert-True ([bool]$changed.material) "Material candidate was rejected: $($changed.reason)"
    Assert-True ([bool]$changed.candidateCheckpointId) 'Material candidate did not get a checkpoint.'
    $session=Get-SCWorkerSession $sessionId
    Assert-True ($session.candidateNumber-eq2) "Expected candidateNumber=2, got $($session.candidateNumber)."
    Assert-True ($session.candidateClaim.expectedArtifacts[0]-eq'artifact.txt') 'Expected artifact claim was not persisted.'

    Write-Host '  WS 3: checkpoint restores worktree without moving HEAD'
    $checkpointId=[string]$changed.candidateCheckpointId
    $headBefore=([string](& git rev-parse HEAD)).Trim()
    "after-checkpoint"|Set-Content -LiteralPath 'artifact.txt' -Encoding UTF8
    "throwaway"|Set-Content -LiteralPath 'untracked.tmp' -Encoding UTF8
    Restore-SCWorkerCheckpoint $sessionId $checkpointId|Out-Null
    $headAfter=([string](& git rev-parse HEAD)).Trim()
    Assert-True ($headBefore-eq$headAfter) 'Restoring a worker checkpoint moved the worktree branch HEAD.'
    Assert-True ((Get-Content -Raw -LiteralPath 'artifact.txt').Trim()-eq'candidate-two') 'Checkpoint restore did not recover the candidate artifact.'
    Assert-True (-not(Test-Path -LiteralPath 'untracked.tmp')) 'Checkpoint restore did not remove post-checkpoint untracked work.'

    Write-Host '  WS 4: diagnosis tasks may legitimately produce zero diff'
    $diagnosis=[pscustomobject]@{id='diagnosis-task';title='diagnosis';role='worker';outputKind='diagnosis'}
    $diagId='wsess-diagnosis'
    [void](New-SCWorkerSession $diagId $diagnosis $comp 'inspect only' 'native' $registry)
    Set-SCWorkerCandidateClaim $diagId ([pscustomobject]@{summary='nothing to change';expectedArtifacts=@();verification=@()}) $null
    $diag=Get-SCWorkerCandidatePreflight $diagId $diagnosis
    Assert-True ([bool]$diag.material) 'Explicit diagnosis output kind incorrectly required a worktree mutation.'

    Write-Host 'PASS: durable worker sessions, pre-critic materiality gate, and restorable API-boundary Git checkpoints.'
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

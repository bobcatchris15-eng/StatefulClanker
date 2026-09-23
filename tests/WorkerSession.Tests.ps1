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

    Write-Host '  WS 1: unchanged artifact-producing candidate is rejected before validator'
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

    Write-Host '  WS 4: worker route pins are preferences and can migrate when the pinned route is unavailable'
    Set-SCWorkerSessionRoutePin $sessionId 'endpoint-a' 'connection-a' 'model-a'
    $pin=Get-SCWorkerSessionRoutePin $sessionId
    Assert-True ($pin.endpoint-eq'endpoint-a'-and$pin.connection-eq'connection-a'-and$pin.model-eq'model-a') 'Worker route pin was not persisted.'
    $task|Add-Member -NotePropertyName latestWorkerSessionId -NotePropertyValue $sessionId -Force
    Assert-True ((Get-SCReusableWorkerSessionId $task)-eq$sessionId) 'Active worker session was not reusable.'
    Set-SCWorkerSessionRoutePin $sessionId 'endpoint-b' 'connection-b' 'model-b'
    $migratedPin=Get-SCWorkerSessionRoutePin $sessionId
    Assert-True ($migratedPin.endpoint-eq'endpoint-b'-and$migratedPin.connection-eq'connection-b'-and$migratedPin.model-eq'model-b') 'Unavailable worker route pin could not migrate to a compatible replacement.'
    Close-SCWorkerSession $sessionId 'validator-error'
    Assert-True ((Get-SCReusableWorkerSessionId $task)-eq$sessionId) 'Validator-error session should be resumable.'
    Close-SCWorkerSession $sessionId 'completed'
    Assert-True ($null-eq(Get-SCReusableWorkerSessionId $task)) 'Completed worker session should not be reused.'

    Write-Host '  WS 5: closing a crashed session clears the task active-session handle'
    $crashedTask=[pscustomobject]@{id='crashed-session-task';stateRevision=0;activeWorkerSessionId='wsess-crashed';latestWorkerSessionId='wsess-crashed'}
    New-Item -ItemType Directory -Force -Path (Join-Path $stateDir 'tasks')|Out-Null
    Write-SCJson (Join-Path $stateDir 'tasks/crashed-session-task.json') $crashedTask
    [void](New-SCWorkerSession 'wsess-crashed' $crashedTask $comp 'make a material change' 'native' $registry)
    Close-SCWorkerSession 'wsess-crashed' 'provider-error'
    Assert-True ($null-eq(Get-SCTask 'crashed-session-task').activeWorkerSessionId) 'Terminal provider failure left activeWorkerSessionId set.'

    Write-Host '  WS 6: a route receipt records the exact route-catalog snapshot used for selection'
    $script:SCWorkerSessionCatalogPath=Join-Path $temp 'endpoints.json'
    '{"entries":{}}'|Set-Content -LiteralPath $script:SCWorkerSessionCatalogPath -Encoding UTF8
    function Get-SCMachineEndpointCatalogPath { return $script:SCWorkerSessionCatalogPath }
    $before=Get-SCRouteSnapshotReceipt
    Start-Sleep -Milliseconds 20
    '{"entries":{"replacement":{"enabled":true}}}'|Set-Content -LiteralPath $script:SCWorkerSessionCatalogPath -Encoding UTF8
    $after=Get-SCRouteSnapshotReceipt
    Assert-True ($before.catalogFingerprint-ne$after.catalogFingerprint) 'Route catalog snapshot did not change after catalog content changed.'

    Write-Host '  WS 7: durable route preference is stored without reimplementing router selection'
    Set-SCWorkerSessionRoutePin $sessionId 'endpoint-a' 'connection-a' 'model-a'
    $pin=Get-SCWorkerSessionRoutePin $sessionId
    Assert-True ($pin.endpoint-eq'endpoint-a') 'Worker session did not retain its endpoint preference.'
    Assert-True ($pin.connection-eq'connection-a') 'Worker session did not retain its connection preference.'
    Write-Host '  WS 8: cold worker turn budget makes the legacy 24-turn connection default irrelevant'
    $budgetTask=[pscustomobject]@{id='budget-task';role='worker';size='small'}
    $legacyConnection=[pscustomobject]@{maxSteps=24}
    Assert-True ((Get-SCWorkerMaxSteps $legacyConnection $budgetTask 'run')-ge512) 'Cold run retained a low legacy turn limit.'
    Assert-True ((Get-SCWorkerMaxSteps $legacyConnection $budgetTask 'validator')-eq24) 'Reviewer turn budget should still respect the connection setting.'

    Write-Host '  WS 9: diagnosis tasks may legitimately produce zero diff'
    $diagnosis=[pscustomobject]@{id='diagnosis-task';title='diagnosis';role='worker';outputKind='diagnosis'}
    $diagId='wsess-diagnosis'
    [void](New-SCWorkerSession $diagId $diagnosis $comp 'inspect only' 'native' $registry)
    Set-SCWorkerCandidateClaim $diagId ([pscustomobject]@{summary='nothing to change';expectedArtifacts=@();verification=@()}) $null
    $diag=Get-SCWorkerCandidatePreflight $diagId $diagnosis
    Assert-True ([bool]$diag.material) 'Explicit diagnosis output kind incorrectly required a worktree mutation.'

    Write-Host 'PASS: durable worker sessions, migration-safe route preferences, terminal cleanup, catalog snapshots, pre-validator materiality gate, and restorable API-boundary Git checkpoints.'
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

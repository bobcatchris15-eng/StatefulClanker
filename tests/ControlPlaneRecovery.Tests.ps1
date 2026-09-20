$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$harness=Join-Path $repo 'StatefulClanker.ps1'

function Assert-True([bool]$Condition,[string]$Message){
    if(-not$Condition){throw "CONTROL-PLANE RECOVERY TEST FAILED: $Message"}
}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-recovery-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null

try{
    Push-Location $temp
    & $harness init | Out-Null
    & $harness task add -TaskId recovery-task -Title 'Recovery task' -Instruction 'Old instruction' -Accept 'old acceptance' | Out-Null

    $taskPath=Join-Path $temp '.statefulclanker\tasks\recovery-task.json'
    $task=Get-Content -Raw -LiteralPath $taskPath|ConvertFrom-Json
    $task.status='needs_rework'
    $task.attemptCount=5
    $task.criticRejectCount=3
    $task.blockReason='Validator repeatedly rejected already-produced work.'
    $task|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $taskPath -Encoding UTF8

    $repairPayload=Join-Path $temp 'repair.json'
    [ordered]@{
        evidence=@(
            'Current artifact exists and matches the requested public behavior.'
            'Reviewer evidence shows the old acceptance wording is the remaining mismatch.'
        )
        patch=[ordered]@{
            instruction='Repaired instruction grounded in current intent'
            acceptance=@('new observable acceptance')
            retrieval=@('src/*')
        }
    }|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $repairPayload -Encoding UTF8

    & $harness task repair -TaskId recovery-task -Path $repairPayload -Reason 'Repair stale task definition after repeated review mismatch.' | Out-Null
    $task=Get-Content -Raw -LiteralPath $taskPath|ConvertFrom-Json
    Assert-True ($task.instruction-eq'Repaired instruction grounded in current intent') 'task repair did not update instruction.'
    Assert-True (@($task.acceptance).Count-eq1-and$task.acceptance[0]-eq'new observable acceptance') 'task repair did not update acceptance.'
    Assert-True ([int]$task.attemptCount-eq0) 'task repair did not reset attemptCount.'
    Assert-True ([int]$task.criticRejectCount-eq0) 'task repair did not reset criticRejectCount.'
    Assert-True ([string]$task.status-eq'ready') "task repair did not recompute readiness; status=$($task.status)"
    Assert-True ([string]$task.lastRecovery.kind-eq'task-repair') 'task repair did not persist recovery metadata.'

    # Simulate another exhausted review loop after the repaired definition. The last
    # resort should accept existing correct work without impersonating human authority.
    $task.status='needs_rework'
    $task.attemptCount=5
    $task.blockReason='Review loop false-negative after project tests pass.'
    $task|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $taskPath -Encoding UTF8

    $completePayload=Join-Path $temp 'complete.json'
    [ordered]@{
        evidence=@(
            'Named project verification command passes against the current checkout.'
            'Artifact inspection confirms every current acceptance condition is present.'
        )
    }|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $completePayload -Encoding UTF8

    & $harness task recover -TaskId recovery-task -Path $completePayload -Reason 'Current evidence proves completion; repeated review state is stale.' | Out-Null
    $task=Get-Content -Raw -LiteralPath $taskPath|ConvertFrom-Json
    Assert-True ([string]$task.status-eq'complete') 'recovery completion did not mark task complete.'
    Assert-True ([string]$task.lastRecovery.kind-eq'accepted-existing-work') 'recovery completion metadata missing.'
    Assert-True ([int]$task.recoveryCount-ge2) 'recovery count did not accumulate.'

    $events=Get-Content -LiteralPath (Join-Path $temp '.statefulclanker\events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json}
    $repairEvent=@($events|Where-Object{$_.type-eq'task.repaired.control_plane'}|Select-Object -Last 1)
    $completeEvent=@($events|Where-Object{$_.type-eq'task.completed.control_plane_recovery'}|Select-Object -Last 1)
    Assert-True ($repairEvent.Count-eq1) 'task repair audit event missing.'
    Assert-True ($completeEvent.Count-eq1) 'recovery completion audit event missing.'
    Assert-True ([string]$completeEvent[0].data.authority-eq'control-plane-recovery') 'recovery completion was not labeled control-plane authority.'
    Assert-True ([bool]$completeEvent[0].data.bypassedReviewGate) 'recovery completion did not explicitly record review-gate bypass.'

    # Human gates remain a hard boundary.
    & $harness task add -TaskId human-gated -Title 'Human gate' -Instruction 'Must await human' -HumanGate | Out-Null
    $humanPath=Join-Path $temp '.statefulclanker\tasks\human-gated.json'
    $human=Get-Content -Raw -LiteralPath $humanPath|ConvertFrom-Json
    $human.status='blocked'
    $human.blockReason='Waiting for explicit human choice.'
    $human|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $humanPath -Encoding UTF8
    $blocked=$false
    try{& $harness task recover -TaskId human-gated -Path $completePayload -Reason 'should refuse' | Out-Null}catch{$blocked=$true}
    Assert-True $blocked 'control-plane recovery crossed a human gate.'

    # The control inbox should treat a mechanical stall as attention/recovery, not
    # immediately as a human-required semantic decision.
    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    Set-SCRoots $temp $temp
    . (Join-Path $repo 'lib\StatefulClanker.Eventing.ps1')
    Add-SCEvent 'autofill.stalled' 'CONTROL-PLANE RECOVERY REQUIRED test event.' @{stalledCount=1;recoveryPolicy='control-plane-first'}
    $control=Get-Content -LiteralPath (Join-Path $temp '.statefulclanker\control\events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json}|Where-Object{$_.type-eq'autofill.stalled'}|Select-Object -Last 1
    Assert-True ($null-ne$control) 'autofill.stalled control event missing.'
    Assert-True ([string]$control.level-eq'attention') "autofill.stalled should be attention, got '$($control.level)'."

    Write-Host 'PASS: control-plane recovery repairs stalled task metadata, can audited-recover completed work, and preserves human gates.'
}finally{
    try{Pop-Location}catch{}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

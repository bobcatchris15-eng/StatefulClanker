$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "CANDIDATE PRESERVATION TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-candidate-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
    . (Join-Path $repo 'lib/StatefulClanker.Core.ps1')
    . (Join-Path $repo 'lib/StatefulClanker.Signals.ps1')
    . (Join-Path $repo 'lib/StatefulClanker.Manifests.ps1')
    . (Join-Path $repo 'lib/StatefulClanker.ExecutionProjection.ps1')
    . (Join-Path $repo 'lib/StatefulClanker.Concurrency.ps1')
    function Add-SCEvent {param($Type,$Message,$Data)}
    function Add-SCProgressRecord {param($Task,$Run,$Advancing,$Kind,$Reason)}
    function Add-SCCompletedTaskCount {}
    function Update-SCReadiness {}
    Set-SCRoots $temp $temp
    git -C $temp init -q
    git -C $temp config user.name 'Candidate Test'
    git -C $temp config user.email 'test@localhost'
    '.statefulclanker/'|Set-Content (Join-Path $temp '.gitignore')
    'seed'|Set-Content (Join-Path $temp 'seed.txt')
    git -C $temp add -A
    git -C $temp commit -qm seed
    Write-SCJson (Get-SCPath 'state.json') @{schemaVersion=4;projectId='candidate-test';directionRevision=0}
    Write-SCJson (Get-SCPath 'config.json') @{}
    function New-TestTask([string]$Id,[string]$Status){
        $task=[pscustomobject]@{id=$Id;title=$Id;instruction='produce artifact';status=$Status;controlRevision=0;stateRevision=0;acceptance=@();dependsOn=@();relations=@();retrieval=@();evidence=@();provider=$null;role='worker';humanGate=$false;latestRunId="run-$Id";latestValidationId="val-$Id";latestProposalId="proposal-$Id";blockReason=$null}
        Save-SCTask $task
        return $task
    }
    function New-TestRun($Worktree,[int]$ExitCode=0){
        $log=Join-Path $temp "$($Worktree.taskId).log"
        return [pscustomobject]@{taskId=$Worktree.taskId;worktree=$Worktree;process=[pscustomobject]@{ExitCode=$ExitCode};logPath=$log;startedAt=Get-Date;provider=$null}
    }

    $task=New-TestTask 'self-committed' 'validated'
    Write-SCJson (Get-SCPath 'proposals/proposal-self-committed.json') @{id=$task.latestProposalId;taskId=$task.id;status='validated';committedAt=$null;evidence=@{runId=$task.latestRunId;validationId=$task.latestValidationId;validationVerdict='PASS'}}
    $wt=New-SCWorktree $temp $task.id
    'worker artifact'|Set-Content (Join-Path $wt.path 'committed.txt')
    [void](Save-SCWorktreeWork $wt 'worker commits before finish')
    $result=Complete-SCParallelChild $temp (New-TestRun $wt)
    Assert-True ($result.merged-and$result.status-eq'complete') 'validated worker commit was mistaken for no work'
    Assert-True (Test-Path (Join-Path $temp 'committed.txt')) 'worker commit did not reach project'

    $task=New-TestTask 'failed-committed' 'needs_rework'
    $wt=New-SCWorktree $temp $task.id
    'recover me'|Set-Content (Join-Path $wt.path 'recover.txt')
    [void](Save-SCWorktreeWork $wt 'candidate before transport error')
    Remove-SCWorktree $temp $task.id
    $saved=Get-SCTask $task.id
    $record=Read-SCJson (Get-SCPath "preserved-candidates/$($saved.latestPreservedCandidateId).json")
    Assert-True ($record.taskStatus-eq'needs_rework'-and-not$record.completionCredited) 'preservation manufactured completion'
    $bytes=Invoke-SCGitCapture $temp @('show',"$($record.branch):recover.txt")
    Assert-True ($bytes.exitCode-eq0-and$bytes.output-match'recover me') 'already committed candidate was orphaned'
    $replacement=New-SCWorktree $temp $task.id
    Assert-True (-not(Test-Path (Join-Path $replacement.path 'recover.txt'))) 'new worker inherited the failed candidate implicitly'
    $projection=Get-SCExecutionProjection (Get-SCTask $task.id)
    Assert-True ($projection.preservedCandidates[0].commit-eq$record.commit) 'replacement packet lacks own preserved candidate identity'
    Remove-SCWorktree $temp $task.id
    Assert-True (Test-SCBranchExists $temp $record.branch) 'replacement cleanup destroyed earlier recovery reference'

    $task=New-TestTask 'transient' 'running'
    $wt=New-SCWorktree $temp $task.id
    'unsaved artifact'|Set-Content (Join-Path $wt.path 'transient.txt')
    $run=New-TestRun $wt 1
    '503 service unavailable'|Set-Content "$($run.logPath).err"
    $result=Complete-SCParallelChild $temp $run
    $saved=Get-SCTask $task.id
    $record=Read-SCJson (Get-SCPath "preserved-candidates/$($saved.latestPreservedCandidateId).json")
    Assert-True ($saved.status-eq'ready') 'transient retry classification changed'
    Assert-True ((Invoke-SCGitCapture $temp @('show',"$($record.branch):transient.txt")).exitCode-eq0) 'transient retry discarded dirty artifact'

    $task=New-TestTask 'empty' 'validated'
    $wt=New-SCWorktree $temp $task.id
    $result=Complete-SCParallelChild $temp (New-TestRun $wt)
    Assert-True (-not$result.merged-and(Get-SCTask $task.id).status-eq'needs_rework') 'empty candidate bypassed materiality gate'

    $task=New-TestTask 'evidence' 'complete'
    $wt=New-SCWorktree $temp $task.id
    'evidence bytes'|Set-Content (Join-Path $wt.path 'evidence.md')
    $result=Complete-SCParallelChild $temp (New-TestRun $wt)
    $saved=Get-SCTask $task.id
    $record=Read-SCJson (Get-SCPath "preserved-candidates/$($saved.latestPreservedCandidateId).json")
    Assert-True (-not$result.merged-and$record.changedFiles-contains'evidence.md') 'evidence-only bytes were discarded'

    $task=New-TestTask 'integrated-uncredited' 'needs_rework'
    $wt=New-SCWorktree $temp $task.id
    'merged before credit failed'|Set-Content (Join-Path $wt.path 'uncredited.txt')
    [void](Save-SCWorktreeWork $wt 'candidate before state failure')
    [void](Merge-SCWorktreeBranch $temp $wt)
    Remove-SCWorktree $temp $task.id
    $saved=Get-SCTask $task.id
    $record=Read-SCJson (Get-SCPath "preserved-candidates/$($saved.latestPreservedCandidateId).json")
    Assert-True ($record.integrated-and-not$record.completionCredited-and$saved.status-eq'needs_rework') 'integration without task credit was discarded or silently approved'

    $task=New-TestTask 'save-failure' 'needs_rework'
    $wt=New-SCWorktree $temp $task.id
    'keep me'|Set-Content (Join-Path $wt.path 'keep.txt')
    $saveFunction=(Get-Command Save-SCWorktreeWork).ScriptBlock
    function Save-SCWorktreeWork {throw 'simulated commit failure'}
    $failed=$false
    try{Remove-SCWorktree $temp $task.id}catch{$failed=$true}
    Set-Item Function:Save-SCWorktreeWork $saveFunction
    Assert-True ($failed-and(Test-Path (Join-Path $wt.path 'keep.txt'))) 'failed preservation did not retain worktree'
    Remove-SCWorktree $temp $task.id
    Write-Host 'PASS: committed/dirty candidates survive teardown and retry; validated self-commits merge; empty candidates remain rejected; preservation fails closed.'
}finally{
    $resolved=[IO.Path]::GetFullPath($temp)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)-and(Split-Path -Leaf $resolved)-like'sc-candidate-*'){
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}

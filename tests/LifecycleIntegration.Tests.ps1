$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
. (Join-Path $repo 'lib\StatefulClanker.Execution.ps1')
. (Join-Path $repo 'lib\StatefulClanker.Concurrency.ps1')

function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "LIFECYCLE TEST FAILED: $Message"}}
function Get-SCConfig { return [pscustomobject]@{validatorEnabled=$true;maxTaskAttempts=5} }
function Get-SCTask([string]$Id) { return $script:task }
function Save-SCTask($Task) { $script:task=$Task }
function Save-SCProposal($Proposal) { $script:proposal=$Proposal }
function Read-SCJson($Path) { return $script:proposal }
function Write-SCJson($Path,$Value) { $script:proposal=$Value }
function Get-SCPath([string]$Child) { return $Child }
function Stop-SCForStaleCompilation { return $false }
function Add-SCEvent($Type,$Message,$Data) { $script:events+=,$Type }
function Add-SCProgressRecord { return $null }
function Add-SCCompletedTaskCount { $script:completedCount++ }
function Update-SCReadiness { }
function Save-SCWorktreeWork { return $true }
function Merge-SCWorktreeBranch { return [pscustomobject]@{merged=$true;reason=$null} }
function Remove-SCWorktree { }

$script:SCManagedChild=$true
$script:events=@();$script:completedCount=0
$script:task=[pscustomobject]@{id='change';outputKind='change';status='validating';blockReason=$null;latestProposalId='proposal-1';title='Change task'}
$script:proposal=[pscustomobject]@{id='proposal-1';taskId='change';status='pending';committedAt=$null;evidence=[pscustomobject]@{validationVerdict='PASS';runId='run-1'}}
$compilation=[pscustomobject]@{id='compile-1'}
Assert-True (Commit-SCProposal $script:task $script:proposal $compilation) 'Validated change proposal was rejected.'
Assert-True ($script:task.status-eq'validated' -and $script:proposal.status-eq'validated') 'Change task completed before merge.'
Assert-True ($script:completedCount-eq0) 'Unmerged task incremented completed count.'
$run=[pscustomobject]@{taskId='change';process=[pscustomobject]@{ExitCode=0};worktree=[pscustomobject]@{branch='sc/task/change';path='unused'};logPath='unused'}
$result=Complete-SCParallelChild 'unused' $run
Assert-True ($result.merged -and $script:task.status-eq'complete') 'Merged change task did not complete.'
Assert-True ($script:proposal.status-eq'committed' -and $script:completedCount-eq1) 'Merge did not commit the validated proposal exactly once.'

$script:task=[pscustomobject]@{id='diagnosis';outputKind='diagnosis';status='validating';blockReason=$null;latestProposalId='proposal-2';title='Diagnosis task'}
$script:proposal=[pscustomobject]@{id='proposal-2';taskId='diagnosis';status='pending';committedAt=$null;evidence=[pscustomobject]@{validationVerdict='PASS';runId='run-2'}}
Assert-True (Commit-SCProposal $script:task $script:proposal $compilation) 'Validated diagnosis proposal was rejected.'
Assert-True ($script:task.status-eq'complete' -and $script:completedCount-eq2) 'Evidence-only task did not complete without merge.'

$script:task=[pscustomobject]@{id='held-change';outputKind='change';status='validating';blockReason=$null;latestProposalId='proposal-3';title='Held change task'}
$script:proposal=[pscustomobject]@{id='proposal-3';taskId='held-change';status='pending';committedAt=$null;evidence=[pscustomobject]@{validationVerdict='PASS';runId='run-3'}}
Assert-True (Commit-SCProposal $script:task $script:proposal $compilation) 'No-merge change proposal was rejected.'
$heldRun=[pscustomobject]@{taskId='held-change';process=[pscustomobject]@{ExitCode=0};worktree=[pscustomobject]@{branch='sc/task/held-change';path='unused'};logPath='unused'}
$held=Complete-SCParallelChild 'unused' $heldRun -NoMerge
Assert-True (-not$held.merged -and $script:task.status-eq'validated' -and $script:proposal.status-eq'validated') 'No-merge work was falsely marked complete.'

function Get-SCTasks { return @($script:retryTasks) }
$script:retryTasks=@(
    [pscustomobject]@{id='infra';status='needs_rework';retryDisposition='acceptance-repair';humanGate=$false;attemptCount=1;dependsOn=@();updatedAt='1'},
    [pscustomobject]@{id='bad-output';status='needs_rework';retryDisposition='auto';humanGate=$false;attemptCount=1;dependsOn=@();updatedAt='2'},
    [pscustomobject]@{id='crash';status='failed';humanGate=$false;attemptCount=1;dependsOn=@();updatedAt='3'},
    [pscustomobject]@{id='stale';status='stale';humanGate=$false;attemptCount=1;dependsOn=@();updatedAt='4'}
)
$retry=@(Get-SCRetryableTasks|ForEach-Object{$_.id})
Assert-True ($retry.Count-eq2 -and $retry-contains'bad-output' -and $retry-contains'stale') 'Autofill retried an infrastructure/crash task or lost an explicitly retryable task.'
Write-Host 'PASS: change tasks complete after validation and merge; evidence-only tasks need no merge; retry queue excludes infrastructure and crashes.'

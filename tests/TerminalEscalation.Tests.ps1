$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "TERMINAL ESCALATION TEST FAILED: $Message"}}

. (Join-Path $repo 'lib\StatefulClanker.Concurrency.ps1')

$script:task=$null
$script:child=$null
$script:events=[Collections.Generic.List[object]]::new()
function Get-SCTask([string]$Id){return $script:task}
function Save-SCTask($Task){$script:task=$Task}
function Get-SCParallelChildOutput($Run){return $script:child}
function Close-SCFailedTaskWorkerSession($Task,[string]$Status='failed'){
    $Task.activeWorkerSessionId=$null
    $script:task=$Task
}
function Add-SCEvent([string]$Type,[string]$Message,$Data){
    $script:events.Add([pscustomobject]@{type=$Type;message=$Message;data=$Data})
}
function Save-SCWorktreeWork($Worktree,[string]$Message){return $false}
function Remove-SCWorktree([string]$StateRoot,[string]$TaskId,[switch]$KeepBranch){}
function Get-SCConfig(){return [pscustomobject]@{providers=[pscustomobject]@{}}}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-terminal-escalation-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try {
    Write-Host '  ESCALATION 1: a genuine worker crash emits run.failed with useful detail'
    $script:task=[pscustomobject]@{
        id='crash-task';title='Crash task';status='running';blockReason=$null
        activeWorkerSessionId='wsess-crash';attemptCount=1
    }
    $script:child=[ordered]@{stdout="worker line 1`nworker line 2";stderr="fatal provider process error"}
    $script:events.Clear()
    $run=[pscustomobject]@{
        taskId='crash-task'
        process=[pscustomobject]@{ExitCode=1}
        provider='test-provider'
        logPath=(Join-Path $temp 'crash.log')
        worktree=[pscustomobject]@{path=$temp;branch='sc/task/crash-task'}
    }
    $result=Complete-SCParallelChild $temp $run -NoMerge
    Assert-True ($script:task.status-eq'failed') 'Genuine process crash did not mark the task failed.'
    Assert-True ($script:task.blockReason-like'*exit code 1*') 'Crash reason lost the exit code.'
    Assert-True ($script:task.blockReason-like'*fatal provider process error*') 'Crash reason lost useful stderr detail.'
    $failed=@($script:events|Where-Object type -eq 'run.failed')
    Assert-True ($failed.Count-eq1) 'Genuine process crash did not emit exactly one run.failed event.'
    Assert-True ($failed[0].data.workerSessionId-eq'wsess-crash') 'run.failed did not preserve the worker session id.'
    Assert-True ([int]$failed[0].data.exitCode-eq1) 'run.failed did not preserve the process exit code.'

    Write-Host '  ESCALATION 2: transient provider failure requeues without run.failed'
    $script:task=[pscustomobject]@{
        id='transient-task';title='Transient task';status='running';blockReason=$null
        activeWorkerSessionId='wsess-transient';attemptCount=1
    }
    $script:child=[ordered]@{stdout='';stderr='HTTP 429 Too Many Requests - rate limit'}
    $script:events.Clear()
    $run=[pscustomobject]@{
        taskId='transient-task'
        process=[pscustomobject]@{ExitCode=1}
        provider=$null
        logPath=(Join-Path $temp 'transient.log')
        worktree=[pscustomobject]@{path=$temp;branch='sc/task/transient-task'}
    }
    $result=Complete-SCParallelChild $temp $run -NoMerge
    Assert-True ($script:task.status-eq'ready') 'Transient provider failure did not requeue the task.'
    Assert-True (@($script:events|Where-Object type -eq 'run.failed').Count-eq0) 'Transient provider failure was incorrectly escalated as a task crash.'
    Assert-True (@($script:events|Where-Object type -eq 'task.retried.transient').Count-eq1) 'Transient provider retry event is missing.'

    Write-Host '  ESCALATION 3: bundled-Pi PTY startup cannot silently discard queued notices'
    $terminalSource=[IO.File]::ReadAllText((Join-Path $repo 'src\StatefulClanker.Tray\EmbeddedTerminalPanel.cs'))
    $start=$terminalSource.IndexOf('    void FlushPendingNotices()')
    $finish=$terminalSource.IndexOf('    public void StopSession()',$start)
    Assert-True ($start-ge0-and$finish-gt$start) 'Could not isolate FlushPendingNotices.'
    $flush=$terminalSource.Substring($start,$finish-$start)
    Assert-True ($flush.Contains('var conpty = _terminal?.ConPTYTerm;')) 'PTY readiness is not checked before injection.'
    Assert-True ($flush.Contains('if (conpty is null) return;')) 'A not-yet-ready ConPTY does not preserve the queued notice.'
    $ready=$flush.Substring($flush.IndexOf('var conpty = _terminal?.ConPTYTerm;'))
    Assert-True ($ready.IndexOf('_pendingNotices.Clear()') -gt $ready.IndexOf('conpty.WriteToTerm')) 'Notice queue is cleared before a successful PTY write once ConPTY exists.'
    Assert-True (-not $ready.Contains('finally')) 'PTY write failure still clears notices through finally.'

    Write-Host 'PASS: real worker failures reach terminal escalation while transient routing and Pi startup remain safe.'
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

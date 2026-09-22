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

    Write-Host '  ESCALATION 3: bundled Pi owns control-plane delivery through an extension'
    $terminalSource=[IO.File]::ReadAllText((Join-Path $repo 'src\StatefulClanker.Tray\EmbeddedTerminalPanel.cs'))
    Assert-True ($terminalSource.Contains('HandlesControlPlaneNatively')) 'Terminal does not expose native Pi control-plane ownership.'
    Assert-True ($terminalSource.Contains('Pi (bundled)')) 'Bundled Pi preset is missing.'

    $programSource=[IO.File]::ReadAllText((Join-Path $repo 'src\StatefulClanker.Tray\Program.cs'))
    Assert-True ($programSource.Contains('.statefulclanker", "control", "events.jsonl"')) 'Tray escalation is not reading the durable control-event stream.'
    Assert-True ($programSource.Contains('_terminal.HandlesControlPlaneNatively')) 'Tray does not suppress duplicate PTY injection for bundled Pi.'
    Assert-True (-not $programSource.Contains('EscalatedEventTypes')) 'Tray still depends on the obsolete hard-coded raw event whitelist.'

    $piCmd=[IO.File]::ReadAllText((Join-Path $repo 'pi\pi.cmd'))
    Assert-True ($piCmd.Contains('--extension "%~dp0extensions\statefulclanker.ts"')) 'Bundled Pi launcher does not load the StatefulClanker extension.'
    $piExtension=Join-Path $repo 'pi\extensions\statefulclanker.ts'
    Assert-True (Test-Path -LiteralPath $piExtension) 'Bundled StatefulClanker Pi extension is missing.'
    $extensionSource=[IO.File]::ReadAllText($piExtension)
    Assert-True ($extensionSource.Contains('rpc("tools/list"')) 'Pi extension does not discover StatefulClanker MCP tools.'
    Assert-True ($extensionSource.Contains('rpc("tools/call"')) 'Pi extension does not bridge StatefulClanker MCP tool calls.'
    Assert-True ($extensionSource.Contains('display: false')) 'Pi control events are not hidden extension context.'
    Assert-True ($extensionSource.Contains('triggerTurn: true')) 'Pi control events do not wake an idle conversational agent.'
    Assert-True ($extensionSource.Contains('event.level === "attention" || event.level === "human_required"')) 'Pi extension is not filtering for actionable control levels.'

    Write-Host 'PASS: real worker failures escalate, transient routing requeues, and Pi receives native control-plane tools/events.'
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

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

    Write-Host '  ESCALATION 2b: post-worker validation crash is not labeled a worker crash'
    $script:task=[pscustomobject]@{
        id='validation-crash';title='Validation crash';status='validating';blockReason=$null
        activeWorkerSessionId='wsess-validation';attemptCount=1
    }
    $script:child=[ordered]@{stdout='worker already completed successfully';stderr="StatefulClanker.ps1: The property 'Count' cannot be found on this object."}
    $script:events.Clear()
    $run=[pscustomobject]@{
        taskId='validation-crash'
        process=[pscustomobject]@{ExitCode=1}
        provider='test-provider'
        logPath=(Join-Path $temp 'validation-crash.log')
        worktree=[pscustomobject]@{path=$temp;branch='sc/task/validation-crash'}
    }
    $result=Complete-SCParallelChild $temp $run -NoMerge
    Assert-True ($script:task.status-eq'needs_rework') 'Post-worker acceptance crash was not preserved as recoverable work.'
    Assert-True ($script:task.blockReason-like'Post-worker acceptance infrastructure crashed*') 'Acceptance crash was still described as a worker crash.'
    Assert-True (@($script:events|Where-Object type -eq 'run.failed').Count-eq0) 'Acceptance infrastructure crash emitted worker run.failed.'
    Assert-True (@($script:events|Where-Object type -eq 'validator.infrastructure_failed').Count-eq1) 'Acceptance infrastructure crash event is missing.'

    Write-Host '  ESCALATION 3: bundled Pi owns control-plane delivery over direct stdio MCP'
    $terminalSource=[IO.File]::ReadAllText((Join-Path $repo 'src\StatefulClanker.Tray\EmbeddedTerminalPanel.cs'))
    Assert-True ($terminalSource.Contains('Pi (bundled)')) 'Bundled Pi preset is missing.'
    Assert-True (-not $terminalSource.Contains('QueueNotice')) 'Terminal still contains PTY control-plane text injection.'
    Assert-True (-not $terminalSource.Contains('HandlesControlPlaneNatively')) 'Terminal still contains obsolete native-vs-PTY control-plane switching.'
    Assert-True (-not $terminalSource.Contains('WriteToTerm')) 'Terminal still writes control-plane messages into ConPTY input.'

    $programSource=[IO.File]::ReadAllText((Join-Path $repo 'src\StatefulClanker.Tray\Program.cs'))
    Assert-True (-not $programSource.Contains('EscalateNewEvents')) 'Tray still polls and injects control events into terminal input.'
    Assert-True (-not $programSource.Contains('_terminal.QueueNotice')) 'Tray still has a PTY escalation path.'

    $piCmd=[IO.File]::ReadAllText((Join-Path $repo 'pi\pi.cmd'))
    Assert-True ($piCmd.Contains('--extension "%~dp0extensions\statefulclanker.ts"')) 'Bundled Pi launcher does not load the StatefulClanker extension.'
    $piExtension=Join-Path $repo 'pi\extensions\statefulclanker.ts'
    Assert-True (Test-Path -LiteralPath $piExtension) 'Bundled StatefulClanker Pi extension is missing.'
    $extensionSource=[IO.File]::ReadAllText($piExtension)
    Assert-True ($extensionSource.Contains('spawn(')) 'Pi extension does not start a direct stdio MCP child.'
    Assert-True ($extensionSource.Contains('StatefulClanker.Mcp.ps1')) 'Pi extension does not launch the StatefulClanker stdio server.'
    Assert-True ($extensionSource.Contains('rpc("tools/list"')) 'Pi extension does not discover StatefulClanker MCP tools.'
    Assert-True ($extensionSource.Contains('rpc("tools/call"')) 'Pi extension does not use StatefulClanker MCP tool calls.'
    Assert-True ($extensionSource.Contains('control_events_since')) 'Pi extension does not consume durable control events through MCP.'
    Assert-True (-not $extensionSource.Contains('fetch(')) 'Pi extension still tunnels local control through HTTP.'
    Assert-True (-not $extensionSource.Contains('mcp-http.json')) 'Pi extension still depends on the resident HTTP rendezvous file.'
    Assert-True (-not $extensionSource.Contains('events.jsonl')) 'Pi extension still knows the control-event file layout.'
    Assert-True ($extensionSource.Contains('display: false')) 'Pi control events are not hidden extension context.'
    Assert-True ($extensionSource.Contains('triggerTurn: true')) 'Pi control events do not wake an idle conversational agent.'
    Assert-True ($extensionSource.Contains('event.level === "attention" || event.level === "human_required"')) 'Pi extension is not filtering for actionable control levels.'

    Write-Host '  ESCALATION 4: bundled Pi receives the full operator manual before its first real turn'
    $manualPath=Join-Path $repo 'skills\statefulclanker\SKILL.md'
    Assert-True (Test-Path -LiteralPath $manualPath) 'Canonical StatefulClanker operator manual is missing.'
    $manualSource=[IO.File]::ReadAllText($manualPath)
    Assert-True ($manualSource.Contains('This is the canonical field manual')) 'StatefulClanker skill no longer identifies itself as the canonical control-plane field manual.'
    Assert-True ($extensionSource.Contains('OPERATOR_MANUAL')) 'Pi extension does not load the canonical StatefulClanker field manual.'
    Assert-True ($extensionSource.Contains('PI_OPERATOR_ADDENDUM')) 'Pi extension is missing its bundled control-plane recovery addendum.'
    Assert-True ($extensionSource.Contains('deliverAs: "nextTurn"')) 'Pi operator manual is not queued for the first real model turn.'
    Assert-True ($extensionSource.Contains('triggerTurn: false')) 'Pi operator manual incorrectly triggers an agent turn by itself.'
    Assert-True ($extensionSource.Contains('manualQueuedForRoot')) 'Pi extension does not guard the large operator manual against repeated injection in one project session.'
    Assert-True ($extensionSource.Contains('If a task is already complete')) 'Pi manual does not explicitly protect completed tasks from stale stagnation/recovery warnings.'
    Assert-True ($extensionSource.Contains('re-read autofill_status')) 'Pi manual does not require current-state verification before acting on Autofill warnings.'
    Assert-True ($extensionSource.Contains('readCurrentTask')) 'Injected task errors are not enriched from the current durable task object.'
    Assert-True ($extensionSource.Contains('readCurrentAutofill')) 'Injected Autofill errors are not enriched with current supervisor state.'
    Assert-True ($extensionSource.Contains('CURRENT TASK OBJECTS')) 'Injected errors do not distinguish event-time evidence from current task state.'
    Assert-True ($extensionSource.Contains('CURRENT TASK_LIST SNAPSHOT')) 'Injected errors do not include a current task-graph summary.'
    Assert-True ($extensionSource.Contains('retainedEvents === 0') -and $extensionSource.Contains('return null')) 'Pi does not suppress stale problem events after current-state reconciliation.'
    Assert-True ($extensionSource.Contains('String(task.status).toLowerCase() === "complete"')) 'Pi does not explicitly retire task-scoped problem events whose current task is complete.'
    Assert-True ($extensionSource.Contains('START HERE:')) 'Injected control-plane errors do not provide an immediate investigation starting point.'
    Assert-True ($extensionSource.Contains('inspect-first paths:')) 'Injected task errors do not surface the task retrieval paths as an immediate inspection target.'
    Assert-True ($extensionSource.Contains('acceptance to verify:')) 'Injected task errors do not surface acceptance criteria for immediate verification.'
    Assert-True ($extensionSource.Contains('latest evidence:')) 'Injected task errors do not surface latest run/review evidence pointers.'
    Assert-True ($extensionSource.Contains('keep task_list and each task object synchronized with the actual project')) 'Pi is not instructed that task bookkeeping must be reconciled to project reality.'

    $canonicalManual=[IO.File]::ReadAllText($manualPath)
    Assert-True ($canonicalManual.Contains('Reconcile the durable graph with current reality')) 'Canonical operator manual lacks task-graph/repository reality reconciliation.'
    Assert-True ($canonicalManual.Contains('truthful graph over a cosmetically green graph')) 'Canonical operator manual does not prioritize truthful bookkeeping over green status.'

    Write-Host 'PASS: real worker failures escalate, transient routing requeues, and Pi receives current-state-enriched events plus a one-shot operator boot manual.'
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

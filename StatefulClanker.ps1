<#
.SYNOPSIS
StatefulClanker: a durable-state orchestration harness for one-shot CLI workers.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Position=0)][string]$Command = 'status',
    [Parameter(Position=1)][string]$Subcommand,
    [string]$Title,
    [string]$Instruction,
    [string[]]$Accept,
    [string[]]$DependsOn,
    [string[]]$Retrieval,
    [string[]]$Evidence,
    [string]$Provider,
    [string]$Role = 'worker',
    [switch]$HumanGate,
    [string]$TaskId,
    [string]$Path,
    [string]$Reason,
    [string]$Message
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-SCRoot { (Get-Location).Path }
function Get-SCDir { Join-Path (Get-SCRoot) '.statefulclanker' }
function Get-SCPath([string]$Child) { Join-Path (Get-SCDir) $Child }
function ConvertTo-SCJson($Value, [int]$Depth = 12) { $Value | ConvertTo-Json -Depth $Depth }
function Write-SCJson([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $tmp = "$Path.tmp"
    ConvertTo-SCJson $Value | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -Force -LiteralPath $tmp -Destination $Path
}
function Read-SCJson([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $raw = Get-Content -Raw -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $raw | ConvertFrom-Json
}
function Assert-SCInitialized {
    if (-not (Test-Path (Get-SCPath 'state.json'))) { throw 'StatefulClanker is not initialized here. Run: .\StatefulClanker.ps1 init' }
}
function New-SCId([string]$Prefix) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $rand = [Guid]::NewGuid().ToString('N').Substring(0,8)
    "$Prefix-$stamp-$rand"
}
function Add-SCEvent([string]$Type, [string]$Text, $Data = $null) {
    Assert-SCInitialized
    $evt = [ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); type=$Type; message=$Text; data=$Data }
    (ConvertTo-SCJson $evt -Depth 8 -replace "`r?`n", '') | Add-Content -LiteralPath (Get-SCPath 'events.jsonl') -Encoding UTF8
}
function Get-SCState { Assert-SCInitialized; Read-SCJson (Get-SCPath 'state.json') }
function Save-SCState($State) { $State.updatedAt=(Get-Date).ToUniversalTime().ToString('o'); Write-SCJson (Get-SCPath 'state.json') $State }
function Get-SCConfig {
    Assert-SCInitialized
    $cfg = Read-SCJson (Get-SCPath 'config.json')
    if ($null -eq $cfg) { throw 'Missing .statefulclanker/config.json' }
    $cfg
}
function Get-SCTask([string]$Id) {
    $task = Read-SCJson (Get-SCPath ("tasks/{0}.json" -f $Id))
    if ($null -eq $task) { throw "Unknown task: $Id" }
    $task
}
function Save-SCTask($Task) { $Task.updatedAt=(Get-Date).ToUniversalTime().ToString('o'); Write-SCJson (Get-SCPath ("tasks/{0}.json" -f $Task.id)) $Task }
function Get-SCTasks {
    Assert-SCInitialized
    $dir=Get-SCPath 'tasks'
    if (-not (Test-Path $dir)) { return @() }
    @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | ForEach-Object { Read-SCJson $_.FullName })
}
function Update-SCReadiness {
    $tasks=@(Get-SCTasks); $byId=@{}
    foreach ($t in $tasks) { $byId[$t.id]=$t }
    foreach ($t in $tasks) {
        if ($t.status -ne 'pending') { continue }
        $ready=$true
        foreach ($dep in @($t.dependsOn)) {
            if (-not $byId.ContainsKey($dep) -or $byId[$dep].status -ne 'complete') { $ready=$false; break }
        }
        if ($ready) { $t.status='ready'; Save-SCTask $t }
    }
}
function Initialize-SC {
    $dir=Get-SCDir
    if (Test-Path (Join-Path $dir 'state.json')) { Write-Host 'Already initialized.'; return }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($child in @('tasks','plans','runs','critiques','validations','prompts','retrieval')) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $child) | Out-Null }
    $now=(Get-Date).ToUniversalTime().ToString('o')
    $state=[ordered]@{ schemaVersion=2; projectId=New-SCId 'project'; projectRoot=Get-SCRoot; goal=''; activePlanId=$null; planApproved=$false; createdAt=$now; updatedAt=$now }
    Write-SCJson (Join-Path $dir 'state.json') $state
    '' | Set-Content -LiteralPath (Join-Path $dir 'events.jsonl') -Encoding UTF8
    $example=Join-Path $PSScriptRoot 'statefulclanker.example.json'
    if (Test-Path $example) { Copy-Item -LiteralPath $example -Destination (Join-Path $dir 'config.json') }
    else { Write-SCJson (Join-Path $dir 'config.json') ([ordered]@{ defaultProvider='opencode'; criticProvider=$null; validatorProvider=$null; providers=[ordered]@{}; workingSetBudgetChars=24000; maxFileChars=8000; requireHumanApprovalForPlan=$true; criticEnabled=$true; validatorEnabled=$true }) }
    Add-SCEvent 'project.initialized' 'StatefulClanker initialized.' @{ root=Get-SCRoot }
    Write-Host "Initialized $dir"
}
function Set-SCGoal([string]$Text) {
    Assert-SCInitialized
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Goal text is required.' }
    $s=Get-SCState; $s.goal=$Text; Save-SCState $s; Add-SCEvent 'goal.changed' $Text; Write-Host 'Goal updated.'
}
function Add-SCTask {
    if ([string]::IsNullOrWhiteSpace($Title)) { throw '-Title is required.' }
    if ([string]::IsNullOrWhiteSpace($Instruction)) { throw '-Instruction is required.' }
    $id=if ($TaskId) { $TaskId } else { New-SCId 'task' }
    if (Get-SCTasks | Where-Object { $_.id -eq $id }) { throw "Task already exists: $id" }
    $now=(Get-Date).ToUniversalTime().ToString('o')
    $task=[ordered]@{ id=$id; title=$Title; instruction=$Instruction; acceptance=@($Accept); dependsOn=@($DependsOn); retrieval=@($Retrieval); evidence=@($Evidence); provider=if($Provider){$Provider}else{$null}; role=$Role; humanGate=[bool]$HumanGate; status='pending'; latestRunId=$null; latestCritiqueId=$null; latestValidationId=$null; blockReason=$null; createdAt=$now; updatedAt=$now }
    Save-SCTask $task; Update-SCReadiness; Add-SCEvent 'task.created' $Title @{ taskId=$id }; Write-Host $id
}
function Show-SCStatus {
    Assert-SCInitialized; Update-SCReadiness; $s=Get-SCState; $tasks=@(Get-SCTasks)
    Write-Host "Goal: $($s.goal)"; Write-Host "Plan: $($s.activePlanId)  Approved: $($s.planApproved)"
    if ($tasks.Count -eq 0) { Write-Host 'Tasks: none'; return }
    $tasks | Sort-Object createdAt | Select-Object id,status,role,title | Format-Table -AutoSize
}
function Show-SCTaskList { Update-SCReadiness; Get-SCTasks | Sort-Object createdAt | Select-Object id,status,role,humanGate,title | Format-Table -AutoSize }
function Import-SCPlan([string]$PlanPath) {
    Assert-SCInitialized
    if (-not (Test-Path $PlanPath)) { throw "Plan file not found: $PlanPath" }
    $resolved=(Resolve-Path $PlanPath).Path; $plan=Read-SCJson $resolved
    if ($null -eq $plan -or $null -eq $plan.tasks) { throw 'Plan must contain a tasks array.' }
    $planId=New-SCId 'plan'
    Write-SCJson (Get-SCPath ("plans/{0}.json" -f $planId)) ([ordered]@{ id=$planId; name=$plan.name; summary=$plan.summary; importedAt=(Get-Date).ToUniversalTime().ToString('o'); source=$resolved; tasks=@($plan.tasks) })
    foreach ($p in @($plan.tasks)) {
        $id=if ($p.id) { [string]$p.id } else { New-SCId 'task' }
        if (Test-Path (Get-SCPath ("tasks/{0}.json" -f $id))) { throw "Plan task id already exists: $id" }
        $now=(Get-Date).ToUniversalTime().ToString('o')
        $task=[ordered]@{ id=$id; title=[string]$p.title; instruction=[string]$p.instruction; acceptance=@($p.acceptance); dependsOn=@($p.dependsOn); retrieval=@($p.retrieval); evidence=@($p.evidence); provider=if($p.provider){[string]$p.provider}else{$null}; role=if($p.role){[string]$p.role}else{'worker'}; humanGate=[bool]$p.humanGate; status='pending'; latestRunId=$null; latestCritiqueId=$null; latestValidationId=$null; blockReason=$null; createdAt=$now; updatedAt=$now }
        Save-SCTask $task
    }
    $s=Get-SCState; $s.activePlanId=$planId; $cfg=Get-SCConfig; $s.planApproved=-not [bool]$cfg.requireHumanApprovalForPlan; Save-SCState $s
    Update-SCReadiness; Add-SCEvent 'plan.imported' "Imported plan $($plan.name)" @{ planId=$planId; taskCount=@($plan.tasks).Count }; Write-Host "Imported $planId"
}
function Approve-SCPlan {
    $s=Get-SCState; if (-not $s.activePlanId) { throw 'No active plan.' }
    $s.planApproved=$true; Save-SCState $s; Add-SCEvent 'plan.approved' "Approved plan $($s.activePlanId)"; Write-Host 'Plan approved.'
}
function Get-SCRecentEvents([int]$Count=12) {
    $path=Get-SCPath 'events.jsonl'; if (-not (Test-Path $path)) { return @() }
    @(Get-Content -LiteralPath $path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last $Count)
}
function Get-SCDependencySummary($Task) {
    $out=@()
    foreach ($dep in @($Task.dependsOn)) {
        $dt=Get-SCTask $dep; $summary=[ordered]@{ id=$dt.id; title=$dt.title; status=$dt.status; latestRunId=$dt.latestRunId }
        if ($dt.latestRunId) { $run=Read-SCJson (Get-SCPath ("runs/{0}.json" -f $dt.latestRunId)); if ($run) { $summary.result=$run.stdout } }
        $out += $summary
    }
    $out
}
function Get-SCRetrievalPacket($Task) {
    $cfg=Get-SCConfig
    $budget=24000; if ($cfg.PSObject.Properties['workingSetBudgetChars']) { $budget=[int]$cfg.workingSetBudgetChars }
    $maxFile=8000; if ($cfg.PSObject.Properties['maxFileChars']) { $maxFile=[int]$cfg.maxFileChars }
    $remaining=$budget; $items=@(); $seen=@{}
    $selectors=@($Task.retrieval) + @($Task.evidence)
    foreach ($selector in $selectors) {
        if ([string]::IsNullOrWhiteSpace([string]$selector) -or $remaining -le 0) { continue }
        $pattern=[string]$selector
        $matches=@()
        try {
            if ($pattern.IndexOfAny(@('*','?','[')) -ge 0) { $matches=@(Get-ChildItem -Path $pattern -File -Recurse -ErrorAction SilentlyContinue) }
            elseif (Test-Path -LiteralPath $pattern -PathType Leaf) { $matches=@(Get-Item -LiteralPath $pattern) }
            elseif (Test-Path -LiteralPath $pattern -PathType Container) { $matches=@(Get-ChildItem -LiteralPath $pattern -File -Recurse -ErrorAction SilentlyContinue) }
        } catch { $matches=@() }
        foreach ($m in $matches) {
            if ($remaining -le 0) { break }
            $full=$m.FullName
            if ($full.StartsWith((Get-SCDir), [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($seen.ContainsKey($full)) { continue }; $seen[$full]=$true
            try { $text=Get-Content -Raw -LiteralPath $full -ErrorAction Stop } catch { continue }
            if ($null -eq $text) { $text='' }
            $take=[Math]::Min([Math]::Min($text.Length,$maxFile),$remaining)
            $excerpt=if($take -gt 0){$text.Substring(0,$take)}else{''}
            $rel=$full.Substring((Get-SCRoot).Length).TrimStart('\','/')
            $items += [ordered]@{ path=$rel; chars=$take; truncated=($text.Length -gt $take); content=$excerpt }
            $remaining-=$take
        }
    }
    [ordered]@{ budgetChars=$budget; usedChars=($budget-$remaining); items=$items }
}
function New-SCWorkerPrompt($Task) {
    $s=Get-SCState; $retrieved=Get-SCRetrievalPacket $Task
    $packet=[ordered]@{ projectGoal=$s.goal; projectRoot=Get-SCRoot; task=[ordered]@{ id=$Task.id; title=$Task.title; instruction=$Task.instruction; role=$Task.role; acceptance=@($Task.acceptance); retrieval=@($Task.retrieval); evidence=@($Task.evidence) }; dependencies=@(Get-SCDependencySummary $Task); retrieved=$retrieved; recentEvents=@(Get-SCRecentEvents 12); outputContract=@{ instruction='Perform only this task. Be explicit about files changed, commands run, failures, and unresolved risks. Do not claim acceptance criteria passed unless you verified them.' } }
@"
You are a cold-start worker in StatefulClanker. You have no useful conversational history beyond this packet.
Treat project files and supplied durable state as authoritative.

STATEFULCLANKER PACKET
======================
$(ConvertTo-SCJson $packet -Depth 14)

Return a concise task result. If you cannot complete the task, report blocking evidence precisely rather than improvising project-wide decisions.
"@
}
function New-SCReviewPrompt($Task,$Run,[string]$Stage) {
    $s=Get-SCState; $retrieved=Get-SCRetrievalPacket $Task
    $contract=if($Stage -eq 'critic'){'Check omissions, contradictions, risky assumptions, regressions, and whether the worker actually addressed the task.'}else{'Judge the acceptance criteria using available evidence. Prefer objective verification. Do not trust the worker claim without evidence.'}
@"
You are the $Stage in StatefulClanker. You did not perform the work.
$contract

PROJECT GOAL:
$($s.goal)

TASK:
$(ConvertTo-SCJson ([ordered]@{id=$Task.id;title=$Task.title;instruction=$Task.instruction;acceptance=@($Task.acceptance)}) -Depth 8)

WORKER RECEIPT:
$(ConvertTo-SCJson ([ordered]@{runId=$Run.id;exitCode=$Run.exitCode;stdout=$Run.stdout;stderr=$Run.stderr}) -Depth 8)

RETRIEVED EVIDENCE:
$(ConvertTo-SCJson $retrieved -Depth 12)

Your first non-empty line MUST be exactly VERDICT: PASS or VERDICT: FAIL.
Then explain the evidence briefly. On FAIL, state the concrete reason and what must change.
"@
}
function Resolve-SCProviderByName([string]$Name) {
    $cfg=Get-SCConfig
    $prop=$cfg.providers.PSObject.Properties[$Name]; if ($null -eq $prop) { throw "Provider '$Name' is not configured in .statefulclanker/config.json" }
    [ordered]@{ name=$Name; config=$prop.Value }
}
function Resolve-SCProvider($Task,[string]$Override,[string]$Stage='worker') {
    $cfg=Get-SCConfig; $name=$null
    if ($Override) { $name=$Override }
    elseif ($Stage -eq 'critic' -and $cfg.PSObject.Properties['criticProvider'] -and $cfg.criticProvider) { $name=[string]$cfg.criticProvider }
    elseif ($Stage -eq 'validator' -and $cfg.PSObject.Properties['validatorProvider'] -and $cfg.validatorProvider) { $name=[string]$cfg.validatorProvider }
    elseif ($Task.provider) { $name=[string]$Task.provider }
    else { $name=[string]$cfg.defaultProvider }
    Resolve-SCProviderByName $name
}
function Expand-SCArg([string]$Arg,[string]$Prompt,[string]$PromptFile,$Task) { $Arg.Replace('{prompt}',$Prompt).Replace('{promptFile}',$PromptFile).Replace('{projectRoot}',(Get-SCRoot)).Replace('{taskId}',[string]$Task.id) }
function Invoke-SCProvider($Task,[string]$Prompt,[string]$Stage,[string]$ProviderOverride) {
    $providerRec=Resolve-SCProvider $Task $ProviderOverride $Stage; $providerCfg=$providerRec.config; $receiptId=New-SCId $Stage
    $promptPath=Get-SCPath ("prompts/{0}.txt" -f $receiptId); $prompt | Set-Content -LiteralPath $promptPath -Encoding UTF8
    $exe=[string]$providerCfg.command; $args=@(); foreach($a in @($providerCfg.args)){ $args += (Expand-SCArg ([string]$a) $prompt $promptPath $Task) }
    $stdoutFile=Get-SCPath ("runs/{0}.stdout.txt" -f $receiptId); $stderrFile=Get-SCPath ("runs/{0}.stderr.txt" -f $receiptId)
    $started=(Get-Date).ToUniversalTime(); $stdout=''; $stderr=''; $exit=-1
    try {
        $proc=Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory (Get-SCRoot) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $exit=$proc.ExitCode; if(Test-Path $stdoutFile){$stdout=Get-Content -Raw -LiteralPath $stdoutFile}; if(Test-Path $stderrFile){$stderr=Get-Content -Raw -LiteralPath $stderrFile}
    } catch { $stderr=$_ | Out-String; $exit=-1 }
    $ended=(Get-Date).ToUniversalTime()
    [ordered]@{ id=$receiptId; taskId=$Task.id; stage=$Stage; provider=$providerRec.name; command=$exe; args=$args; promptPath=$promptPath; startedAt=$started.ToString('o'); endedAt=$ended.ToString('o'); durationSeconds=[math]::Round(($ended-$started).TotalSeconds,3); exitCode=$exit; stdout=$stdout; stderr=$stderr }
}
function Get-SCVerdict([string]$Text,[int]$ExitCode) {
    if ($ExitCode -ne 0) { return 'FAIL' }
    foreach ($line in @($Text -split "`r?`n")) {
        $t=$line.Trim(); if (-not $t) { continue }
        if ($t -match '^VERDICT:\s*PASS\s*$') { return 'PASS' }
        if ($t -match '^VERDICT:\s*FAIL\s*$') { return 'FAIL' }
        break
    }
    'FAIL'
}
function Invoke-SCReviewStage($Task,$Run,[string]$Stage,[string]$ProviderOverride) {
    $prompt=New-SCReviewPrompt $Task $Run $Stage; $receipt=Invoke-SCProvider $Task $prompt $Stage $ProviderOverride; $receipt.verdict=Get-SCVerdict ([string]$receipt.stdout) ([int]$receipt.exitCode)
    $dir=if($Stage -eq 'critic'){'critiques'}else{'validations'}
    Write-SCJson (Get-SCPath ("{0}/{1}.json" -f $dir,$receipt.id)) $receipt
    Add-SCEvent ("{0}.finished" -f $Stage) ("$Stage $($receipt.id): $($receipt.verdict)") @{taskId=$Task.id;receiptId=$receipt.id;verdict=$receipt.verdict}
    $receipt
}
function Invoke-SCTask([string]$RequestedTaskId,[string]$ProviderOverride) {
    Assert-SCInitialized; Update-SCReadiness; $s=Get-SCState; $cfg=Get-SCConfig
    if ($s.activePlanId -and [bool]$cfg.requireHumanApprovalForPlan -and -not [bool]$s.planApproved) { throw 'Active plan requires approval. Run: .\StatefulClanker.ps1 plan approve' }
    $task=if($RequestedTaskId){Get-SCTask $RequestedTaskId}else{Get-SCTasks | Where-Object { $_.status -eq 'ready' -and -not $_.humanGate } | Sort-Object createdAt | Select-Object -First 1}
    if ($null -eq $task) { throw 'No runnable ready task found.' }
    if ($task.status -ne 'ready') { throw "Task $($task.id) is '$($task.status)', not ready." }
    if ($task.humanGate) { throw "Task $($task.id) requires a human gate." }
    $task.status='running'; Save-SCTask $task; Add-SCEvent 'run.started' "Worker started" @{taskId=$task.id}
    $run=Invoke-SCProvider $task (New-SCWorkerPrompt $task) 'run' $ProviderOverride
    Write-SCJson (Get-SCPath ("runs/{0}.json" -f $run.id)) $run
    $task=Get-SCTask $task.id; $task.latestRunId=$run.id
    if ([int]$run.exitCode -ne 0) {
        $task.status='failed'; $task.blockReason="Worker exited $($run.exitCode)"; Save-SCTask $task; Add-SCEvent 'run.failed' $task.blockReason @{taskId=$task.id;runId=$run.id}; Write-Warning $task.blockReason; return
    }
    Add-SCEvent 'run.finished' "Worker finished $($run.id)" @{taskId=$task.id;runId=$run.id}
    if ([bool]$cfg.criticEnabled) {
        $task.status='reviewing'; Save-SCTask $task
        $crit=Invoke-SCReviewStage $task $run 'critic' $null; $task=Get-SCTask $task.id; $task.latestCritiqueId=$crit.id
        if ($crit.verdict -ne 'PASS') { $task.status='needs_rework'; $task.blockReason='Critic rejected worker result.'; Save-SCTask $task; Write-Warning $task.blockReason; return }
    }
    if ([bool]$cfg.validatorEnabled) {
        $task.status='validating'; Save-SCTask $task
        $val=Invoke-SCReviewStage $task $run 'validator' $null; $task=Get-SCTask $task.id; $task.latestValidationId=$val.id
        if ($val.verdict -ne 'PASS') { $task.status='needs_rework'; $task.blockReason='Validator rejected worker result.'; Save-SCTask $task; Write-Warning $task.blockReason; return }
    }
    $task.status='complete'; $task.blockReason=$null; Save-SCTask $task; Add-SCEvent 'task.completed' "Completed $($task.id) after automatic review pipeline" @{taskId=$task.id;runId=$run.id}; Update-SCReadiness
    Write-Host "Task complete: $($task.id)"
}
function Retry-SCTask([string]$Id) { if(-not $Id){throw '-TaskId is required.'}; $t=Get-SCTask $Id; $t.status='ready'; $t.blockReason=$null; Save-SCTask $t; Add-SCEvent 'task.retried' "Retry $Id" @{taskId=$Id}; Write-Host 'Task reset to ready.' }
function Complete-SCTask([string]$Id) { if(-not $Id){throw '-TaskId is required.'}; $t=Get-SCTask $Id; $t.status='complete'; $t.blockReason=$null; Save-SCTask $t; Add-SCEvent 'task.completed.manual' "Completed $Id manually" @{taskId=$Id}; Update-SCReadiness; Write-Host 'Task completed.' }
function Block-SCTask([string]$Id,[string]$Why) { if(-not $Id){throw '-TaskId is required.'}; if(-not $Why){throw '-Reason is required.'}; $t=Get-SCTask $Id; $t.status='blocked'; $t.blockReason=$Why; Save-SCTask $t; Add-SCEvent 'task.blocked' $Why @{taskId=$Id}; Write-Host 'Task blocked.' }
function Show-SCProviders { $cfg=Get-SCConfig; $rows=@(foreach($p in $cfg.providers.PSObject.Properties){[pscustomobject]@{name=$p.Name;command=$p.Value.command;mode=$p.Value.mode}}); $rows | Format-Table -AutoSize }

switch ($Command.ToLowerInvariant()) {
    'init' { Initialize-SC; break }
    'goal' { $text=if($Message){$Message}elseif($Subcommand){$Subcommand}else{$Title}; Set-SCGoal $text; break }
    'status' { Show-SCStatus; break }
    'task' {
        if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='list'}
        switch($Subcommand.ToLowerInvariant()) { 'add'{Add-SCTask;break}; 'list'{Show-SCTaskList;break}; 'show'{if(-not $TaskId){throw '-TaskId is required.'}; Get-SCTask $TaskId | ConvertTo-SCJson -Depth 12 | Write-Host;break}; 'retry'{Retry-SCTask $TaskId;break}; default{throw "Unknown task subcommand: $Subcommand"} }
        break
    }
    'plan' {
        if($null -eq $Subcommand){$Subcommand=''}
        switch($Subcommand.ToLowerInvariant()) { 'import'{if(-not $Path){throw '-Path is required.'}; Import-SCPlan $Path;break}; 'approve'{Approve-SCPlan;break}; default{throw "Unknown plan subcommand: $Subcommand"} }
        break
    }
    'run' { Invoke-SCTask $TaskId $Provider; break }
    'complete' { Complete-SCTask $TaskId; break }
    'block' { Block-SCTask $TaskId $Reason; break }
    'event' { if(-not $Message){throw '-Message is required.'}; Add-SCEvent 'user.note' $Message; Write-Host 'Event recorded.'; break }
    'provider' { if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='list'}; if($Subcommand.ToLowerInvariant() -eq 'list'){Show-SCProviders}else{throw "Unknown provider subcommand: $Subcommand"}; break }
    default { throw "Unknown command: $Command" }
}

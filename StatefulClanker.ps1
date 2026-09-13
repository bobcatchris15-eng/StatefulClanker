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
    return ($raw | ConvertFrom-Json)
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
    foreach ($child in @('tasks','plans','runs','critiques','validations','prompts')) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $child) | Out-Null }
    $now=(Get-Date).ToUniversalTime().ToString('o')
    $state=[ordered]@{ schemaVersion=1; projectId=New-SCId 'project'; projectRoot=Get-SCRoot; goal=''; activePlanId=$null; planApproved=$false; createdAt=$now; updatedAt=$now }
    Write-SCJson (Join-Path $dir 'state.json') $state
    '' | Set-Content -LiteralPath (Join-Path $dir 'events.jsonl') -Encoding UTF8
    $example=Join-Path $PSScriptRoot 'statefulclanker.example.json'
    if (Test-Path $example) { Copy-Item -LiteralPath $example -Destination (Join-Path $dir 'config.json') }
    else { Write-SCJson (Join-Path $dir 'config.json') ([ordered]@{ defaultProvider='opencode'; providers=[ordered]@{}; maxConcurrent=3; workingSetBudgetChars=24000; requireHumanApprovalForPlan=$true; criticEnabled=$true; validatorEnabled=$true }) }
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
    $task=[ordered]@{ id=$id; title=$Title; instruction=$Instruction; acceptance=@($Accept); dependsOn=@($DependsOn); retrieval=@($Retrieval); evidence=@($Evidence); provider=if($Provider){$Provider}else{$null}; role=$Role; humanGate=[bool]$HumanGate; status='pending'; latestRunId=$null; blockReason=$null; createdAt=$now; updatedAt=$now }
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
        $task=[ordered]@{ id=$id; title=[string]$p.title; instruction=[string]$p.instruction; acceptance=@($p.acceptance); dependsOn=@($p.dependsOn); retrieval=@($p.retrieval); evidence=@($p.evidence); provider=if($p.provider){[string]$p.provider}else{$null}; role=if($p.role){[string]$p.role}else{'worker'}; humanGate=[bool]$p.humanGate; status='pending'; latestRunId=$null; blockReason=$null; createdAt=$now; updatedAt=$now }
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
function New-SCPrompt($Task) {
    $s=Get-SCState
    $packet=[ordered]@{ projectGoal=$s.goal; projectRoot=Get-SCRoot; task=[ordered]@{ id=$Task.id; title=$Task.title; instruction=$Task.instruction; role=$Task.role; acceptance=@($Task.acceptance); retrieval=@($Task.retrieval); evidence=@($Task.evidence) }; dependencies=@(Get-SCDependencySummary $Task); recentEvents=@(Get-SCRecentEvents 12); outputContract=@{ instruction='Perform only this task. Be explicit about files changed, commands run, failures, and unresolved risks. Do not claim acceptance criteria passed unless you verified them.' } }
@"
You are a cold-start worker in StatefulClanker. You have no useful conversational history beyond this packet.
Treat the project files and supplied durable state as authoritative.

STATEFULCLANKER PACKET
======================
$(ConvertTo-SCJson $packet -Depth 12)

Return a concise task result. If you cannot complete the task, report the blocking evidence precisely rather than improvising project-wide decisions.
"@
}
function Resolve-SCProvider($Task,[string]$Override) {
    $cfg=Get-SCConfig; $name=if($Override){$Override}elseif($Task.provider){[string]$Task.provider}else{[string]$cfg.defaultProvider}
    $prop=$cfg.providers.PSObject.Properties[$name]; if ($null -eq $prop) { throw "Provider '$name' is not configured in .statefulclanker/config.json" }
    [ordered]@{ name=$name; config=$prop.Value }
}
function Expand-SCArg([string]$Arg,[string]$Prompt,[string]$PromptFile,$Task) { $Arg.Replace('{prompt}',$Prompt).Replace('{promptFile}',$PromptFile).Replace('{projectRoot}',(Get-SCRoot)).Replace('{taskId}',[string]$Task.id) }
function Invoke-SCTask([string]$RequestedTaskId,[string]$ProviderOverride) {
    Assert-SCInitialized; Update-SCReadiness; $s=Get-SCState; $cfg=Get-SCConfig
    if ($s.activePlanId -and [bool]$cfg.requireHumanApprovalForPlan -and -not [bool]$s.planApproved) { throw 'Active plan requires approval. Run: .\StatefulClanker.ps1 plan approve' }
    $task=if($RequestedTaskId){Get-SCTask $RequestedTaskId}else{Get-SCTasks | Where-Object { $_.status -eq 'ready' -and -not $_.humanGate } | Sort-Object createdAt | Select-Object -First 1}
    if ($null -eq $task) { throw 'No runnable ready task found.' }
    if ($task.status -ne 'ready') { throw "Task $($task.id) is '$($task.status)', not ready." }
    if ($task.humanGate) { throw "Task $($task.id) requires a human gate." }
    $providerRec=Resolve-SCProvider $task $ProviderOverride; $providerCfg=$providerRec.config; $prompt=New-SCPrompt $task; $runId=New-SCId 'run'; $promptPath=Get-SCPath ("prompts/{0}.txt" -f $runId)
    $prompt | Set-Content -LiteralPath $promptPath -Encoding UTF8
    $task.status='running'; $task.latestRunId=$runId; Save-SCTask $task; Add-SCEvent 'run.started' "Started $runId" @{ taskId=$task.id; provider=$providerRec.name }
    $exe=[string]$providerCfg.command; $args=@(); foreach($a in @($providerCfg.args)){ $args += (Expand-SCArg ([string]$a) $prompt $promptPath $task) }
    $started=(Get-Date).ToUniversalTime(); $stdout=''; $stderr=''; $exit=-1
    try {
        $stdoutFile=Get-SCPath ("runs/{0}.stdout.txt" -f $runId); $stderrFile=Get-SCPath ("runs/{0}.stderr.txt" -f $runId)
        $proc=Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory (Get-SCRoot) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $exit=$proc.ExitCode; if(Test-Path $stdoutFile){$stdout=Get-Content -Raw -LiteralPath $stdoutFile}; if(Test-Path $stderrFile){$stderr=Get-Content -Raw -LiteralPath $stderrFile}
    } catch { $stderr=$_ | Out-String; $exit=-1 }
    $ended=(Get-Date).ToUniversalTime()
    Write-SCJson (Get-SCPath ("runs/{0}.json" -f $runId)) ([ordered]@{ id=$runId; taskId=$task.id; provider=$providerRec.name; command=$exe; args=$args; promptPath=$promptPath; startedAt=$started.ToString('o'); endedAt=$ended.ToString('o'); durationSeconds=[math]::Round(($ended-$started).TotalSeconds,3); exitCode=$exit; stdout=$stdout; stderr=$stderr })
    $task=Get-SCTask $task.id; $task.status=if($exit -eq 0){'needs_review'}else{'failed'}; Save-SCTask $task; Add-SCEvent 'run.finished' "Finished $runId with exit $exit" @{ taskId=$task.id; runId=$runId; exitCode=$exit }
    Write-Host "Run: $runId"; Write-Host "Task status: $($task.status)"; if($stdout){Write-Host $stdout}; if($stderr){Write-Warning $stderr}
}
function Complete-SCTask([string]$Id) { if(-not $Id){throw '-TaskId is required.'}; $t=Get-SCTask $Id; $t.status='complete'; $t.blockReason=$null; Save-SCTask $t; Add-SCEvent 'task.completed' "Completed $Id" @{taskId=$Id}; Update-SCReadiness; Write-Host 'Task completed.' }
function Block-SCTask([string]$Id,[string]$Why) { if(-not $Id){throw '-TaskId is required.'}; if(-not $Why){throw '-Reason is required.'}; $t=Get-SCTask $Id; $t.status='blocked'; $t.blockReason=$Why; Save-SCTask $t; Add-SCEvent 'task.blocked' $Why @{taskId=$Id}; Write-Host 'Task blocked.' }
function Show-SCProviders { $cfg=Get-SCConfig; $rows=@(foreach($p in $cfg.providers.PSObject.Properties){[pscustomobject]@{name=$p.Name;command=$p.Value.command;mode=$p.Value.mode}}); $rows | Format-Table -AutoSize }
switch ($Command.ToLowerInvariant()) {
    'init' { Initialize-SC; break }
    'goal' { $text=if($Message){$Message}elseif($Subcommand){$Subcommand}else{$Title}; Set-SCGoal $text; break }
    'status' { Show-SCStatus; break }
    'task' {
        if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='list'}
        switch($Subcommand.ToLowerInvariant()) { 'add'{Add-SCTask;break}; 'list'{Show-SCTaskList;break}; 'show'{if(-not $TaskId){throw '-TaskId is required.'}; Get-SCTask $TaskId | ConvertTo-SCJson -Depth 12 | Write-Host;break}; default{throw "Unknown task subcommand: $Subcommand"} }
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

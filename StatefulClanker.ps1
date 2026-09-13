<# StatefulClanker: durable-state orchestration for cold-start CLI workers. #>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Position=0)][string]$Command='status',
    [Parameter(Position=1)][string]$Subcommand,
    [string]$Title,[string]$Instruction,[string[]]$Accept,[string[]]$DependsOn,
    [string[]]$Retrieval,[string[]]$Evidence,[string]$Provider,[string]$Role='worker',
    [switch]$HumanGate,[string]$TaskId,[string]$Path,[string]$Reason,[string]$Message,[string]$RunId
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Get-SCRoot { (Get-Location).Path }
function Get-SCDir { Join-Path (Get-SCRoot) '.statefulclanker' }
function Get-SCPath([string]$Child) { Join-Path (Get-SCDir) $Child }
function ConvertTo-SCJson($Value,[int]$Depth=12) { $Value | ConvertTo-Json -Depth $Depth }
function Write-SCJson([string]$TargetPath,$Value) {
    $parent=Split-Path -Parent $TargetPath
    if($parent -and -not(Test-Path $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
    $tmp="$TargetPath.tmp"
    ConvertTo-SCJson $Value 20 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -Force -LiteralPath $tmp -Destination $TargetPath
}
function Read-SCJson([string]$TargetPath) {
    if(-not(Test-Path $TargetPath)){return $null}
    $raw=Get-Content -Raw -LiteralPath $TargetPath
    if([string]::IsNullOrWhiteSpace($raw)){return $null}
    return ($raw|ConvertFrom-Json)
}
function Assert-SCInitialized { if(-not(Test-Path (Get-SCPath 'state.json'))){throw 'Not initialized. Run: .\StatefulClanker.ps1 init'} }
function New-SCId([string]$Prefix) { "$Prefix-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0,8))" }
function Add-SCEvent([string]$Type,[string]$Text,$Data=$null) {
    Assert-SCInitialized
    $evt=[ordered]@{ts=(Get-Date).ToUniversalTime().ToString('o');type=$Type;message=$Text;data=$Data}
    (ConvertTo-SCJson $evt 10 -replace "`r?`n",'')|Add-Content -LiteralPath (Get-SCPath 'events.jsonl') -Encoding UTF8
}
function Get-SCState { Assert-SCInitialized;Read-SCJson (Get-SCPath 'state.json') }
function Save-SCState($State) { $State.updatedAt=(Get-Date).ToUniversalTime().ToString('o');Write-SCJson (Get-SCPath 'state.json') $State }
function Get-SCConfig { Assert-SCInitialized;$cfg=Read-SCJson (Get-SCPath 'config.json');if($null-eq$cfg){throw 'Missing .statefulclanker/config.json'};return $cfg }
function Get-SCTask([string]$Id) { $task=Read-SCJson (Get-SCPath ("tasks/{0}.json"-f$Id));if($null-eq$task){throw "Unknown task: $Id"};return $task }
function Save-SCTask($Task) { $Task.updatedAt=(Get-Date).ToUniversalTime().ToString('o');Write-SCJson (Get-SCPath ("tasks/{0}.json"-f$Task.id)) $Task }
function Get-SCTasks { Assert-SCInitialized;$dir=Get-SCPath 'tasks';if(-not(Test-Path $dir)){return @()};return @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File|ForEach-Object{Read-SCJson $_.FullName}) }
function Update-SCReadiness {
    $tasks=@(Get-SCTasks);$map=@{}
    foreach($task in $tasks){if($task.id){$map[[string]$task.id]=$task}}
    foreach($task in $tasks){
        if($task.status-ne'pending'){continue};$ready=$true
        foreach($dep in @($task.dependsOn)){
            if([string]::IsNullOrWhiteSpace([string]$dep)){continue}
            if(-not$map.ContainsKey([string]$dep)-or$map[[string]$dep].status-ne'complete'){$ready=$false;break}
        }
        if($ready){$task.status='ready';Save-SCTask $task}
    }
}
function Ensure-SCTelemetryLayout {
    foreach($child in @('telemetry','telemetry/active','telemetry/runs')){$target=Get-SCPath $child;if(-not(Test-Path $target)){New-Item -ItemType Directory -Force -Path $target|Out-Null}}
    $events=Get-SCPath 'telemetry/events.jsonl';if(-not(Test-Path $events)){''|Set-Content -LiteralPath $events -Encoding UTF8}
}
function Add-SCTelemetryEvent([string]$Type,$Record) {
    Ensure-SCTelemetryLayout
    $evt=[ordered]@{ts=(Get-Date).ToUniversalTime().ToString('o');type=$Type;agentId=$Record.agentId;taskId=$Record.taskId;stage=$Record.stage;lifecycle=$Record.lifecycle;provider=$Record.provider}
    (ConvertTo-SCJson $evt 8 -replace "`r?`n",'')|Add-Content -LiteralPath (Get-SCPath 'telemetry/events.jsonl') -Encoding UTF8
}
function Save-SCActiveTelemetry($Record) { Ensure-SCTelemetryLayout;Write-SCJson (Get-SCPath ("telemetry/active/{0}.json"-f$Record.agentId)) $Record }
function Complete-SCTelemetry($Record) {
    Ensure-SCTelemetryLayout;Write-SCJson (Get-SCPath ("telemetry/runs/{0}.json"-f$Record.agentId)) $Record
    $active=Get-SCPath ("telemetry/active/{0}.json"-f$Record.agentId);if(Test-Path $active){Remove-Item -Force -LiteralPath $active}
    Add-SCTelemetryEvent 'agent.finished' $Record
}
function Get-SCActiveTelemetry { Ensure-SCTelemetryLayout;return @(Get-ChildItem -LiteralPath (Get-SCPath 'telemetry/active') -Filter '*.json' -File|ForEach-Object{Read-SCJson $_.FullName}|Sort-Object startedAt) }
function Get-SCTelemetryRuns([int]$Limit=100) { Ensure-SCTelemetryLayout;return @(Get-ChildItem -LiteralPath (Get-SCPath 'telemetry/runs') -Filter '*.json' -File|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First $Limit|ForEach-Object{Read-SCJson $_.FullName}) }

function Initialize-SC {
    $dir=Get-SCDir
    if(Test-Path (Join-Path $dir 'state.json')){Ensure-SCTelemetryLayout;Write-Host 'Already initialized.';return}
    New-Item -ItemType Directory -Force -Path $dir|Out-Null
    foreach($child in @('tasks','plans','runs','critiques','validations','prompts','telemetry','telemetry/active','telemetry/runs')){New-Item -ItemType Directory -Force -Path (Join-Path $dir $child)|Out-Null}
    $now=(Get-Date).ToUniversalTime().ToString('o')
    Write-SCJson (Join-Path $dir 'state.json') ([ordered]@{schemaVersion=3;projectId=New-SCId 'project';projectRoot=Get-SCRoot;goal='';activePlanId=$null;planApproved=$false;createdAt=$now;updatedAt=$now})
    ''|Set-Content -LiteralPath (Join-Path $dir 'events.jsonl') -Encoding UTF8
    ''|Set-Content -LiteralPath (Join-Path $dir 'telemetry/events.jsonl') -Encoding UTF8
    $example=Join-Path $PSScriptRoot 'statefulclanker.example.json'
    if(Test-Path $example){Copy-Item -LiteralPath $example -Destination (Join-Path $dir 'config.json')}
    else{Write-SCJson (Join-Path $dir 'config.json') ([ordered]@{defaultProvider='opencode';criticProvider=$null;validatorProvider=$null;providers=[ordered]@{};workingSetBudgetChars=24000;maxFileChars=8000;requireHumanApprovalForPlan=$true;criticEnabled=$true;validatorEnabled=$true})}
    Add-SCEvent 'project.initialized' 'StatefulClanker initialized.' @{root=Get-SCRoot};Write-Host "Initialized $dir"
}
function Set-SCGoal([string]$Text) { Assert-SCInitialized;if([string]::IsNullOrWhiteSpace($Text)){throw 'Goal text required.'};$state=Get-SCState;$state.goal=$Text;Save-SCState $state;Add-SCEvent 'goal.changed' $Text;Write-Host 'Goal updated.' }
function Add-SCTask {
    if([string]::IsNullOrWhiteSpace($Title)){throw '-Title is required.'};if([string]::IsNullOrWhiteSpace($Instruction)){throw '-Instruction is required.'}
    $id=if($TaskId){$TaskId}else{New-SCId 'task'};if(@(Get-SCTasks|Where-Object{$_.id-eq$id}).Count-gt 0){throw "Task exists: $id"}
    $now=(Get-Date).ToUniversalTime().ToString('o')
    $task=[ordered]@{id=$id;title=$Title;instruction=$Instruction;acceptance=@($Accept);dependsOn=@($DependsOn);retrieval=@($Retrieval);evidence=@($Evidence);provider=if($Provider){$Provider}else{$null};role=$Role;humanGate=[bool]$HumanGate;status='pending';latestRunId=$null;latestCritiqueId=$null;latestValidationId=$null;blockReason=$null;createdAt=$now;updatedAt=$now}
    Save-SCTask $task;Update-SCReadiness;Add-SCEvent 'task.created' $Title @{taskId=$id};Write-Host $id
}
function Show-SCStatus {
    Assert-SCInitialized;Update-SCReadiness;$state=Get-SCState;$tasks=@(Get-SCTasks);$active=@(Get-SCActiveTelemetry)
    Write-Host "Goal: $($state.goal)";Write-Host "Plan: $($state.activePlanId)  Approved: $($state.planApproved)";Write-Host "Active agents: $($active.Count)"
    if($tasks.Count-eq 0){Write-Host 'Tasks: none';return};$tasks|Sort-Object createdAt|Select-Object id,status,role,title|Format-Table -AutoSize
}
function Import-SCPlan([string]$PlanPath) {
    Assert-SCInitialized;if(-not(Test-Path $PlanPath)){throw "Plan not found: $PlanPath"};$resolved=(Resolve-Path $PlanPath).Path;$plan=Read-SCJson $resolved
    if($null-eq$plan-or$null-eq$plan.tasks){throw 'Plan must contain tasks.'};$planId=New-SCId 'plan'
    $name=if($plan.PSObject.Properties['name']){$plan.name}else{'Imported plan'};$summary=if($plan.PSObject.Properties['summary']){$plan.summary}else{''}
    Write-SCJson (Get-SCPath ("plans/{0}.json"-f$planId)) ([ordered]@{id=$planId;name=$name;summary=$summary;source=$resolved;importedAt=(Get-Date).ToUniversalTime().ToString('o');tasks=@($plan.tasks)})
    foreach($item in @($plan.tasks)){
        $id=if($item.PSObject.Properties['id']-and$item.id){[string]$item.id}else{New-SCId 'task'};if(Test-Path (Get-SCPath ("tasks/{0}.json"-f$id))){throw "Plan task id already exists: $id"};$now=(Get-Date).ToUniversalTime().ToString('o')
        $task=[ordered]@{id=$id;title=[string]$item.title;instruction=[string]$item.instruction;acceptance=if($item.PSObject.Properties['acceptance']){@($item.acceptance)}else{@()};dependsOn=if($item.PSObject.Properties['dependsOn']){@($item.dependsOn)}else{@()};retrieval=if($item.PSObject.Properties['retrieval']){@($item.retrieval)}else{@()};evidence=if($item.PSObject.Properties['evidence']){@($item.evidence)}else{@()};provider=if($item.PSObject.Properties['provider']-and$item.provider){[string]$item.provider}else{$null};role=if($item.PSObject.Properties['role']-and$item.role){[string]$item.role}else{'worker'};humanGate=if($item.PSObject.Properties['humanGate']){[bool]$item.humanGate}else{$false};status='pending';latestRunId=$null;latestCritiqueId=$null;latestValidationId=$null;blockReason=$null;createdAt=$now;updatedAt=$now}
        Save-SCTask $task
    }
    $state=Get-SCState;$state.activePlanId=$planId;$cfg=Get-SCConfig;$state.planApproved=-not[bool]$cfg.requireHumanApprovalForPlan;Save-SCState $state;Update-SCReadiness;Add-SCEvent 'plan.imported' "Imported $planId" @{taskCount=@($plan.tasks).Count};Write-Host "Imported $planId"
}
function Approve-SCPlan { $state=Get-SCState;if(-not$state.activePlanId){throw 'No active plan.'};$state.planApproved=$true;Save-SCState $state;Add-SCEvent 'plan.approved' "Approved $($state.activePlanId)";Write-Host 'Plan approved.' }
function Get-SCRecentEvents([int]$Count=12) { $path=Get-SCPath 'events.jsonl';if(-not(Test-Path $path)){return @()};return @(Get-Content -LiteralPath $path|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Select-Object -Last $Count) }
function Get-SCDependencySummary($Task) {
    $out=@();foreach($dep in @($Task.dependsOn)){if([string]::IsNullOrWhiteSpace([string]$dep)){continue};$dependency=Get-SCTask ([string]$dep);$summary=[ordered]@{id=$dependency.id;title=$dependency.title;status=$dependency.status;latestRunId=$dependency.latestRunId};if($dependency.latestRunId){$receipt=Read-SCJson (Get-SCPath ("runs/{0}.json"-f$dependency.latestRunId));if($receipt){$summary.result=$receipt.stdout}};$out+=$summary};return $out
}
function Get-SCRetrievalPacket($Task) {
    $cfg=Get-SCConfig;$budget=if($cfg.PSObject.Properties['workingSetBudgetChars']){[int]$cfg.workingSetBudgetChars}else{24000};$maxFile=if($cfg.PSObject.Properties['maxFileChars']){[int]$cfg.maxFileChars}else{8000};$remaining=$budget;$items=@();$seen=@{}
    foreach($selector in @($Task.retrieval)+@($Task.evidence)){
        if([string]::IsNullOrWhiteSpace([string]$selector)-or$remaining-le 0){continue};$pattern=[string]$selector;$matches=@()
        try{if($pattern-match'[*?\[]'){$matches=@(Get-ChildItem -Path $pattern -File -Recurse -ErrorAction SilentlyContinue)}elseif(Test-Path -LiteralPath $pattern -PathType Leaf){$matches=@(Get-Item -LiteralPath $pattern)}elseif(Test-Path -LiteralPath $pattern -PathType Container){$matches=@(Get-ChildItem -LiteralPath $pattern -File -Recurse -ErrorAction SilentlyContinue)}}catch{$matches=@()}
        foreach($match in $matches){if($remaining-le 0){break};$full=$match.FullName;if($full.StartsWith((Get-SCDir),[StringComparison]::OrdinalIgnoreCase)){continue};if($seen.ContainsKey($full)){continue};$seen[$full]=$true;try{$text=Get-Content -Raw -LiteralPath $full}catch{continue};if($null-eq$text){$text=''};$take=[Math]::Min([Math]::Min($text.Length,$maxFile),$remaining);$excerpt=if($take-gt 0){$text.Substring(0,$take)}else{''};$relative=($full.Substring((Get-SCRoot).Length)-replace'^[\\/]+','');$items+=[ordered]@{path=$relative;chars=$take;truncated=($text.Length-gt$take);content=$excerpt};$remaining-=$take}
    }
    return [ordered]@{budgetChars=$budget;usedChars=($budget-$remaining);items=$items}
}
function New-SCWorkerPrompt($Task) {
    $state=Get-SCState;$packet=[ordered]@{projectGoal=$state.goal;projectRoot=Get-SCRoot;task=[ordered]@{id=$Task.id;title=$Task.title;instruction=$Task.instruction;role=$Task.role;acceptance=@($Task.acceptance);retrieval=@($Task.retrieval);evidence=@($Task.evidence)};dependencies=@(Get-SCDependencySummary $Task);retrieved=Get-SCRetrievalPacket $Task;recentEvents=@(Get-SCRecentEvents 12);outputContract='Perform only this task. Report files changed, commands run, failures, and unresolved risks. Do not claim verification you did not perform.'}
    return "You are a cold-start StatefulClanker worker. Durable state and project files are authoritative.`r`n`r`nSTATEFULCLANKER PACKET`r`n======================`r`n$(ConvertTo-SCJson $packet 14)`r`n`r`nComplete only this bounded task."
}
function New-SCReviewPrompt($Task,$Run,[string]$Stage) {
    $state=Get-SCState;$rule=if($Stage-eq'critic'){'Check omissions, contradictions, risky assumptions, regressions, and whether the worker addressed the task.'}else{'Judge acceptance criteria from available evidence. Do not trust the worker claim without evidence.'}
    return "You are the $Stage in StatefulClanker. You did not perform the work.`r`n$rule`r`n`r`nPROJECT GOAL:`r`n$($state.goal)`r`n`r`nTASK:`r`n$(ConvertTo-SCJson ([ordered]@{id=$Task.id;title=$Task.title;instruction=$Task.instruction;acceptance=@($Task.acceptance)}) 8)`r`n`r`nWORKER RECEIPT:`r`n$(ConvertTo-SCJson ([ordered]@{runId=$Run.id;exitCode=$Run.exitCode;stdout=$Run.stdout;stderr=$Run.stderr}) 8)`r`n`r`nRETRIEVED EVIDENCE:`r`n$(ConvertTo-SCJson (Get-SCRetrievalPacket $Task) 12)`r`n`r`nFirst non-empty line MUST be exactly VERDICT: PASS or VERDICT: FAIL. Then explain evidence briefly."
}
function Resolve-SCProvider($Task,[string]$Override,[string]$Stage='worker') {
    $cfg=Get-SCConfig;$name=$null;if($Override){$name=$Override}elseif($Stage-eq'critic'-and$cfg.PSObject.Properties['criticProvider']-and$cfg.criticProvider){$name=[string]$cfg.criticProvider}elseif($Stage-eq'validator'-and$cfg.PSObject.Properties['validatorProvider']-and$cfg.validatorProvider){$name=[string]$cfg.validatorProvider}elseif($Task.provider){$name=[string]$Task.provider}else{$name=[string]$cfg.defaultProvider};$property=$cfg.providers.PSObject.Properties[$name];if($null-eq$property){throw "Provider '$name' not configured."};return [ordered]@{name=$name;config=$property.Value}
}
function Expand-SCArg([string]$Arg,[string]$Prompt,[string]$PromptFile,$Task) { $Arg.Replace('{prompt}',$Prompt).Replace('{promptFile}',$PromptFile).Replace('{projectRoot}',(Get-SCRoot)).Replace('{taskId}',[string]$Task.id) }
function Invoke-SCProvider($Task,[string]$Prompt,[string]$Stage,[string]$ProviderOverride,[string]$ParentAgentId=$null) {
    $providerRecord=Resolve-SCProvider $Task $ProviderOverride $Stage;$receiptId=New-SCId $Stage;$agentId=New-SCId 'agent';$promptPath=Get-SCPath ("prompts/{0}.txt"-f$receiptId);$Prompt|Set-Content -LiteralPath $promptPath -Encoding UTF8
    $exe=[string]$providerRecord.config.command;$args=@();foreach($arg in @($providerRecord.config.args)){$args+=Expand-SCArg ([string]$arg) $Prompt $promptPath $Task}
    $stdoutPath=Get-SCPath ("runs/{0}.stdout.txt"-f$receiptId);$stderrPath=Get-SCPath ("runs/{0}.stderr.txt"-f$receiptId);$started=(Get-Date).ToUniversalTime()
    $telemetry=[ordered]@{schemaVersion=1;agentId=$agentId;receiptId=$receiptId;parentAgentId=$ParentAgentId;taskId=$Task.id;taskTitle=$Task.title;stage=$Stage;provider=$providerRecord.name;model=$null;lifecycle='running';processId=$null;startedAt=$started.ToString('o');heartbeatAt=$started.ToString('o');endedAt=$null;durationSeconds=$null;promptChars=$Prompt.Length;retrievedChars=if($Stage-eq'run'){[int](Get-SCRetrievalPacket $Task).usedChars}else{0};command=$exe;args=$args;exitCode=$null;verdict=$null;stdoutPath=$stdoutPath;stderrPath=$stderrPath;error=$null}
    Save-SCActiveTelemetry $telemetry;Add-SCTelemetryEvent 'agent.started' $telemetry;$stdout='';$stderr='';$exitCode=-1
    try{
        & $exe @args 1> $stdoutPath 2> $stderrPath
        $exitCode=$LASTEXITCODE
        if($null-eq$exitCode){$exitCode=0}
        if(Test-Path $stdoutPath){$stdout=Get-Content -Raw -LiteralPath $stdoutPath}
        if(Test-Path $stderrPath){$stderr=Get-Content -Raw -LiteralPath $stderrPath}
    }catch{$stderr=$_|Out-String;$telemetry.error=$stderr;$exitCode=-1}
    $ended=(Get-Date).ToUniversalTime();$telemetry.lifecycle=if($exitCode-eq 0){'completed'}else{'failed'};$telemetry.exitCode=$exitCode;$telemetry.endedAt=$ended.ToString('o');$telemetry.heartbeatAt=$telemetry.endedAt;$telemetry.durationSeconds=[math]::Round(($ended-$started).TotalSeconds,3);Complete-SCTelemetry $telemetry
    return [ordered]@{id=$receiptId;agentId=$agentId;taskId=$Task.id;stage=$Stage;provider=$providerRecord.name;command=$exe;args=$args;promptPath=$promptPath;startedAt=$started.ToString('o');endedAt=$ended.ToString('o');durationSeconds=$telemetry.durationSeconds;exitCode=$exitCode;stdout=$stdout;stderr=$stderr}
}
function Get-SCVerdict([string]$Text,[int]$ExitCode) { if($ExitCode-ne 0){return'FAIL'};foreach($line in @($Text-split"`r?`n")){$trimmed=$line.Trim();if(-not$trimmed){continue};if($trimmed-match'^VERDICT:\s*PASS\s*$'){return'PASS'};if($trimmed-match'^VERDICT:\s*FAIL\s*$'){return'FAIL'};break};return'FAIL' }
function Set-SCTelemetryVerdict([string]$AgentId,[string]$Verdict) { $path=Get-SCPath ("telemetry/runs/{0}.json"-f$AgentId);$record=Read-SCJson $path;if($record){$record.verdict=$Verdict;Write-SCJson $path $record} }
function Invoke-SCReview($Task,$Run,[string]$Stage) {
    $receipt=Invoke-SCProvider $Task (New-SCReviewPrompt $Task $Run $Stage) $Stage $null $Run.agentId;$receipt.verdict=Get-SCVerdict ([string]$receipt.stdout) ([int]$receipt.exitCode);Set-SCTelemetryVerdict $receipt.agentId $receipt.verdict;$dir=if($Stage-eq'critic'){'critiques'}else{'validations'};Write-SCJson (Get-SCPath ("{0}/{1}.json"-f$dir,$receipt.id)) $receipt;Add-SCEvent "$Stage.finished" "$Stage $($receipt.id): $($receipt.verdict)" @{taskId=$Task.id;receiptId=$receipt.id;agentId=$receipt.agentId;verdict=$receipt.verdict};return $receipt
}
function Invoke-SCTask([string]$RequestedTaskId,[string]$ProviderOverride) {
    Assert-SCInitialized;Update-SCReadiness;$state=Get-SCState;$cfg=Get-SCConfig;if($state.activePlanId-and[bool]$cfg.requireHumanApprovalForPlan-and-not[bool]$state.planApproved){throw 'Active plan requires approval.'}
    $task=if($RequestedTaskId){Get-SCTask $RequestedTaskId}else{Get-SCTasks|Where-Object{$_.status-eq'ready'-and-not$_.humanGate}|Sort-Object createdAt|Select-Object -First 1};if($null-eq$task){throw 'No runnable ready task.'};if($task.status-ne'ready'){throw "Task $($task.id) is $($task.status), not ready."};if($task.humanGate){throw 'Task requires human gate.'}
    $task.status='running';Save-SCTask $task;Add-SCEvent 'run.started' 'Worker started' @{taskId=$task.id};$run=Invoke-SCProvider $task (New-SCWorkerPrompt $task) 'run' $ProviderOverride;Write-SCJson (Get-SCPath ("runs/{0}.json"-f$run.id)) $run;$task=Get-SCTask $task.id;$task.latestRunId=$run.id
    if([int]$run.exitCode-ne 0){$task.status='failed';$task.blockReason="Worker exited $($run.exitCode)";Save-SCTask $task;Add-SCEvent 'run.failed' $task.blockReason @{taskId=$task.id;runId=$run.id;agentId=$run.agentId};Write-Warning $task.blockReason;return};Add-SCEvent 'run.finished' "Worker finished $($run.id)" @{taskId=$task.id;runId=$run.id;agentId=$run.agentId}
    if([bool]$cfg.criticEnabled){$task.status='reviewing';Save-SCTask $task;$critique=Invoke-SCReview $task $run 'critic';$task=Get-SCTask $task.id;$task.latestCritiqueId=$critique.id;if($critique.verdict-ne'PASS'){$task.status='needs_rework';$task.blockReason='Critic rejected worker result.';Save-SCTask $task;Write-Warning $task.blockReason;return}}
    if([bool]$cfg.validatorEnabled){$task.status='validating';Save-SCTask $task;$validation=Invoke-SCReview $task $run 'validator';$task=Get-SCTask $task.id;$task.latestValidationId=$validation.id;if($validation.verdict-ne'PASS'){$task.status='needs_rework';$task.blockReason='Validator rejected worker result.';Save-SCTask $task;Write-Warning $task.blockReason;return}}
    $task.status='complete';$task.blockReason=$null;Save-SCTask $task;Add-SCEvent 'task.completed' "Completed $($task.id) after review pipeline" @{taskId=$task.id;runId=$run.id};Update-SCReadiness;Write-Host "Task complete: $($task.id)"
}
function Retry-SCTask([string]$Id) { if(-not$Id){throw '-TaskId required.'};$task=Get-SCTask $Id;$task.status='ready';$task.blockReason=$null;Save-SCTask $task;Add-SCEvent 'task.retried' "Retry $Id" @{taskId=$Id};Write-Host 'Task reset to ready.' }
function Complete-SCTask([string]$Id) { if(-not$Id){throw '-TaskId required.'};$task=Get-SCTask $Id;$task.status='complete';$task.blockReason=$null;Save-SCTask $task;Add-SCEvent 'task.completed.manual' "Completed $Id manually" @{taskId=$Id};Update-SCReadiness;Write-Host 'Task completed.' }
function Block-SCTask([string]$Id,[string]$Why) { if(-not$Id){throw '-TaskId required.'};if(-not$Why){throw '-Reason required.'};$task=Get-SCTask $Id;$task.status='blocked';$task.blockReason=$Why;Save-SCTask $task;Add-SCEvent 'task.blocked' $Why @{taskId=$Id};Write-Host 'Task blocked.' }
function Show-SCProviders { $cfg=Get-SCConfig;$rows=@();foreach($property in $cfg.providers.PSObject.Properties){$rows+=[pscustomobject]@{name=$property.Name;command=$property.Value.command;mode=$property.Value.mode}};$rows|Format-Table -AutoSize }
function Show-SCTelemetry([string]$Mode,[string]$Id) { if([string]::IsNullOrWhiteSpace($Mode)){$Mode='active'};switch($Mode.ToLowerInvariant()){'active'{@(Get-SCActiveTelemetry)|Select-Object agentId,taskId,stage,provider,lifecycle,processId,startedAt,heartbeatAt|Format-Table -AutoSize;break};'history'{@(Get-SCTelemetryRuns 100)|Select-Object agentId,taskId,stage,provider,lifecycle,exitCode,verdict,durationSeconds,startedAt|Format-Table -AutoSize;break};'show'{if(-not$Id){throw '-RunId required (agent id).'};$record=Read-SCJson (Get-SCPath ("telemetry/runs/{0}.json"-f$Id));if(-not$record){throw "Unknown telemetry run: $Id"};ConvertTo-SCJson $record 12|Write-Host;break};default{throw "Unknown telemetry subcommand: $Mode"}} }

switch($Command.ToLowerInvariant()){
'init'{Initialize-SC;break}
'goal'{$text=if($Message){$Message}elseif($Subcommand){$Subcommand}else{$Title};Set-SCGoal $text;break}
'status'{Show-SCStatus;break}
'task'{if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='list'};switch($Subcommand.ToLowerInvariant()){'add'{Add-SCTask;break};'list'{Update-SCReadiness;Get-SCTasks|Sort-Object createdAt|Select-Object id,status,role,humanGate,title|Format-Table -AutoSize;break};'show'{if(-not$TaskId){throw '-TaskId required.'};Get-SCTask $TaskId|ConvertTo-SCJson -Depth 12|Write-Host;break};'retry'{Retry-SCTask $TaskId;break};default{throw "Unknown task subcommand: $Subcommand"}};break}
'plan'{if($null-eq$Subcommand){$Subcommand=''};switch($Subcommand.ToLowerInvariant()){'import'{if(-not$Path){throw '-Path required.'};Import-SCPlan $Path;break};'approve'{Approve-SCPlan;break};default{throw "Unknown plan subcommand: $Subcommand"}};break}
'run'{Invoke-SCTask $TaskId $Provider;break}
'complete'{Complete-SCTask $TaskId;break}
'block'{Block-SCTask $TaskId $Reason;break}
'event'{if(-not$Message){throw '-Message required.'};Add-SCEvent 'user.note' $Message;Write-Host 'Event recorded.';break}
'provider'{if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='list'};if($Subcommand.ToLowerInvariant()-eq'list'){Show-SCProviders}else{throw "Unknown provider subcommand: $Subcommand"};break}
'telemetry'{Show-SCTelemetry $Subcommand $RunId;break}
default{throw "Unknown command: $Command"}
}

<#
.SYNOPSIS
StatefulClanker: durable-state orchestration for cold-start CLI workers.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Position=0)][string]$Command='status',
    [Parameter(Position=1)][string]$Subcommand,
    [string]$Title,[string]$Instruction,[string[]]$Accept,[string[]]$DependsOn,
    [string[]]$Retrieval,[string[]]$Evidence,[string]$Provider,[string]$Role='worker',
    [switch]$HumanGate,[string]$TaskId,[string]$Path,[string]$Reason,[string]$Message
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Root { (Get-Location).Path }
function SCDir { Join-Path (Root) '.statefulclanker' }
function SCPath([string]$p) { Join-Path (SCDir) $p }
function ToJson($v,[int]$d=12) { $v | ConvertTo-Json -Depth $d }
function WriteJson([string]$p,$v) { $parent=Split-Path -Parent $p; if($parent -and -not(Test-Path $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}; $tmp="$p.tmp"; ToJson $v 16|Set-Content -LiteralPath $tmp -Encoding UTF8; Move-Item -Force $tmp $p }
function ReadJson([string]$p) { if(-not(Test-Path $p)){return $null}; $r=Get-Content -Raw -LiteralPath $p; if([string]::IsNullOrWhiteSpace($r)){return $null}; $r|ConvertFrom-Json }
function AssertInit { if(-not(Test-Path (SCPath 'state.json'))){throw 'Not initialized. Run: .\StatefulClanker.ps1 init'} }
function NewId([string]$p) { "$p-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0,8))" }
function Event([string]$type,[string]$text,$data=$null) { AssertInit; $e=[ordered]@{ts=(Get-Date).ToUniversalTime().ToString('o');type=$type;message=$text;data=$data}; (ToJson $e 8 -replace "`r?`n",'')|Add-Content -LiteralPath (SCPath 'events.jsonl') -Encoding UTF8 }
function State { AssertInit; ReadJson (SCPath 'state.json') }
function SaveState($s) { $s.updatedAt=(Get-Date).ToUniversalTime().ToString('o'); WriteJson (SCPath 'state.json') $s }
function Config { AssertInit; $c=ReadJson (SCPath 'config.json'); if($null -eq $c){throw 'Missing .statefulclanker/config.json'}; $c }
function Task([string]$id) { $t=ReadJson (SCPath ("tasks/{0}.json" -f $id)); if($null -eq $t){throw "Unknown task: $id"}; $t }
function SaveTask($t) { $t.updatedAt=(Get-Date).ToUniversalTime().ToString('o'); WriteJson (SCPath ("tasks/{0}.json" -f $t.id)) $t }
function Tasks { AssertInit; $d=SCPath 'tasks'; if(-not(Test-Path $d)){return @()}; @(Get-ChildItem -LiteralPath $d -Filter '*.json' -File|ForEach-Object{ReadJson $_.FullName}) }
function UpdateReady {
    $all=@(Tasks); $map=@{}; foreach($t in $all){if($t.id){$map[[string]$t.id]=$t}}
    foreach($t in $all){
        if($t.status -ne 'pending'){continue}; $ok=$true
        foreach($dep in @($t.dependsOn)){
            if([string]::IsNullOrWhiteSpace([string]$dep)){continue}
            if(-not $map.ContainsKey([string]$dep) -or $map[[string]$dep].status -ne 'complete'){$ok=$false;break}
        }
        if($ok){$t.status='ready';SaveTask $t}
    }
}
function Init {
    $d=SCDir; if(Test-Path (Join-Path $d 'state.json')){Write-Host 'Already initialized.';return}
    New-Item -ItemType Directory -Force -Path $d|Out-Null; foreach($x in @('tasks','plans','runs','critiques','validations','prompts')){New-Item -ItemType Directory -Force -Path (Join-Path $d $x)|Out-Null}
    $now=(Get-Date).ToUniversalTime().ToString('o'); WriteJson (Join-Path $d 'state.json') ([ordered]@{schemaVersion=2;projectId=NewId 'project';projectRoot=Root;goal='';activePlanId=$null;planApproved=$false;createdAt=$now;updatedAt=$now}); ''|Set-Content (Join-Path $d 'events.jsonl') -Encoding UTF8
    $ex=Join-Path $PSScriptRoot 'statefulclanker.example.json'; if(Test-Path $ex){Copy-Item $ex (Join-Path $d 'config.json')}else{WriteJson (Join-Path $d 'config.json') ([ordered]@{defaultProvider='opencode';criticProvider=$null;validatorProvider=$null;providers=[ordered]@{};workingSetBudgetChars=24000;maxFileChars=8000;requireHumanApprovalForPlan=$true;criticEnabled=$true;validatorEnabled=$true})}
    Event 'project.initialized' 'StatefulClanker initialized.' @{root=Root}; Write-Host "Initialized $d"
}
function SetGoal([string]$text) { AssertInit; if([string]::IsNullOrWhiteSpace($text)){throw 'Goal text required.'}; $s=State;$s.goal=$text;SaveState $s;Event 'goal.changed' $text;Write-Host 'Goal updated.' }
function AddTask {
    if([string]::IsNullOrWhiteSpace($Title)){throw '-Title is required.'};if([string]::IsNullOrWhiteSpace($Instruction)){throw '-Instruction is required.'}
    $id=if($TaskId){$TaskId}else{NewId 'task'}; if(@(Tasks|Where-Object{$_.id -eq $id}).Count -gt 0){throw "Task exists: $id"};$now=(Get-Date).ToUniversalTime().ToString('o')
    $t=[ordered]@{id=$id;title=$Title;instruction=$Instruction;acceptance=@($Accept);dependsOn=@($DependsOn);retrieval=@($Retrieval);evidence=@($Evidence);provider=if($Provider){$Provider}else{$null};role=$Role;humanGate=[bool]$HumanGate;status='pending';latestRunId=$null;latestCritiqueId=$null;latestValidationId=$null;blockReason=$null;createdAt=$now;updatedAt=$now}
    SaveTask $t;UpdateReady;Event 'task.created' $Title @{taskId=$id};Write-Host $id
}
function ShowStatus { AssertInit;UpdateReady;$s=State;$a=@(Tasks);Write-Host "Goal: $($s.goal)";Write-Host "Plan: $($s.activePlanId)  Approved: $($s.planApproved)";if($a.Count -eq 0){Write-Host 'Tasks: none';return};$a|Sort-Object createdAt|Select-Object id,status,role,title|Format-Table -AutoSize }
function ImportPlan([string]$p) {
    AssertInit;if(-not(Test-Path $p)){throw "Plan not found: $p"};$resolved=(Resolve-Path $p).Path;$plan=ReadJson $resolved;if($null -eq $plan -or $null -eq $plan.tasks){throw 'Plan must contain tasks.'};$pid=NewId 'plan';WriteJson (SCPath ("plans/{0}.json" -f $pid)) ([ordered]@{id=$pid;name=$plan.name;summary=$plan.summary;source=$resolved;importedAt=(Get-Date).ToUniversalTime().ToString('o');tasks=@($plan.tasks)})
    foreach($x in @($plan.tasks)){$id=if($x.id){[string]$x.id}else{NewId 'task'};$now=(Get-Date).ToUniversalTime().ToString('o');$t=[ordered]@{id=$id;title=[string]$x.title;instruction=[string]$x.instruction;acceptance=@($x.acceptance);dependsOn=@($x.dependsOn);retrieval=@($x.retrieval);evidence=@($x.evidence);provider=if($x.provider){[string]$x.provider}else{$null};role=if($x.role){[string]$x.role}else{'worker'};humanGate=[bool]$x.humanGate;status='pending';latestRunId=$null;latestCritiqueId=$null;latestValidationId=$null;blockReason=$null;createdAt=$now;updatedAt=$now};SaveTask $t}
    $s=State;$s.activePlanId=$pid;$c=Config;$s.planApproved=-not[bool]$c.requireHumanApprovalForPlan;SaveState $s;UpdateReady;Event 'plan.imported' "Imported $pid" @{taskCount=@($plan.tasks).Count};Write-Host "Imported $pid"
}
function ApprovePlan { $s=State;if(-not$s.activePlanId){throw 'No active plan.'};$s.planApproved=$true;SaveState $s;Event 'plan.approved' "Approved $($s.activePlanId)";Write-Host 'Plan approved.' }
function RecentEvents([int]$n=12) { $p=SCPath 'events.jsonl';if(-not(Test-Path $p)){return @()};@(Get-Content $p|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Select-Object -Last $n) }
function DepSummary($t) { $o=@();foreach($d in @($t.dependsOn)){if([string]::IsNullOrWhiteSpace([string]$d)){continue};$x=Task ([string]$d);$r=[ordered]@{id=$x.id;title=$x.title;status=$x.status;latestRunId=$x.latestRunId};if($x.latestRunId){$rr=ReadJson (SCPath ("runs/{0}.json" -f $x.latestRunId));if($rr){$r.result=$rr.stdout}};$o+=$r};$o }
function Retrieve($t) {
    $c=Config;$budget=if($c.PSObject.Properties['workingSetBudgetChars']){[int]$c.workingSetBudgetChars}else{24000};$max=if($c.PSObject.Properties['maxFileChars']){[int]$c.maxFileChars}else{8000};$left=$budget;$items=@();$seen=@{}
    foreach($sel in @($t.retrieval)+@($t.evidence)){
        if([string]::IsNullOrWhiteSpace([string]$sel)-or$left-le 0){continue};$pat=[string]$sel;$matches=@()
        try{if($pat -match '[*?\[]'){$matches=@(Get-ChildItem -Path $pat -File -Recurse -ErrorAction SilentlyContinue)}elseif(Test-Path -LiteralPath $pat -PathType Leaf){$matches=@(Get-Item -LiteralPath $pat)}elseif(Test-Path -LiteralPath $pat -PathType Container){$matches=@(Get-ChildItem -LiteralPath $pat -File -Recurse -ErrorAction SilentlyContinue)}}catch{$matches=@()}
        foreach($m in $matches){if($left-le 0){break};$full=$m.FullName;if($full.StartsWith((SCDir),[StringComparison]::OrdinalIgnoreCase)){continue};if($seen.ContainsKey($full)){continue};$seen[$full]=$true;try{$txt=Get-Content -Raw -LiteralPath $full}catch{continue};if($null-eq$txt){$txt=''};$take=[Math]::Min([Math]::Min($txt.Length,$max),$left);$excerpt=if($take-gt 0){$txt.Substring(0,$take)}else{''};$rel=($full.Substring((Root).Length) -replace '^[\\/]+' ,'');$items+=[ordered]@{path=$rel;chars=$take;truncated=($txt.Length-gt$take);content=$excerpt};$left-=$take}
    }
    [ordered]@{budgetChars=$budget;usedChars=($budget-$left);items=$items}
}
function WorkerPrompt($t) { $s=State;$packet=[ordered]@{projectGoal=$s.goal;projectRoot=Root;task=[ordered]@{id=$t.id;title=$t.title;instruction=$t.instruction;role=$t.role;acceptance=@($t.acceptance);retrieval=@($t.retrieval);evidence=@($t.evidence)};dependencies=@(DepSummary $t);retrieved=(Retrieve $t);recentEvents=@(RecentEvents 12);outputContract='Perform only this task. Report files changed, commands run, failures, and unresolved risks. Do not claim verification you did not perform.'};"You are a cold-start StatefulClanker worker. Durable state and project files are authoritative.`r`n`r`nSTATEFULCLANKER PACKET`r`n======================`r`n$(ToJson $packet 14)`r`n`r`nComplete only this bounded task." }
function ReviewPrompt($t,$run,[string]$stage) { $s=State;$rule=if($stage-eq'critic'){'Check omissions, contradictions, risky assumptions, regressions, and whether the worker addressed the task.'}else{'Judge acceptance criteria from available evidence. Do not trust the worker claim without evidence.'};"You are the $stage in StatefulClanker. You did not perform the work.`r`n$rule`r`n`r`nPROJECT GOAL:`r`n$($s.goal)`r`n`r`nTASK:`r`n$(ToJson ([ordered]@{id=$t.id;title=$t.title;instruction=$t.instruction;acceptance=@($t.acceptance)}) 8)`r`n`r`nWORKER RECEIPT:`r`n$(ToJson ([ordered]@{runId=$run.id;exitCode=$run.exitCode;stdout=$run.stdout;stderr=$run.stderr}) 8)`r`n`r`nRETRIEVED EVIDENCE:`r`n$(ToJson (Retrieve $t) 12)`r`n`r`nFirst non-empty line MUST be exactly VERDICT: PASS or VERDICT: FAIL. Then explain evidence briefly." }
function ResolveProvider($t,[string]$override,[string]$stage='worker') { $c=Config;$name=$null;if($override){$name=$override}elseif($stage-eq'critic'-and$c.PSObject.Properties['criticProvider']-and$c.criticProvider){$name=[string]$c.criticProvider}elseif($stage-eq'validator'-and$c.PSObject.Properties['validatorProvider']-and$c.validatorProvider){$name=[string]$c.validatorProvider}elseif($t.provider){$name=[string]$t.provider}else{$name=[string]$c.defaultProvider};$p=$c.providers.PSObject.Properties[$name];if($null-eq$p){throw "Provider '$name' not configured."};[ordered]@{name=$name;config=$p.Value} }
function ExpandArg([string]$a,[string]$prompt,[string]$pf,$t) { $a.Replace('{prompt}',$prompt).Replace('{promptFile}',$pf).Replace('{projectRoot}',(Root)).Replace('{taskId}',[string]$t.id) }
function InvokeProvider($t,[string]$prompt,[string]$stage,[string]$override) {
    $pr=ResolveProvider $t $override $stage;$id=NewId $stage;$pf=SCPath ("prompts/{0}.txt"-f$id);$prompt|Set-Content -LiteralPath $pf -Encoding UTF8;$exe=[string]$pr.config.command;$args=@();foreach($a in @($pr.config.args)){$args+=ExpandArg ([string]$a) $prompt $pf $t};$outf=SCPath ("runs/{0}.stdout.txt"-f$id);$errf=SCPath ("runs/{0}.stderr.txt"-f$id);$start=(Get-Date).ToUniversalTime();$out='';$err='';$exit=-1
    try{$proc=Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory (Root) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outf -RedirectStandardError $errf;$exit=$proc.ExitCode;if(Test-Path$outf){$out=Get-Content -Raw $outf};if(Test-Path$errf){$err=Get-Content -Raw $errf}}catch{$err=$_|Out-String;$exit=-1};$end=(Get-Date).ToUniversalTime();[ordered]@{id=$id;taskId=$t.id;stage=$stage;provider=$pr.name;command=$exe;args=$args;promptPath=$pf;startedAt=$start.ToString('o');endedAt=$end.ToString('o');durationSeconds=[math]::Round(($end-$start).TotalSeconds,3);exitCode=$exit;stdout=$out;stderr=$err}
}
function Verdict([string]$text,[int]$exit) { if($exit-ne 0){return'FAIL'};foreach($line in @($text-split"`r?`n")){$x=$line.Trim();if(-not$x){continue};if($x-match'^VERDICT:\s*PASS\s*$'){return'PASS'};if($x-match'^VERDICT:\s*FAIL\s*$'){return'FAIL'};break};'FAIL' }
function Review($t,$run,[string]$stage) { $r=InvokeProvider $t (ReviewPrompt $t $run $stage) $stage $null;$r.verdict=Verdict ([string]$r.stdout) ([int]$r.exitCode);$dir=if($stage-eq'critic'){'critiques'}else{'validations'};WriteJson (SCPath ("{0}/{1}.json"-f$dir,$r.id)) $r;Event "$stage.finished" "$stage $($r.id): $($r.verdict)" @{taskId=$t.id;receiptId=$r.id;verdict=$r.verdict};$r }
function RunTask([string]$id,[string]$override) {
    AssertInit;UpdateReady;$s=State;$c=Config;if($s.activePlanId-and[bool]$c.requireHumanApprovalForPlan-and-not[bool]$s.planApproved){throw 'Active plan requires approval.'};$t=if($id){Task $id}else{Tasks|Where-Object{$_.status-eq'ready'-and-not$_.humanGate}|Sort-Object createdAt|Select-Object -First 1};if($null-eq$t){throw'No runnable ready task.'};if($t.status-ne'ready'){throw"Task $($t.id) is $($t.status), not ready."};if($t.humanGate){throw'Task requires human gate.'}
    $t.status='running';SaveTask$t;Event 'run.started' 'Worker started' @{taskId=$t.id};$run=InvokeProvider $t (WorkerPrompt $t) 'run' $override;WriteJson (SCPath ("runs/{0}.json"-f$run.id)) $run;$t=Task$t.id;$t.latestRunId=$run.id
    if([int]$run.exitCode-ne 0){$t.status='failed';$t.blockReason="Worker exited $($run.exitCode)";SaveTask$t;Event 'run.failed' $t.blockReason @{taskId=$t.id;runId=$run.id};Write-Warning$t.blockReason;return};Event 'run.finished' "Worker finished $($run.id)" @{taskId=$t.id;runId=$run.id}
    if([bool]$c.criticEnabled){$t.status='reviewing';SaveTask$t;$r=Review $t $run 'critic';$t=Task$t.id;$t.latestCritiqueId=$r.id;if($r.verdict-ne'PASS'){$t.status='needs_rework';$t.blockReason='Critic rejected worker result.';SaveTask$t;Write-Warning$t.blockReason;return}}
    if([bool]$c.validatorEnabled){$t.status='validating';SaveTask$t;$r=Review $t $run 'validator';$t=Task$t.id;$t.latestValidationId=$r.id;if($r.verdict-ne'PASS'){$t.status='needs_rework';$t.blockReason='Validator rejected worker result.';SaveTask$t;Write-Warning$t.blockReason;return}}
    $t.status='complete';$t.blockReason=$null;SaveTask$t;Event 'task.completed' "Completed $($t.id) after review pipeline" @{taskId=$t.id;runId=$run.id};UpdateReady;Write-Host "Task complete: $($t.id)"
}
function Retry([string]$id){if(-not$id){throw'-TaskId required.'};$t=Task$id;$t.status='ready';$t.blockReason=$null;SaveTask$t;Event'task.retried'"Retry $id"@{taskId=$id};Write-Host'Task reset to ready.'}
function Complete([string]$id){if(-not$id){throw'-TaskId required.'};$t=Task$id;$t.status='complete';$t.blockReason=$null;SaveTask$t;Event'task.completed.manual'"Completed $id manually"@{taskId=$id};UpdateReady;Write-Host'Task completed.'}
function Block([string]$id,[string]$why){if(-not$id){throw'-TaskId required.'};if(-not$why){throw'-Reason required.'};$t=Task$id;$t.status='blocked';$t.blockReason=$why;SaveTask$t;Event'task.blocked'$why@{taskId=$id};Write-Host'Task blocked.'}
function Providers{$c=Config;@(foreach($p in$c.providers.PSObject.Properties){[pscustomobject]@{name=$p.Name;command=$p.Value.command;mode=$p.Value.mode}})|Format-Table -AutoSize}

switch($Command.ToLowerInvariant()){
'init'{Init;break}
'goal'{$text=if($Message){$Message}elseif($Subcommand){$Subcommand}else{$Title};SetGoal$text;break}
'status'{ShowStatus;break}
'task'{if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='list'};switch($Subcommand.ToLowerInvariant()){'add'{AddTask;break};'list'{UpdateReady;Tasks|Sort-Object createdAt|Select-Object id,status,role,humanGate,title|Format-Table -AutoSize;break};'show'{if(-not$TaskId){throw'-TaskId required.'};Task$TaskId|ToJson -d 12|Write-Host;break};'retry'{Retry$TaskId;break};default{throw"Unknown task subcommand: $Subcommand"}};break}
'plan'{if($null-eq$Subcommand){$Subcommand=''};switch($Subcommand.ToLowerInvariant()){'import'{if(-not$Path){throw'-Path required.'};ImportPlan$Path;break};'approve'{ApprovePlan;break};default{throw"Unknown plan subcommand: $Subcommand"}};break}
'run'{RunTask$TaskId$Provider;break}
'complete'{Complete$TaskId;break}
'block'{Block$TaskId$Reason;break}
'event'{if(-not$Message){throw'-Message required.'};Event'user.note'$Message;Write-Host'Event recorded.';break}
'provider'{if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='list'};if($Subcommand.ToLowerInvariant()-eq'list'){Providers}else{throw"Unknown provider subcommand: $Subcommand"};break}
default{throw"Unknown command: $Command"}
}

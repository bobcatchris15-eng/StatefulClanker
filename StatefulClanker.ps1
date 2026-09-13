<# StatefulClanker: durable-state orchestration for cold-start CLI workers. #>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Position=0)][string]$Command='status',
    [Parameter(Position=1)][string]$Subcommand,
    [string]$Title,[string]$Instruction,[string[]]$Accept,[string[]]$DependsOn,
    [string[]]$Retrieval,[string[]]$Evidence,[string[]]$Relation,[string]$Provider,[string]$Role='worker',
    [switch]$HumanGate,[string]$TaskId,[string]$Path,[string]$Reason,[string]$Message,[string]$RunId,[string]$CompilationId
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Get-SCRoot { (Get-Location).Path }
function Get-SCDir { Join-Path (Get-SCRoot) '.statefulclanker' }
function Get-SCPath([string]$Child) { Join-Path (Get-SCDir) $Child }
function ConvertTo-SCJson($Value,[int]$Depth=12) { $Value | ConvertTo-Json -Depth $Depth }
function Set-SCProperty($Object,[string]$Name,$Value) {
    if($Object -is [System.Collections.IDictionary]){$Object[$Name]=$Value;return}
    if($Object.PSObject.Properties[$Name]){$Object.$Name=$Value}else{$Object|Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force}
}
function Write-SCJson([string]$TargetPath,$Value) {
    $parent=Split-Path -Parent $TargetPath
    if($parent -and -not(Test-Path $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
    $tmp="$TargetPath.tmp"
    ConvertTo-SCJson $Value 30 | Set-Content -LiteralPath $tmp -Encoding UTF8
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
function Get-SCHashString([string]$Text) {
    if($null-eq$Text){$Text=''}
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try{$bytes=[Text.Encoding]::UTF8.GetBytes($Text);return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Get-SCFileHashValue([string]$FilePath) {
    if(-not(Test-Path -LiteralPath $FilePath -PathType Leaf)){return $null}
    try{return (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()}catch{return $null}
}
function Add-SCEvent([string]$Type,[string]$Text,$Data=$null) {
    Assert-SCInitialized
    $evt=[ordered]@{id=New-SCId 'event';ts=(Get-Date).ToUniversalTime().ToString('o');type=$Type;message=$Text;data=$Data}
    (ConvertTo-SCJson $evt 12 -replace "`r?`n",'')|Add-Content -LiteralPath (Get-SCPath 'events.jsonl') -Encoding UTF8
}
function Get-SCState { Assert-SCInitialized;Read-SCJson (Get-SCPath 'state.json') }
function Save-SCState($State) {
    $revision=0;if($State.PSObject.Properties['revision']){$revision=[int]$State.revision}
    Set-SCProperty $State 'revision' ($revision+1);Set-SCProperty $State 'updatedAt' ((Get-Date).ToUniversalTime().ToString('o'));Write-SCJson (Get-SCPath 'state.json') $State
}
function Get-SCConfig { Assert-SCInitialized;$cfg=Read-SCJson (Get-SCPath 'config.json');if($null-eq$cfg){throw 'Missing .statefulclanker/config.json'};return $cfg }
function Get-SCTask([string]$Id) { $task=Read-SCJson (Get-SCPath ("tasks/{0}.json"-f$Id));if($null-eq$task){throw "Unknown task: $Id"};return $task }
function Save-SCTask($Task) {
    $revision=0;if($Task.PSObject.Properties['stateRevision']){$revision=[int]$Task.stateRevision}
    Set-SCProperty $Task 'stateRevision' ($revision+1);Set-SCProperty $Task 'updatedAt' ((Get-Date).ToUniversalTime().ToString('o'));Write-SCJson (Get-SCPath ("tasks/{0}.json"-f$Task.id)) $Task
}
function Get-SCTasks { Assert-SCInitialized;$dir=Get-SCPath 'tasks';if(-not(Test-Path $dir)){return @()};return @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File|ForEach-Object{Read-SCJson $_.FullName}) }
function ConvertTo-SCRelations($InputRelations) {
    $out=@()
    foreach($relation in @($InputRelations)){
        if($null-eq$relation){continue}
        if($relation-is[string]){
            $text=[string]$relation;if([string]::IsNullOrWhiteSpace($text)){continue};$parts=$text.Split(':',2)
            if($parts.Count-ne 2-or[string]::IsNullOrWhiteSpace($parts[0])-or[string]::IsNullOrWhiteSpace($parts[1])){throw "Relation must be type:target, got '$text'."}
            $out+=[ordered]@{type=$parts[0].Trim();target=$parts[1].Trim()}
        }else{
            $type=$null;$target=$null
            if($relation.PSObject.Properties['type']){$type=[string]$relation.type};if($relation.PSObject.Properties['target']){$target=[string]$relation.target}
            if(-not[string]::IsNullOrWhiteSpace($type)-and-not[string]::IsNullOrWhiteSpace($target)){$out+=[ordered]@{type=$type;target=$target}}
        }
    }
    return @($out)
}
function Get-SCTaskDefinitionHash($Task) {
    $definition=[ordered]@{title=$Task.title;instruction=$Task.instruction;acceptance=@($Task.acceptance);dependsOn=@($Task.dependsOn);relations=if($Task.PSObject.Properties['relations']){@($Task.relations)}else{@()};retrieval=@($Task.retrieval);evidence=@($Task.evidence);provider=$Task.provider;role=$Task.role;humanGate=[bool]$Task.humanGate}
    return Get-SCHashString (ConvertTo-SCJson $definition 14)
}
function Update-SCReadiness {
    $tasks=@(Get-SCTasks);$map=@{}
    foreach($task in $tasks){if($task.id){$map[[string]$task.id]=$task}}
    foreach($task in $tasks){
        if($task.status-ne'pending'-and$task.status-ne'ready'){continue};$ready=$true
        foreach($dep in @($task.dependsOn)){
            if([string]::IsNullOrWhiteSpace([string]$dep)){continue}
            if(-not$map.ContainsKey([string]$dep)-or$map[[string]$dep].status-ne'complete'){$ready=$false;break}
        }
        $desired=if($ready){'ready'}else{'pending'}
        if($task.status-ne$desired){$task.status=$desired;Save-SCTask $task}
    }
}
function Invalidate-SCDependents([string]$ChangedTaskId,[string]$Why) {
    $queue=New-Object Collections.Queue;$queue.Enqueue($ChangedTaskId);$seen=@{}
    while($queue.Count-gt 0){
        $current=[string]$queue.Dequeue();if($seen.ContainsKey($current)){continue};$seen[$current]=$true
        foreach($task in @(Get-SCTasks|Where-Object{@($_.dependsOn)-contains$current})){
            if($task.status-ne'running'){
                $was=$task.status;$task.status=if($was-eq'complete'){'stale'}else{'pending'};$task.blockReason="Invalidated by $current: $Why";Save-SCTask $task
                Add-SCEvent 'task.invalidated' "Invalidated $($task.id) because $current changed." @{taskId=$task.id;sourceTaskId=$current;previousStatus=$was;reason=$Why}
            }
            $queue.Enqueue([string]$task.id)
        }
    }
    Update-SCReadiness
}
function Ensure-SCTelemetryLayout {
    foreach($child in @('telemetry','telemetry/active','telemetry/runs')){$target=Get-SCPath $child;if(-not(Test-Path $target)){New-Item -ItemType Directory -Force -Path $target|Out-Null}}
    foreach($file in @('telemetry/events.jsonl','telemetry/context-faults.jsonl')){$target=Get-SCPath $file;if(-not(Test-Path $target)){''|Set-Content -LiteralPath $target -Encoding UTF8}}
}
function Add-SCTelemetryEvent([string]$Type,$Record) {
    Ensure-SCTelemetryLayout
    $evt=[ordered]@{ts=(Get-Date).ToUniversalTime().ToString('o');type=$Type;agentId=$Record.agentId;taskId=$Record.taskId;stage=$Record.stage;lifecycle=$Record.lifecycle;provider=$Record.provider;compilationId=if($Record.PSObject.Properties['compilationId']){$Record.compilationId}else{$null}}
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
function Get-SCContextFaults([int]$Limit=100) { Ensure-SCTelemetryLayout;$p=Get-SCPath 'telemetry/context-faults.jsonl';return @(Get-Content -LiteralPath $p|Where-Object{$_}|Select-Object -Last $Limit|ForEach-Object{$_|ConvertFrom-Json}) }

function Upgrade-SCStateLayout {
    Assert-SCInitialized
    foreach($child in @('tasks','plans','runs','critiques','validations','prompts','compilations','proposals','progress','telemetry','telemetry/active','telemetry/runs')){$target=Get-SCPath $child;if(-not(Test-Path $target)){New-Item -ItemType Directory -Force -Path $target|Out-Null}}
    Ensure-SCTelemetryLayout
    $state=Get-SCState;$changed=$false
    if(-not$state.PSObject.Properties['schemaVersion']-or[int]$state.schemaVersion-lt 4){Set-SCProperty $state 'schemaVersion' 4;$changed=$true}
    if(-not$state.PSObject.Properties['revision']){Set-SCProperty $state 'revision' 0;$changed=$true}
    if($changed){Save-SCState $state;Add-SCEvent 'state.migrated' 'Upgraded durable state layout to schema version 4.' @{schemaVersion=4}}
}
function Initialize-SC {
    $dir=Get-SCDir
    if(Test-Path (Join-Path $dir 'state.json')){Upgrade-SCStateLayout;Write-Host 'Already initialized; state layout checked.';return}
    New-Item -ItemType Directory -Force -Path $dir|Out-Null
    foreach($child in @('tasks','plans','runs','critiques','validations','prompts','compilations','proposals','progress','telemetry','telemetry/active','telemetry/runs')){New-Item -ItemType Directory -Force -Path (Join-Path $dir $child)|Out-Null}
    $now=(Get-Date).ToUniversalTime().ToString('o')
    Write-SCJson (Join-Path $dir 'state.json') ([ordered]@{schemaVersion=4;revision=0;projectId=New-SCId 'project';projectRoot=Get-SCRoot;goal='';activePlanId=$null;planApproved=$false;createdAt=$now;updatedAt=$now})
    ''|Set-Content -LiteralPath (Join-Path $dir 'events.jsonl') -Encoding UTF8
    ''|Set-Content -LiteralPath (Join-Path $dir 'telemetry/events.jsonl') -Encoding UTF8
    ''|Set-Content -LiteralPath (Join-Path $dir 'telemetry/context-faults.jsonl') -Encoding UTF8
    $example=Join-Path $PSScriptRoot 'statefulclanker.example.json'
    if(Test-Path $example){Copy-Item -LiteralPath $example -Destination (Join-Path $dir 'config.json')}
    else{Write-SCJson (Join-Path $dir 'config.json') ([ordered]@{defaultProvider='opencode';criticProvider=$null;validatorProvider=$null;providers=[ordered]@{};workingSetBudgetChars=24000;maxFileChars=8000;recentEventCount=12;stagnationWarningThreshold=2;requireHumanApprovalForPlan=$true;criticEnabled=$true;validatorEnabled=$true})}
    Add-SCEvent 'project.initialized' 'StatefulClanker initialized.' @{root=Get-SCRoot};Write-Host "Initialized $dir"
}
function Set-SCGoal([string]$Text) { Assert-SCInitialized;if([string]::IsNullOrWhiteSpace($Text)){throw 'Goal text required.'};$state=Get-SCState;$state.goal=$Text;Save-SCState $state;Add-SCEvent 'goal.changed' $Text;Write-Host 'Goal updated.' }
function New-SCTaskObject([string]$Id,[string]$TaskTitle,[string]$TaskInstruction,$TaskAcceptance,$TaskDepends,$TaskRelations,$TaskRetrieval,$TaskEvidence,[string]$TaskProvider,[string]$TaskRole,[bool]$TaskHumanGate) {
    $now=(Get-Date).ToUniversalTime().ToString('o')
    return [ordered]@{schemaVersion=2;id=$Id;title=$TaskTitle;instruction=$TaskInstruction;acceptance=@($TaskAcceptance);dependsOn=@($TaskDepends);relations=@(ConvertTo-SCRelations $TaskRelations);retrieval=@($TaskRetrieval);evidence=@($TaskEvidence);provider=if($TaskProvider){$TaskProvider}else{$null};role=if($TaskRole){$TaskRole}else{'worker'};humanGate=$TaskHumanGate;status='pending';stateRevision=0;attemptCount=0;latestRunId=$null;latestCompilationId=$null;latestProposalId=$null;latestCritiqueId=$null;latestValidationId=$null;blockReason=$null;createdAt=$now;updatedAt=$now}
}
function Add-SCTask {
    if([string]::IsNullOrWhiteSpace($Title)){throw '-Title is required.'};if([string]::IsNullOrWhiteSpace($Instruction)){throw '-Instruction is required.'}
    $id=if($TaskId){$TaskId}else{New-SCId 'task'};if(@(Get-SCTasks|Where-Object{$_.id-eq$id}).Count-gt 0){throw "Task exists: $id"}
    $task=New-SCTaskObject $id $Title $Instruction @($Accept) @($DependsOn) @($Relation) @($Retrieval) @($Evidence) $Provider $Role ([bool]$HumanGate)
    Save-SCTask $task;Update-SCReadiness;Add-SCEvent 'task.created' $Title @{taskId=$id;relations=@($task.relations)};Write-Host $id
}
function Show-SCStatus {
    Assert-SCInitialized;Update-SCReadiness;$state=Get-SCState;$tasks=@(Get-SCTasks);$active=@(Get-SCActiveTelemetry);$faults=@(Get-SCContextFaults 100)
    Write-Host "Goal: $($state.goal)";Write-Host "Plan: $($state.activePlanId)  Approved: $($state.planApproved)  Revision: $($state.revision)";Write-Host "Active agents: $($active.Count)  Recent context faults: $($faults.Count)"
    if($tasks.Count-eq 0){Write-Host 'Tasks: none';return};$tasks|Sort-Object createdAt|Select-Object id,status,attemptCount,role,title|Format-Table -AutoSize
}
function Import-SCPlan([string]$PlanPath) {
    Assert-SCInitialized;if(-not(Test-Path $PlanPath)){throw "Plan not found: $PlanPath"};$resolved=(Resolve-Path $PlanPath).Path;$plan=Read-SCJson $resolved
    if($null-eq$plan-or$null-eq$plan.tasks){throw 'Plan must contain tasks.'};$planId=New-SCId 'plan'
    $name=if($plan.PSObject.Properties['name']){$plan.name}else{'Imported plan'};$summary=if($plan.PSObject.Properties['summary']){$plan.summary}else{''}
    Write-SCJson (Get-SCPath ("plans/{0}.json"-f$planId)) ([ordered]@{schemaVersion=2;id=$planId;name=$name;summary=$summary;source=$resolved;importedAt=(Get-Date).ToUniversalTime().ToString('o');tasks=@($plan.tasks)})
    foreach($item in @($plan.tasks)){
        $id=if($item.PSObject.Properties['id']-and$item.id){[string]$item.id}else{New-SCId 'task'};if(Test-Path (Get-SCPath ("tasks/{0}.json"-f$id))){throw "Plan task id already exists: $id"}
        $itemAcceptance=if($item.PSObject.Properties['acceptance']){@($item.acceptance)}else{@()};$itemDepends=if($item.PSObject.Properties['dependsOn']){@($item.dependsOn)}else{@()};$itemRelations=if($item.PSObject.Properties['relations']){@($item.relations)}else{@()};$itemRetrieval=if($item.PSObject.Properties['retrieval']){@($item.retrieval)}else{@()};$itemEvidence=if($item.PSObject.Properties['evidence']){@($item.evidence)}else{@()}
        $itemProvider=if($item.PSObject.Properties['provider']-and$item.provider){[string]$item.provider}else{$null};$itemRole=if($item.PSObject.Properties['role']-and$item.role){[string]$item.role}else{'worker'};$itemHumanGate=if($item.PSObject.Properties['humanGate']){[bool]$item.humanGate}else{$false}
        $task=New-SCTaskObject $id ([string]$item.title) ([string]$item.instruction) $itemAcceptance $itemDepends $itemRelations $itemRetrieval $itemEvidence $itemProvider $itemRole $itemHumanGate
        Save-SCTask $task
    }
    $state=Get-SCState;$state.activePlanId=$planId;$cfg=Get-SCConfig;$state.planApproved=-not[bool]$cfg.requireHumanApprovalForPlan;Save-SCState $state;Update-SCReadiness;Add-SCEvent 'plan.imported' "Imported $planId" @{taskCount=@($plan.tasks).Count};Write-Host "Imported $planId"
}
function Approve-SCPlan { $state=Get-SCState;if(-not$state.activePlanId){throw 'No active plan.'};$state.planApproved=$true;Save-SCState $state;Add-SCEvent 'plan.approved' "Approved $($state.activePlanId)";Write-Host 'Plan approved.' }
function Get-SCRecentEvents([int]$Count=12) {
    $path=Get-SCPath 'events.jsonl';if(-not(Test-Path $path)){return @()};$out=@()
    foreach($line in @(Get-Content -LiteralPath $path|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Select-Object -Last $Count)){try{$out+=($line|ConvertFrom-Json)}catch{$out+=[ordered]@{type='unparsed';message=$line}}};return @($out)
}
function Get-SCDependencySummary($Task) {
    $out=@();foreach($dep in @($Task.dependsOn)){if([string]::IsNullOrWhiteSpace([string]$dep)){continue};$dependency=Get-SCTask ([string]$dep);$summary=[ordered]@{id=$dependency.id;title=$dependency.title;status=$dependency.status;definitionHash=Get-SCTaskDefinitionHash $dependency;latestRunId=$dependency.latestRunId;latestValidationId=$dependency.latestValidationId};if($dependency.latestRunId){$receipt=Read-SCJson (Get-SCPath ("runs/{0}.json"-f$dependency.latestRunId));if($receipt){$summary.result=$receipt.stdout}};$out+=$summary};return $out
}
function Resolve-SCSelector([string]$Pattern) {
    $matches=@();try{if($Pattern-match'[*?\[]'){$matches=@(Get-ChildItem -Path $Pattern -File -Recurse -ErrorAction SilentlyContinue)}elseif(Test-Path -LiteralPath $Pattern -PathType Leaf){$matches=@(Get-Item -LiteralPath $Pattern)}elseif(Test-Path -LiteralPath $Pattern -PathType Container){$matches=@(Get-ChildItem -LiteralPath $Pattern -File -Recurse -ErrorAction SilentlyContinue)}}catch{$matches=@()};return @($matches)
}
function Get-SCRetrievalPacket($Task) {
    $cfg=Get-SCConfig;$budget=if($cfg.PSObject.Properties['workingSetBudgetChars']){[int]$cfg.workingSetBudgetChars}else{24000};$maxFile=if($cfg.PSObject.Properties['maxFileChars']){[int]$cfg.maxFileChars}else{8000};$remaining=$budget;$items=@();$seen=@{};$unmatched=@();$selectors=@()
    foreach($s in @($Task.retrieval)){if(-not[string]::IsNullOrWhiteSpace([string]$s)){$selectors+=[ordered]@{selector=[string]$s;kind='retrieval';authority='context'}}}
    foreach($s in @($Task.evidence)){if(-not[string]::IsNullOrWhiteSpace([string]$s)){$selectors+=[ordered]@{selector=[string]$s;kind='evidence';authority='evidence'}}}
    foreach($entry in $selectors){
        if($remaining-le 0){break};$pattern=[string]$entry.selector;$matches=@(Resolve-SCSelector $pattern);if($matches.Count-eq 0){$unmatched+=$pattern;continue}
        foreach($match in $matches){
            if($remaining-le 0){break};$full=$match.FullName;if($full.StartsWith((Get-SCDir),[StringComparison]::OrdinalIgnoreCase)){continue};if($seen.ContainsKey($full)){continue};$seen[$full]=$true
            try{$text=Get-Content -Raw -LiteralPath $full}catch{continue};if($null-eq$text){$text=''};$take=[Math]::Min([Math]::Min($text.Length,$maxFile),$remaining);$excerpt=if($take-gt 0){$text.Substring(0,$take)}else{''};$relative=($full.Substring((Get-SCRoot).Length)-replace'^[\\/]+','')
            $items+=[ordered]@{path=$relative;selector=$pattern;kind=$entry.kind;authority=$entry.authority;chars=$take;fullChars=$text.Length;truncated=($text.Length-gt$take);sha256=Get-SCFileHashValue $full;content=$excerpt};$remaining-=$take
        }
    }
    return [ordered]@{budgetChars=$budget;usedChars=($budget-$remaining);remainingChars=$remaining;budgetExhausted=($remaining-le 0);unmatchedSelectors=@($unmatched);items=@($items)}
}
function New-SCCompilation($Task) {
    $state=Get-SCState;$cfg=Get-SCConfig;$compilationId=New-SCId 'compile';$retrieved=Get-SCRetrievalPacket $Task;$dependencies=@(Get-SCDependencySummary $Task);$eventCount=if($cfg.PSObject.Properties['recentEventCount']){[int]$cfg.recentEventCount}else{12}
    $readSet=[ordered]@{projectGoalHash=Get-SCHashString ([string]$state.goal);activePlanId=$state.activePlanId;taskId=$Task.id;taskDefinitionHash=Get-SCTaskDefinitionHash $Task;dependencies=@($dependencies|ForEach-Object{[ordered]@{id=$_.id;status=$_.status;definitionHash=$_.definitionHash;latestRunId=$_.latestRunId;latestValidationId=$_.latestValidationId}});files=@($retrieved.items|ForEach-Object{[ordered]@{path=$_.path;sha256=$_.sha256;authority=$_.authority}})}
    $inputFingerprint=Get-SCHashString (ConvertTo-SCJson $readSet 20)
    $contract=@('Perform only this bounded task.','Treat durable state and project files as authoritative.','Report files changed, commands run, failures, and unresolved risks.','Do not claim verification you did not perform.','If required state or evidence is missing, emit CONTEXT_REQUEST: <specific missing state> rather than guessing.')
    $ir=[ordered]@{schemaVersion=1;compilationId=$compilationId;compiledAt=(Get-Date).ToUniversalTime().ToString('o');project=[ordered]@{goal=$state.goal;root=Get-SCRoot;activePlanId=$state.activePlanId;stateRevision=$state.revision};task=[ordered]@{id=$Task.id;title=$Task.title;instruction=$Task.instruction;role=$Task.role;acceptance=@($Task.acceptance);dependsOn=@($Task.dependsOn);relations=if($Task.PSObject.Properties['relations']){@($Task.relations)}else{@()}};dependencies=$dependencies;sources=[ordered]@{retrieved=$retrieved;recentEvents=@(Get-SCRecentEvents $eventCount)};outputContract=$contract}
    $receipt=[ordered]@{schemaVersion=1;id=$compilationId;taskId=$Task.id;compiledAt=$ir.compiledAt;inputFingerprint=$inputFingerprint;readSet=$readSet;retrievalStats=[ordered]@{budgetChars=$retrieved.budgetChars;usedChars=$retrieved.usedChars;budgetExhausted=$retrieved.budgetExhausted;unmatchedSelectors=@($retrieved.unmatchedSelectors);itemCount=@($retrieved.items).Count;truncatedCount=@($retrieved.items|Where-Object{$_.truncated}).Count};ir=$ir}
    Write-SCJson (Get-SCPath ("compilations/{0}.json"-f$compilationId)) $receipt;$Task.latestCompilationId=$compilationId;Save-SCTask $Task
    if($receipt.retrievalStats.unmatchedSelectors.Count-gt 0){Add-SCEvent 'context.selector_unmatched' "Compilation $compilationId had unmatched selectors." @{taskId=$Task.id;compilationId=$compilationId;selectors=@($receipt.retrievalStats.unmatchedSelectors)}}
    return $receipt
}
function Test-SCCompilationFreshness($Compilation,[string]$Mode='commit') {
    $reasons=@();$state=Get-SCState;$task=Get-SCTask ([string]$Compilation.taskId)
    if((Get-SCHashString ([string]$state.goal))-ne[string]$Compilation.readSet.projectGoalHash){$reasons+='project goal changed'}
    if([string]$state.activePlanId-ne[string]$Compilation.readSet.activePlanId){$reasons+='active plan changed'}
    if((Get-SCTaskDefinitionHash $task)-ne[string]$Compilation.readSet.taskDefinitionHash){$reasons+='task definition changed'}
    foreach($depRead in @($Compilation.readSet.dependencies)){
        try{$dep=Get-SCTask ([string]$depRead.id)}catch{$reasons+="dependency missing: $($depRead.id)";continue}
        if([string]$dep.status-ne[string]$depRead.status){$reasons+="dependency status changed: $($dep.id)"}
        if([string]$dep.latestRunId-ne[string]$depRead.latestRunId){$reasons+="dependency run changed: $($dep.id)"}
        if([string]$dep.latestValidationId-ne[string]$depRead.latestValidationId){$reasons+="dependency validation changed: $($dep.id)"}
        if((Get-SCTaskDefinitionHash $dep)-ne[string]$depRead.definitionHash){$reasons+="dependency definition changed: $($dep.id)"}
    }
    if($Mode-eq'dispatch'){
        foreach($fileRead in @($Compilation.readSet.files)){$full=Join-Path (Get-SCRoot) ([string]$fileRead.path);$current=Get-SCFileHashValue $full;if([string]$current-ne[string]$fileRead.sha256){$reasons+="context file changed before dispatch: $($fileRead.path)"}}
    }
    return [ordered]@{fresh=($reasons.Count-eq 0);mode=$Mode;checkedAt=(Get-Date).ToUniversalTime().ToString('o');reasons=@($reasons)}
}
function New-SCWorkerPrompt($Compilation) {
    return "You are a cold-start StatefulClanker worker. The compiled packet is a temporary projection; durable state and project files are authoritative.`r`n`r`nSTATEFULCLANKER COMPILED CONTEXT`r`n================================`r`n$(ConvertTo-SCJson $Compilation.ir 22)`r`n`r`nComplete only this bounded task."
}
function New-SCReviewPrompt($Task,$Run,$Compilation,[string]$Stage) {
    $rule=if($Stage-eq'critic'){'Check omissions, contradictions, risky assumptions, regressions, and whether the worker addressed the bounded task.'}else{'Judge acceptance criteria from the compiled evidence and worker receipt. Do not trust the worker claim without evidence.'}
    return "You are the $Stage in StatefulClanker. You did not perform the work.`r`n$rule`r`n`r`nCOMPILED CONTEXT:`r`n$(ConvertTo-SCJson $Compilation.ir 22)`r`n`r`nWORKER RECEIPT:`r`n$(ConvertTo-SCJson ([ordered]@{runId=$Run.id;exitCode=$Run.exitCode;stdout=$Run.stdout;stderr=$Run.stderr;contextRequests=if($Run.PSObject.Properties['contextRequests']){@($Run.contextRequests)}else{@()}}) 12)`r`n`r`nFirst non-empty line MUST be exactly VERDICT: PASS or VERDICT: FAIL. Then explain evidence briefly."
}
function Resolve-SCProvider($Task,[string]$Override,[string]$Stage='worker') {
    $cfg=Get-SCConfig;$name=$null;if($Override){$name=$Override}elseif($Stage-eq'critic'-and$cfg.PSObject.Properties['criticProvider']-and$cfg.criticProvider){$name=[string]$cfg.criticProvider}elseif($Stage-eq'validator'-and$cfg.PSObject.Properties['validatorProvider']-and$cfg.validatorProvider){$name=[string]$cfg.validatorProvider}elseif($Task.provider){$name=[string]$Task.provider}else{$name=[string]$cfg.defaultProvider};$property=$cfg.providers.PSObject.Properties[$name];if($null-eq$property){throw "Provider '$name' not configured."};return [ordered]@{name=$name;config=$property.Value}
}
function Expand-SCArg([string]$Arg,[string]$Prompt,[string]$PromptFile,$Task) { $Arg.Replace('{prompt}',$Prompt).Replace('{promptFile}',$PromptFile).Replace('{projectRoot}',(Get-SCRoot)).Replace('{taskId}',[string]$Task.id) }
function Invoke-SCProvider($Task,[string]$Prompt,[string]$Stage,[string]$ProviderOverride,[string]$ParentAgentId=$null,$Compilation=$null) {
    $providerRecord=Resolve-SCProvider $Task $ProviderOverride $Stage;$receiptId=New-SCId $Stage;$agentId=New-SCId 'agent';$promptPath=Get-SCPath ("prompts/{0}.txt"-f$receiptId);$Prompt|Set-Content -LiteralPath $promptPath -Encoding UTF8
    $exe=[string]$providerRecord.config.command;$args=@();foreach($arg in @($providerRecord.config.args)){$args+=Expand-SCArg ([string]$arg) $Prompt $promptPath $Task}
    $stdoutPath=Get-SCPath ("runs/{0}.stdout.txt"-f$receiptId);$stderrPath=Get-SCPath ("runs/{0}.stderr.txt"-f$receiptId);$started=(Get-Date).ToUniversalTime()
    $compilationId=if($Compilation){$Compilation.id}else{$null};$fingerprint=if($Compilation){$Compilation.inputFingerprint}else{$null};$retrievedChars=0;if($Compilation-and$Compilation.ir.sources.retrieved){$retrievedChars=[int]$Compilation.ir.sources.retrieved.usedChars}
    $telemetry=[ordered]@{schemaVersion=2;agentId=$agentId;receiptId=$receiptId;parentAgentId=$ParentAgentId;taskId=$Task.id;taskTitle=$Task.title;stage=$Stage;provider=$providerRecord.name;model=$null;lifecycle='running';processId=$null;startedAt=$started.ToString('o');heartbeatAt=$started.ToString('o');endedAt=$null;durationSeconds=$null;promptChars=$Prompt.Length;retrievedChars=$retrievedChars;compilationId=$compilationId;inputFingerprint=$fingerprint;command=$exe;args=$args;exitCode=$null;verdict=$null;stdoutPath=$stdoutPath;stderrPath=$stderrPath;error=$null}
    Save-SCActiveTelemetry $telemetry;Add-SCTelemetryEvent 'agent.started' $telemetry;$stdout='';$stderr='';$exitCode=-1
    try{& $exe @args 1> $stdoutPath 2> $stderrPath;$exitCode=$LASTEXITCODE;if($null-eq$exitCode){$exitCode=0};if(Test-Path $stdoutPath){$stdout=Get-Content -Raw -LiteralPath $stdoutPath};if(Test-Path $stderrPath){$stderr=Get-Content -Raw -LiteralPath $stderrPath}}catch{$stderr=$_|Out-String;$telemetry.error=$stderr;$exitCode=-1}
    $ended=(Get-Date).ToUniversalTime();$telemetry.lifecycle=if($exitCode-eq 0){'completed'}else{'failed'};$telemetry.exitCode=$exitCode;$telemetry.endedAt=$ended.ToString('o');$telemetry.heartbeatAt=$telemetry.endedAt;$telemetry.durationSeconds=[math]::Round(($ended-$started).TotalSeconds,3);Complete-SCTelemetry $telemetry
    return [ordered]@{schemaVersion=2;id=$receiptId;agentId=$agentId;taskId=$Task.id;stage=$Stage;provider=$providerRecord.name;compilationId=$compilationId;inputFingerprint=$fingerprint;command=$exe;args=$args;promptPath=$promptPath;startedAt=$started.ToString('o');endedAt=$ended.ToString('o');durationSeconds=$telemetry.durationSeconds;exitCode=$exitCode;stdout=$stdout;stderr=$stderr}
}
function Capture-SCContextRequests($Task,$Run,$Compilation) {
    $requests=@();foreach($line in @(([string]$Run.stdout)-split"`r?`n")){if($line-match'^\s*CONTEXT_(?:REQUEST|MISS):\s*(.+?)\s*$'){$requests+=$Matches[1]}}
    Set-SCProperty $Run 'contextRequests' @($requests)
    if($requests.Count-gt 0){
        Ensure-SCTelemetryLayout
        foreach($request in $requests){$record=[ordered]@{ts=(Get-Date).ToUniversalTime().ToString('o');taskId=$Task.id;runId=$Run.id;compilationId=$Compilation.id;inputFingerprint=$Compilation.inputFingerprint;request=$request};(ConvertTo-SCJson $record 8 -replace"`r?`n",'')|Add-Content -LiteralPath (Get-SCPath 'telemetry/context-faults.jsonl') -Encoding UTF8}
        Add-SCEvent 'context.fault' "Worker requested missing context." @{taskId=$Task.id;runId=$Run.id;compilationId=$Compilation.id;requests=@($requests)}
    }
    return @($requests)
}
function Get-SCVerdict([string]$Text,[int]$ExitCode) { if($ExitCode-ne 0){return'FAIL'};foreach($line in @($Text-split"`r?`n")){$trimmed=$line.Trim();if(-not$trimmed){continue};if($trimmed-match'^VERDICT:\s*PASS\s*$'){return'PASS'};if($trimmed-match'^VERDICT:\s*FAIL\s*$'){return'FAIL'};break};return'FAIL' }
function Set-SCTelemetryVerdict([string]$AgentId,[string]$Verdict) { $path=Get-SCPath ("telemetry/runs/{0}.json"-f$AgentId);$record=Read-SCJson $path;if($record){$record.verdict=$Verdict;Write-SCJson $path $record} }
function Invoke-SCReview($Task,$Run,$Compilation,[string]$Stage) {
    $receipt=Invoke-SCProvider $Task (New-SCReviewPrompt $Task $Run $Compilation $Stage) $Stage $null $Run.agentId $Compilation;$receipt.verdict=Get-SCVerdict ([string]$receipt.stdout) ([int]$receipt.exitCode);Set-SCTelemetryVerdict $receipt.agentId $receipt.verdict;$dir=if($Stage-eq'critic'){'critiques'}else{'validations'};Write-SCJson (Get-SCPath ("{0}/{1}.json"-f$dir,$receipt.id)) $receipt;Add-SCEvent "$Stage.finished" "$Stage $($receipt.id): $($receipt.verdict)" @{taskId=$Task.id;receiptId=$receipt.id;agentId=$receipt.agentId;verdict=$receipt.verdict;compilationId=$Compilation.id};return $receipt
}
function New-SCCompletionProposal($Task,$Run,$Compilation) {
    $proposal=[ordered]@{schemaVersion=1;id=New-SCId 'proposal';taskId=$Task.id;kind='task_completion';status='pending';createdAt=(Get-Date).ToUniversalTime().ToString('o');committedAt=$null;rejectedAt=$null;base=[ordered]@{compilationId=$Compilation.id;inputFingerprint=$Compilation.inputFingerprint;taskDefinitionHash=$Compilation.readSet.taskDefinitionHash};evidence=[ordered]@{runId=$Run.id;criticId=$null;criticVerdict=$null;validationId=$null;validationVerdict=$null};rejectionReasons=@()}
    Write-SCJson (Get-SCPath ("proposals/{0}.json"-f$proposal.id)) $proposal;$Task.latestProposalId=$proposal.id;Save-SCTask $Task;Add-SCEvent 'state.proposed' "Proposed completion for $($Task.id)." @{taskId=$Task.id;proposalId=$proposal.id;compilationId=$Compilation.id};return $proposal
}
function Save-SCProposal($Proposal){Write-SCJson (Get-SCPath ("proposals/{0}.json"-f$Proposal.id)) $Proposal}
function Reject-SCProposal($Proposal,$Reasons) {$Proposal.status='rejected';$Proposal.rejectedAt=(Get-Date).ToUniversalTime().ToString('o');$Proposal.rejectionReasons=@($Reasons);Save-SCProposal $Proposal;Add-SCEvent 'state.proposal_rejected' "Rejected $($Proposal.id)." @{taskId=$Proposal.taskId;proposalId=$Proposal.id;reasons=@($Reasons)}}
function Add-SCProgressRecord($Task,$Compilation,[bool]$Advanced,[string]$Outcome,[string]$Reason) {
    $record=[ordered]@{schemaVersion=1;id=New-SCId 'progress';ts=(Get-Date).ToUniversalTime().ToString('o');taskId=$Task.id;compilationId=if($Compilation){$Compilation.id}else{$null};inputFingerprint=if($Compilation){$Compilation.inputFingerprint}else{$null};advanced=$Advanced;outcome=$Outcome;reason=$Reason;taskStatus=$Task.status;attemptCount=if($Task.PSObject.Properties['attemptCount']){$Task.attemptCount}else{$null}}
    Write-SCJson (Get-SCPath ("progress/{0}.json"-f$record.id)) $record
    if(-not$Advanced-and$Compilation){
        $cfg=Get-SCConfig;$threshold=if($cfg.PSObject.Properties['stagnationWarningThreshold']){[int]$cfg.stagnationWarningThreshold}else{2};$same=@(Get-ChildItem -LiteralPath (Get-SCPath 'progress') -Filter '*.json' -File|ForEach-Object{Read-SCJson $_.FullName}|Where-Object{$_.taskId-eq$Task.id-and-not[bool]$_.advanced-and$_.inputFingerprint-eq$Compilation.inputFingerprint})
        if($same.Count-ge$threshold){Add-SCEvent 'task.stagnation.warning' "Task $($Task.id) has $($same.Count) non-advancing attempts against the same compiled input." @{taskId=$Task.id;inputFingerprint=$Compilation.inputFingerprint;count=$same.Count}}
    }
    return $record
}
function Commit-SCProposal($Task,$Proposal,$Compilation) {
    $fresh=Test-SCCompilationFreshness $Compilation 'commit';if(-not$fresh.fresh){Reject-SCProposal $Proposal @($fresh.reasons);$Task.status='needs_rework';$Task.blockReason='Compiled state became stale before commit.';Save-SCTask $Task;Add-SCProgressRecord $Task $Compilation $false 'stale' ($fresh.reasons -join '; ')|Out-Null;return $false}
    $Proposal.status='committed';$Proposal.committedAt=(Get-Date).ToUniversalTime().ToString('o');Save-SCProposal $Proposal;$Task.status='complete';$Task.blockReason=$null;Save-SCTask $Task;Add-SCEvent 'state.committed' "Committed completion proposal $($Proposal.id)." @{taskId=$Task.id;proposalId=$Proposal.id;compilationId=$Compilation.id};Add-SCEvent 'task.completed' "Completed $($Task.id) after validated commit." @{taskId=$Task.id;runId=$Proposal.evidence.runId;proposalId=$Proposal.id};Add-SCProgressRecord $Task $Compilation $true 'committed' 'Validated proposal committed.'|Out-Null;Update-SCReadiness;return $true
}
function Invoke-SCTask([string]$RequestedTaskId,[string]$ProviderOverride) {
    Assert-SCInitialized;Update-SCReadiness;$state=Get-SCState;$cfg=Get-SCConfig;if($state.activePlanId-and[bool]$cfg.requireHumanApprovalForPlan-and-not[bool]$state.planApproved){throw 'Active plan requires approval.'}
    $task=if($RequestedTaskId){Get-SCTask $RequestedTaskId}else{Get-SCTasks|Where-Object{$_.status-eq'ready'-and-not$_.humanGate}|Sort-Object createdAt|Select-Object -First 1};if($null-eq$task){throw 'No runnable ready task.'};if($task.status-ne'ready'){throw "Task $($task.id) is $($task.status), not ready."};if($task.humanGate){throw 'Task requires human gate.'}
    $task.status='running';$task.attemptCount=if($task.PSObject.Properties['attemptCount']){[int]$task.attemptCount+1}else{1};$task.blockReason=$null;Save-SCTask $task;Add-SCEvent 'run.started' 'Worker cycle started' @{taskId=$task.id;attempt=$task.attemptCount}
    $compilation=New-SCCompilation $task;$fresh=Test-SCCompilationFreshness $compilation 'dispatch'
    if(-not$fresh.fresh){$task=Get-SCTask $task.id;$task.status='needs_rework';$task.blockReason='Compiled context became stale before dispatch.';Save-SCTask $task;Add-SCProgressRecord $task $compilation $false 'stale-before-dispatch' ($fresh.reasons -join '; ')|Out-Null;Add-SCEvent 'context.stale' $task.blockReason @{taskId=$task.id;compilationId=$compilation.id;reasons=@($fresh.reasons)};Write-Warning $task.blockReason;return}
    $run=Invoke-SCProvider $task (New-SCWorkerPrompt $compilation) 'run' $ProviderOverride $null $compilation;Capture-SCContextRequests $task $run $compilation|Out-Null;Write-SCJson (Get-SCPath ("runs/{0}.json"-f$run.id)) $run;$task=Get-SCTask $task.id;$task.latestRunId=$run.id;Save-SCTask $task
    if([int]$run.exitCode-ne 0){$task.status='failed';$task.blockReason="Worker exited $($run.exitCode)";Save-SCTask $task;Add-SCEvent 'run.failed' $task.blockReason @{taskId=$task.id;runId=$run.id;agentId=$run.agentId;compilationId=$compilation.id};Add-SCProgressRecord $task $compilation $false 'worker-failed' $task.blockReason|Out-Null;Write-Warning $task.blockReason;return};Add-SCEvent 'run.finished' "Worker finished $($run.id)" @{taskId=$task.id;runId=$run.id;agentId=$run.agentId;compilationId=$compilation.id}
    $proposal=New-SCCompletionProposal $task $run $compilation
    if([bool]$cfg.criticEnabled){$task.status='reviewing';Save-SCTask $task;$critique=Invoke-SCReview $task $run $compilation 'critic';$proposal.evidence.criticId=$critique.id;$proposal.evidence.criticVerdict=$critique.verdict;Save-SCProposal $proposal;$task=Get-SCTask $task.id;$task.latestCritiqueId=$critique.id;Save-SCTask $task;if($critique.verdict-ne'PASS'){Reject-SCProposal $proposal @('critic rejected worker result');$task.status='needs_rework';$task.blockReason='Critic rejected worker result.';Save-SCTask $task;Add-SCProgressRecord $task $compilation $false 'critic-rejected' $task.blockReason|Out-Null;Write-Warning $task.blockReason;return}}
    if([bool]$cfg.validatorEnabled){$task.status='validating';Save-SCTask $task;$validation=Invoke-SCReview $task $run $compilation 'validator';$proposal.evidence.validationId=$validation.id;$proposal.evidence.validationVerdict=$validation.verdict;Save-SCProposal $proposal;$task=Get-SCTask $task.id;$task.latestValidationId=$validation.id;Save-SCTask $task;if($validation.verdict-ne'PASS'){Reject-SCProposal $proposal @('validator rejected worker result');$task.status='needs_rework';$task.blockReason='Validator rejected worker result.';Save-SCTask $task;Add-SCProgressRecord $task $compilation $false 'validator-rejected' $task.blockReason|Out-Null;Write-Warning $task.blockReason;return}}
    $task=Get-SCTask $task.id;if(Commit-SCProposal $task $proposal $compilation){Write-Host "Task complete: $($task.id)"}else{Write-Warning "Task not committed: $($task.id)"}
}
function Retry-SCTask([string]$Id) { if(-not$Id){throw '-TaskId required.'};$task=Get-SCTask $Id;$was=$task.status;$task.status='ready';$task.blockReason=$null;Save-SCTask $task;if($was-eq'complete'-or$was-eq'stale'){Invalidate-SCDependents $Id 'upstream task retried'};Update-SCReadiness;Add-SCEvent 'task.retried' "Retry $Id" @{taskId=$Id;previousStatus=$was};Write-Host 'Task reset to ready.' }
function Complete-SCTask([string]$Id) { if(-not$Id){throw '-TaskId required.'};$task=Get-SCTask $Id;$was=$task.status;$task.status='complete';$task.blockReason=$null;Save-SCTask $task;Add-SCEvent 'task.completed.manual' "Completed $Id manually" @{taskId=$Id;previousStatus=$was;authority='human'};Add-SCProgressRecord $task $null $true 'human-commit' 'Human explicitly committed task completion.'|Out-Null;Update-SCReadiness;Write-Host 'Task completed.' }
function Block-SCTask([string]$Id,[string]$Why) { if(-not$Id){throw '-TaskId required.'};if(-not$Why){throw '-Reason required.'};$task=Get-SCTask $Id;$was=$task.status;$task.status='blocked';$task.blockReason=$Why;Save-SCTask $task;if($was-eq'complete'){Invalidate-SCDependents $Id 'upstream task blocked after completion'};Add-SCEvent 'task.blocked' $Why @{taskId=$Id};Write-Host 'Task blocked.' }
function Show-SCProviders { $cfg=Get-SCConfig;$rows=@();foreach($property in $cfg.providers.PSObject.Properties){$rows+=[pscustomobject]@{name=$property.Name;command=$property.Value.command;mode=$property.Value.mode}};$rows|Format-Table -AutoSize }
function Show-SCTelemetry([string]$Mode,[string]$Id) { if([string]::IsNullOrWhiteSpace($Mode)){$Mode='active'};switch($Mode.ToLowerInvariant()){'active'{@(Get-SCActiveTelemetry)|Select-Object agentId,taskId,stage,provider,lifecycle,compilationId,startedAt|Format-Table -AutoSize;break};'history'{@(Get-SCTelemetryRuns 100)|Select-Object agentId,taskId,stage,provider,lifecycle,exitCode,verdict,durationSeconds,compilationId,startedAt|Format-Table -AutoSize;break};'faults'{@(Get-SCContextFaults 100)|Select-Object ts,taskId,runId,compilationId,request|Format-Table -AutoSize;break};'show'{if(-not$Id){throw '-RunId required (agent id).'};$record=Read-SCJson (Get-SCPath ("telemetry/runs/{0}.json"-f$Id));if(-not$record){throw "Unknown telemetry run: $Id"};ConvertTo-SCJson $record 14|Write-Host;break};default{throw "Unknown telemetry subcommand: $Mode"}} }
function Show-SCContext([string]$Mode,[string]$Id) { if([string]::IsNullOrWhiteSpace($Mode)){$Mode='faults'};switch($Mode.ToLowerInvariant()){'faults'{@(Get-SCContextFaults 100)|ConvertTo-SCJson -Depth 12|Write-Host;break};'show'{if(-not$Id){throw '-CompilationId required.'};$record=Read-SCJson (Get-SCPath ("compilations/{0}.json"-f$Id));if(-not$record){throw "Unknown compilation: $Id"};ConvertTo-SCJson $record 24|Write-Host;break};default{throw "Unknown context subcommand: $Mode"}} }
function Show-SCProgress([string]$Mode) { if([string]::IsNullOrWhiteSpace($Mode)){$Mode='history'};if($Mode.ToLowerInvariant()-ne'history'){throw "Unknown progress subcommand: $Mode"};@(Get-ChildItem -LiteralPath (Get-SCPath 'progress') -Filter '*.json' -File|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 100|ForEach-Object{Read-SCJson $_.FullName})|Select-Object ts,taskId,advanced,outcome,attemptCount,inputFingerprint|Format-Table -AutoSize }

switch($Command.ToLowerInvariant()){
'init'{Initialize-SC;break}
'goal'{$text=if($Message){$Message}elseif($Subcommand){$Subcommand}else{$Title};Set-SCGoal $text;break}
'status'{Show-SCStatus;break}
'task'{if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='list'};switch($Subcommand.ToLowerInvariant()){'add'{Add-SCTask;break};'list'{Update-SCReadiness;Get-SCTasks|Sort-Object createdAt|Select-Object id,status,attemptCount,role,humanGate,title|Format-Table -AutoSize;break};'show'{if(-not$TaskId){throw '-TaskId required.'};Get-SCTask $TaskId|ConvertTo-SCJson -Depth 16|Write-Host;break};'retry'{Retry-SCTask $TaskId;break};default{throw "Unknown task subcommand: $Subcommand"}};break}
'plan'{if($null-eq$Subcommand){$Subcommand=''};switch($Subcommand.ToLowerInvariant()){'import'{if(-not$Path){throw '-Path required.'};Import-SCPlan $Path;break};'approve'{Approve-SCPlan;break};default{throw "Unknown plan subcommand: $Subcommand"}};break}
'run'{Invoke-SCTask $TaskId $Provider;break}
'complete'{Complete-SCTask $TaskId;break}
'block'{Block-SCTask $TaskId $Reason;break}
'event'{if(-not$Message){throw '-Message required.'};Add-SCEvent 'user.note' $Message;Write-Host 'Event recorded.';break}
'provider'{if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='list'};if($Subcommand.ToLowerInvariant()-eq'list'){Show-SCProviders}else{throw "Unknown provider subcommand: $Subcommand"};break}
'telemetry'{Show-SCTelemetry $Subcommand $RunId;break}
'context'{Show-SCContext $Subcommand $CompilationId;break}
'progress'{Show-SCProgress $Subcommand;break}
default{throw "Unknown command: $Command"}
}

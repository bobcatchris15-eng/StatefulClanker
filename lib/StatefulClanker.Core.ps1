<# Two distinct roots.

   WorkRoot  - where the worker operates and retrieval selectors resolve.
   StateRoot - where .statefulclanker lives.

   They are the same directory for an ordinary run. They differ when a cycle runs
   inside a git worktree: the worker edits an isolated checkout while durable state
   stays canonical in the main tree, shared by every concurrent cycle. Before this
   split, Get-SCRoot served both roles, so a worktree cycle would have looked for
   .statefulclanker inside the worktree, where it does not exist. #>
$script:SCWorkRoot = $null
$script:SCStateRoot = $null
function Set-SCRoots([string]$WorkRoot, [string]$StateRoot) {
    if ($WorkRoot) { $script:SCWorkRoot = (Resolve-Path -LiteralPath $WorkRoot).Path }
    if ($StateRoot) { $script:SCStateRoot = (Resolve-Path -LiteralPath $StateRoot).Path }
}
function Get-SCRoot { if ($script:SCWorkRoot) { $script:SCWorkRoot } else { (Get-Location).Path } }
function Get-SCStateRoot { if ($script:SCStateRoot) { $script:SCStateRoot } else { Get-SCRoot } }
function Get-SCDir { Join-Path (Get-SCStateRoot) '.statefulclanker' }
function Get-SCPath([string]$Child) { Join-Path (Get-SCDir) $Child }

<# Cross-process mutual exclusion over durable state.

   Concurrent cycles are separate processes, so an in-process lock is useless. Every
   read-modify-write of state.json, the task files and the event log goes through
   here. Update-SCReadiness is the sharpest edge: it rewrites the status of tasks
   that the calling cycle does not own, so two unsynchronised cycles will clobber
   each other's work. #>
function Get-SCLockName {
    'Local\StatefulClanker-' + (Get-SCHashString ((Get-SCStateRoot).ToLowerInvariant())).Substring(0, 32)
}
function Invoke-SCLocked([scriptblock]$Body, [int]$TimeoutSeconds = 120) {
    $mutex = New-Object System.Threading.Mutex($false, (Get-SCLockName))
    $held = $false
    try {
        try {
            $held = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        } catch [System.Threading.AbandonedMutexException] {
            # The previous holder died without releasing. We now own it, and the
            # state on disk is whatever that process left behind; every write here
            # is atomic (temp file + move), so a half-written file is not possible.
            $held = $true
        }
        if (-not $held) { throw "Timed out after ${TimeoutSeconds}s waiting for the StatefulClanker state lock." }
        return (& $Body)
    } finally {
        if ($held) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}
function ConvertTo-SCJson {
    param([Parameter(ValueFromPipeline=$true, Position=0)]$Value, [Parameter(Position=1)][int]$Depth=12)
    process {
        if ($null -ne $Value) { $Value | ConvertTo-Json -Depth $Depth }
    }
}
function Set-SCProperty($Object,[string]$Name,$Value) {
    if($Object -is [System.Collections.IDictionary]){$Object[$Name]=$Value;return}
    if($Object.PSObject.Properties[$Name]){$Object.$Name=$Value}else{$Object|Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force}
}
function Write-SCJson([string]$TargetPath,$Value) {
    $parent=Split-Path -Parent $TargetPath
    if($parent -and -not(Test-Path $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
    $leaf=Split-Path -Leaf $TargetPath;$nonce="$PID-$([Guid]::NewGuid().ToString('N'))";$tmp=Join-Path $parent (".{0}.{1}.tmp"-f$leaf,$nonce);$backup=Join-Path $parent (".{0}.{1}.bak"-f$leaf,$nonce)
    try {
        ConvertTo-SCJson $Value 30 | Set-Content -LiteralPath $tmp -Encoding UTF8
        for($i=0;$i-lt40;$i++){
            try {
                if(Test-Path -LiteralPath $TargetPath){[IO.File]::Replace($tmp,$TargetPath,$backup)}else{[IO.File]::Move($tmp,$TargetPath)}
                return
            } catch [System.IO.IOException] {
                if($i-ge39){throw};Start-Sleep -Milliseconds 25
            }
        }
    } finally {
        if(Test-Path -LiteralPath $tmp){Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue}
        if(Test-Path -LiteralPath $backup){Remove-Item -Force -LiteralPath $backup -ErrorAction SilentlyContinue}
    }
}
function Read-SCJson([string]$TargetPath) {
    if(-not(Test-Path $TargetPath)){return $null}
    $raw=Get-Content -Raw -LiteralPath $TargetPath
    if([string]::IsNullOrWhiteSpace($raw)){return $null}
    try {
        return ($raw|ConvertFrom-Json)
    } catch {
        throw "Failed to parse JSON in '$TargetPath': $($_.Exception.Message)"
    }
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
function Add-SCTextLine([string]$TargetPath,[string]$Line,[int]$Retries=40) {
    $parent=Split-Path -Parent $TargetPath;if($parent-and-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
    for($i=0;$i-lt$Retries;$i++){
        try{$Line|Add-Content -LiteralPath $TargetPath -Encoding UTF8;return}
        catch [System.IO.IOException]{if($i-ge($Retries-1)){throw};Start-Sleep -Milliseconds 25}
    }
}
function Add-SCEvent([string]$Type,[string]$Text,$Data=$null) {
    Assert-SCInitialized
    $evt=[ordered]@{id=New-SCId 'event';ts=(Get-Date).ToUniversalTime().ToString('o');type=$Type;message=$Text;data=$Data}
    Invoke-SCLocked { Add-SCTextLine (Get-SCPath 'events.jsonl') ((ConvertTo-SCJson $evt 12) -replace "`r?`n",'') }
}
function Get-SCState { Assert-SCInitialized;Invoke-SCLocked { Read-SCJson (Get-SCPath 'state.json') } }
function Save-SCState($State) {
    Invoke-SCLocked {
        $revision=0;if($State.PSObject.Properties['revision']){$revision=[int]$State.revision}
        Set-SCProperty $State 'revision' ($revision+1);Set-SCProperty $State 'updatedAt' ((Get-Date).ToUniversalTime().ToString('o'));Write-SCJson (Get-SCPath 'state.json') $State
    }
}
function Get-SCConfig { Assert-SCInitialized;$cfg=Read-SCJson (Get-SCPath 'config.json');if($null-eq$cfg){throw 'Missing .statefulclanker/config.json'};return $cfg }
<# Reads take the same lock as writes.

   Write-SCJson writes a unique temp file and atomically replaces the destination. Reads
   take the same mutex as task/state writes, so they do not race replacement and
   surface spurious missing/partial state. The mutex is reentrant per-thread, so
   nesting inside a Save-* is fine. #>
function Get-SCTask([string]$Id) { $task=Invoke-SCLocked { Read-SCJson (Get-SCPath ("tasks/{0}.json"-f$Id)) };if($null-eq$task){throw "Unknown task: $Id"};return $task }
function Save-SCTask($Task) {
    Invoke-SCLocked {
        $revision=0;if($Task.PSObject.Properties['stateRevision']){$revision=[int]$Task.stateRevision}
        Set-SCProperty $Task 'stateRevision' ($revision+1);Set-SCProperty $Task 'updatedAt' ((Get-Date).ToUniversalTime().ToString('o'));Write-SCJson (Get-SCPath ("tasks/{0}.json"-f$Task.id)) $Task
    }
}
function Get-SCTasks { Assert-SCInitialized;$dir=Get-SCPath 'tasks';if(-not(Test-Path $dir)){return @()};return @(Invoke-SCLocked { @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File|ForEach-Object{Read-SCJson $_.FullName}|Where-Object{$null-ne$_}) }) }
function Get-SCTaskControlRevision($Task) { if($Task.PSObject.Properties['controlRevision']){return [int]$Task.controlRevision};return 0 }
function Advance-SCTaskControlRevision($Task) { $next=(Get-SCTaskControlRevision $Task)+1;Set-SCProperty $Task 'controlRevision' $next;return $next }
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
    Invoke-SCLocked { Update-SCReadinessCore }
}
function Update-SCReadinessCore {
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
                $was=$task.status;$task.status=if($was-eq'complete'){'stale'}else{'pending'};$task.blockReason="Invalidated by ${current}: $Why";Save-SCTask $task
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
    Add-SCTextLine (Get-SCPath 'telemetry/events.jsonl') ((ConvertTo-SCJson $evt 8) -replace "`r?`n",'')
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
    foreach($child in @('tasks','plans','runs','critiques','validations','prompts','compilations','proposals','progress','reviews','telemetry','telemetry/active','telemetry/runs')){$target=Get-SCPath $child;if(-not(Test-Path $target)){New-Item -ItemType Directory -Force -Path $target|Out-Null}}
    Ensure-SCTelemetryLayout
    $state=Get-SCState;$changed=$false
    if(-not$state.PSObject.Properties['schemaVersion']-or[int]$state.schemaVersion-lt 4){Set-SCProperty $state 'schemaVersion' 4;$changed=$true}
    if(-not$state.PSObject.Properties['revision']){Set-SCProperty $state 'revision' 0;$changed=$true}
    if(-not$state.PSObject.Properties['directionRevision']){Set-SCProperty $state 'directionRevision' 0;$changed=$true}
    if($changed){Save-SCState $state;Add-SCEvent 'state.migrated' 'Upgraded durable state layout to schema version 4.' @{schemaVersion=4}}
}
function Initialize-SC {
    $dir=Get-SCDir
    if(Test-Path (Join-Path $dir 'state.json')){Upgrade-SCStateLayout;Write-Host 'Already initialized; state layout checked.';return}
    New-Item -ItemType Directory -Force -Path $dir|Out-Null
    foreach($child in @('tasks','plans','runs','critiques','validations','prompts','compilations','proposals','progress','reviews','telemetry','telemetry/active','telemetry/runs')){New-Item -ItemType Directory -Force -Path (Join-Path $dir $child)|Out-Null}
    $now=(Get-Date).ToUniversalTime().ToString('o')
    Write-SCJson (Join-Path $dir 'state.json') ([ordered]@{schemaVersion=4;revision=0;directionRevision=0;projectId=New-SCId 'project';projectRoot=Get-SCRoot;goal='';activePlanId=$null;planApproved=$false;createdAt=$now;updatedAt=$now})
    ''|Set-Content -LiteralPath (Join-Path $dir 'events.jsonl') -Encoding UTF8
    ''|Set-Content -LiteralPath (Join-Path $dir 'telemetry/events.jsonl') -Encoding UTF8
    ''|Set-Content -LiteralPath (Join-Path $dir 'telemetry/context-faults.jsonl') -Encoding UTF8
    $example=Join-Path $script:StatefulClankerHome 'statefulclanker.example.json'
    if(Test-Path $example){Copy-Item -LiteralPath $example -Destination (Join-Path $dir 'config.json')}
    else{Write-SCJson (Join-Path $dir 'config.json') ([ordered]@{defaultProvider='opencode';criticProvider=$null;validatorProvider=$null;providers=[ordered]@{};maxConcurrent=3;autofillEnabled=$true;autofillIntervalSeconds=300;workingSetBudgetChars=24000;maxFileChars=8000;dependencyResultBudgetChars=8000;recentEventCount=12;recentEventBudgetChars=4000;stagnationWarningThreshold=2;requireHumanApprovalForPlan=$true;criticEnabled=$true;validatorEnabled=$true})}
    $root=Get-SCRoot;$giPath=Join-Path $root '.gitignore'
    try{
        if(Test-Path -LiteralPath $giPath -PathType Leaf){
            $giContent=Get-Content -LiteralPath $giPath -Raw
            if($giContent -notmatch '(?m)^\.statefulclanker/?$'){Add-Content -LiteralPath $giPath -Value "`n.statefulclanker/" -Encoding UTF8}
        }else{Set-Content -LiteralPath $giPath -Value ".statefulclanker/`n" -Encoding UTF8}
    }catch{}
    if((Test-SCGitAvailable) -and (Test-SCGitRepo $root)){
        try{
            $tracked=(Invoke-SCGitCapture $root @('ls-files', '.statefulclanker')).output
            if(-not[string]::IsNullOrWhiteSpace($tracked)){
                $msg=".statefulclanker is tracked in git index, which will cause merge and worktree dirty lockouts. Run 'git rm -r --cached .statefulclanker' to untrack."
                Write-Warning $msg
                Add-SCEvent 'git.tracked_state_warning' $msg @{root=$root}
            }
        }catch{}
    }
    Add-SCEvent 'project.initialized' 'StatefulClanker initialized.' @{root=Get-SCRoot};Write-Host "Initialized $dir"
}
function Set-SCGoal([string]$Text) { Assert-SCInitialized;if([string]::IsNullOrWhiteSpace($Text)){throw 'Goal text required.'};$state=Get-SCState;$state.goal=$Text;Save-SCState $state;Add-SCEvent 'goal.changed' $Text;Write-Host 'Goal updated.' }
function Add-SCDirection([string]$Text) { Assert-SCInitialized;if([string]::IsNullOrWhiteSpace($Text)){throw '-Message required.'};$state=Get-SCState;$current=if($state.PSObject.Properties['directionRevision']){[int]$state.directionRevision}else{0};Set-SCProperty $state 'directionRevision' ($current+1);Save-SCState $state;Add-SCEvent 'user.note' $Text @{directionRevision=$state.directionRevision};Write-Host 'Direction recorded.' }
function New-SCTaskObject([string]$Id,[string]$TaskTitle,[string]$TaskInstruction,$TaskAcceptance,$TaskDepends,$TaskRelations,$TaskRetrieval,$TaskEvidence,[string]$TaskProvider,[string]$TaskRole,[bool]$TaskHumanGate) {
    $now=(Get-Date).ToUniversalTime().ToString('o')
    return [ordered]@{schemaVersion=3;id=$Id;title=$TaskTitle;instruction=$TaskInstruction;acceptance=@($TaskAcceptance);dependsOn=@($TaskDepends);relations=@(ConvertTo-SCRelations $TaskRelations);retrieval=@($TaskRetrieval);evidence=@($TaskEvidence);provider=if($TaskProvider){$TaskProvider}else{$null};role=if($TaskRole){$TaskRole}else{'worker'};humanGate=$TaskHumanGate;status='pending';stateRevision=0;controlRevision=0;attemptCount=0;latestRunId=$null;latestCompilationId=$null;latestProposalId=$null;latestCritiqueId=$null;latestValidationId=$null;blockReason=$null;createdAt=$now;updatedAt=$now}
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

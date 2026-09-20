# Extensions layered over McpCore so both stdio and Streamable HTTP expose the same
# Windows-resident control-plane behavior without duplicating the core tool surface.

$script:SCBaseInvokeMcpRpc = (Get-Item Function:\Invoke-McpRpc).ScriptBlock
$script:SCControlEventsResource='statefulclanker://project/current/control-events'
$script:SCCurrentDirectivesResource='statefulclanker://project/current/directives'
$script:SCProjectSnapshotResource='statefulclanker://project/current/snapshot'

function Get-McpResidentActiveProject {
    $path=Join-Path (Join-Path $env:LOCALAPPDATA 'StatefulClanker') 'active-project.txt'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    try{$value=(Get-Content -Raw -LiteralPath $path).Trim()}catch{return $null}
    if([string]::IsNullOrWhiteSpace($value)){return $null}
    if(-not(Test-Path -LiteralPath $value -PathType Container)){return $null}
    return (Resolve-Path -LiteralPath $value).Path
}

# Explicit project argument wins. An explicit -ProjectPath/session default is next
# for headless compatibility. Otherwise follow the active project selected by the
# resident Windows application.
function Get-McpProject($Arguments) {
    $candidate=$null
    if($Arguments-and$Arguments.PSObject.Properties['project']-and$Arguments.project){$candidate=[string]$Arguments.project}
    elseif($script:McpDefaultProject){$candidate=$script:McpDefaultProject}
    else{$candidate=Get-McpResidentActiveProject}
    if([string]::IsNullOrWhiteSpace($candidate)){throw 'No active project. Select one in StatefulClanker or pass "project" explicitly.'}
    if(-not(Test-Path -LiteralPath $candidate -PathType Container)){throw "Project path does not exist: $candidate"}
    return (Resolve-Path -LiteralPath $candidate).Path
}

function Get-SCControlPlaneInstructions {
    @'
STATEFULCLANKER CONTROL-PLANE PRIORITIES

1. Preserve and transmit human intent with the least semantic loss possible.
2. Keep the human accurately informed about meaningful project-state changes.
3. Delegate implementation to bounded provider-CLI workers; implementation is not the control plane's primary job.

INTENT FIDELITY IS THE PRIMARY JOB

Aggressively clarify material ambiguity with the human. Do not optimize for fewer conversational turns. If two competent implementers could reasonably make materially different choices from the current human direction, ask before encoding the choice into Intent, plans, or tasks. When the host offers a structured question/questionnaire/quiz tool, prefer it. Contrastive questions are especially useful: "Current direction could mean A or B; which is intended?"

Current human directives are separate from normalized Intent. A directive is the latest direct human word for one named decision/scope. When the human changes an existing decision, update the SAME directive id with directive_set; do not leave both versions active. The latest direct word within that scope is authoritative. Superseded directive revisions remain audit history only and MUST NOT be treated as current specification. If it is unclear whether a new statement replaces an older rule, narrows it, or creates an exception, ask the human.

For material human direction:
- use directive_set with a stable topic id and the human wording;
- preserve the returned sourceRef;
- reconcile the full current directive set against the normalized Intent Contract;
- resolve any contradiction or uncertain precedence with the human;
- call intent_apply with a contradiction-free contract reflecting the current directives.

StatefulClanker deliberately blocks new worker compilation after directive changes until intent_apply commits a reconciled Intent revision. Never bypass that gate merely to keep work moving.

The control plane should maintain traceability from current directive/source -> Intent -> plan -> task. Workers receive the project goal, current directive snapshot, reconciled Intent revision/hash, task, and relevant source references directly. Current directive source artifacts are durable and may be inspected when wording needs verification. Historical/superseded directive revisions are for audit/debugging, not normal worker context.

PROJECT AWARENESS IS THE SECOND JOB

Keep the human informed about meaningful state changes without flooding them with routine subprocess chatter. When supported by the MCP host, subscribe to statefulclanker://project/current/control-events with subscriptions/listen. The stream is level-triggered; after notifications/resources/updated, read the resource or call control_events_since using the last sequence you consumed. If subscriptions are unavailable, poll control_events_since from the last cursor after substantial actions and at the beginning of a resumed control-plane turn.

Treat event levels as:
- human_required: return to the human promptly; affected work should not be guessed through.
- attention: summarize failures, holds, invalidations, accepted/rejected milestones, or intent changes that materially affect progress.
- fyi: batch or omit routine detail unless useful.

Decompose work semantically into independently understandable and independently verifiable cold-start tasks. Prefer tiny/small/medium tasks when separation is natural; never use regex, line count, file count, or arbitrary token thresholds as substitutes for semantic decomposition.

Size against the worker, not against the plan. Task workers are cold-start, unspecialized, workhorse-class models with no memory of this conversation. A well-cut task gives one such worker enough to finish correctly in roughly 2-6 tool-using turns: one concrete objective, a read set the worker does not have to go discover for itself, and acceptance criteria it can check by inspection or by running something, not by judgment. If completing a task would require the worker to first explore the codebase to figure out what it even needs to touch, or to make a design choice a sibling task also depends on, that exploration or that decision is its own task upstream, not an implicit step inside a bigger one.

A task that has already failed critic or validator review is a decomposition signal, not a retry-harder signal. Before resubmitting it unchanged, check its attemptCount and blockReason (surfaced on every task in status/list output). One rejection can be a fluke; a second rejection at the same scope means the task was cut too coarse for a cold-start worker to land in one shot. Split it -- commonly into a narrower spike/investigation task that resolves the ambiguity, followed by an implementation task written with that resolution already known -- rather than spending remaining attempts on the same instruction. A task whose attemptCount reaches maxTaskAttempts stops being retried automatically and goes silent; treat that silence itself as human_required, not as done or abandoned, and either decompose it or bring it to the human explicitly.

Prefer plan_apply with SCPLAN 1 for substantial plans. Do not implement project work in the conversational thread when it belongs in a worker task. StatefulClanker compiles truth packets, invokes configured provider CLIs such as codex/agy/claude/opencode, persists receipts, and applies critic/validator gates.

Workers must never weaken current human directives or the reconciled Intent Contract. INTENT_QUESTION and INTENT_CONFLICT are successful detection of specification uncertainty: surface them to the human rather than penalizing the worker or guessing.

TARGET-POOL MAINTENANCE IS OPERATIONAL, NOT SEMANTIC AUTHORITY

Automatic inference routing draws worker, critic, and validator calls from one project-local target pool using health-aware pseudo-round-robin. Do not assign models to permanent roles or rank them by presumed intelligence. The working hypothesis is that sufficiently capable workhorse models plus strong tooling/context/decomposition are interchangeable enough for these bounded tasks.

Use connection_catalog to inspect the machine's live discovered catalogs and target_pool_list to inspect current project choices. When the pool is stale, sparse, or contains ambiguous free-tier entries, briefly research current provider/model availability and then use target_pool_upsert/target_pool_remove to maintain it. Prefer currently free or local chat/coding models with tool calling when available and enough context for the compiled packet. Record a compact rationale and researchedAt timestamp. Free-tier claims are time-sensitive operational facts, not durable Intent. Never copy credentials or secrets into project state.
'@
}

function Get-McpCurrentDirectives([string]$Project) {
    $dir=Join-Path (Get-McpStateDir $Project) 'directives\current'
    if(-not(Test-Path -LiteralPath $dir)){return @()}
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File|Sort-Object Name|ForEach-Object{Read-McpJson $_.FullName}|Where-Object{$null-ne$_})
}
function Get-McpDirectiveHistory([string]$Project,[string]$Id) {
    if($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'){throw 'Invalid directive id.'}
    $dir=Join-Path (Get-McpStateDir $Project) ("directives\history\{0}"-f$Id)
    if(-not(Test-Path -LiteralPath $dir)){return @()}
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File|Sort-Object Name|ForEach-Object{Read-McpJson $_.FullName}|Where-Object{$null-ne$_})
}
function Get-McpControlCursor([string]$Project) {
    $state=Read-McpJson (Join-Path (Get-McpStateDir $Project) 'control\state.json')
    if($state-and$state.PSObject.Properties['lastSequence']){return [long]$state.lastSequence}
    return 0
}
function Get-McpControlEventsSince([string]$Project,[long]$Since,[int]$Limit=100,[string]$MinimumLevel=$null) {
    $path=Join-Path (Get-McpStateDir $Project) 'control\events.jsonl'
    if(-not(Test-Path -LiteralPath $path)){return @()}
    $rank=@{fyi=0;attention=1;human_required=2};$minRank=0
    if($MinimumLevel){if(-not$rank.ContainsKey($MinimumLevel)){throw "Invalid minimumLevel '$MinimumLevel'."};$minRank=[int]$rank[$MinimumLevel]}
    $out=@();$cap=[Math]::Min(1000,[Math]::Max(1,$Limit))
    foreach($line in @(Get-Content -LiteralPath $path|Where-Object{$_})) {
        try{$evt=$line|ConvertFrom-Json}catch{continue}
        if([long]$evt.sequence-le$Since){continue}
        $level=if($evt.PSObject.Properties['level']){[string]$evt.level}else{'fyi'}
        $eventRank=if($rank.ContainsKey($level)){[int]$rank[$level]}else{0}
        if($eventRank-lt$minRank){continue}
        $out+=,$evt;if($out.Count-ge$cap){break}
    }
    return @($out)
}
function Get-McpControlSnapshot([string]$Project) {
    Assert-McpInitialized $Project
    $stateDir=Get-McpStateDir $Project;$state=Read-McpJson (Join-Path $stateDir 'state.json');$intent=Read-McpJson (Join-Path $stateDir 'intent\contract.json')
    $tasks=@(Read-McpJsonDir (Join-Path $stateDir 'tasks'));$active=@(Read-McpJsonDir (Join-Path $stateDir 'telemetry\active'))
    $summary=[ordered]@{}
    foreach($status in @('pending','ready','running','reviewing','validating','complete','blocked','stale')){$summary[$status]=@($tasks|Where-Object{[string]$_.status-eq$status}).Count}
    return [ordered]@{
        project=$Project
        cursor=Get-McpControlCursor $Project
        goal=if($state){$state.goal}else{$null}
        stateRevision=if($state){$state.revision}else{$null}
        directiveRevision=if($state-and$state.PSObject.Properties['directiveRevision']){$state.directiveRevision}else{0}
        directiveReconciliationRequired=if($state-and$state.PSObject.Properties['directiveReconciliationRequired']){[bool]$state.directiveReconciliationRequired}else{$false}
        pendingDirectiveIds=if($state-and$state.PSObject.Properties['pendingDirectiveIds']){@($state.pendingDirectiveIds)}else{@()}
        currentDirectives=@(Get-McpCurrentDirectives $Project)
        intent=$intent
        activePlanId=if($state){$state.activePlanId}else{$null}
        planApproved=if($state){$state.planApproved}else{$null}
        projectHold=if($state-and$state.PSObject.Properties['projectHold']){$state.projectHold}else{$null}
        taskSummary=$summary
        activeAgents=@($active|ForEach-Object{[ordered]@{agentId=$_.agentId;taskId=$_.taskId;stage=$_.stage;provider=$_.provider;startedAt=$_.startedAt}})
    }
}


function Get-McpConnectionCatalog([string]$Connection=$null) {
    $path=Join-Path (Join-Path $env:LOCALAPPDATA 'StatefulClanker') 'connections.json'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return @()}
    try{$root=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json}catch{return @()}
    if(-not$root-or-not$root.PSObject.Properties['connections']){return @()}
    $rows=@()
    foreach($p in $root.connections.PSObject.Properties){
        if($Connection-and-not[string]::Equals($Connection,[string]$p.Name,[StringComparison]::OrdinalIgnoreCase)){continue}
        $v=$p.Value
        $models=@()
        if($v.PSObject.Properties['models'] -and $v.models){
            foreach($m in @($v.models)){
                $models += [ordered]@{
                    id=if($m.PSObject.Properties['id']){[string]$m.id}else{$null}
                    displayName=if($m.PSObject.Properties['displayName']){[string]$m.displayName}else{$null}
                    contextLength=if($m.PSObject.Properties['contextLength']){$m.contextLength}else{$null}
                    supportsTools=if($m.PSObject.Properties['supportsTools']){$m.supportsTools}else{$null}
                    isFree=if($m.PSObject.Properties['isFree']){$m.isFree}else{$null}
                    inputPrice=if($m.PSObject.Properties['inputPrice']){$m.inputPrice}else{$null}
                    outputPrice=if($m.PSObject.Properties['outputPrice']){$m.outputPrice}else{$null}
                }
            }
        }
        $rows += [ordered]@{
            name=[string]$p.Name
            presetId=if($v.PSObject.Properties['presetId']){[string]$v.presetId}else{'custom'}
            protocol=if($v.PSObject.Properties['protocol']){[string]$v.protocol}else{'openai-chat'}
            baseUrl=if($v.PSObject.Properties['baseUrl']){[string]$v.baseUrl}else{$null}
            health=if($v.PSObject.Properties['health']){[string]$v.health}else{'unknown'}
            lastTestAt=if($v.PSObject.Properties['lastTestAt']){$v.lastTestAt}else{$null}
            models=@($models)
        }
    }
    return @($rows)
}

function Get-McpTargetPoolPath([string]$Project) {
    $dir=Join-Path (Get-McpStateDir $Project) 'routing'
    if(-not(Test-Path -LiteralPath $dir)){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    return Join-Path $dir 'target-pool.json'
}

function Get-McpTargetPool([string]$Project) {
    $path=Get-McpTargetPoolPath $Project
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return [pscustomobject]@{schemaVersion=1;updatedAt=$null;entries=[pscustomobject]@{}}}
    try{
        $pool=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json
        if(-not$pool.PSObject.Properties['entries']){$pool|Add-Member -NotePropertyName entries -NotePropertyValue ([pscustomobject]@{}) -Force}
        return $pool
    }catch{throw "Target pool is invalid JSON: $($_.Exception.Message)"}
}

function Save-McpTargetPool([string]$Project,$Pool) {
    $path=Get-McpTargetPoolPath $Project
    if(-not$Pool.PSObject.Properties['schemaVersion']){$Pool|Add-Member -NotePropertyName schemaVersion -NotePropertyValue 1 -Force}else{$Pool.schemaVersion=1}
    if(-not$Pool.PSObject.Properties['updatedAt']){$Pool|Add-Member -NotePropertyName updatedAt -NotePropertyValue ([datetimeoffset]::UtcNow.ToString('o')) -Force}else{$Pool.updatedAt=[datetimeoffset]::UtcNow.ToString('o')}
    $tmp=$path+'.tmp'
    $json=$Pool|ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText($tmp,$json,(New-Object Text.UTF8Encoding($false)))
    [IO.File]::Move($tmp,$path,$true)
}

function Find-McpCatalogModel([string]$Connection,[string]$Model) {
    $catalog=@(Get-McpConnectionCatalog $Connection)
    if($catalog.Count-eq 0){throw "Unknown machine connection '$Connection'."}
    $match=@($catalog[0].models|Where-Object{[string]::Equals([string]$_.id,$Model,[StringComparison]::OrdinalIgnoreCase)}|Select-Object -First 1)
    if($match.Count-eq 0){throw "Model '$Model' is not in the last discovered catalog for connection '$Connection'. Refresh the connection first."}
    return $match[0]
}


function Get-McpObjectValue($Object,[string]$Name) {
    if($null-eq$Object){return $null}
    if($Object-is[System.Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]};return $null}
    $p=$Object.PSObject.Properties[$Name];if($p){return $p.Value};return $null
}

function Limit-McpRecoveryText($Value,[int]$MaxChars=12000) {
    if($null-eq$Value){return $null}
    $text=[string]$Value
    if($text.Length-le$MaxChars){return $text}
    return $text.Substring(0,$MaxChars)+[Environment]::NewLine+'...[truncated by task_recovery_context]'
}

function Get-McpTaskRecoveryContext([string]$Project,[string]$TaskId) {
    Assert-McpInitialized $Project
    if([string]::IsNullOrWhiteSpace($TaskId)){throw 'taskId required.'}
    $stateDir=Get-McpStateDir $Project
    $task=Read-McpJson (Join-Path $stateDir ("tasks\{0}.json"-f$TaskId))
    if($null-eq$task){throw "Unknown task: $TaskId"}

    $readById={
        param([string]$Dir,$Id)
        if($null-eq$Id-or[string]::IsNullOrWhiteSpace([string]$Id)){return $null}
        return Read-McpJson (Join-Path $stateDir ("{0}\{1}.json"-f$Dir,[string]$Id))
    }
    $comp=&$readById 'compilations' (Get-McpObjectValue $task 'latestCompilationId')
    $run=&$readById 'runs' (Get-McpObjectValue $task 'latestRunId')
    $proposal=&$readById 'proposals' (Get-McpObjectValue $task 'latestProposalId')
    $critique=&$readById 'critiques' (Get-McpObjectValue $task 'latestCritiqueId')
    $validation=&$readById 'validations' (Get-McpObjectValue $task 'latestValidationId')

    $compView=$null
    if($comp){
        $ir=Get-McpObjectValue $comp 'ir'
        $compView=[ordered]@{
            id=Get-McpObjectValue $comp 'id'
            inputFingerprint=Get-McpObjectValue $comp 'inputFingerprint'
            contextFingerprint=Get-McpObjectValue $comp 'contextFingerprint'
            readSet=Get-McpObjectValue $comp 'readSet'
            retrievalStats=Get-McpObjectValue $comp 'retrievalStats'
            project=Get-McpObjectValue $ir 'project'
            task=Get-McpObjectValue $ir 'task'
            dependencies=Get-McpObjectValue $ir 'dependencies'
            outputContract=Get-McpObjectValue $ir 'outputContract'
        }
    }
    $runView=$null
    if($run){
        $runView=[ordered]@{
            id=Get-McpObjectValue $run 'id';agentId=Get-McpObjectValue $run 'agentId'
            workerSessionId=Get-McpObjectValue $run 'workerSessionId'
            provider=Get-McpObjectValue $run 'provider';endpoint=Get-McpObjectValue $run 'endpoint';model=Get-McpObjectValue $run 'model'
            exitCode=Get-McpObjectValue $run 'exitCode';startedAt=Get-McpObjectValue $run 'startedAt';endedAt=Get-McpObjectValue $run 'endedAt'
            stdout=Limit-McpRecoveryText (Get-McpObjectValue $run 'stdout')
            stderr=Limit-McpRecoveryText (Get-McpObjectValue $run 'stderr')
            contextRequests=Get-McpObjectValue $run 'contextRequests'
            candidatePreflight=Get-McpObjectValue $run 'candidatePreflight'
            candidateClaim=Get-McpObjectValue $run 'candidateClaim'
            routeHistory=Get-McpObjectValue $run 'routeHistory'
        }
    }
    $reviewView={
        param($r)
        if($null-eq$r){return $null}
        return [ordered]@{
            id=Get-McpObjectValue $r 'id';agentId=Get-McpObjectValue $r 'agentId'
            provider=Get-McpObjectValue $r 'provider';endpoint=Get-McpObjectValue $r 'endpoint';model=Get-McpObjectValue $r 'model'
            verdict=Get-McpObjectValue $r 'verdict';exitCode=Get-McpObjectValue $r 'exitCode'
            stdout=Limit-McpRecoveryText (Get-McpObjectValue $r 'stdout')
            stderr=Limit-McpRecoveryText (Get-McpObjectValue $r 'stderr')
            compilationId=Get-McpObjectValue $r 'compilationId'
            inputFingerprint=Get-McpObjectValue $r 'inputFingerprint'
        }
    }

    $progress=@(Read-McpJsonDir (Join-Path $stateDir 'progress')|
        Where-Object{[string](Get-McpObjectValue $_ 'taskId')-eq$TaskId}|
        Sort-Object ts -Descending|Select-Object -First 30)

    $recentEvents=@()
    $eventPath=Join-Path $stateDir 'events.jsonl'
    if(Test-Path -LiteralPath $eventPath -PathType Leaf){
        foreach($line in @(Get-Content -LiteralPath $eventPath|Where-Object{$_}|Select-Object -Last 400)){
            try{$evt=$line|ConvertFrom-Json}catch{continue}
            $data=Get-McpObjectValue $evt 'data'
            $eventTask=Get-McpObjectValue $data 'taskId'
            $message=[string](Get-McpObjectValue $evt 'message')
            if(([string]$eventTask-eq$TaskId)-or(-not[string]::IsNullOrWhiteSpace($message)-and$message.Contains($TaskId))){
                $recentEvents+=,$evt
            }
        }
        if($recentEvents.Count-gt30){$recentEvents=@($recentEvents|Select-Object -Last 30)}
    }

    return [ordered]@{
        task=$task
        compilation=$compView
        run=$runView
        proposal=$proposal
        critique=&$reviewView $critique
        validation=&$reviewView $validation
        progress=@($progress)
        recentEvents=@($recentEvents)
        recoveryRules=@{
            investigateBeforeMutating=$true
            humanGatedTasksMayNotBeRecovered=$true
            activeTasksMayNotBeRecovered=$true
            repairPreferredBeforeBypass=$true
            recoverCompleteIsLastResort=$true
            recoverCompleteRequiresConcreteEvidence=$true
            unresolvedHumanIntentMustReturnToHuman=$true
        }
    }
}

function Invoke-McpRecoveryMutation([string]$Project,[string]$TaskId,[string]$Reason,$Evidence,$Patch=$null,[switch]$Complete) {
    Assert-McpInitialized $Project
    if([string]::IsNullOrWhiteSpace($TaskId)){throw 'taskId required.'}
    if([string]::IsNullOrWhiteSpace($Reason)){throw 'reason required.'}
    $items=@($Evidence|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}|ForEach-Object{[string]$_})
    if($items.Count-eq0){throw 'At least one concrete evidence item is required.'}
    if(-not$Complete-and$null-eq$Patch){throw 'task_repair requires a patch object.'}

    $payload=[ordered]@{evidence=@($items)}
    if(-not$Complete){$payload['patch']=$Patch}
    $temp=Join-Path ([IO.Path]::GetTempPath()) ("statefulclanker-recovery-{0}.json"-f[Guid]::NewGuid().ToString('N'))
    try{
        [IO.File]::WriteAllText($temp,($payload|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
        $sub=if($Complete){'recover'}else{'repair'}
        $result=Invoke-McpHarness $Project @('task',$sub,'-TaskId',$TaskId,'-Path',$temp,'-Reason',$Reason)
        $fresh=Read-McpJson (Join-Path (Get-McpStateDir $Project) ("tasks\{0}.json"-f$TaskId))
        return [ordered]@{
            taskId=$TaskId
            action=if($Complete){'recover-complete'}else{'repair'}
            authority='control-plane-recovery'
            bypassedReviewGate=[bool]$Complete
            evidence=@($items)
            reason=$Reason
            task=$fresh
            output=$result.stdout
        }
    }finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
}

function New-SCExtendedTools {
    @(
        @{name='plan_apply';description='Apply a compact SCPLAN 1 plan directly from text. Preferred for conversational planning because no intermediate local file is required.';inputSchema=@{type='object';properties=@{project=@{type='string'};text=@{type='string';description='Complete SCPLAN 1 document.'}};required=@('text')}},
        @{name='source_add';description='Persist verbatim source/background text as a durable human:<id> artifact. For material current human direction use directive_set instead.';inputSchema=@{type='object';properties=@{project=@{type='string'};text=@{type='string'}};required=@('text')}},
        @{name='source_get';description='Read a durable source by reference, including optional #Lx-Ly ranges.';inputSchema=@{type='object';properties=@{project=@{type='string'};sourceRef=@{type='string'}};required=@('sourceRef')}},
        @{name='source_list';description='List durable source artifacts. This includes historical evidence; listing it does NOT make superseded wording current authority.';inputSchema=@{type='object';properties=@{project=@{type='string'}}}},
        @{name='directive_set';description='Set/replace the CURRENT direct human wording for one stable decision scope. Reusing an id supersedes its prior current revision and requires Intent reconciliation.';inputSchema=@{type='object';properties=@{project=@{type='string'};id=@{type='string'};text=@{type='string'};scope=@{type='string'};sourceRef=@{type='string'};intentRefs=@{type='array';items=@{type='string'}};reason=@{type='string'}};required=@('id','text')}},
        @{name='directive_list';description='List only CURRENT authoritative human directives. Superseded revisions are excluded.';inputSchema=@{type='object';properties=@{project=@{type='string'}}}},
        @{name='directive_get';description='Read one CURRENT authoritative human directive.';inputSchema=@{type='object';properties=@{project=@{type='string'};id=@{type='string'}};required=@('id')}},
        @{name='directive_history';description='Audit/debug only: read superseded revisions for a directive. Never treat these as current worker specification.';inputSchema=@{type='object';properties=@{project=@{type='string'};id=@{type='string'}};required=@('id')}},
        @{name='directive_retire';description='Retire a current human directive because the human removed that rule/feature. Requires Intent reconciliation.';inputSchema=@{type='object';properties=@{project=@{type='string'};id=@{type='string'};reason=@{type='string'}};required=@('id')}},
        @{name='intent_apply';description='Commit the complete normalized Intent Contract after reconciling it against ALL current human directives. Clears the directive-reconciliation gate. contract object requires 9 fields: objective (string), requirements (array), constraints (array), invariants (array), nonGoals (array), decisions (array), preferences (array), openQuestions (array), successDefinition (string).';inputSchema=@{type='object';properties=@{project=@{type='string'};contract=@{type='object';description='Intent contract object containing objective, requirements, constraints, invariants, nonGoals, decisions, preferences, openQuestions, successDefinition.'};reason=@{type='string'}};required=@('contract')}},
        @{name='control_events_since';description='Read durable sequenced control-plane events after a cursor. Keep the returned cursor and use it next time; push notifications are only a wake-up signal.';inputSchema=@{type='object';properties=@{project=@{type='string'};since=@{type='integer';minimum=0};limit=@{type='integer';minimum=1;maximum=1000};minimumLevel=@{type='string';enum=@('fyi','attention','human_required')}}}},
        @{name='control_snapshot';description='Read the current human-facing project snapshot: goal, current directives, Intent, reconciliation gate, task counts, holds, active agents, and event cursor.';inputSchema=@{type='object';properties=@{project=@{type='string'}}}},
        @{name='autofill_status';description='Inspect the resident autofill supervisor: state (running, paused, idle, blocked, draining, stopped), PID, slot availability, ready task count, and blocking reasons.';inputSchema=@{type='object';properties=@{project=@{type='string'}}}},
        @{name='autofill_control';description='Control the resident autofill supervisor: pause (suspend dispatch and allow manual runs), resume, stop (drain and exit), or trigger_now (immediate dispatch tick).';inputSchema=@{type='object';properties=@{project=@{type='string'};action=@{type='string';enum=@('stop','pause','resume','trigger_now')}};required=@('action')}},
        @{name='task_recovery_context';description='Read one stalled task recovery dossier: task state plus latest compilation, worker receipt, proposal, critic, validator, progress, and recent task events. Use this before asking the human about a mechanical/review stall.';inputSchema=@{type='object';properties=@{project=@{type='string'};taskId=@{type='string'}};required=@('taskId')}},
        @{name='task_repair';description='CONTROL-PLANE RECOVERY: repair a stalled non-human-gated task definition/graph metadata after investigation, reset exhausted failure counters, and return it to readiness. Requires a reason, concrete evidence, and an explicit patch. Does not change Human Directives or Intent.';inputSchema=@{type='object';properties=@{project=@{type='string'};taskId=@{type='string'};reason=@{type='string'};evidence=@{type='array';items=@{type='string'}};patch=@{type='object';description='Supported fields include title, instruction, size, outputKind, acceptance, dependsOn, relations, retrieval, evidence, provider, role, sources, intentRefs, capabilityProfile, toolPolicy, implications, proofObligations, parentTaskId, childTaskIds.'}};required=@('taskId','reason','evidence','patch')}},
        @{name='task_recover_complete';description='LAST-RESORT CONTROL-PLANE RECOVERY: mark a stalled non-human-gated task complete when concrete current evidence proves the work already satisfies current Human Directives and reconciled Intent despite a broken/repeated review loop. Audited as a review-gate bypass; never use for unresolved human intent.';inputSchema=@{type='object';properties=@{project=@{type='string'};taskId=@{type='string'};reason=@{type='string'};evidence=@{type='array';items=@{type='string'}}};required=@('taskId','reason','evidence')}},
        @{name='connection_catalog';description='Read sanitized machine inference connections and their last discovered model catalogs. Secrets and custom headers are never returned. Use this before maintaining the project target pool.';inputSchema=@{type='object';properties=@{project=@{type='string'};connection=@{type='string';description='Optional connection name to inspect.'}}}},
        @{name='target_pool_list';description='Read the project-local workhorse model target pool used by automatic pseudo-round-robin routing.';inputSchema=@{type='object';properties=@{project=@{type='string'}}}},
        @{name='target_pool_upsert';description='Add or update one discovered connection/model in the automatic workhorse target pool. Record a short rationale and research date when Clanker has checked current suitability/free status.';inputSchema=@{type='object';properties=@{project=@{type='string'};connection=@{type='string'};model=@{type='string'};displayName=@{type='string'};enabled=@{type='boolean'};workhorse=@{type='boolean'};free=@{type='boolean'};supportsTools=@{type='boolean'};contextLength=@{type='integer';minimum=1};toolMode=@{type='string';enum=@('native','text')};rationale=@{type='string'};researchedAt=@{type='string';description='ISO-8601 timestamp; defaults to now when rationale is supplied.'};source=@{type='string';description='Defaults to clanker.'}};required=@('connection','model')}},
        @{name='target_pool_remove';description='Remove one connection/model from the project target pool without altering the machine connection or discovered catalog.';inputSchema=@{type='object';properties=@{project=@{type='string'};connection=@{type='string'};model=@{type='string'}};required=@('connection','model')}}
    )
}

function Invoke-SCDirectiveTool([string]$Name,$Arguments) {
    $project=Get-McpProject $Arguments;Assert-McpInitialized $project
    switch($Name) {
        'directive_list' { return New-McpTextResult ([ordered]@{directives=@(Get-McpCurrentDirectives $project)}) }
        'directive_get' {
            $id=Get-McpArgRequired $Arguments 'id';$path=Join-Path (Get-McpStateDir $project) ("directives\current\{0}.json"-f$id);$d=Read-McpJson $path;if(-not$d){throw "Unknown current directive: $id"};return New-McpTextResult $d
        }
        'directive_history' { $id=Get-McpArgRequired $Arguments 'id';return New-McpTextResult ([ordered]@{directiveId=$id;history=@(Get-McpDirectiveHistory $project $id);authority='audit only; not current specification'}) }
        'directive_set' {
            $id=Get-McpArgRequired $Arguments 'id';$text=Get-McpArgRequired $Arguments 'text';$cli=@('directive','set','-DirectiveId',$id,'-Message',$text)
            $scope=Get-McpArgOptional $Arguments 'scope';if($scope){$cli+=@('-Scope',$scope)}
            $source=Get-McpArgOptional $Arguments 'sourceRef';if($source){$cli+=@('-SourceRef',$source)}
            $reason=Get-McpArgOptional $Arguments 'reason';if($reason){$cli+=@('-Reason',$reason)}
            $refs=@(Get-McpArgArray $Arguments 'intentRefs');if($refs.Count-gt0){$cli+='-IntentRef';$cli+=,$refs}
            $result=Invoke-McpHarness $project $cli
            return New-McpTextResult ([ordered]@{updated=$true;requiresIntentReconciliation=$true;output=$result.stdout})
        }
        'directive_retire' {
            $id=Get-McpArgRequired $Arguments 'id';$cli=@('directive','retire','-DirectiveId',$id);$reason=Get-McpArgOptional $Arguments 'reason';if($reason){$cli+=@('-Reason',$reason)}
            $result=Invoke-McpHarness $project $cli
            return New-McpTextResult ([ordered]@{retired=$true;requiresIntentReconciliation=$true;output=$result.stdout})
        }
        default {throw "Unknown directive tool: $Name"}
    }
}

function Invoke-SCExtendedTool([string]$Name,$Arguments) {
    $project=Get-McpProject $Arguments;Assert-McpInitialized $project
    switch($Name) {
        'plan_apply' {
            $text=Get-McpArgRequired $Arguments 'text';if($text -notmatch '(?m)^\s*SCPLAN\s+1\s*$'){throw 'plan_apply requires a complete SCPLAN 1 document.'}
            $temp=Join-Path ([IO.Path]::GetTempPath()) ("statefulclanker-{0}.scplan"-f[Guid]::NewGuid().ToString('N'))
            try{[IO.File]::WriteAllText($temp,$text,(New-Object Text.UTF8Encoding($false)));$result=Invoke-McpHarness $project @('plan','import','-Path',$temp);return New-McpTextResult ([ordered]@{applied=$true;output=$result.stdout})}finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
        }
        'source_add' {$text=Get-McpArgRequired $Arguments 'text';$result=Invoke-McpHarness $project @('source','add','-Message',$text);return New-McpTextResult ([ordered]@{sourceRef=([string]$result.stdout).Trim();output=$result.stdout})}
        'source_get' {$ref=Get-McpArgRequired $Arguments 'sourceRef';$result=Invoke-McpHarness $project @('source','show','-SourceRef',$ref);return New-McpTextResult ([ordered]@{sourceRef=$ref;text=$result.stdout})}
        'source_list' {$result=Invoke-McpHarness $project @('source','list');return New-McpTextResult ([ordered]@{authority='provenance/history; inspect current directives to determine current human authority';output=$result.stdout})}
        'intent_apply' {
            if(-not$Arguments-or-not$Arguments.PSObject.Properties['contract']-or$null-eq$Arguments.contract){throw 'Required argument missing: contract'}
            $temp=Join-Path ([IO.Path]::GetTempPath()) ("statefulclanker-intent-{0}.json"-f[Guid]::NewGuid().ToString('N'))
            $reason=Get-McpArgOptional $Arguments 'reason';if(-not$reason){$reason='Reconciled current human directives from conversational control plane.'}
            try{$Arguments.contract|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $temp -Encoding UTF8;$result=Invoke-McpHarness $project @('intent','replace','-Path',$temp,'-Reason',$reason);return New-McpTextResult ([ordered]@{applied=$true;reconciliationCleared=$true;output=$result.stdout})}finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
        }
        'control_events_since' {
            $since=0;if($Arguments-and$Arguments.PSObject.Properties['since']-and$null-ne$Arguments.since){$since=[long]$Arguments.since};$limit=100;if($Arguments-and$Arguments.PSObject.Properties['limit']-and$null-ne$Arguments.limit){$limit=[int]$Arguments.limit};$min=Get-McpArgOptional $Arguments 'minimumLevel'
            $events=@(Get-McpControlEventsSince $project $since $limit $min);return New-McpTextResult ([ordered]@{since=$since;cursor=Get-McpControlCursor $project;events=$events})
        }
        'control_snapshot' {return New-McpTextResult (Get-McpControlSnapshot $project)}
        'task_recovery_context' {
            $taskId=Get-McpArgRequired $Arguments 'taskId'
            return New-McpTextResult (Get-McpTaskRecoveryContext $project $taskId)
        }
        'task_repair' {
            $taskId=Get-McpArgRequired $Arguments 'taskId'
            $reason=Get-McpArgRequired $Arguments 'reason'
            $evidence=@(Get-McpArgArray $Arguments 'evidence')
            $patch=Get-McpObjectValue $Arguments 'patch'
            return New-McpTextResult (Invoke-McpRecoveryMutation $project $taskId $reason $evidence $patch)
        }
        'task_recover_complete' {
            $taskId=Get-McpArgRequired $Arguments 'taskId'
            $reason=Get-McpArgRequired $Arguments 'reason'
            $evidence=@(Get-McpArgArray $Arguments 'evidence')
            return New-McpTextResult (Invoke-McpRecoveryMutation $project $taskId $reason $evidence $null -Complete)
        }
        'connection_catalog' {
            $connection=Get-McpArgOptional $Arguments 'connection'
            return New-McpTextResult ([ordered]@{connections=@(Get-McpConnectionCatalog $connection);note='Machine-local discovery metadata only; no credentials or custom headers are exposed.'})
        }
        'target_pool_list' {
            $pool=Get-McpTargetPool $project
            return New-McpTextResult ([ordered]@{project=$project;path=(Get-McpTargetPoolPath $project);updatedAt=$pool.updatedAt;entries=@($pool.entries.PSObject.Properties|ForEach-Object{$_.Value})})
        }
        'target_pool_upsert' {
            $connection=Get-McpArgRequired $Arguments 'connection';$model=Get-McpArgRequired $Arguments 'model'
            $catalogModel=Find-McpCatalogModel $connection $model
            $pool=Get-McpTargetPool $project;$id="$connection::$model";$existing=$pool.entries.PSObject.Properties[$id]
            $displayName=Get-McpArgOptional $Arguments 'displayName';$enabled=Get-McpArgOptional $Arguments 'enabled';$workhorse=Get-McpArgOptional $Arguments 'workhorse'
            $free=Get-McpArgOptional $Arguments 'free';$supportsTools=Get-McpArgOptional $Arguments 'supportsTools';$contextLength=Get-McpArgOptional $Arguments 'contextLength'
            $toolMode=Get-McpArgOptional $Arguments 'toolMode';$source=Get-McpArgOptional $Arguments 'source';$rationale=Get-McpArgOptional $Arguments 'rationale';$researchedAt=Get-McpArgOptional $Arguments 'researchedAt'
            $value=[ordered]@{
                id=$id;connection=$connection;model=$model
                displayName=if($displayName){[string]$displayName}elseif($catalogModel.displayName){[string]$catalogModel.displayName}else{$model}
                enabled=if($null-ne$enabled){[bool]$enabled}else{$true}
                workhorse=if($null-ne$workhorse){[bool]$workhorse}else{$true}
                free=if($null-ne$free){[bool]$free}else{$catalogModel.isFree}
                supportsTools=if($null-ne$supportsTools){[bool]$supportsTools}else{$catalogModel.supportsTools}
                contextLength=if($contextLength){[long]$contextLength}else{$catalogModel.contextLength}
                toolMode=if($toolMode){[string]$toolMode}elseif($catalogModel.supportsTools-eq$false){'text'}else{'native'}
                source=if($source){[string]$source}else{'clanker'}
                rationale=if($null-ne$rationale){[string]$rationale}elseif($existing-and$existing.Value.PSObject.Properties['rationale']){$existing.Value.rationale}else{$null}
                researchedAt=if($researchedAt){[string]$researchedAt}elseif($rationale){[datetimeoffset]::UtcNow.ToString('o')}elseif($existing-and$existing.Value.PSObject.Properties['researchedAt']){$existing.Value.researchedAt}else{$null}
                updatedAt=[datetimeoffset]::UtcNow.ToString('o')
            }
            if($existing){$existing.Value=[pscustomobject]$value}else{$pool.entries|Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject]$value) -Force}
            Save-McpTargetPool $project $pool
            return New-McpTextResult ([ordered]@{updated=$true;entry=$value})
        }
        'target_pool_remove' {
            $connection=Get-McpArgRequired $Arguments 'connection';$model=Get-McpArgRequired $Arguments 'model';$id="$connection::$model"
            $pool=Get-McpTargetPool $project;$existed=$null-ne$pool.entries.PSObject.Properties[$id]
            if($existed){$pool.entries.PSObject.Properties.Remove($id);Save-McpTargetPool $project $pool}
            return New-McpTextResult ([ordered]@{removed=$existed;id=$id})
        }
        'autofill_status' {
            $status=Invoke-McpHarness $project @('autofill','status')
            $sJson=Join-Path (Get-McpStateDir $project) 'autofill\supervisor.json'
            if(Test-Path -LiteralPath $sJson -PathType Leaf){
                try{
                    $record=Read-McpJson $sJson
                    if($record){
                        return New-McpTextResult ([ordered]@{
                            running=$true
                            state=[string]$record.state
                            pid=[int]$record.pid
                            startedAt=$record.startedAt
                            updatedAt=$record.updatedAt
                            intervalSeconds=[int]$record.intervalSeconds
                            maxConcurrent=[int]$record.maxConcurrent
                            ownedActive=[int]$record.ownedActive
                            activeTasks=@($record.activeTasks)
                            readyCount=[int]$record.readyCount
                            slots=[int]$record.slots
                            lastDispatchAt=$record.lastDispatchAt
                            blockReason=$record.blockReason
                            paused=if($record.PSObject.Properties['paused']){[bool]$record.paused}else{$false}
                            output=$status.stdout
                        })
                    }
                }catch{}
            }
            return New-McpTextResult ([ordered]@{
                running=$false
                state='stopped'
                output=$status.stdout
            })
        }
        'autofill_control' {
            $action=Get-McpArgRequired $Arguments 'action'
            $subcmd=switch($action.ToLowerInvariant()){
                'stop' { 'stop' }
                'pause' { 'pause' }
                'resume' { 'resume' }
                'trigger_now' { 'trigger' }
                default { throw "Unknown autofill action: $action. Expected stop, pause, resume, trigger_now." }
            }
            $res=Invoke-McpHarness $project @('autofill',$subcmd)
            return New-McpTextResult ([ordered]@{
                action=$action
                success=$true
                output=$res.stdout
            })
        }
        default {throw "Unknown extended tool: $Name"}
    }
}

function Invoke-SCDirectionAdd($Arguments) {
    $project=Get-McpProject $Arguments;Assert-McpInitialized $project;$message=Get-McpArgRequired $Arguments 'message';$result=Invoke-McpHarness $project @('event','-Message',$message);$sourceRef=$null
    if(([string]$result.stdout)-match '(human:[A-Za-z0-9_.-]+)'){$sourceRef=$Matches[1]}
    return New-McpTextResult ([ordered]@{recorded=$true;sourceRef=$sourceRef;note='Unstructured compatibility note only. Material current human direction should be represented with directive_set and reconciled through intent_apply.';output=$result.stdout})
}

function Invoke-SCSemanticTaskAdd($Arguments) {
    $project=Get-McpProject $Arguments;Assert-McpInitialized $project;$title=Get-McpArgRequired $Arguments 'title';$instruction=Get-McpArgRequired $Arguments 'instruction';$cli=@('task','add','-Title',$title,'-Instruction',$instruction)
    $taskId=Get-McpArgOptional $Arguments 'taskId';if($taskId){$cli+=@('-TaskId',$taskId)};$size=Get-McpArgOptional $Arguments 'size';if($size){$cli+=@('-Size',$size)};$provider=Get-McpArgOptional $Arguments 'provider';if($provider){$cli+=@('-Provider',$provider)}
    foreach($pair in @(@('accept','-Accept'),@('dependsOn','-DependsOn'),@('retrieval','-Retrieval'),@('evidence','-Evidence'),@('relation','-Relation'),@('source','-Source'),@('intentRef','-IntentRef'))){$values=@(Get-McpArgArray $Arguments $pair[0]);if($values.Count-gt0){$cli+=$pair[1];$cli+=,$values}}
    if($Arguments-and$Arguments.PSObject.Properties['humanGate']-and[bool]$Arguments.humanGate){$cli+='-HumanGate'}
    $result=Invoke-McpHarness $project $cli;return New-McpTextResult ([ordered]@{taskId=([string]$result.stdout).Trim();output=$result.stdout})
}

function Get-McpResourceListResult {
    return [ordered]@{resources=@(
        [ordered]@{uri=$script:SCControlEventsResource;name='StatefulClanker control events';description='Durable sequenced FYI/ATTENTION/HUMAN_REQUIRED project updates. Subscribe to this URI for level-triggered change notifications.';mimeType='application/json'},
        [ordered]@{uri=$script:SCCurrentDirectivesResource;name='Current human directives';description='Only the latest direct human wording for each active directive scope; superseded history excluded.';mimeType='application/json'},
        [ordered]@{uri=$script:SCProjectSnapshotResource;name='Current project snapshot';description='Goal, directives, reconciled Intent, task state, holds, active agents, and event cursor.';mimeType='application/json'}
    )}
}
function Get-McpResourceReadResult([string]$Uri) {
    $project=Get-McpProject $null;Assert-McpInitialized $project
    switch($Uri) {
        {$_-eq$script:SCControlEventsResource} {$value=[ordered]@{cursor=Get-McpControlCursor $project;events=@(Get-McpControlEventsSince $project ([Math]::Max(0,(Get-McpControlCursor $project)-100)) 100 $null)};break}
        {$_-eq$script:SCCurrentDirectivesResource} {$value=[ordered]@{authority='current only; latest direct human word by scope';directives=@(Get-McpCurrentDirectives $project)};break}
        {$_-eq$script:SCProjectSnapshotResource} {$value=Get-McpControlSnapshot $project;break}
        default {throw "Unknown resource: $Uri"}
    }
    return [ordered]@{contents=@([ordered]@{uri=$Uri;mimeType='application/json';text=($value|ConvertTo-Json -Depth 30)})}
}

function Invoke-McpRpc($Request) {
    $method=[string]$Request.method
    if($method-eq'server/discover') {
        return [ordered]@{jsonrpc='2.0';id=$Request.id;result=[ordered]@{resultType='complete';supportedVersions=@('2026-07-28','2025-06-18');capabilities=[ordered]@{tools=@{};resources=[ordered]@{subscribe=$true;listChanged=$false}};serverInfo=[ordered]@{name='statefulclanker';version=$script:McpVersion};instructions=Get-SCControlPlaneInstructions;_meta=@{'io.modelcontextprotocol/serverInfo'=@{name='statefulclanker';version=$script:McpVersion}}}}
    }
    if($method-eq'initialize') {
        $response=& $script:SCBaseInvokeMcpRpc $Request
        if($response-and$response.result){$response.result['instructions']=Get-SCControlPlaneInstructions;$response.result.capabilities['resources']=@{subscribe=$true;listChanged=$false}}
        return $response
    }
    if($method-eq'resources/list'){return [ordered]@{jsonrpc='2.0';id=$Request.id;result=(Get-McpResourceListResult)}}
    if($method-eq'resources/read'){
        try{$uri=[string]$Request.params.uri;return [ordered]@{jsonrpc='2.0';id=$Request.id;result=(Get-McpResourceReadResult $uri)}}catch{return [ordered]@{jsonrpc='2.0';id=$Request.id;error=@{code=-32000;message=$_.Exception.Message}}}
    }
    if($method-eq'tools/list') {
        $response=& $script:SCBaseInvokeMcpRpc $Request
        if($response-and$response.result) {
            $tools=@($response.result.tools);$task=@($tools|Where-Object{[string]$_.name-eq'task_add'}|Select-Object -First 1)
            if($task.Count-gt0){$props=$task[0].inputSchema.properties;$props['size']=@{type='string';enum=@('tiny','small','medium','large');description='Semantic size assigned by the conversational planner; never inferred mechanically.'};$props['source']=@{type='array';items=@{type='string'};description='Durable current-source references, normally from current directives.'};$props['intentRef']=@{type='array';items=@{type='string'};description='Governing normalized Intent identifiers.'}}
            $plan=@($tools|Where-Object{[string]$_.name-eq'plan_import'}|Select-Object -First 1);if($plan.Count-gt0){$plan[0].description='Import a JSON or compact SCPLAN 1 task graph from a local file path.'}
            $direction=@($tools|Where-Object{[string]$_.name-eq'direction_add'}|Select-Object -First 1);if($direction.Count-gt0){$direction[0].description='Legacy unstructured human note/source capture. For material current direction use directive_set, then reconcile with intent_apply.'}
            $response.result.tools=@($tools+(New-SCExtendedTools))
        }
        return $response
    }
    if($method-eq'tools/call') {
        $params = if($Request -is [System.Collections.IDictionary]){$Request['params']}else{$Request.params}
        $name = if($params -is [System.Collections.IDictionary]){[string]$params['name']}else{[string]$params.name}
        $args = $null
        if($params -is [System.Collections.IDictionary]){if($params.Contains('arguments')){$args=$params['arguments']}}
        elseif($params -and $params.PSObject.Properties['arguments']){$args=$params.arguments}
        $hasSemanticTaskAdd = $args -and (($args -is [System.Collections.IDictionary] -and ($args.Contains('size') -or $args.Contains('source') -or $args.Contains('intentRef'))) -or ($args.PSObject.Properties['size'] -or $args.PSObject.Properties['source'] -or $args.PSObject.Properties['intentRef']))
        if(@('directive_set','directive_list','directive_get','directive_history','directive_retire')-contains$name){try{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=(Invoke-SCDirectiveTool $name $args)}}catch{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=@{isError=$true;content=@(@{type='text';text=("Tool '{0}' failed: {1}"-f$name,$_.Exception.Message)})}}}}
        if($name-eq'direction_add'){try{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=(Invoke-SCDirectionAdd $args)}}catch{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=@{isError=$true;content=@(@{type='text';text=("Tool 'direction_add' failed: {0}"-f$_.Exception.Message)})}}}}
        if($name-eq'task_add'-and$hasSemanticTaskAdd){try{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=(Invoke-SCSemanticTaskAdd $args)}}catch{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=@{isError=$true;content=@(@{type='text';text=("Tool 'task_add' failed: {0}"-f$_.Exception.Message)})}}}}
        $extNames=@(New-SCExtendedTools|ForEach-Object{[string]$_.name})
        if($extNames -contains $name){try{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=(Invoke-SCExtendedTool $name $args)}}catch{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=@{isError=$true;content=@(@{type='text';text=("Tool '{0}' failed: {1}"-f$name,$_.Exception.Message)})}}}}
    }
    return (& $script:SCBaseInvokeMcpRpc $Request)
}

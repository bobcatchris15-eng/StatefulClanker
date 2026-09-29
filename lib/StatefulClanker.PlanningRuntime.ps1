# Session-scoped planning inference runtime.
# Planning participants are ephemeral model sessions whose durable outputs live under
# the active Planner session. They never mutate live project semantics or task state.

function Get-SCPlanningRuntimeActive {
    $active=Get-SCPlanningActiveRecord
    if($null-eq$active){throw 'No active planning session.'}
    if(@('planning','review')-notcontains[string]$active.phase){throw "Planning inference requires phase planning/review; current phase is '$($active.phase)'."}
    return $active
}
function Get-SCPlanningRuntimeSessionDir($Active=$null) {
    if($null-eq$Active){$Active=Get-SCPlanningRuntimeActive}
    return Get-SCPath ("planning/sessions/{0}"-f[string]$Active.sessionId)
}
function Get-SCPlanningParticipantDir($Active=$null) {
    $p=Join-Path (Get-SCPlanningRuntimeSessionDir $Active) 'participants'
    if(-not(Test-Path -LiteralPath $p)){New-Item -ItemType Directory -Force -Path $p|Out-Null}
    return $p
}
function Get-SCPlanningArtifactDir($Active=$null) {
    $p=Join-Path (Get-SCPlanningRuntimeSessionDir $Active) 'artifacts'
    if(-not(Test-Path -LiteralPath $p)){New-Item -ItemType Directory -Force -Path $p|Out-Null}
    return $p
}
function Get-SCPlanningRecipeDir($Active=$null) {
    $p=Join-Path (Get-SCPlanningRuntimeSessionDir $Active) 'recipes'
    if(-not(Test-Path -LiteralPath $p)){New-Item -ItemType Directory -Force -Path $p|Out-Null}
    return $p
}
function Get-SCPlanningParticipants {
    $active=Get-SCPlanningRuntimeActive;$dir=Get-SCPlanningParticipantDir $active
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue|Sort-Object Name|ForEach-Object{Read-SCJson $_.FullName}|Where-Object{$null-ne$_})
}
function Get-SCPlanningArtifacts {
    $active=Get-SCPlanningRuntimeActive;$dir=Get-SCPlanningArtifactDir $active
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue|Sort-Object Name|ForEach-Object{Read-SCJson $_.FullName}|Where-Object{$null-ne$_})
}
function Get-SCPlanningRecipes {
    $active=Get-SCPlanningRuntimeActive;$dir=Get-SCPlanningRecipeDir $active
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue|Sort-Object Name|ForEach-Object{Read-SCJson $_.FullName}|Where-Object{$null-ne$_})
}
function Get-SCPlanningRoleDoctrine([string]$Role) {
    switch($Role){
        'intent' {return 'Normalize the requested future. Separate direct human authority, existing accepted constraints, assumptions, unresolved questions, desired end state, and fit criteria. Do not invent product choices.'}
        'architecture' {return 'Identify components, interfaces, state transitions, integration boundaries, architectural obligations, and decisions that materially constrain implementation. Prefer explicit obligations over vague recommendations.'}
        'code_implications' {return 'Inspect the repository read-only. Identify concrete code surfaces, callers, tests, packaging/install/runtime implications, hidden coupling, and discovery work needed before implementation.'}
        'state_implications' {return 'Inspect persistence, migrations, durable state, compatibility, rollback/recovery, concurrency, and lifecycle implications. Identify invariants that implementation tasks must preserve.'}
        'failure_modes' {return 'Adversarially enumerate likely literal-but-wrong completions, missing dependencies, unsafe assumptions, unprovable acceptance, and failure/recovery paths materially connected to current intent.'}
        'decomposition' {return 'Turn reconciled obligations into a cold-worker task graph. One implementation thesis per task, explicit dependencies, narrow acceptance, and durable traceability. Produce a candidate SCPLAN 1 inside your structured result.'}
        'adversary' {return 'Attack the proposed decomposition. Find missing coverage, oversized tasks, false dependencies, hidden product decisions, dangling traceability, unprovable acceptance, and integration gaps. Do not rewrite the whole plan.'}
        'reconciler' {return 'Reconcile all specialist artifacts into one coherent planning bundle. Resolve only evidence-backed disagreements; preserve unresolved human-owned decisions as open questions. Produce the final candidate Intent and SCPLAN without applying them.'}
        default {throw "Unknown planning role '$Role'."}
    }
}
function Get-SCPlanningBaselineContext($Active,[string]$Brief,[bool]$IncludeArtifacts=$false,[string]$RecipeId=$null) {
    if([string]::IsNullOrWhiteSpace([string]$Active.baselinePath)){throw 'Planning session is not settled.'}
    $baselinePath=Resolve-SCPlanningArtifactPath ([string]$Active.baselinePath)
    $baseline=Read-SCJson $baselinePath
    if($null-eq$baseline){throw 'Planning baseline is missing.'}
    $snapshot=Resolve-SCPlanningArtifactPath ([string]$baseline.snapshotPath)
    $state=Read-SCJson (Join-Path $snapshot 'state.json')
    $intent=Read-SCJson (Join-Path $snapshot 'intent/contract.json')
    $directives=@()
    $dd=Join-Path $snapshot 'directives/current'
    if(Test-Path -LiteralPath $dd){$directives=@(Get-ChildItem -LiteralPath $dd -Filter '*.json' -File|Sort-Object Name|ForEach-Object{Read-SCJson $_.FullName}|Where-Object{$null-ne$_})}
    $tasks=@()
    $td=Join-Path $snapshot 'tasks'
    if(Test-Path -LiteralPath $td){
        $tasks=@(Get-ChildItem -LiteralPath $td -Filter '*.json' -File|Sort-Object Name|ForEach-Object{
            $t=Read-SCJson $_.FullName
            if($t){[ordered]@{id=$t.id;status=$t.status;title=$t.title;instruction=$t.instruction;intentRefs=@($t.intentRefs);dependsOn=@($t.dependsOn);acceptance=@($t.acceptance)}}
        })
    }
    $context=[ordered]@{
        planningSessionId=[string]$Active.sessionId
        brief=$Brief
        baseline=[ordered]@{gitHead=$baseline.gitHead;projectGoal=$baseline.projectGoal;activePlanId=$baseline.activePlanId;taskCounts=$baseline.taskCounts}
        state=$state
        currentDirectives=@($directives)
        intent=$intent
        currentTasks=@($tasks)
    }
    if($IncludeArtifacts){
        $prior=@(Get-SCPlanningArtifacts)
        if(-not[string]::IsNullOrWhiteSpace($RecipeId)){$prior=@($prior|Where-Object{$_.PSObject.Properties['recipeId']-and[string]$_.recipeId-eq$RecipeId})}
        $context['priorArtifacts']=@($prior|ForEach-Object{
            $payload=if($_.PSObject.Properties['structured']-and$null-ne$_.structured){$_.structured}else{[string]$_.content}
            [ordered]@{id=$_.id;recipeId=if($_.PSObject.Properties['recipeId']){$_.recipeId}else{$null};role=$_.role;kind=$_.kind;payload=$payload}
        })
    }
    return $context
}
function ConvertFrom-SCPlanningStructuredOutput([string]$Text) {
    if([string]::IsNullOrWhiteSpace($Text)){return $null}
    $trim=$Text.Trim()
    try{return $trim|ConvertFrom-Json -ErrorAction Stop}catch{}
    $m=[regex]::Match($trim,'(?s)\{.*\}')
    if($m.Success){try{return $m.Value|ConvertFrom-Json -ErrorAction Stop}catch{}}
    return $null
}
function Assert-SCPlanningStructuredOutput([string]$Role,$Structured) {
    if($null-eq$Structured){throw "Planning pass '$Role' returned no parseable structured JSON."}
    $required=if($Role-eq'reconciler'){
        @('summary','projectGoal','intentContract','directiveChanges','planText','openQuestions','unresolvedConflicts')
    }elseif($Role-eq'decomposition'){
        @('summary','obligationsCovered','openQuestions','planText')
    }else{
        @('summary','observations','obligations','assumptions','questions','risks','evidence')
    }
    $missing=@($required|Where-Object{-not$Structured.PSObject.Properties[$_]})
    if($missing.Count-gt0){throw "Planning pass '$Role' structured output is missing: $($missing -join ', ')." }
    if(@('decomposition','reconciler')-contains$Role){
        $planText=[string]$Structured.planText
        if([string]::IsNullOrWhiteSpace($planText)-or$planText -notmatch '(?m)^\s*SCPLAN\s+1\s*    return [pscustomobject][ordered]@{
        id=$ParticipantId;title=("Planning pass: "+$Role);instruction=(Get-SCPlanningRoleDoctrine $Role)
        role='planner';outputKind='research';humanGate=$false;capabilityProfile=$null
        toolPolicy=[pscustomobject][ordered]@{
            allow=@('builtin.read_file','builtin.search_text','builtin.git_diff','intent.human.read','intent.normalized.read')
            deny=@('builtin.write_file','builtin.replace_text','builtin.run_command','builtin.collaboration.*','rpk.*')
        }
    }
}
function Invoke-SCPlanningPass([string]$Role,[string]$Brief,[string]$ProviderOverride=$null,[string]$EndpointOverride=$null,[string]$ConnectionOverride=$null,[string]$RecipeId=$null) {
    $active=Get-SCPlanningRuntimeActive
    $roleName=$Role.ToLowerInvariant()
    $doctrine=Get-SCPlanningRoleDoctrine $roleName
    $includeArtifacts=@('decomposition','adversary','reconciler')-contains$roleName
    $ctx=Get-SCPlanningBaselineContext $active $Brief $includeArtifacts $RecipeId
    $participantId=('planning-'+$roleName+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $participant=[ordered]@{
        schemaVersion=1;id=$participantId;sessionId=[string]$active.sessionId;recipeId=$RecipeId;role=$roleName;status='running'
        createdAt=[datetimeoffset]::UtcNow.ToString('o');updatedAt=[datetimeoffset]::UtcNow.ToString('o')
        provider=$null;endpoint=$null;connection=$null;model=$null;promptTokens=0;completionTokens=0;totalTokens=0
        receiptId=$null;artifactId=$null;error=$null
    }
    $participantPath=Join-Path (Get-SCPlanningParticipantDir $active) ($participantId+'.json')
    Write-SCJson $participantPath $participant
    $outputContract=if($roleName-eq'reconciler'){
        'Return one JSON object with keys: summary, projectGoal, intentContract, directiveChanges, planText, openQuestions, unresolvedConflicts. planText must be a complete SCPLAN 1 document. Any staged Intent entries in requirements/constraints/invariants/nonGoals/decisions/preferences/openQuestions must be structured objects with stable id, kind, text (or question), source, and authority so planner inference cannot masquerade as human authority. Use null/[] where unchanged.'
    }elseif($roleName-eq'decomposition'){
        'Return one JSON object with keys: summary, obligationsCovered, openQuestions, planText. planText must be a complete SCPLAN 1 candidate, not applied state.'
    }else{
        'Return one JSON object with keys: summary, observations, obligations, assumptions, questions, risks, evidence. Keep observations concise and evidence-addressable.'
    }
    $prompt=@"
STATEFULCLANKER PLANNING PARTICIPANT
Session: $($active.sessionId)
Role: $roleName

You are an independent planning specialist. You do NOT implement or mutate the project. Repository tools are read-only for this pass.
Your epistemic job:
$doctrine

Rules:
- Current human directives outrank normalized Intent; both outrank planner inference.
- Distinguish evidence from inference and assumptions.
- Do not silently decide human-owned product choices.
- Inspect repository evidence when your role needs it.
- Do not generate hidden reasoning transcripts for peers; emit compact findings.
- $outputContract

PLANNING CONTEXT
$($ctx|ConvertTo-Json -Depth 30)
"@
    $task=New-SCPlanningSyntheticTask $participantId $roleName
    try{
        $receipt=Invoke-SCProvider $task $prompt 'planning' $ProviderOverride $null $null $null $null $EndpointOverride $ConnectionOverride
        $participant.status=if([int]$receipt.exitCode-eq0){'complete'}else{'failed'}
        $participant.updatedAt=[datetimeoffset]::UtcNow.ToString('o')
        $participant.provider=if($receipt.PSObject.Properties['provider']){[string]$receipt.provider}else{$null}
        $participant.endpoint=if($receipt.PSObject.Properties['endpoint']){[string]$receipt.endpoint}else{$null}
        $participant.connection=if($receipt.PSObject.Properties['connection']){[string]$receipt.connection}else{$null}
        $participant.model=if($receipt.PSObject.Properties['model']){[string]$receipt.model}else{$null}
        if($receipt.PSObject.Properties['promptTokens']){$participant.promptTokens=[long]$receipt.promptTokens}
        if($receipt.PSObject.Properties['completionTokens']){$participant.completionTokens=[long]$receipt.completionTokens}
        if($receipt.PSObject.Properties['totalTokens']){$participant.totalTokens=[long]$receipt.totalTokens}
        $participant.receiptId=$receipt.id
        if([int]$receipt.exitCode-ne0){$participant.error=[string]$receipt.stderr;Write-SCJson $participantPath $participant;throw "Planning pass '$roleName' failed: $($receipt.stderr)"}
        $structured=ConvertFrom-SCPlanningStructuredOutput ([string]$receipt.stdout)
        [void](Assert-SCPlanningStructuredOutput $roleName $structured)
        $artifactId=('pa-'+[guid]::NewGuid().ToString('N').Substring(0,12))
        $artifact=[ordered]@{
            schemaVersion=1;id=$artifactId;sessionId=[string]$active.sessionId;recipeId=$RecipeId;participantId=$participantId;role=$roleName
            kind=if($roleName-eq'reconciler'){'candidate_bundle'}elseif($roleName-eq'decomposition'){'decomposition'}else{'observation'}
            createdAt=[datetimeoffset]::UtcNow.ToString('o');content=[string]$receipt.stdout;structured=$structured
            receiptId=$receipt.id;provider=$participant.provider;endpoint=$participant.endpoint;connection=$participant.connection;model=$participant.model
            tokenUsage=[ordered]@{prompt=$participant.promptTokens;completion=$participant.completionTokens;total=$participant.totalTokens}
        }
        Write-SCJson (Join-Path (Get-SCPlanningArtifactDir $active) ($artifactId+'.json')) $artifact
        $participant.artifactId=$artifactId;Write-SCJson $participantPath $participant
        return [pscustomobject][ordered]@{participant=[pscustomobject]$participant;artifact=[pscustomobject]$artifact}
    }catch{
        $participant.status='failed';$participant.updatedAt=[datetimeoffset]::UtcNow.ToString('o');$participant.error=$_.Exception.Message
        Write-SCJson $participantPath $participant
        throw
    }
}
function Invoke-SCPlanningRecipe([string]$Brief,[string]$ProviderOverride=$null,[string]$EndpointOverride=$null,[string]$ConnectionOverride=$null) {
    $active=Get-SCPlanningRuntimeActive
    $roles=@('intent','architecture','code_implications','state_implications','failure_modes','decomposition','adversary','reconciler')
    $recipeId=('recipe-'+[guid]::NewGuid().ToString('N').Substring(0,12))
    $recipePath=Join-Path (Get-SCPlanningRecipeDir $active) ($recipeId+'.json')
    $record=[pscustomobject][ordered]@{
        schemaVersion=1;id=$recipeId;sessionId=[string]$active.sessionId;status='running';brief=$Brief
        roles=@($roles);participantIds=@();artifactIds=@();createdAt=[datetimeoffset]::UtcNow.ToString('o');updatedAt=[datetimeoffset]::UtcNow.ToString('o')
        planningTokens=0;targetTokens=if($active.budget-and$active.budget.PSObject.Properties['planningTargetTokens']){$active.budget.planningTargetTokens}else{$null}
        finalArtifactId=$null;error=$null
    }
    Write-SCJson $recipePath $record
    $runs=@()
    try{
        foreach($role in $roles){
            $run=Invoke-SCPlanningPass $role $Brief $ProviderOverride $EndpointOverride $ConnectionOverride $recipeId
            $runs+=,$run
            $record.participantIds=@($runs|ForEach-Object{$_.participant.id})
            $record.artifactIds=@($runs|ForEach-Object{$_.artifact.id})
            $record.planningTokens=[long](($runs|ForEach-Object{[long]$_.participant.totalTokens}|Measure-Object -Sum).Sum)
            $record.updatedAt=[datetimeoffset]::UtcNow.ToString('o')
            Write-SCJson $recipePath $record
        }
        $final=$runs[-1].artifact
        $record.status='complete';$record.finalArtifactId=[string]$final.id;$record.updatedAt=[datetimeoffset]::UtcNow.ToString('o')
        Write-SCJson $recipePath $record
        return [pscustomobject][ordered]@{
            sessionId=[string]$active.sessionId;recipeId=$recipeId;completed=$true;roles=@($roles)
            participantIds=@($record.participantIds);artifactIds=@($record.artifactIds);planningTokens=[long]$record.planningTokens
            targetTokens=$record.targetTokens;overTarget=($null-ne$record.targetTokens-and[long]$record.planningTokens-gt[long]$record.targetTokens)
            finalArtifact=$final
        }
    }catch{
        $record.status='failed';$record.error=$_.Exception.Message;$record.updatedAt=[datetimeoffset]::UtcNow.ToString('o')
        $record.participantIds=@($runs|ForEach-Object{$_.participant.id});$record.artifactIds=@($runs|ForEach-Object{$_.artifact.id})
        $record.planningTokens=[long](($runs|ForEach-Object{[long]$_.participant.totalTokens}|Measure-Object -Sum).Sum)
        Write-SCJson $recipePath $record
        throw
    }
}
){
            throw "Planning pass '$Role' did not return a complete SCPLAN 1 planText."
        }
    }
    return $true
}
function New-SCPlanningSyntheticTask([string]$ParticipantId,[string]$Role) {
    return [pscustomobject][ordered]@{
        id=$ParticipantId;title=("Planning pass: "+$Role);instruction=(Get-SCPlanningRoleDoctrine $Role)
        role='planner';outputKind='research';humanGate=$false;capabilityProfile=$null
        toolPolicy=[pscustomobject][ordered]@{
            allow=@('builtin.read_file','builtin.search_text','builtin.git_diff','builtin.finish','intent.human.read','intent.normalized.read')
            deny=@('builtin.write_file','builtin.replace_text','builtin.run_command','builtin.collaboration.*','rpk.*')
        }
    }
}
function Invoke-SCPlanningPass([string]$Role,[string]$Brief,[string]$ProviderOverride=$null,[string]$EndpointOverride=$null,[string]$ConnectionOverride=$null,[string]$RecipeId=$null) {
    $active=Get-SCPlanningRuntimeActive
    $roleName=$Role.ToLowerInvariant()
    $doctrine=Get-SCPlanningRoleDoctrine $roleName
    $includeArtifacts=@('decomposition','adversary','reconciler')-contains$roleName
    $ctx=Get-SCPlanningBaselineContext $active $Brief $includeArtifacts $RecipeId
    $participantId=('planning-'+$roleName+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $participant=[ordered]@{
        schemaVersion=1;id=$participantId;sessionId=[string]$active.sessionId;recipeId=$RecipeId;role=$roleName;status='running'
        createdAt=[datetimeoffset]::UtcNow.ToString('o');updatedAt=[datetimeoffset]::UtcNow.ToString('o')
        provider=$null;endpoint=$null;connection=$null;model=$null;promptTokens=0;completionTokens=0;totalTokens=0
        receiptId=$null;artifactId=$null;error=$null
    }
    $participantPath=Join-Path (Get-SCPlanningParticipantDir $active) ($participantId+'.json')
    Write-SCJson $participantPath $participant
    $outputContract=if($roleName-eq'reconciler'){
        'Return one JSON object with keys: summary, projectGoal, intentContract, directiveChanges, planText, openQuestions, unresolvedConflicts. planText must be a complete SCPLAN 1 document. Any staged Intent entries in requirements/constraints/invariants/nonGoals/decisions/preferences/openQuestions must be structured objects with stable id, kind, text (or question), source, and authority so planner inference cannot masquerade as human authority. Use null/[] where unchanged.'
    }elseif($roleName-eq'decomposition'){
        'Return one JSON object with keys: summary, obligationsCovered, openQuestions, planText. planText must be a complete SCPLAN 1 candidate, not applied state.'
    }else{
        'Return one JSON object with keys: summary, observations, obligations, assumptions, questions, risks, evidence. Keep observations concise and evidence-addressable.'
    }
    $prompt=@"
STATEFULCLANKER PLANNING PARTICIPANT
Session: $($active.sessionId)
Role: $roleName

You are an independent planning specialist. You do NOT implement or mutate the project. Repository tools are read-only for this pass.
Your epistemic job:
$doctrine

Rules:
- Current human directives outrank normalized Intent; both outrank planner inference.
- Distinguish evidence from inference and assumptions.
- Do not silently decide human-owned product choices.
- Inspect repository evidence when your role needs it.
- Do not generate hidden reasoning transcripts for peers; emit compact findings.
- $outputContract

PLANNING CONTEXT
$($ctx|ConvertTo-Json -Depth 30)
"@
    $task=New-SCPlanningSyntheticTask $participantId $roleName
    try{
        $receipt=Invoke-SCProvider $task $prompt 'planning' $ProviderOverride $null $null $null $null $EndpointOverride $ConnectionOverride
        $participant.status=if([int]$receipt.exitCode-eq0){'complete'}else{'failed'}
        $participant.updatedAt=[datetimeoffset]::UtcNow.ToString('o')
        $participant.provider=if($receipt.PSObject.Properties['provider']){[string]$receipt.provider}else{$null}
        $participant.endpoint=if($receipt.PSObject.Properties['endpoint']){[string]$receipt.endpoint}else{$null}
        $participant.connection=if($receipt.PSObject.Properties['connection']){[string]$receipt.connection}else{$null}
        $participant.model=if($receipt.PSObject.Properties['model']){[string]$receipt.model}else{$null}
        if($receipt.PSObject.Properties['promptTokens']){$participant.promptTokens=[long]$receipt.promptTokens}
        if($receipt.PSObject.Properties['completionTokens']){$participant.completionTokens=[long]$receipt.completionTokens}
        if($receipt.PSObject.Properties['totalTokens']){$participant.totalTokens=[long]$receipt.totalTokens}
        $participant.receiptId=$receipt.id
        if([int]$receipt.exitCode-ne0){$participant.error=[string]$receipt.stderr;Write-SCJson $participantPath $participant;throw "Planning pass '$roleName' failed: $($receipt.stderr)"}
        $structured=ConvertFrom-SCPlanningStructuredOutput ([string]$receipt.stdout)
        $artifactId=('pa-'+[guid]::NewGuid().ToString('N').Substring(0,12))
        $artifact=[ordered]@{
            schemaVersion=1;id=$artifactId;sessionId=[string]$active.sessionId;recipeId=$RecipeId;participantId=$participantId;role=$roleName
            kind=if($roleName-eq'reconciler'){'candidate_bundle'}elseif($roleName-eq'decomposition'){'decomposition'}else{'observation'}
            createdAt=[datetimeoffset]::UtcNow.ToString('o');content=[string]$receipt.stdout;structured=$structured
            receiptId=$receipt.id;provider=$participant.provider;endpoint=$participant.endpoint;connection=$participant.connection;model=$participant.model
            tokenUsage=[ordered]@{prompt=$participant.promptTokens;completion=$participant.completionTokens;total=$participant.totalTokens}
        }
        Write-SCJson (Join-Path (Get-SCPlanningArtifactDir $active) ($artifactId+'.json')) $artifact
        $participant.artifactId=$artifactId;Write-SCJson $participantPath $participant
        return [pscustomobject][ordered]@{participant=[pscustomobject]$participant;artifact=[pscustomobject]$artifact}
    }catch{
        $participant.status='failed';$participant.updatedAt=[datetimeoffset]::UtcNow.ToString('o');$participant.error=$_.Exception.Message
        Write-SCJson $participantPath $participant
        throw
    }
}
function Invoke-SCPlanningRecipe([string]$Brief,[string]$ProviderOverride=$null,[string]$EndpointOverride=$null,[string]$ConnectionOverride=$null) {
    $active=Get-SCPlanningRuntimeActive
    $roles=@('intent','architecture','code_implications','state_implications','failure_modes','decomposition','adversary','reconciler')
    $recipeId=('recipe-'+[guid]::NewGuid().ToString('N').Substring(0,12))
    $recipePath=Join-Path (Get-SCPlanningRecipeDir $active) ($recipeId+'.json')
    $record=[pscustomobject][ordered]@{
        schemaVersion=1;id=$recipeId;sessionId=[string]$active.sessionId;status='running';brief=$Brief
        roles=@($roles);participantIds=@();artifactIds=@();createdAt=[datetimeoffset]::UtcNow.ToString('o');updatedAt=[datetimeoffset]::UtcNow.ToString('o')
        planningTokens=0;targetTokens=if($active.budget-and$active.budget.PSObject.Properties['planningTargetTokens']){$active.budget.planningTargetTokens}else{$null}
        finalArtifactId=$null;error=$null
    }
    Write-SCJson $recipePath $record
    $runs=@()
    try{
        foreach($role in $roles){
            $run=Invoke-SCPlanningPass $role $Brief $ProviderOverride $EndpointOverride $ConnectionOverride $recipeId
            $runs+=,$run
            $record.participantIds=@($runs|ForEach-Object{$_.participant.id})
            $record.artifactIds=@($runs|ForEach-Object{$_.artifact.id})
            $record.planningTokens=[long](($runs|ForEach-Object{[long]$_.participant.totalTokens}|Measure-Object -Sum).Sum)
            $record.updatedAt=[datetimeoffset]::UtcNow.ToString('o')
            Write-SCJson $recipePath $record
        }
        $final=$runs[-1].artifact
        $record.status='complete';$record.finalArtifactId=[string]$final.id;$record.updatedAt=[datetimeoffset]::UtcNow.ToString('o')
        Write-SCJson $recipePath $record
        return [pscustomobject][ordered]@{
            sessionId=[string]$active.sessionId;recipeId=$recipeId;completed=$true;roles=@($roles)
            participantIds=@($record.participantIds);artifactIds=@($record.artifactIds);planningTokens=[long]$record.planningTokens
            targetTokens=$record.targetTokens;overTarget=($null-ne$record.targetTokens-and[long]$record.planningTokens-gt[long]$record.targetTokens)
            finalArtifact=$final
        }
    }catch{
        $record.status='failed';$record.error=$_.Exception.Message;$record.updatedAt=[datetimeoffset]::UtcNow.ToString('o')
        $record.participantIds=@($runs|ForEach-Object{$_.participant.id});$record.artifactIds=@($runs|ForEach-Object{$_.artifact.id})
        $record.planningTokens=[long](($runs|ForEach-Object{[long]$_.participant.totalTokens}|Measure-Object -Sum).Sum)
        Write-SCJson $recipePath $record
        throw
    }
}

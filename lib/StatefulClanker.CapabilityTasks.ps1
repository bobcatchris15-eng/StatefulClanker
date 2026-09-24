# First-class task capability narrowing layered over compact-plan/task authoring.
# Machine policy remains the grant authority; profiles and task policy only narrow it.

function New-SCTaskToolPolicy($Allow,$Deny) {
    $a=@($Allow|Where-Object{$_ -and -not[string]::IsNullOrWhiteSpace([string]$_)}|ForEach-Object{[string]$_})
    $d=@($Deny|Where-Object{$_ -and -not[string]::IsNullOrWhiteSpace([string]$_)}|ForEach-Object{[string]$_})
    if($a.Count-eq0-and$d.Count-eq0){return $null}
    return [pscustomobject]@{allow=if($a.Count-gt0){@($a)}else{$null};deny=@($d)}
}

function Read-SCCompactPlan([string]$Path) {
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Plan not found: $Path"}
    $lines=@(Get-Content -LiteralPath $Path);$first=$null
    foreach($raw in $lines){$trim=$raw.Trim();if($trim-and-not$trim.StartsWith('#')){$first=$trim;break}}
    if($first-ne'SCPLAN 1'){throw 'Compact plan must begin with SCPLAN 1.'}
    $plan=[ordered]@{name='Compact plan';summary='';sources=@();intent=@();tasks=@();warnings=@()};$task=$null;$ids=@{}
    foreach($raw in $lines){
        $line=$raw.Trim();if(-not$line-or$line.StartsWith('#')-or$line-eq'SCPLAN 1'){continue};$parts=$line -split '\s+',2;$key=$parts[0].ToLowerInvariant();$value=if($parts.Count-gt1){$parts[1].Trim()}else{''}
        if($key-eq'task'){
            if($null-ne$task){throw "Nested task before 'end': $value"};if([string]::IsNullOrWhiteSpace($value)){throw 'task requires an id.'};if($ids.ContainsKey($value)){throw "Duplicate task id: $value"};$ids[$value]=$true
            $task=[ordered]@{id=$value;title='';instruction='';size='small';sources=@();intentRefs=@();acceptance=@();checks=@();semanticAcceptance=@();implications=@();proofObligations=@();dependsOn=@();relations=@();retrieval=@();evidence=@();provider=$null;role='worker';outputKind='change';humanGate=$false;capabilityProfile=$null;toolAllow=@();toolDeny=@();refinementStatus='pending';refinementDepth=0;parentTaskId=$null;childTaskIds=@();unknown=@()};continue
        }
        if($key-eq'end'){
            if($null-eq$task){throw "Unexpected end outside a task."};if([string]::IsNullOrWhiteSpace($task.title)){throw "Task $($task.id) is missing title."};if([string]::IsNullOrWhiteSpace($task.instruction)){throw "Task $($task.id) is missing instruction."}
            $task.toolPolicy=New-SCTaskToolPolicy $task.toolAllow $task.toolDeny;$task.Remove('toolAllow');$task.Remove('toolDeny');$plan.tasks+=,[pscustomobject]$task;$task=$null;continue
        }
        if($null-ne$task){
            switch($key){
              'title'{$task.title=$value};'instruction'{$task.instruction=$value};'size'{if(@('tiny','small','medium','large')-notcontains$value.ToLowerInvariant()){throw "Task $($task.id) has invalid size '$value'."};$task.size=$value.ToLowerInvariant()}
              'source'{$task.sources+=,$value};'intent'{$task.intentRefs+=,$value};'accept'{$task.acceptance+=,$value};'check'{$task.checks+=,$value};'judge'{$task.semanticAcceptance+=,$value};'imply'{$task.implications+=,$value};'prove'{$task.proofObligations+=,$value};'depends'{$task.dependsOn+=,$value};'retrieve'{$task.retrieval+=,$value};'evidence'{$task.evidence+=,$value};'provider'{$task.provider=$value};'role'{$task.role=$value};'output-kind'{if(@('change','document','state-update','research','diagnosis','answer','none','no-change')-notcontains$value.ToLowerInvariant()){throw "Task $($task.id) has invalid output-kind '$value'."};$task.outputKind=$value.ToLowerInvariant()}
              'relation'{$rp=$value -split '\s+',2;if($rp.Count-lt2){throw "Task $($task.id) relation requires type and target."};$task.relations+=,[pscustomobject]@{type=$rp[0];target=$rp[1]}}
              'human-gate'{if($value-notmatch'^(?i:true|false)$'){throw "Task $($task.id) human-gate must be true or false."};$task.humanGate=[bool]::Parse($value)}
              'capability-profile'{$task.capabilityProfile=$value};'tool-allow'{$task.toolAllow+=,$value};'tool-deny'{$task.toolDeny+=,$value}
              default{$task.unknown+=,$line;$plan.warnings+=,"Task $($task.id): unknown field '$key' ignored."}
            }
        }else{switch($key){'plan'{$plan.name=$value};'summary'{$plan.summary=$value};'source'{$plan.sources+=,$value};'intent'{$plan.intent+=,$value};default{$plan.warnings+=,"Plan: unknown field '$key' ignored."}}}
    }
    if($null-ne$task){throw "Task $($task.id) is missing terminating 'end'."};if($plan.tasks.Count-eq0){throw 'Plan contains no tasks.'};return [pscustomobject]$plan
}

$script:SCBaseImportPlanCapabilities=${function:Import-SCPlan}
function Import-SCPlan([string]$PlanPath) {
    Assert-SCInitialized;if(-not(Test-Path -LiteralPath $PlanPath)){throw "Plan not found: $PlanPath"};Ensure-SCInputLayout
    $input=Get-SCPlanInput $PlanPath;$plan=$input.plan;if($null-eq$plan-or$null-eq$plan.tasks){throw 'Plan must contain tasks.'}
    $planId=New-SCId 'plan';$name=if($plan.PSObject.Properties['name']){[string]$plan.name}else{'Imported plan'};$summary=if($plan.PSObject.Properties['summary']){[string]$plan.summary}else{''}
    $planSources=if($plan.PSObject.Properties['sources']){@($plan.sources)}else{@()};$planIntent=if($plan.PSObject.Properties['intent']){@($plan.intent)}else{@()}
    $planRecord=[ordered]@{schemaVersion=4;id=$planId;name=$name;summary=$summary;format=$input.format;source=$input.resolved;sourceRefs=$planSources;intentRefs=$planIntent;importedAt=(Get-Date).ToUniversalTime().ToString('o');tasks=@($plan.tasks)}
    Write-SCJson (Get-SCPath ("plans/{0}.json"-f$planId)) $planRecord;if($input.format-eq'scplan'){Copy-Item -LiteralPath $input.resolved -Destination (Get-SCPath ("plans/{0}.scplan"-f$planId)) -Force}
    foreach($item in @($plan.tasks)){
        $id=if($item.PSObject.Properties['id']-and$item.id){[string]$item.id}else{New-SCId 'task'}
        if(Test-Path (Get-SCPath ("tasks/{0}.json"-f$id))){throw "Plan task id already exists: $id"}

        $itemAcceptance=@();if($item.PSObject.Properties['acceptance']){$itemAcceptance=@($item.acceptance)}
        $itemDepends=@();if($item.PSObject.Properties['dependsOn']){$itemDepends=@($item.dependsOn)}
        $itemRelations=@();if($item.PSObject.Properties['relations']){$itemRelations=@($item.relations)}
        $itemRetrieval=@();if($item.PSObject.Properties['retrieval']){$itemRetrieval=@($item.retrieval)}
        $itemEvidence=@();if($item.PSObject.Properties['evidence']){$itemEvidence=@($item.evidence)}
        $itemSources=@();if($item.PSObject.Properties['sources']){$itemSources=@($item.sources)}
        $itemIntentRefs=@();if($item.PSObject.Properties['intentRefs']){$itemIntentRefs=@($item.intentRefs)}
        $itemChecks=@();if($item.PSObject.Properties['checks']){$itemChecks=@($item.checks)}
        $itemSemantic=@();if($item.PSObject.Properties['semanticAcceptance']){$itemSemantic=@($item.semanticAcceptance)}
        $itemImplications=@();if($item.PSObject.Properties['implications']){$itemImplications=@($item.implications)}
        $itemProof=@();if($item.PSObject.Properties['proofObligations']){$itemProof=@($item.proofObligations)}

        $provider=if($item.PSObject.Properties['provider']){[string]$item.provider}else{$null}
        $role=if($item.PSObject.Properties['role']-and$item.role){[string]$item.role}else{'worker'}
        $humanGate=if($item.PSObject.Properties['humanGate']){[bool]$item.humanGate}else{$false}
        $taskObj=New-SCTaskObject $id ([string]$item.title) ([string]$item.instruction) $itemAcceptance $itemDepends $itemRelations $itemRetrieval $itemEvidence $provider $role $humanGate
        Set-SCProperty $taskObj 'size' $(if($item.PSObject.Properties['size']){[string]$item.size}else{'small'})
        Set-SCProperty $taskObj 'outputKind' $(if($item.PSObject.Properties['outputKind']-and$item.outputKind){[string]$item.outputKind}else{'change'})
        Set-SCProperty $taskObj 'sources' $itemSources
        Set-SCProperty $taskObj 'intentRefs' $itemIntentRefs
        Set-SCProperty $taskObj 'capabilityProfile' $(if($item.PSObject.Properties['capabilityProfile']-and$item.capabilityProfile){[string]$item.capabilityProfile}else{$null})
        Set-SCProperty $taskObj 'toolPolicy' $(if($item.PSObject.Properties['toolPolicy']){$item.toolPolicy}else{$null})
        Set-SCProperty $taskObj 'checks' $itemChecks
        Set-SCProperty $taskObj 'semanticAcceptance' $itemSemantic
        Set-SCProperty $taskObj 'implications' $itemImplications
        Set-SCProperty $taskObj 'proofObligations' $itemProof
        Set-SCProperty $taskObj 'refinementStatus' 'pending'
        Set-SCProperty $taskObj 'refinementDepth' 0
        Set-SCProperty $taskObj 'parentTaskId' $null
        Set-SCProperty $taskObj 'childTaskIds' @()
        Save-SCTask $taskObj
    }
    $state=Get-SCState;$state.activePlanId=$planId;$cfg=Get-SCConfig;$state.planApproved=-not[bool]$cfg.requireHumanApprovalForPlan;Save-SCState $state;Update-SCReadiness;Add-SCEvent 'plan.imported' "Imported $planId" @{taskCount=@($plan.tasks).Count;format=$input.format};Write-Host "Imported $planId ($($input.format), $(@($plan.tasks).Count) tasks)"
}

function Get-SCTaskDefinitionHash($Task) {
    $taskRole=if($Task.PSObject.Properties['role']-and$Task.role){[string]$Task.role}else{'worker'}
    $sources=@();if($Task.PSObject.Properties['sources']){$sources=@($Task.sources)}
    $intentRefs=@();if($Task.PSObject.Properties['intentRefs']){$intentRefs=@($Task.intentRefs)}
    $checks=@();if($Task.PSObject.Properties['checks']){$checks=@($Task.checks)}
    $semantic=@();if($Task.PSObject.Properties['semanticAcceptance']){$semantic=@($Task.semanticAcceptance)}
    $implications=@();if($Task.PSObject.Properties['implications']){$implications=@($Task.implications)}
    $proof=@();if($Task.PSObject.Properties['proofObligations']){$proof=@($Task.proofObligations)}
    $relations=@();if($Task.PSObject.Properties['relations']){$relations=@($Task.relations)}
    $definition=[ordered]@{
        title=$Task.title;instruction=$Task.instruction;size=if($Task.PSObject.Properties['size']){$Task.size}else{'small'}
        sources=$sources;intentRefs=$intentRefs;capabilityProfile=if($Task.PSObject.Properties['capabilityProfile']){$Task.capabilityProfile}else{$null}
        toolPolicy=if($Task.PSObject.Properties['toolPolicy']){$Task.toolPolicy}else{$null};acceptance=@($Task.acceptance)
        checks=$checks;semanticAcceptance=$semantic;implications=$implications;proofObligations=$proof
        parentTaskId=if($Task.PSObject.Properties['parentTaskId']){$Task.parentTaskId}else{$null};dependsOn=@($Task.dependsOn);relations=$relations
        retrieval=@($Task.retrieval);evidence=@($Task.evidence);provider=$Task.provider;role=$taskRole
        outputKind=if($Task.PSObject.Properties['outputKind']){$Task.outputKind}else{'change'};humanGate=[bool]$Task.humanGate
    }
    return Get-SCHashString (ConvertTo-SCJson $definition 18)
}

function Add-SCTask {
    if([string]::IsNullOrWhiteSpace($Title)){throw '-Title is required.'};if([string]::IsNullOrWhiteSpace($Instruction)){throw '-Instruction is required.'};$id=if($TaskId){$TaskId}else{New-SCId 'task'};if(@(Get-SCTasks|Where-Object{$_.id-eq$id}).Count-gt0){throw "Task exists: $id"}
    $taskObj=New-SCTaskObject $id $Title $Instruction @($Accept) @($DependsOn) @($Relation) @($Retrieval) @($Evidence) $Provider $Role ([bool]$HumanGate);$sizeValue=if($Size){$Size.ToLowerInvariant()}else{'small'};if(@('tiny','small','medium','large')-notcontains$sizeValue){throw "Invalid -Size '$Size'."}
    $outputKindValue=if($OutputKind){$OutputKind.ToLowerInvariant()}else{'change'};if(@('change','document','state-update','research','diagnosis','answer','none','no-change')-notcontains$outputKindValue){throw "Invalid -OutputKind '$OutputKind'."};Set-SCProperty $taskObj 'size' $sizeValue;Set-SCProperty $taskObj 'outputKind' $outputKindValue;Set-SCProperty $taskObj 'sources' @($Source);Set-SCProperty $taskObj 'intentRefs' @($IntentRef);Set-SCProperty $taskObj 'capabilityProfile' $CapabilityProfile;Set-SCProperty $taskObj 'toolPolicy' (New-SCTaskToolPolicy $ToolAllow $ToolDeny);Set-SCProperty $taskObj 'checks' @($Check);Set-SCProperty $taskObj 'semanticAcceptance' @($Judge);Set-SCProperty $taskObj 'implications' @();Set-SCProperty $taskObj 'proofObligations' @();Set-SCProperty $taskObj 'refinementStatus' 'pending';Set-SCProperty $taskObj 'refinementDepth' 0;Set-SCProperty $taskObj 'parentTaskId' $null;Set-SCProperty $taskObj 'childTaskIds' @()
    Save-SCTask $taskObj;Update-SCReadiness;Add-SCEvent 'task.created' $Title @{taskId=$id;size=$sizeValue;capabilityProfile=$CapabilityProfile;toolPolicy=$taskObj.toolPolicy};[Console]::Out.WriteLine($id)
}


# Control-plane recovery is distinct from human authority. It may repair orchestration
# metadata after a task has stalled, but it cannot rewrite current human directives,
# normalized Intent, or a human-gated task. Every recovery records concrete evidence.
function Get-SCRecoveryPayload([string]$PayloadPath) {
    if([string]::IsNullOrWhiteSpace($PayloadPath)-or-not(Test-Path -LiteralPath $PayloadPath -PathType Leaf)){throw '-Path to recovery JSON is required.'}
    $payload=Read-SCJson $PayloadPath
    if($null-eq$payload){throw 'Recovery payload is empty or invalid.'}
    return $payload
}

function Assert-SCRecoveryTaskMutable($Task) {
    if($null-eq$Task){throw 'Recovery task is missing.'}
    if([bool]$Task.humanGate){throw "Task $($Task.id) is human-gated; control-plane recovery must stop for human direction."}
    if(@('running','reviewing','validating')-contains[string]$Task.status){throw "Task $($Task.id) is active ($($Task.status)); recovery cannot rewrite in-flight state."}
}

function Get-SCRecoveryEvidence($Payload) {
    $items=@()
    if($Payload.PSObject.Properties['evidence']){
        $items=@($Payload.evidence|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}|ForEach-Object{[string]$_})
    }
    if($items.Count-eq0){throw 'Control-plane recovery requires at least one concrete evidence item.'}
    return @($items)
}

function Repair-SCTaskFromRecovery([string]$Id,[string]$PayloadPath,[string]$Why) {
    if([string]::IsNullOrWhiteSpace($Id)){throw '-TaskId required.'}
    if([string]::IsNullOrWhiteSpace($Why)){throw '-Reason required for control-plane task repair.'}
    $payload=Get-SCRecoveryPayload $PayloadPath
    $evidence=@(Get-SCRecoveryEvidence $payload)
    if(-not$payload.PSObject.Properties['patch']-or$null-eq$payload.patch){throw 'Recovery repair payload requires a patch object.'}
    $patch=$payload.patch
    $task=Get-SCTask $Id
    Assert-SCRecoveryTaskMutable $task
    if([string]$task.status-eq'complete'){throw "Task $Id is already complete; recovery repair is for incomplete stalled state."}

    $beforeHash=Get-SCTaskDefinitionHash $task
    $changed=@()
    $allowed=@('title','instruction','size','outputKind','acceptance','checks','semanticAcceptance','dependsOn','relations','retrieval','evidence','provider','role','sources','intentRefs','capabilityProfile','toolPolicy','implications','proofObligations','parentTaskId','childTaskIds')
    foreach($name in $allowed){
        $prop=$patch.PSObject.Properties[$name]
        if($null-eq$prop){continue}
        $value=$prop.Value
        switch($name){
            'title' {if([string]::IsNullOrWhiteSpace([string]$value)){throw 'Recovered task title cannot be empty.'};Set-SCProperty $task $name ([string]$value)}
            'instruction' {if([string]::IsNullOrWhiteSpace([string]$value)){throw 'Recovered task instruction cannot be empty.'};Set-SCProperty $task $name ([string]$value)}
            'size' {$v=([string]$value).ToLowerInvariant();if(@('tiny','small','medium','large')-notcontains$v){throw "Invalid recovery size '$value'."};Set-SCProperty $task $name $v}
            'outputKind' {$v=([string]$value).ToLowerInvariant();if(@('change','document','state-update','research','diagnosis','answer','none','no-change')-notcontains$v){throw "Invalid recovery outputKind '$value'."};Set-SCProperty $task $name $v}
            'acceptance' {Set-SCProperty $task $name @($value)}
            'dependsOn' {Set-SCProperty $task $name @($value)}
            'relations' {Set-SCProperty $task $name @(ConvertTo-SCRelations $value)}
            'retrieval' {Set-SCProperty $task $name @($value)}
            'evidence' {Set-SCProperty $task $name @($value)}
            'sources' {Set-SCProperty $task $name @($value)}
            'intentRefs' {Set-SCProperty $task $name @($value)}
            'implications' {Set-SCProperty $task $name @($value)}
            'proofObligations' {Set-SCProperty $task $name @($value)}
            'childTaskIds' {Set-SCProperty $task $name @($value)}
            'provider' {Set-SCProperty $task $name $(if($null-eq$value-or[string]::IsNullOrWhiteSpace([string]$value)){$null}else{[string]$value})}
            'capabilityProfile' {Set-SCProperty $task $name $(if($null-eq$value-or[string]::IsNullOrWhiteSpace([string]$value)){$null}else{[string]$value})}
            'toolPolicy' {Set-SCProperty $task $name $value}
            'parentTaskId' {Set-SCProperty $task $name $(if($null-eq$value-or[string]::IsNullOrWhiteSpace([string]$value)){$null}else{[string]$value})}
            default {Set-SCProperty $task $name ([string]$value)}
        }
        $changed+=,$name
    }
    if($changed.Count-eq0){throw 'Recovery patch did not contain any supported task fields.'}

    Advance-SCTaskControlRevision $task|Out-Null
    $previousStatus=[string]$task.status
    $previousAttempts=if($task.PSObject.Properties['attemptCount']){[int]$task.attemptCount}else{0}
    Set-SCProperty $task 'attemptCount' 0
    Set-SCProperty $task 'criticRejectCount' 0
    Set-SCProperty $task 'validatorRejectCount' 0
    Set-SCProperty $task 'activeWorkerSessionId' $null
    Set-SCProperty $task 'blockReason' $null
    Set-SCProperty $task 'status' 'pending'
    $recoveryCount=if($task.PSObject.Properties['recoveryCount']){[int]$task.recoveryCount+1}else{1}
    Set-SCProperty $task 'recoveryCount' $recoveryCount
    Set-SCProperty $task 'lastRecovery' ([pscustomobject][ordered]@{
        kind='task-repair';ts=(Get-Date).ToUniversalTime().ToString('o');reason=$Why;evidence=@($evidence);changedFields=@($changed)
    })
    Save-SCTask $task
    Update-SCReadiness
    $task=Get-SCTask $Id
    $afterHash=Get-SCTaskDefinitionHash $task
    Add-SCEvent 'task.repaired.control_plane' "Control plane repaired stalled task ${Id}: $Why" @{
        taskId=$Id;previousStatus=$previousStatus;previousAttempts=$previousAttempts;changedFields=@($changed);
        reason=$Why;evidence=@($evidence);beforeDefinitionHash=$beforeHash;afterDefinitionHash=$afterHash;
        controlRevision=$task.controlRevision;recoveryCount=$recoveryCount;newStatus=$task.status
    }
    if(Get-Command Add-SCProgressRecord -ErrorAction SilentlyContinue){
        Add-SCProgressRecord $task $null $true 'control-plane-task-repair' $Why|Out-Null
    }
    Write-Host "Recovered task definition: $Id -> $($task.status)"
    return $task
}

function Complete-SCTaskFromRecovery([string]$Id,[string]$PayloadPath,[string]$Why) {
    if([string]::IsNullOrWhiteSpace($Id)){throw '-TaskId required.'}
    if([string]::IsNullOrWhiteSpace($Why)){throw '-Reason required for control-plane recovery completion.'}
    $payload=Get-SCRecoveryPayload $PayloadPath
    $evidence=@(Get-SCRecoveryEvidence $payload)
    $task=Get-SCTask $Id
    Assert-SCRecoveryTaskMutable $task
    if([string]$task.status-eq'complete'){Write-Host "Task already complete: $Id";return $task}

    $allowedStatus=@('pending','ready','needs_rework','stale','blocked','failed')
    if($allowedStatus-notcontains[string]$task.status){throw "Task $Id status '$($task.status)' is not eligible for recovery completion."}
    $previousStatus=[string]$task.status
    $previousAttempts=if($task.PSObject.Properties['attemptCount']){[int]$task.attemptCount}else{0}
    Advance-SCTaskControlRevision $task|Out-Null
    $task.status='complete'
    $task.blockReason=$null
    Set-SCProperty $task 'activeWorkerSessionId' $null
    $recoveryCount=if($task.PSObject.Properties['recoveryCount']){[int]$task.recoveryCount+1}else{1}
    Set-SCProperty $task 'recoveryCount' $recoveryCount
    Set-SCProperty $task 'lastRecovery' ([pscustomobject][ordered]@{
        kind='accepted-existing-work';ts=(Get-Date).ToUniversalTime().ToString('o');reason=$Why;evidence=@($evidence)
    })
    Save-SCTask $task
    Add-SCEvent 'task.completed.control_plane_recovery' "Control plane accepted existing work for stalled task ${Id}: $Why" @{
        taskId=$Id;previousStatus=$previousStatus;previousAttempts=$previousAttempts;reason=$Why;evidence=@($evidence);
        authority='control-plane-recovery';bypassedReviewGate=$true;controlRevision=$task.controlRevision;
        latestRunId=$task.latestRunId;latestProposalId=$task.latestProposalId;latestCritiqueId=$task.latestCritiqueId;latestValidationId=$task.latestValidationId;
        recoveryCount=$recoveryCount
    }
    if(Get-Command Add-SCProgressRecord -ErrorAction SilentlyContinue){
        Add-SCProgressRecord $task $null $true 'control-plane-recovery-commit' $Why|Out-Null
    }
    Update-SCReadiness
    Write-Host "Task recovery-completed: $Id"
    return (Get-SCTask $Id)
}


# ---------------------------------------------------------------------------
# Transactional planning handoff application.
# ---------------------------------------------------------------------------

function Resolve-SCPlanningArtifactPath([string]$PathValue) {
    if([string]::IsNullOrWhiteSpace($PathValue)){return $null}
    $stateDir=[IO.Path]::GetFullPath((Get-SCDir))
    $root=[IO.Path]::GetFullPath((Get-SCStateRoot))
    $text=[string]$PathValue
    if([IO.Path]::IsPathRooted($text)){$full=[IO.Path]::GetFullPath($text)}
    elseif($text -match '^\.statefulclanker[/\\](.+)$'){$full=[IO.Path]::GetFullPath((Join-Path $stateDir $Matches[1]))}
    else{$full=[IO.Path]::GetFullPath((Join-Path $root $text))}
    if(-not($full.StartsWith($stateDir,[StringComparison]::OrdinalIgnoreCase))){throw "Planning artifact escaped .statefulclanker: $PathValue"}
    return $full
}

function Get-SCPlanningActiveRecord {
    $path=Get-SCPath 'planning/active.json'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    return Read-SCJson $path
}

function Get-SCPlanningTransactionRoot { Get-SCPath 'transactions' }

function Copy-SCPathTree([string]$Source,[string]$Destination) {
    if(Test-Path -LiteralPath $Destination){Remove-Item -LiteralPath $Destination -Recurse -Force}
    if(Test-Path -LiteralPath $Source -PathType Container){
        New-Item -ItemType Directory -Force -Path $Destination|Out-Null
        foreach($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue)){
            Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force -ErrorAction Stop
        }
        return
    }
    if(Test-Path -LiteralPath $Source -PathType Leaf){
        $parent=Split-Path -Parent $Destination
        if($parent-and-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
    }
}

function Restore-SCTransactionBackup($Journal) {
    foreach($target in @($Journal.targets)){
        $live=[string]$target.livePath
        $backup=[string]$target.backupPath
        $existed=[bool]$target.existed
        if(Test-Path -LiteralPath $live){Remove-Item -LiteralPath $live -Recurse -Force -ErrorAction Stop}
        if($existed){
            if(-not(Test-Path -LiteralPath $backup)){throw "Transaction backup is missing: $backup"}
            Copy-SCPathTree $backup $live
        }
    }
}

function Recover-SCInterruptedPlanTransactions {
    $root=Get-SCPlanningTransactionRoot
    if(-not(Test-Path -LiteralPath $root -PathType Container)){return @()}
    $recovered=@()
    foreach($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue|Sort-Object Name)){
        $journalPath=Join-Path $dir.FullName 'journal.json'
        if(-not(Test-Path -LiteralPath $journalPath -PathType Leaf)){continue}
        try{$journal=Read-SCJson $journalPath}catch{continue}
        if($null-eq$journal){continue}
        $status=[string]$journal.status
        if($status-eq'committing'){
            Invoke-SCLocked {
                Restore-SCTransactionBackup $journal
                $journal.status='rolled_back'
                Set-SCProperty $journal 'rolledBackAt' ((Get-Date).ToUniversalTime().ToString('o'))
                Set-SCProperty $journal 'rollbackReason' 'Recovered an interrupted planning transaction during startup.'
                Write-SCJson $journalPath $journal
            }|Out-Null
            $recovered+=,[string]$journal.id
        } elseif(@('staging','prepared')-contains$status) {
            $journal.status='abandoned'
            Set-SCProperty $journal 'closedAt' ((Get-Date).ToUniversalTime().ToString('o'))
            Set-SCProperty $journal 'closeReason' 'Transaction never entered commit; no live state required restoration.'
            Write-SCJson $journalPath $journal
        }
    }
    return @($recovered)
}

function Get-SCFileSetAggregateHash([string]$Directory) {
    $files=if(Test-Path -LiteralPath $Directory -PathType Container){@(Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File|Sort-Object Name)}else{@()}
    $inc=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try{
        foreach($file in $files){
            $name=[Text.Encoding]::UTF8.GetBytes($file.Name.ToLowerInvariant()+[char]10)
            $inc.AppendData($name)
            $inc.AppendData([IO.File]::ReadAllBytes($file.FullName))
        }
        return ([BitConverter]::ToString($inc.GetHashAndReset())).Replace('-','').ToLowerInvariant()
    }finally{$inc.Dispose()}
}

function Get-SCPlanningDirtyFiles {
    $root=Get-SCStateRoot
    $old=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';$raw=& git -C $root status --porcelain --untracked-files=all 2>$null|Out-String}finally{$ErrorActionPreference=$old}
    $paths=@()
    foreach($line in @($raw -split '\r?\n')){
        if([string]::IsNullOrWhiteSpace($line)){continue}
        $path=if($line.Length-gt3){$line.Substring(3).Trim().Trim('"')}else{$line.Trim()}
        if($path -match ' -> '){$path=($path -split ' -> ',2)[1].Trim().Trim('"')}
        if([string]::IsNullOrWhiteSpace($path)){continue}
        $paths+=,$path.Replace('\','/')
    }
    $out=@()
    foreach($path in @($paths|Sort-Object -Unique)){
        $full=Join-Path $root ($path.Replace('/',[IO.Path]::DirectorySeparatorChar))
        $hash=if(Test-Path -LiteralPath $full -PathType Leaf){Get-SCFileHashValue $full}else{'<missing>'}
        $out+=,[ordered]@{path=$path;sha256=$hash}
    }
    return @($out)
}

function Assert-SCPlanningBaselineFresh($Baseline) {
    if($null-eq$Baseline){throw 'Planning baseline is missing.'}
    $busy=@(Get-SCTasks|Where-Object{@('running','reviewing','validating')-contains[string]$_.status}|ForEach-Object{[string]$_.id})
    if($busy.Count-gt0){throw "Planning handoff cannot apply while tasks are active: $($busy -join ', ')"}

    $state=Get-SCState
    if([string]$state.goal-ne[string]$Baseline.projectGoal){throw 'Planning baseline drift: project goal changed after settle.'}
    if([string]$state.activePlanId-ne[string]$Baseline.activePlanId){throw "Planning baseline drift: activePlanId changed from '$($Baseline.activePlanId)' to '$($state.activePlanId)'."}

    $taskHash=Get-SCFileSetAggregateHash (Get-SCPath 'tasks')
    if([string]$taskHash-ne[string]$Baseline.taskGraphHash){throw 'Planning baseline drift: active task graph changed after settle. Re-settle/replan against current reality.'}

    $intentPath=Get-SCPath 'intent/contract.json'
    $intentHash=if(Test-Path -LiteralPath $intentPath -PathType Leaf){Get-SCFileHashValue $intentPath}else{$null}
    if([string]$intentHash-ne[string]$Baseline.intentHash){throw 'Planning baseline drift: Intent changed after settle.'}

    $directiveHash=Get-SCFileSetAggregateHash (Get-SCPath 'directives/current')
    if([string]$directiveHash-ne[string]$Baseline.directiveHash){throw 'Planning baseline drift: current human directives changed after settle. Stage directive changes in the handoff instead of mutating live authority during planning.'}

    if($Baseline.PSObject.Properties['gitHead']-and$Baseline.gitHead){
        $old=$ErrorActionPreference
        try{$ErrorActionPreference='Continue';$head=(& git -C (Get-SCStateRoot) rev-parse HEAD 2>$null|Out-String).Trim()}finally{$ErrorActionPreference=$old}
        if([string]$head-ne[string]$Baseline.gitHead){throw "Planning baseline drift: Git HEAD changed from $($Baseline.gitHead) to $head."}
    }

    $expected=@{}
    foreach($item in @($Baseline.dirtyFiles)){if($item.path){$expected[[string]$item.path]=[string]$item.sha256}}
    $current=@{}
    foreach($item in @(Get-SCPlanningDirtyFiles)){$current[[string]$item.path]=[string]$item.sha256}
    if($expected.Count-ne$current.Count){throw 'Planning baseline drift: dirty/untracked file set changed after settle.'}
    foreach($key in $expected.Keys){
        if(-not$current.ContainsKey($key)-or[string]$current[$key]-ne[string]$expected[$key]){throw "Planning baseline drift: worktree content changed for '$key'."}
    }
}

function New-SCTaskFromPlanItem($Item) {
    if($null-eq$Item){throw 'Plan task is empty.'}
    $id=if($Item.PSObject.Properties['id']-and$Item.id){[string]$Item.id}else{throw 'Every transactional plan task requires a stable id.'}
    $accept=if($Item.PSObject.Properties['acceptance']){@($Item.acceptance)}else{@()}
    $depends=if($Item.PSObject.Properties['dependsOn']){@($Item.dependsOn)}else{@()}
    $relations=if($Item.PSObject.Properties['relations']){@($Item.relations)}else{@()}
    $retrieval=if($Item.PSObject.Properties['retrieval']){@($Item.retrieval)}else{@()}
    $evidence=if($Item.PSObject.Properties['evidence']){@($Item.evidence)}else{@()}
    $provider=if($Item.PSObject.Properties['provider']){[string]$Item.provider}else{$null}
    $role=if($Item.PSObject.Properties['role']-and$Item.role){[string]$Item.role}else{'worker'}
    $human=if($Item.PSObject.Properties['humanGate']){[bool]$Item.humanGate}else{$false}
    $task=New-SCTaskObject $id ([string]$Item.title) ([string]$Item.instruction) $accept $depends $relations $retrieval $evidence $provider $role $human
    Set-SCProperty $task 'size' $(if($Item.PSObject.Properties['size']){[string]$Item.size}else{'small'})
    Set-SCProperty $task 'outputKind' $(if($Item.PSObject.Properties['outputKind']-and$Item.outputKind){[string]$Item.outputKind}else{'change'})
    Set-SCProperty $task 'sources' $(if($Item.PSObject.Properties['sources']){@($Item.sources)}else{@()})
    Set-SCProperty $task 'intentRefs' $(if($Item.PSObject.Properties['intentRefs']){@($Item.intentRefs)}else{@()})
    Set-SCProperty $task 'capabilityProfile' $(if($Item.PSObject.Properties['capabilityProfile']-and$Item.capabilityProfile){[string]$Item.capabilityProfile}else{$null})
    Set-SCProperty $task 'toolPolicy' $(if($Item.PSObject.Properties['toolPolicy']){$Item.toolPolicy}else{$null})
    Set-SCProperty $task 'checks' $(if($Item.PSObject.Properties['checks']){@($Item.checks)}else{@()})
    Set-SCProperty $task 'semanticAcceptance' $(if($Item.PSObject.Properties['semanticAcceptance']){@($Item.semanticAcceptance)}else{@()})
    Set-SCProperty $task 'implications' $(if($Item.PSObject.Properties['implications']){@($Item.implications)}else{@()})
    Set-SCProperty $task 'proofObligations' $(if($Item.PSObject.Properties['proofObligations']){@($Item.proofObligations)}else{@()})
    Set-SCProperty $task 'refinementStatus' 'pending'
    Set-SCProperty $task 'refinementDepth' 0
    Set-SCProperty $task 'parentTaskId' $null
    Set-SCProperty $task 'childTaskIds' @()
    return $task
}

function Assert-SCReplacementPlanGraph($Tasks) {
    $items=@($Tasks);$map=@{}
    foreach($task in $items){
        $id=[string]$task.id
        if([string]::IsNullOrWhiteSpace($id)){throw 'Replacement plan contains a task without id.'}
        if($map.ContainsKey($id)){throw "Replacement plan contains duplicate task id '$id'."}
        $map[$id]=$task
    }
    foreach($task in $items){
        foreach($dep in @($task.dependsOn)){
            $id=[string]$dep
            if([string]::IsNullOrWhiteSpace($id)){continue}
            if($id-eq[string]$task.id){throw "Task '$($task.id)' depends on itself."}
            if(-not$map.ContainsKey($id)){throw "Task '$($task.id)' depends on '$id', which is absent from the replacement graph. Include preserved completed prerequisites explicitly."}
        }
    }
    $indegree=@{};$children=@{}
    foreach($task in $items){$indegree[[string]$task.id]=0;$children[[string]$task.id]=@()}
    foreach($task in $items){
        foreach($dep in @($task.dependsOn)){
            if([string]::IsNullOrWhiteSpace([string]$dep)){continue}
            $indegree[[string]$task.id]=[int]$indegree[[string]$task.id]+1
            $children[[string]$dep]=@($children[[string]$dep])+[string]$task.id
        }
    }
    $queue=New-Object Collections.Queue
    foreach($id in $indegree.Keys){if([int]$indegree[$id]-eq0){$queue.Enqueue($id)}}
    $seen=0
    while($queue.Count-gt0){
        $id=[string]$queue.Dequeue();$seen++
        foreach($child in @($children[$id])){
            $indegree[$child]=[int]$indegree[$child]-1
            if([int]$indegree[$child]-eq0){$queue.Enqueue($child)}
        }
    }
    if($seen-ne$items.Count){
        $cycle=@($indegree.Keys|Where-Object{[int]$indegree[$_]-gt0}|Sort-Object)
        throw "Replacement task graph contains a dependency cycle involving: $($cycle -join ', ')"
    }
}

function Get-SCIntentSemanticHash($Intent) {
    if($null-eq$Intent){return $null}
    $projection=[ordered]@{}
    foreach($name in @('objective','requirements','constraints','invariants','nonGoals','decisions','preferences','openQuestions','successDefinition')){
        $projection[$name]=if($Intent.PSObject.Properties[$name]){$Intent.$name}else{$null}
    }
    return Get-SCHashString (ConvertTo-SCJson $projection 24)
}

function Find-SCIntentRefValue($Intent,[string]$Ref) {
    if($null-eq$Intent-or[string]::IsNullOrWhiteSpace($Ref)){return $null}
    foreach($field in @('requirements','constraints','invariants','nonGoals','decisions','preferences','openQuestions')){
        if(-not$Intent.PSObject.Properties[$field]){continue}
        foreach($item in @($Intent.$field)){
            if($item-is[string]){
                $text=[string]$item
                if($text-eq$Ref-or$text-match('^\s*'+[regex]::Escape($Ref)+'(?:\s*[:\-]\s*|\s*$)')){return [ordered]@{field=$field;value=$text}}
            } elseif($null-ne$item) {
                foreach($key in @('id','ref','key','name')){
                    if($item.PSObject.Properties[$key]-and[string]$item.$key-eq$Ref){return [ordered]@{field=$field;value=$item}}
                }
            }
        }
    }
    return $null
}

function Assert-SCStagedDirectiveIntentRefs($DirectiveResult,$Intent) {
    foreach($change in @($DirectiveResult.changes)){
        if([string]$change.action-ne'set'){continue}
        foreach($ref in @($change.record.intentRefs)){
            $id=[string]$ref
            if([string]::IsNullOrWhiteSpace($id)){continue}
            if($null-eq(Find-SCIntentRefValue $Intent $id)){
                throw "Staged directive '$($change.id)' references Intent '$id', but that ref is absent from the candidate Intent."
            }
        }
    }
}

function Test-SCTaskIntentCompatible($Task,$OldIntent,$NewIntent,[string]$OldGoal,[string]$NewGoal,$DirectiveChanges) {
    $refs=if($Task.PSObject.Properties['intentRefs']){@($Task.intentRefs|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}|ForEach-Object{[string]$_})}else{@()}
    $sources=if($Task.PSObject.Properties['sources']){@($Task.sources|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}|ForEach-Object{[string]$_})}else{@()}
    $changes=@($DirectiveChanges)

    foreach($change in $changes){
        $previousSource=if($change.PSObject.Properties['previousSourceRef']){[string]$change.previousSourceRef}else{$null}
        if([string]::IsNullOrWhiteSpace($previousSource)){continue}
        foreach($source in $sources){
            if($source-eq$previousSource-or$source.StartsWith($previousSource+'#',[StringComparison]::OrdinalIgnoreCase)){return $false}
        }
    }

    if($changes.Count-gt0){
        if($refs.Count-eq0){return $false}
        foreach($change in $changes){
            $directiveRefs=if($change.record-and$change.record.PSObject.Properties['intentRefs']){@($change.record.intentRefs|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}|ForEach-Object{[string]$_})}else{@()}
            if($directiveRefs.Count-eq0){return $false}
            foreach($ref in $refs){if($directiveRefs-contains$ref){return $false}}
        }
    }

    if($refs.Count-eq0){
        if($OldGoal-ne$NewGoal){return $false}
        return ([string](Get-SCIntentSemanticHash $OldIntent)-eq[string](Get-SCIntentSemanticHash $NewIntent))
    }
    foreach($ref in $refs){
        $old=Find-SCIntentRefValue $OldIntent $ref
        $new=Find-SCIntentRefValue $NewIntent $ref
        if($null-eq$old-or$null-eq$new){return $false}
        if((Get-SCHashString (ConvertTo-SCJson $old 16))-ne(Get-SCHashString (ConvertTo-SCJson $new 16))){return $false}
    }
    return $true
}

function Copy-SCCompletedTaskRuntime($OldTask,$FreshTask) {
    $definition=@('schemaVersion','id','title','instruction','size','sources','intentRefs','capabilityProfile','toolPolicy','acceptance','checks','semanticAcceptance','implications','proofObligations','parentTaskId','childTaskIds','refinementStatus','refinementDepth','dependsOn','relations','retrieval','evidence','provider','role','outputKind','humanGate')
    foreach($p in $OldTask.PSObject.Properties){
        if($definition -contains [string]$p.Name){continue}
        Set-SCProperty $FreshTask ([string]$p.Name) $p.Value
    }
    $FreshTask.status='complete'
    Set-SCProperty $FreshTask 'activeWorkerSessionId' $null
    Set-SCProperty $FreshTask 'blockReason' $null
}

function Reset-SCReplannedTaskRuntime($Task) {
    $Task.status='pending';$Task.stateRevision=0;$Task.controlRevision=0;$Task.attemptCount=0;$Task.criticRejectCount=0;$Task.validatorRejectCount=0
    foreach($name in @('activeWorkerSessionId','latestWorkerSessionId','latestRunId','latestCompilationId','latestProposalId','latestCritiqueId','latestValidationId','blockReason','routingNotBefore')){Set-SCProperty $Task $name $null}
    Set-SCProperty $Task 'updatedAt' ((Get-Date).ToUniversalTime().ToString('o'))
}

function Get-SCStagedDirectiveRecords([string]$StageDirectives) {
    $dir=Join-Path $StageDirectives 'current'
    if(-not(Test-Path -LiteralPath $dir -PathType Container)){return @()}
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File|Sort-Object Name|ForEach-Object{Read-SCJson $_.FullName}|Where-Object{$null-ne$_})
}

function New-SCStagedHumanSource([string]$StageInput,[string]$Text,[string]$DirectiveId) {
    $id=New-SCId 'h'
    $txt=Join-Path $StageInput ("{0}.txt"-f$id)
    $meta=Join-Path $StageInput ("{0}.meta.json"-f$id)
    if(-not(Test-Path -LiteralPath $StageInput)){New-Item -ItemType Directory -Force -Path $StageInput|Out-Null}
    [IO.File]::WriteAllText($txt,$Text,(New-Object Text.UTF8Encoding($false)))
    $lines=if($Text.Length-eq0){0}else{@($Text -split '\r?\n').Count}
    Write-SCJson $meta ([ordered]@{schemaVersion=1;id=$id;ref="human:$id";kind='directive';origin=$DirectiveId;createdAt=(Get-Date).ToUniversalTime().ToString('o');lineCount=$lines;sha256=Get-SCFileHashValue $txt})
    return "human:$id"
}

function Apply-SCStagedDirectiveChanges([string]$ChangesPath,[string]$StageDirectives,[string]$StageInput,[int]$StartingRevision) {
    if([string]::IsNullOrWhiteSpace($ChangesPath)){
        return [ordered]@{revision=$StartingRevision;hash=(Get-SCDirectiveHash (Get-SCStagedDirectiveRecords $StageDirectives));changes=@()}
    }
    $raw=Read-SCJson $ChangesPath
    if($null-eq$raw){throw 'Directive changes artifact is empty.'}
    $hasChangesProperty=$null-ne$raw.PSObject.Properties['changes']
    if($hasChangesProperty){$changes=@($raw.changes)}
    elseif($raw-is[System.Collections.IEnumerable]-and-not($raw-is[string])){$changes=@($raw)}
    else{$changes=@($raw)}
    $global=$StartingRevision;$events=@()
    foreach($change in $changes){
        if($null-eq$change){continue}
        $action=if($change.PSObject.Properties['action']){([string]$change.action).ToLowerInvariant()}else{'set'}
        $id=if($change.PSObject.Properties['id']){[string]$change.id}else{''}
        Assert-SCDirectiveId $id
        $currentDir=Join-Path $StageDirectives 'current'
        $historyRoot=Join-Path $StageDirectives 'history'
        if(-not(Test-Path -LiteralPath $currentDir)){New-Item -ItemType Directory -Force -Path $currentDir|Out-Null}
        if(-not(Test-Path -LiteralPath $historyRoot)){New-Item -ItemType Directory -Force -Path $historyRoot|Out-Null}
        $path=Join-Path $currentDir ("{0}.json"-f$id)
        $previous=Read-SCJson $path
        if($action-eq'set'){
            $text=if($change.PSObject.Properties['text']){[string]$change.text}else{''}
            if([string]::IsNullOrWhiteSpace($text)){throw "Directive change '$id' requires text."}
            $scope=if($change.PSObject.Properties['scope']-and$change.scope){[string]$change.scope}else{$id}
            foreach($other in @(Get-SCStagedDirectiveRecords $StageDirectives)){
                if([string]$other.id-ne$id-and[string]$other.scope-eq$scope){throw "Directive scope '$scope' is already owned by '$($other.id)'."}
            }
            $sourceRef=if($change.PSObject.Properties['sourceRef']-and$change.sourceRef){[string]$change.sourceRef}else{$null}
            if($sourceRef){
                if($sourceRef -notmatch '^human:([^#]+)'){throw "Staged directive '$id' sourceRef must be a human: source."}
                $sourceId=$Matches[1]
                $sourcePath=Join-Path $StageInput ("{0}.txt"-f$sourceId)
                if(-not(Test-Path -LiteralPath $sourcePath -PathType Leaf)){throw "Staged directive '$id' sourceRef not found: $sourceRef"}
                if(([string](Get-Content -Raw -LiteralPath $sourcePath)).TrimEnd()-ne$text.TrimEnd()){throw "Staged directive '$id' text does not match sourceRef verbatim."}
            }else{$sourceRef=New-SCStagedHumanSource $StageInput $text $id}
            $next=1
            if($previous){
                $next=[int]$previous.revision+1
                $history=Join-Path $historyRoot $id
                if(-not(Test-Path -LiteralPath $history)){New-Item -ItemType Directory -Force -Path $history|Out-Null}
                Write-SCJson (Join-Path $history ("revision-{0:d4}.json"-f[int]$previous.revision)) $previous
            }
            $record=[ordered]@{
                schemaVersion=1;id=$id;scope=$scope;revision=$next;text=$text;sourceRef=$sourceRef
                intentRefs=if($change.PSObject.Properties['intentRefs']){@($change.intentRefs|Where-Object{$_}|ForEach-Object{[string]$_})}else{@()}
                updatedAt=(Get-Date).ToUniversalTime().ToString('o')
                reason=if($change.PSObject.Properties['reason']){[string]$change.reason}else{$null}
                authority='latest direct human word for this directive scope'
            }
            Write-SCJson $path $record;$global++
            $events+=,[ordered]@{
                action='set';id=$id;record=$record
                previousSourceRef=if($previous-and$previous.PSObject.Properties['sourceRef']){[string]$previous.sourceRef}else{$null}
                previousRevision=if($previous-and$previous.PSObject.Properties['revision']){[int]$previous.revision}else{$null}
            }
        } elseif($action-eq'retire'){
            if($null-eq$previous){throw "Cannot retire unknown current directive '$id'."}
            $history=Join-Path $historyRoot $id
            if(-not(Test-Path -LiteralPath $history)){New-Item -ItemType Directory -Force -Path $history|Out-Null}
            Set-SCProperty $previous 'retiredAt' ((Get-Date).ToUniversalTime().ToString('o'))
            Set-SCProperty $previous 'retireReason' $(if($change.PSObject.Properties['reason']){[string]$change.reason}else{$null})
            Write-SCJson (Join-Path $history ("revision-{0:d4}-retired.json"-f[int]$previous.revision)) $previous
            Remove-Item -LiteralPath $path -Force
            $global++
            $events+=,[ordered]@{
                action='retire';id=$id;record=$previous
                previousSourceRef=if($previous.PSObject.Properties['sourceRef']){[string]$previous.sourceRef}else{$null}
                previousRevision=if($previous.PSObject.Properties['revision']){[int]$previous.revision}else{$null}
            }
        }else{throw "Unknown staged directive action '$action' for '$id'."}
    }
    $records=Get-SCStagedDirectiveRecords $StageDirectives
    return [ordered]@{revision=$global;hash=(Get-SCDirectiveHash $records);changes=@($events)}
}

function Invalidate-SCStagedCompletedDependents([string]$StageTasks,$Dispositions) {
    $files=@(Get-ChildItem -LiteralPath $StageTasks -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $map=@{}
    foreach($file in $files){$task=Read-SCJson $file.FullName;$map[[string]$task.id]=[ordered]@{task=$task;path=$file.FullName}}
    $dispositionMap=@{}
    foreach($item in @($Dispositions)){$dispositionMap[[string]$item.taskId]=$item}

    $changed=$true
    while($changed){
        $changed=$false
        foreach($entry in $map.Values){
            $task=$entry.task
            if([string]$task.status-ne'complete'){continue}
            $invalid=@()
            foreach($dep in @($task.dependsOn)){
                $id=[string]$dep
                if([string]::IsNullOrWhiteSpace($id)){continue}
                if(-not$map.ContainsKey($id)-or[string]$map[$id].task.status-ne'complete'){$invalid+=,$id}
            }
            if($invalid.Count-eq0){continue}

            Reset-SCReplannedTaskRuntime $task
            Write-SCJson $entry.path $task
            if($dispositionMap.ContainsKey([string]$task.id)){
                $disp=$dispositionMap[[string]$task.id]
                $disp['action']='dependency-invalidated'
                $disp['dependencyInvalidatedBy']=@($invalid)
                $disp['semanticCompatible']=$true
            }
            $changed=$true
        }
    }
}

function Set-SCStagedTaskReadiness([string]$StageTasks) {
    $files=@(Get-ChildItem -LiteralPath $StageTasks -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $map=@{}
    foreach($file in $files){$task=Read-SCJson $file.FullName;$map[[string]$task.id]=[ordered]@{task=$task;path=$file.FullName}}
    foreach($entry in $map.Values){
        $task=$entry.task
        if([string]$task.status-eq'complete'){continue}
        $ready=$true
        foreach($dep in @($task.dependsOn)){
            if([string]::IsNullOrWhiteSpace([string]$dep)){continue}
            if(-not$map.ContainsKey([string]$dep)-or[string]$map[[string]$dep].task.status-ne'complete'){$ready=$false;break}
        }
        $task.status=if($ready){'ready'}else{'pending'}
        Write-SCJson $entry.path $task
    }
}

function Find-SCCommittedPlanningTransaction([string]$HandoffId) {
    $root=Get-SCPlanningTransactionRoot
    if(-not(Test-Path -LiteralPath $root -PathType Container)){return $null}
    foreach($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue|Sort-Object Name -Descending)){
        $path=Join-Path $dir.FullName 'journal.json'
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){continue}
        $j=Read-SCJson $path
        if($j-and[string]$j.handoffId-eq$HandoffId-and[string]$j.status-eq'committed'){return $j}
    }
    return $null
}

function Apply-SCPlanningHandoff([string]$HandoffPath) {
    Assert-SCInitialized
    Recover-SCInterruptedPlanTransactions|Out-Null
    if([string]::IsNullOrWhiteSpace($HandoffPath)-or-not(Test-Path -LiteralPath $HandoffPath -PathType Leaf)){throw '-Path to accepted planning handoff is required.'}
    $handoff=Read-SCJson (Resolve-Path -LiteralPath $HandoffPath).Path
    if($null-eq$handoff){throw 'Planning handoff is empty.'}

    $already=Find-SCCommittedPlanningTransaction ([string]$handoff.id)
    if($already){return $already.result}

    $active=Get-SCPlanningActiveRecord
    if($null-eq$active){throw 'No active planning session owns this project.'}
    if([string]$active.phase-ne'handoff'){throw "Planning session is '$($active.phase)', not handoff."}
    if([string]$active.sessionId-ne[string]$handoff.sessionId-or[string]$active.acceptedHandoffId-ne[string]$handoff.id){throw 'Handoff does not match the active accepted planning handoff.'}

    $planPath=Resolve-SCPlanningArtifactPath ([string]$handoff.planPath)
    if(-not(Test-Path -LiteralPath $planPath -PathType Leaf)){throw "Handoff plan artifact is missing: $($handoff.planPath)"}
    if((Get-SCFileHashValue $planPath)-ne[string]$handoff.planSha256){throw 'Handoff plan hash mismatch.'}
    $intentPath=if($handoff.PSObject.Properties['intentPath']-and$handoff.intentPath){Resolve-SCPlanningArtifactPath ([string]$handoff.intentPath)}else{$null}
    if($intentPath-and(Get-SCFileHashValue $intentPath)-ne[string]$handoff.intentSha256){throw 'Handoff Intent hash mismatch.'}
    $directiveChangesPath=if($handoff.PSObject.Properties['directiveChangesPath']-and$handoff.directiveChangesPath){Resolve-SCPlanningArtifactPath ([string]$handoff.directiveChangesPath)}else{$null}
    if($directiveChangesPath-and(Get-SCFileHashValue $directiveChangesPath)-ne[string]$handoff.directiveChangesSha256){throw 'Handoff directive-change hash mismatch.'}

    $baselinePath=Resolve-SCPlanningArtifactPath ([string]$handoff.baselinePath)
    $baseline=Read-SCJson $baselinePath
    if($null-eq$baseline-or-not$baseline.PSObject.Properties['snapshotPath']-or-not$baseline.snapshotPath){throw 'Planning handoff baseline does not contain a frozen state snapshot.'}
    $snapshot=Resolve-SCPlanningArtifactPath ([string]$baseline.snapshotPath)
    if(-not(Test-Path -LiteralPath $snapshot -PathType Container)){throw "Planning baseline snapshot is missing: $($baseline.snapshotPath)"}

    $input=Get-SCPlanInput $planPath
    $plan=$input.plan
    if($null-eq$plan-or$null-eq$plan.tasks-or@($plan.tasks).Count-eq0){throw 'Replacement handoff plan contains no tasks.'}

    $transactionId=New-SCId 'replan'
    $transactionDir=Join-Path (Get-SCPlanningTransactionRoot) $transactionId
    $stage=Join-Path $transactionDir 'stage'
    $backup=Join-Path $transactionDir 'backup'
    New-Item -ItemType Directory -Force -Path $stage,$backup|Out-Null
    $journalPath=Join-Path $transactionDir 'journal.json'
    $journal=[ordered]@{schemaVersion=1;id=$transactionId;handoffId=[string]$handoff.id;sessionId=[string]$handoff.sessionId;status='staging';createdAt=(Get-Date).ToUniversalTime().ToString('o');targets=@();result=$null}
    Write-SCJson $journalPath $journal

    try {
        $result=Invoke-SCLocked {
            Assert-SCPlanningBaselineFresh $baseline

            $liveState=Get-SCState
            $cfg=Get-SCConfig
            $baselineTasksDir=Join-Path $snapshot 'tasks'
            $baselineIntent=Read-SCJson (Join-Path $snapshot 'intent/contract.json')
            $oldTasks=@{}
            if(Test-Path -LiteralPath $baselineTasksDir){
                foreach($file in @(Get-ChildItem -LiteralPath $baselineTasksDir -Filter '*.json' -File)){
                    try{$t=Read-SCJson $file.FullName;if($t){$oldTasks[[string]$t.id]=$t}}catch{}
                }
            }

            $stageTasks=Join-Path $stage 'tasks'
            $stagePlans=Join-Path $stage 'plans'
            $stageIntent=Join-Path $stage 'intent'
            $stageDirectives=Join-Path $stage 'directives'
            $stageInput=Join-Path $stage 'input'
            New-Item -ItemType Directory -Force -Path $stageTasks|Out-Null
            Copy-SCPathTree (Get-SCPath 'plans') $stagePlans
            Copy-SCPathTree (Get-SCPath 'intent') $stageIntent
            Copy-SCPathTree (Get-SCPath 'directives') $stageDirectives
            Copy-SCPathTree (Get-SCPath 'input') $stageInput
            foreach($dir in @($stagePlans,$stageIntent,$stageDirectives,$stageInput)){if(-not(Test-Path -LiteralPath $dir)){New-Item -ItemType Directory -Force -Path $dir|Out-Null}}

            $startingDirectiveRevision=if($liveState.PSObject.Properties['directiveRevision']){[int]$liveState.directiveRevision}else{0}
            $directiveResult=Apply-SCStagedDirectiveChanges $directiveChangesPath $stageDirectives $stageInput $startingDirectiveRevision
            if(@($directiveResult.changes).Count-gt0-and-not$intentPath){throw 'A handoff that changes human directives must include a reconciled Intent candidate.'}
            if(-not$intentPath-and$liveState.PSObject.Properties['directiveReconciliationRequired']-and[bool]$liveState.directiveReconciliationRequired){throw 'Live directives require reconciliation, but the handoff contains no Intent candidate.'}

            $newIntent=Read-SCJson (Join-Path $stageIntent 'contract.json')
            $intentChanged=$false
            if($intentPath){
                $newIntent=Read-SCJson $intentPath
                Assert-SCIntentShape $newIntent
                $currentIntent=Read-SCJson (Get-SCPath 'intent/contract.json')
                $next=[int]$currentIntent.revision+1
                Set-SCProperty $newIntent 'schemaVersion' 2
                Set-SCProperty $newIntent 'revision' $next
                Set-SCProperty $newIntent 'updatedAt' ((Get-Date).ToUniversalTime().ToString('o'))
                Set-SCProperty $newIntent 'directiveRevision' ([int]$directiveResult.revision)
                Set-SCProperty $newIntent 'directiveHash' ([string]$directiveResult.hash)
                Set-SCProperty $newIntent 'authority' ([ordered]@{owner='orchestrator';workers='read-only';humanDirectives='latest direct human word wins within each directive scope'})
                $history=Join-Path $stageIntent 'history'
                if(-not(Test-Path -LiteralPath $history)){New-Item -ItemType Directory -Force -Path $history|Out-Null}
                Write-SCJson (Join-Path $history ("revision-{0:d4}.json"-f$next)) $newIntent
                Write-SCJson (Join-Path $stageIntent 'contract.json') $newIntent
                $intentChanged=$true
            }
            if(@($directiveResult.changes).Count-gt0){Assert-SCStagedDirectiveIntentRefs $directiveResult $newIntent}

            $oldGoal=[string]$liveState.goal
            $newGoal=if($handoff.PSObject.Properties['projectGoal']-and-not[string]::IsNullOrWhiteSpace([string]$handoff.projectGoal)){[string]$handoff.projectGoal}else{$oldGoal}

            $freshTasks=@()
            foreach($item in @($plan.tasks)){$freshTasks+=,(New-SCTaskFromPlanItem $item)}
            Assert-SCReplacementPlanGraph $freshTasks

            $dispositions=@()
            $candidateIds=@{}
            foreach($fresh in $freshTasks){
                $id=[string]$fresh.id
                $candidateIds[$id]=$true
                $old=if($oldTasks.ContainsKey($id)){$oldTasks[$id]}else{$null}
                $newHash=Get-SCTaskDefinitionHash $fresh
                if($old){
                    $oldHash=Get-SCTaskDefinitionHash $old
                    $semanticCompatible=Test-SCTaskIntentCompatible $fresh $baselineIntent $newIntent $oldGoal $newGoal $directiveResult.changes
                    if($oldHash-eq$newHash-and$semanticCompatible-and[string]$old.status-eq'complete'){
                        Copy-SCCompletedTaskRuntime $old $fresh
                        $dispositions+=,[ordered]@{taskId=$id;action='preserved-complete';previousStatus=[string]$old.status;definitionChanged=$false;semanticCompatible=$true}
                    } elseif($oldHash-eq$newHash-and$semanticCompatible){
                        Reset-SCReplannedTaskRuntime $fresh
                        $dispositions+=,[ordered]@{taskId=$id;action='carried-reset';previousStatus=[string]$old.status;definitionChanged=$false;semanticCompatible=$true}
                    } else {
                        Reset-SCReplannedTaskRuntime $fresh
                        $dispositions+=,[ordered]@{taskId=$id;action='replaced';previousStatus=[string]$old.status;definitionChanged=($oldHash-ne$newHash);semanticCompatible=$semanticCompatible}
                    }
                } else {
                    Reset-SCReplannedTaskRuntime $fresh
                    $dispositions+=,[ordered]@{taskId=$id;action='new';previousStatus=$null;definitionChanged=$true;semanticCompatible=$false}
                }
                Write-SCJson (Join-Path $stageTasks ("{0}.json"-f$id)) $fresh
            }

            foreach($oldId in $oldTasks.Keys){
                if($candidateIds.ContainsKey($oldId)){continue}
                $old=$oldTasks[$oldId]
                $action=if([string]$old.status-eq'complete'){'retired-complete'}else{'invalidated-removed'}
                $dispositions+=,[ordered]@{taskId=$oldId;action=$action;previousStatus=[string]$old.status;definitionChanged=$true;semanticCompatible=$false}
            }
            Invalidate-SCStagedCompletedDependents $stageTasks $dispositions
            Set-SCStagedTaskReadiness $stageTasks

            $planId=New-SCId 'plan'
            $name=if($plan.PSObject.Properties['name']){[string]$plan.name}else{'Planning handoff'}
            $summary=if($plan.PSObject.Properties['summary']){[string]$plan.summary}else{''}
            $planRecord=[ordered]@{
                schemaVersion=5;id=$planId;name=$name;summary=$summary;format=$input.format;source=$planPath
                sourceRefs=if($plan.PSObject.Properties['sources']){@($plan.sources)}else{@()}
                intentRefs=if($plan.PSObject.Properties['intent']){@($plan.intent)}else{@()}
                importedAt=(Get-Date).ToUniversalTime().ToString('o')
                transactionId=$transactionId;handoffId=[string]$handoff.id;replacesPlanId=[string]$baseline.activePlanId
                intentRevision=if($newIntent.PSObject.Properties['revision']){[int]$newIntent.revision}else{$null}
                directiveRevision=[int]$directiveResult.revision
                taskDispositions=@($dispositions)
                tasks=@($plan.tasks)
            }
            Write-SCJson (Join-Path $stagePlans ("{0}.json"-f$planId)) $planRecord
            if($input.format-eq'scplan'){Copy-Item -LiteralPath $planPath -Destination (Join-Path $stagePlans ("{0}.scplan"-f$planId)) -Force}

            $nextState=(ConvertTo-SCJson $liveState 30)|ConvertFrom-Json
            $nextState.goal=$newGoal
            $nextState.activePlanId=$planId
            $nextState.planApproved=-not[bool]$cfg.requireHumanApprovalForPlan
            if($intentChanged){
                $direction=if($nextState.PSObject.Properties['directionRevision']){[int]$nextState.directionRevision}else{0}
                Set-SCProperty $nextState 'directionRevision' ($direction+1)
                Set-SCProperty $nextState 'intentRevision' ([int]$newIntent.revision)
            }
            Set-SCProperty $nextState 'directiveRevision' ([int]$directiveResult.revision)
            Set-SCProperty $nextState 'directiveReconciledRevision' ([int]$directiveResult.revision)
            Set-SCProperty $nextState 'directiveReconciliationRequired' $false
            Set-SCProperty $nextState 'pendingDirectiveIds' @()
            $rev=if($nextState.PSObject.Properties['revision']){[int]$nextState.revision}else{0}
            Set-SCProperty $nextState 'revision' ($rev+1)
            Set-SCProperty $nextState 'updatedAt' ((Get-Date).ToUniversalTime().ToString('o'))
            Write-SCJson (Join-Path $stage 'state.json') $nextState

            $targets=@(
                [ordered]@{name='tasks';livePath=(Get-SCPath 'tasks');stagePath=$stageTasks;backupPath=(Join-Path $backup 'tasks')},
                [ordered]@{name='plans';livePath=(Get-SCPath 'plans');stagePath=$stagePlans;backupPath=(Join-Path $backup 'plans')},
                [ordered]@{name='intent';livePath=(Get-SCPath 'intent');stagePath=$stageIntent;backupPath=(Join-Path $backup 'intent')},
                [ordered]@{name='directives';livePath=(Get-SCPath 'directives');stagePath=$stageDirectives;backupPath=(Join-Path $backup 'directives')},
                [ordered]@{name='input';livePath=(Get-SCPath 'input');stagePath=$stageInput;backupPath=(Join-Path $backup 'input')},
                [ordered]@{name='state';livePath=(Get-SCPath 'state.json');stagePath=(Join-Path $stage 'state.json');backupPath=(Join-Path $backup 'state.json')}
            )
            foreach($target in $targets){
                $target['existed']=Test-Path -LiteralPath $target.livePath
                if($target.existed){Copy-SCPathTree $target.livePath $target.backupPath}
            }

            $journal.targets=@($targets)
            $journal.status='prepared'
            Write-SCJson $journalPath $journal
            $journal.status='committing'
            Set-SCProperty $journal 'commitStartedAt' ((Get-Date).ToUniversalTime().ToString('o'))
            Write-SCJson $journalPath $journal

            try {
                foreach($target in $targets){
                    if(Test-Path -LiteralPath $target.livePath){Remove-Item -LiteralPath $target.livePath -Recurse -Force -ErrorAction Stop}
                    Copy-SCPathTree $target.stagePath $target.livePath
                }
            } catch {
                Restore-SCTransactionBackup $journal
                $journal.status='rolled_back'
                Set-SCProperty $journal 'rolledBackAt' ((Get-Date).ToUniversalTime().ToString('o'))
                Set-SCProperty $journal 'rollbackReason' $_.Exception.Message
                Write-SCJson $journalPath $journal
                throw
            }

            $summary=[ordered]@{
                transactionId=$transactionId;handoffId=[string]$handoff.id;appliedPlanId=$planId;replacedPlanId=[string]$baseline.activePlanId
                previousGoal=$oldGoal;projectGoal=$newGoal;goalChanged=($oldGoal-ne$newGoal)
                intentRevision=if($newIntent.PSObject.Properties['revision']){[int]$newIntent.revision}else{$null}
                directiveRevision=[int]$directiveResult.revision
                directiveChanges=@($directiveResult.changes)
                preservedComplete=@($dispositions|Where-Object{$_.action-eq'preserved-complete'}|ForEach-Object{$_.taskId})
                resetTasks=@($dispositions|Where-Object{$_.action-eq'carried-reset'}|ForEach-Object{$_.taskId})
                replacedTasks=@($dispositions|Where-Object{$_.action-eq'replaced'}|ForEach-Object{$_.taskId})
                dependencyInvalidated=@($dispositions|Where-Object{$_.action-eq'dependency-invalidated'}|ForEach-Object{$_.taskId})
                newTasks=@($dispositions|Where-Object{$_.action-eq'new'}|ForEach-Object{$_.taskId})
                retiredTasks=@($dispositions|Where-Object{@('retired-complete','invalidated-removed')-contains$_.action}|ForEach-Object{$_.taskId})
                taskDispositions=@($dispositions)
            }
            $journal.result=$summary
            $journal.status='committed'
            Set-SCProperty $journal 'committedAt' ((Get-Date).ToUniversalTime().ToString('o'))
            Write-SCJson $journalPath $journal
            return $summary
        }

        try {
            Add-SCEvent 'planning.handoff_applied' "Applied planning handoff $($handoff.id) as plan $($result.appliedPlanId)." $result
            Add-SCEvent 'plan.replaced' "Active plan replaced transactionally: $($result.replacedPlanId) -> $($result.appliedPlanId)." @{transactionId=$result.transactionId;handoffId=$handoff.id;previousPlanId=$result.replacedPlanId;activePlanId=$result.appliedPlanId;preservedComplete=@($result.preservedComplete);resetTasks=@($result.resetTasks);replacedTasks=@($result.replacedTasks);dependencyInvalidated=@($result.dependencyInvalidated);newTasks=@($result.newTasks);retiredTasks=@($result.retiredTasks)}
            if([bool]$result.goalChanged){Add-SCEvent 'goal.changed' ([string]$result.projectGoal) @{transactionId=$result.transactionId;handoffId=$handoff.id;previousGoal=$result.previousGoal}}
            if($intentPath){Add-SCEvent 'intent.revised' "Intent contract revised transactionally to $($result.intentRevision)." @{revision=$result.intentRevision;transactionId=$result.transactionId;handoffId=$handoff.id}}
            foreach($change in @($result.directiveChanges)){
                if([string]$change.action-eq'set'){
                    Add-SCEvent 'directive.revised' "Human directive '$($change.id)' revised transactionally." @{directiveId=$change.id;transactionId=$result.transactionId;handoffId=$handoff.id;directiveRevision=$result.directiveRevision;sourceRef=$change.record.sourceRef;intentRefs=@($change.record.intentRefs)}
                } elseif([string]$change.action-eq'retire'){
                    Add-SCEvent 'directive.retired' "Human directive '$($change.id)' retired transactionally." @{directiveId=$change.id;transactionId=$result.transactionId;handoffId=$handoff.id;directiveRevision=$result.directiveRevision}
                }
            }
        } catch {
            Write-Warning "Planning transaction $($result.transactionId) committed, but post-commit event logging failed: $($_.Exception.Message)"
        }
        return $result
    } catch {
        if(Test-Path -LiteralPath $journalPath -PathType Leaf){
            try{
                $latest=Read-SCJson $journalPath
                if($latest-and[string]$latest.status-eq'staging'){
                    $latest.status='failed'
                    Set-SCProperty $latest 'failedAt' ((Get-Date).ToUniversalTime().ToString('o'))
                    Set-SCProperty $latest 'failure' $_.Exception.Message
                    Write-SCJson $journalPath $latest
                }
            }catch{}
        }
        throw
    }
}

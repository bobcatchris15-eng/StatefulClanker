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
            $task=[ordered]@{id=$value;title='';instruction='';size='small';sources=@();intentRefs=@();acceptance=@();implications=@();proofObligations=@();dependsOn=@();relations=@();retrieval=@();evidence=@();provider=$null;role='worker';outputKind='change';humanGate=$false;capabilityProfile=$null;toolAllow=@();toolDeny=@();refinementStatus='pending';refinementDepth=0;parentTaskId=$null;childTaskIds=@();unknown=@()};continue
        }
        if($key-eq'end'){
            if($null-eq$task){throw "Unexpected end outside a task."};if([string]::IsNullOrWhiteSpace($task.title)){throw "Task $($task.id) is missing title."};if([string]::IsNullOrWhiteSpace($task.instruction)){throw "Task $($task.id) is missing instruction."}
            $task.toolPolicy=New-SCTaskToolPolicy $task.toolAllow $task.toolDeny;$task.Remove('toolAllow');$task.Remove('toolDeny');$plan.tasks+=,[pscustomobject]$task;$task=$null;continue
        }
        if($null-ne$task){
            switch($key){
              'title'{$task.title=$value};'instruction'{$task.instruction=$value};'size'{if(@('tiny','small','medium','large')-notcontains$value.ToLowerInvariant()){throw "Task $($task.id) has invalid size '$value'."};$task.size=$value.ToLowerInvariant()}
              'source'{$task.sources+=,$value};'intent'{$task.intentRefs+=,$value};'accept'{$task.acceptance+=,$value};'imply'{$task.implications+=,$value};'prove'{$task.proofObligations+=,$value};'depends'{$task.dependsOn+=,$value};'retrieve'{$task.retrieval+=,$value};'evidence'{$task.evidence+=,$value};'provider'{$task.provider=$value};'role'{$task.role=$value};'output-kind'{if(@('change','document','state-update','research','diagnosis','answer','none','no-change')-notcontains$value.ToLowerInvariant()){throw "Task $($task.id) has invalid output-kind '$value'."};$task.outputKind=$value.ToLowerInvariant()}
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
        $id=if($item.PSObject.Properties['id']-and$item.id){[string]$item.id}else{New-SCId 'task'};if(Test-Path (Get-SCPath ("tasks/{0}.json"-f$id))){throw "Plan task id already exists: $id"}
        $taskObj=New-SCTaskObject $id ([string]$item.title) ([string]$item.instruction) $(if($item.PSObject.Properties['acceptance']){@($item.acceptance)}else{@()}) $(if($item.PSObject.Properties['dependsOn']){@($item.dependsOn)}else{@()}) $(if($item.PSObject.Properties['relations']){@($item.relations)}else{@()}) $(if($item.PSObject.Properties['retrieval']){@($item.retrieval)}else{@()}) $(if($item.PSObject.Properties['evidence']){@($item.evidence)}else{@()}) $(if($item.PSObject.Properties['provider']){[string]$item.provider}else{$null}) $(if($item.PSObject.Properties['role']-and$item.role){[string]$item.role}else{'worker'}) $(if($item.PSObject.Properties['humanGate']){[bool]$item.humanGate}else{$false})
        Set-SCProperty $taskObj 'size' $(if($item.PSObject.Properties['size']){[string]$item.size}else{'small'});Set-SCProperty $taskObj 'outputKind' $(if($item.PSObject.Properties['outputKind']-and$item.outputKind){[string]$item.outputKind}else{'change'});Set-SCProperty $taskObj 'sources' $(if($item.PSObject.Properties['sources']){@($item.sources)}else{@()});Set-SCProperty $taskObj 'intentRefs' $(if($item.PSObject.Properties['intentRefs']){@($item.intentRefs)}else{@()})
        Set-SCProperty $taskObj 'capabilityProfile' $(if($item.PSObject.Properties['capabilityProfile']-and$item.capabilityProfile){[string]$item.capabilityProfile}else{$null});Set-SCProperty $taskObj 'toolPolicy' $(if($item.PSObject.Properties['toolPolicy']){$item.toolPolicy}else{$null});Set-SCProperty $taskObj 'implications' $(if($item.PSObject.Properties['implications']){@($item.implications)}else{@()});Set-SCProperty $taskObj 'proofObligations' $(if($item.PSObject.Properties['proofObligations']){@($item.proofObligations)}else{@()});Set-SCProperty $taskObj 'refinementStatus' 'pending';Set-SCProperty $taskObj 'refinementDepth' 0;Set-SCProperty $taskObj 'parentTaskId' $null;Set-SCProperty $taskObj 'childTaskIds' @();Save-SCTask $taskObj
    }
    $state=Get-SCState;$state.activePlanId=$planId;$cfg=Get-SCConfig;$state.planApproved=-not[bool]$cfg.requireHumanApprovalForPlan;Save-SCState $state;Update-SCReadiness;Add-SCEvent 'plan.imported' "Imported $planId" @{taskCount=@($plan.tasks).Count;format=$input.format};Write-Host "Imported $planId ($($input.format), $(@($plan.tasks).Count) tasks)"
}

function Get-SCTaskDefinitionHash($Task) {
    $taskRole=if($Task.PSObject.Properties['role']-and$Task.role){[string]$Task.role}else{'worker'}
    $definition=[ordered]@{title=$Task.title;instruction=$Task.instruction;size=if($Task.PSObject.Properties['size']){$Task.size}else{'small'};sources=if($Task.PSObject.Properties['sources']){@($Task.sources)}else{@()};intentRefs=if($Task.PSObject.Properties['intentRefs']){@($Task.intentRefs)}else{@()};capabilityProfile=if($Task.PSObject.Properties['capabilityProfile']){$Task.capabilityProfile}else{$null};toolPolicy=if($Task.PSObject.Properties['toolPolicy']){$Task.toolPolicy}else{$null};acceptance=@($Task.acceptance);implications=if($Task.PSObject.Properties['implications']){@($Task.implications)}else{@()};proofObligations=if($Task.PSObject.Properties['proofObligations']){@($Task.proofObligations)}else{@()};parentTaskId=if($Task.PSObject.Properties['parentTaskId']){$Task.parentTaskId}else{$null};dependsOn=@($Task.dependsOn);relations=if($Task.PSObject.Properties['relations']){@($Task.relations)}else{@()};retrieval=@($Task.retrieval);evidence=@($Task.evidence);provider=$Task.provider;role=$taskRole;outputKind=if($Task.PSObject.Properties['outputKind']){$Task.outputKind}else{'change'};humanGate=[bool]$Task.humanGate}
    return Get-SCHashString (ConvertTo-SCJson $definition 18)
}

function Add-SCTask {
    if([string]::IsNullOrWhiteSpace($Title)){throw '-Title is required.'};if([string]::IsNullOrWhiteSpace($Instruction)){throw '-Instruction is required.'};$id=if($TaskId){$TaskId}else{New-SCId 'task'};if(@(Get-SCTasks|Where-Object{$_.id-eq$id}).Count-gt0){throw "Task exists: $id"}
    $taskObj=New-SCTaskObject $id $Title $Instruction @($Accept) @($DependsOn) @($Relation) @($Retrieval) @($Evidence) $Provider $Role ([bool]$HumanGate);$sizeValue=if($Size){$Size.ToLowerInvariant()}else{'small'};if(@('tiny','small','medium','large')-notcontains$sizeValue){throw "Invalid -Size '$Size'."}
    $outputKindValue=if($OutputKind){$OutputKind.ToLowerInvariant()}else{'change'};if(@('change','document','state-update','research','diagnosis','answer','none','no-change')-notcontains$outputKindValue){throw "Invalid -OutputKind '$OutputKind'."};Set-SCProperty $taskObj 'size' $sizeValue;Set-SCProperty $taskObj 'outputKind' $outputKindValue;Set-SCProperty $taskObj 'sources' @($Source);Set-SCProperty $taskObj 'intentRefs' @($IntentRef);Set-SCProperty $taskObj 'capabilityProfile' $CapabilityProfile;Set-SCProperty $taskObj 'toolPolicy' (New-SCTaskToolPolicy $ToolAllow $ToolDeny);Set-SCProperty $taskObj 'implications' @();Set-SCProperty $taskObj 'proofObligations' @();Set-SCProperty $taskObj 'refinementStatus' 'pending';Set-SCProperty $taskObj 'refinementDepth' 0;Set-SCProperty $taskObj 'parentTaskId' $null;Set-SCProperty $taskObj 'childTaskIds' @()
    Save-SCTask $taskObj;Update-SCReadiness;Add-SCEvent 'task.created' $Title @{taskId=$id;size=$sizeValue;capabilityProfile=$CapabilityProfile;toolPolicy=$taskObj.toolPolicy};[Console]::Out.WriteLine($id)
}

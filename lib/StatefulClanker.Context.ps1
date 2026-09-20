function Get-SCRecentEvents([int]$Count=12,[int]$BudgetChars=4000) {
    $path=Get-SCPath 'events.jsonl';if(-not(Test-Path $path)){return @()};$remaining=$BudgetChars;$selected=New-Object Collections.ArrayList
    $lines=@(Get-Content -LiteralPath $path|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Select-Object -Last $Count)
    for($i=$lines.Count-1;$i-ge 0-and$remaining-gt 0;$i--){$line=[string]$lines[$i];$take=[Math]::Min($line.Length,$remaining);$fragment=if($take-gt 0){$line.Substring(0,$take)}else{''};try{$evt=$fragment|ConvertFrom-Json}catch{$evt=[ordered]@{type='truncated_event';message=$fragment}};[void]$selected.Insert(0,$evt);$remaining-=$take}
    return @($selected)
}
function Get-SCExecutionPolicyHash { return Get-SCHashString (ConvertTo-SCJson (Get-SCConfig) 20) }
function Get-SCActivePlanIntent($State) {
    if($null-eq$State-or-not$State.activePlanId){return $null}
    $plan=Read-SCJson (Get-SCPath ("plans/{0}.json"-f$State.activePlanId))
    if($null-eq$plan){return [ordered]@{id=$State.activePlanId;name=$null;summary=$null}}
    return [ordered]@{id=$plan.id;name=$plan.name;summary=$plan.summary}
}
function Get-SCDependencySummary($Task) {
    $cfg=Get-SCConfig;$remaining=if($cfg.PSObject.Properties['dependencyResultBudgetChars']){[int]$cfg.dependencyResultBudgetChars}else{8000};$out=@()
    foreach($dep in @($Task.dependsOn)){if([string]::IsNullOrWhiteSpace([string]$dep)){continue};$dependency=Get-SCTask ([string]$dep);$summary=[ordered]@{id=$dependency.id;title=$dependency.title;status=$dependency.status;definitionHash=Get-SCTaskDefinitionHash $dependency;latestRunId=$dependency.latestRunId;latestValidationId=$dependency.latestValidationId;resultTruncated=$false};if($dependency.latestRunId){$receipt=Read-SCJson (Get-SCPath ("runs/{0}.json"-f$dependency.latestRunId));if($receipt-and$remaining-gt 0){$text=[string]$receipt.stdout;$take=[Math]::Min($text.Length,$remaining);$summary.result=if($take-gt 0){$text.Substring(0,$take)}else{''};$summary.resultTruncated=($text.Length-gt$take);$remaining-=$take}elseif($receipt){$summary.resultTruncated=$true}};$out+=$summary}
    return $out
}
function Resolve-SCSelector([string]$Pattern) {
    $matches=@();try{if($Pattern-match'[*?\[]'){$matches=@(Get-ChildItem -Path $Pattern -File -Recurse -ErrorAction SilentlyContinue)}elseif(Test-Path -LiteralPath $Pattern -PathType Leaf){$matches=@(Get-Item -LiteralPath $Pattern)}elseif(Test-Path -LiteralPath $Pattern -PathType Container){$matches=@(Get-ChildItem -LiteralPath $Pattern -File -Recurse -ErrorAction SilentlyContinue)}}catch{$matches=@()};return @($matches)
}
function Get-SCRetrievalPacket($Task) {
    $cfg=Get-SCConfig;$budget=if($cfg.PSObject.Properties['workingSetBudgetChars']){[int]$cfg.workingSetBudgetChars}else{24000};$maxFile=if($cfg.PSObject.Properties['maxFileChars']){[int]$cfg.maxFileChars}else{8000};$remaining=$budget;$items=@();$seen=@{};$unmatched=@();$selectors=@()
    foreach($s in @($Task.evidence)){if(-not[string]::IsNullOrWhiteSpace([string]$s)){$selectors+=[ordered]@{selector=[string]$s;kind='evidence';authority='evidence'}}}
    foreach($s in @($Task.retrieval)){if(-not[string]::IsNullOrWhiteSpace([string]$s)){$selectors+=[ordered]@{selector=[string]$s;kind='retrieval';authority='context'}}}
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
    $state=Get-SCState;$cfg=Get-SCConfig;$compilationId=New-SCId 'compile';$retrieved=Get-SCRetrievalPacket $Task;$dependencies=@(Get-SCDependencySummary $Task);$eventCount=if($cfg.PSObject.Properties['recentEventCount']){[int]$cfg.recentEventCount}else{12};$eventBudget=if($cfg.PSObject.Properties['recentEventBudgetChars']){[int]$cfg.recentEventBudgetChars}else{4000};$taskControlRevision=Get-SCTaskControlRevision $Task;$policyHash=Get-SCExecutionPolicyHash
    $intent=Get-SCIntentContract;$intentHash=Get-SCIntentHash $intent;$planIntent=Get-SCActivePlanIntent $state;$planIntentHash=Get-SCHashString (ConvertTo-SCJson $planIntent 8)
    $readSet=[ordered]@{projectGoalHash=Get-SCHashString ([string]$state.goal);activePlanId=$state.activePlanId;planIntentHash=$planIntentHash;directionRevision=$state.directionRevision;intentRevision=[int]$intent.revision;intentHash=$intentHash;executionPolicyHash=$policyHash;taskId=$Task.id;taskControlRevision=$taskControlRevision;taskDefinitionHash=Get-SCTaskDefinitionHash $Task;dependencies=@($dependencies|ForEach-Object{[ordered]@{id=$_.id;status=$_.status;definitionHash=$_.definitionHash;latestRunId=$_.latestRunId;latestValidationId=$_.latestValidationId}});files=@($retrieved.items|ForEach-Object{[ordered]@{path=$_.path;sha256=$_.sha256;authority=$_.authority}})}
    $inputFingerprint=Get-SCHashString (ConvertTo-SCJson $readSet 20)
    $contract=@('Perform only this bounded task.','The authoritative intent contract is read-only to workers. Never edit, replace, reinterpret away, or weaken it.','If task instructions conflict with the intent contract, emit INTENT_CONFLICT: <specific conflict> and stop rather than choosing your own interpretation.','If the intent contract is ambiguous or insufficient for a material choice, emit INTENT_QUESTION: <specific question> and stop rather than guessing.','Treat durable state and project files as authoritative.','Report files changed, commands run, failures, and unresolved risks.','Do not claim verification you did not perform.','If required state or evidence is missing, emit CONTEXT_REQUEST: <specific missing state> rather than guessing.')
        $latestFeedback = $null
    if ($Task.PSObject.Properties['latestCritiqueId'] -and $Task.latestCritiqueId) {
        try {
            $c = Read-SCJson (Get-SCPath ("critiques/{0}.json" -f $Task.latestCritiqueId))
            if ($c) { $latestFeedback = [ordered]@{ verdict = $c.verdict; feedback = $c.stdout } }
        } catch {}
    }
    $taskRole=if($Task.PSObject.Properties['role']-and$Task.role){[string]$Task.role}else{'worker'}
    $ir=[ordered]@{schemaVersion=2;compilationId=$compilationId;compiledAt=(Get-Date).ToUniversalTime().ToString('o');project=[ordered]@{goal=$state.goal;root=Get-SCRoot;activePlan=$planIntent;directionRevision=$state.directionRevision;stateRevision=$state.revision;executionPolicyHash=$policyHash;intent=[ordered]@{revision=[int]$intent.revision;hash=$intentHash;authority='orchestrator-owned; worker read-only';contract=$intent}};task=[ordered]@{id=$Task.id;title=$Task.title;instruction=$Task.instruction;role=$taskRole;outputKind=if($Task.PSObject.Properties['outputKind']){[string]$Task.outputKind}else{'change'};controlRevision=$taskControlRevision;acceptance=@($Task.acceptance);dependsOn=@($Task.dependsOn);relations=if($Task.PSObject.Properties['relations']){@($Task.relations)}else{@()};latestFeedback=$latestFeedback};dependencies=$dependencies;sources=[ordered]@{retrieved=$retrieved;recentEvents=@(Get-SCRecentEvents $eventCount $eventBudget)};outputContract=$contract}
    $contextFingerprint=Get-SCHashString (ConvertTo-SCJson $ir 24)
    $receipt=[ordered]@{schemaVersion=2;id=$compilationId;taskId=$Task.id;compiledAt=$ir.compiledAt;inputFingerprint=$inputFingerprint;contextFingerprint=$contextFingerprint;readSet=$readSet;retrievalStats=[ordered]@{budgetChars=$retrieved.budgetChars;usedChars=$retrieved.usedChars;budgetExhausted=$retrieved.budgetExhausted;unmatchedSelectors=@($retrieved.unmatchedSelectors);itemCount=@($retrieved.items).Count;truncatedCount=@($retrieved.items|Where-Object{$_.truncated}).Count};ir=$ir}
    Write-SCJson (Get-SCPath ("compilations/{0}.json"-f$compilationId)) $receipt;Set-SCProperty $Task 'latestCompilationId' $compilationId;Save-SCTask $Task
    if($receipt.retrievalStats.unmatchedSelectors.Count-gt 0){Add-SCEvent 'context.selector_unmatched' "Compilation $compilationId had unmatched selectors." @{taskId=$Task.id;compilationId=$compilationId;selectors=@($receipt.retrievalStats.unmatchedSelectors)}}
    return $receipt
}
function Test-SCCompilationFreshness($Compilation,[string]$Mode='commit') {
    $reasons=@()
    <# These reads take the cross-process state lock, same as every writer, because
       Write-SCJson's atomic replace is not instantaneous: an unlocked reader can
       transiently observe the target missing mid-replace, which an unwrapped
       Read-SCJson surfaces as a spurious "unavailable" rather than the current
       (or previous) committed content. #>
    try{$state=Invoke-SCLocked { Read-SCJson (Get-SCPath 'state.json') }}catch{$state=$null}
    try{$task=Invoke-SCLocked { Read-SCJson (Get-SCPath ("tasks/{0}.json"-f$Compilation.taskId)) }}catch{$task=$null}
    try{$intent=Invoke-SCLocked { Read-SCJson (Get-SCPath 'intent/contract.json') }}catch{$intent=$null}
    if($null-eq$state){$reasons+='project state unavailable during freshness check';return [ordered]@{fresh=$false;mode=$Mode;checkedAt=(Get-Date).ToUniversalTime().ToString('o');reasons=@($reasons)}}
    if($null-eq$task){$reasons+='task unavailable during freshness check';return [ordered]@{fresh=$false;mode=$Mode;checkedAt=(Get-Date).ToUniversalTime().ToString('o');reasons=@($reasons)}}
    $planIntent=Get-SCActivePlanIntent $state
    if((Get-SCHashString ([string]$state.goal))-ne[string]$Compilation.readSet.projectGoalHash){$reasons+='project goal changed'}
    if([string]$state.activePlanId-ne[string]$Compilation.readSet.activePlanId){$reasons+='active plan changed'}
    if((Get-SCHashString (ConvertTo-SCJson $planIntent 8))-ne[string]$Compilation.readSet.planIntentHash){$reasons+='active plan intent changed'}
    if([int]$state.directionRevision-ne[int]$Compilation.readSet.directionRevision){$reasons+='human direction changed'}
    if($null-eq$intent-or[int]$intent.revision-ne[int]$Compilation.readSet.intentRevision-or(Get-SCIntentHash $intent)-ne[string]$Compilation.readSet.intentHash){$reasons+='authoritative intent changed'}
    if((Get-SCExecutionPolicyHash)-ne[string]$Compilation.readSet.executionPolicyHash){$reasons+='execution policy/config changed'}
    if((Get-SCTaskControlRevision $task)-ne[int]$Compilation.readSet.taskControlRevision){$reasons+='human task control changed'}
    if((Get-SCTaskDefinitionHash $task)-ne[string]$Compilation.readSet.taskDefinitionHash){$reasons+='task definition changed'}
    foreach($depRead in @($Compilation.readSet.dependencies)){
        try{$dep=Invoke-SCLocked { Read-SCJson (Get-SCPath ("tasks/{0}.json"-f$depRead.id)) }}catch{$dep=$null}
        if($null-eq$dep){$reasons+="dependency missing: $($depRead.id)";continue}
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
    return "You are a cold-start StatefulClanker worker. The compiled packet is a temporary projection; durable state and project files are authoritative. The project intent contract inside the packet is orchestrator-owned and READ-ONLY: never modify or weaken it. Raise INTENT_QUESTION or INTENT_CONFLICT instead of guessing or changing intent. FILESYSTEM BOUNDARY: operate only inside the current project/worktree. Do not read or write project data through parent, absolute, user-profile, temp, or other outside paths; do not mutate .statefulclanker or .git control state directly; and do not terminate StatefulClanker processes. Installed executables may live outside the project, but their file arguments must remain inside the project.`r`n`r`nSTATEFULCLANKER COMPILED CONTEXT`r`n================================`r`n$(ConvertTo-SCJson $Compilation.ir 22)`r`n`r`nComplete only this bounded task."
}
function New-SCReviewPrompt($Task,$Run,$Compilation,[string]$Stage) {
    $rule=if($Stage-eq'critic'){'Check omissions, contradictions, risky assumptions, regressions, whether the worker addressed the bounded task, and especially whether it preserved the authoritative intent contract.'}else{'Judge acceptance criteria and intent-contract compliance from the compiled evidence and worker receipt. Do not trust the worker claim without evidence.'}
    return "You are the $Stage in StatefulClanker. You did not perform the work.`r`n$rule`r`n`r`nCOMPILED CONTEXT:`r`n$(ConvertTo-SCJson $Compilation.ir 22)`r`n`r`nWORKER RECEIPT:`r`n$(ConvertTo-SCJson ([ordered]@{runId=$Run.id;exitCode=$Run.exitCode;stdout=$Run.stdout;stderr=$Run.stderr;contextRequests=if($Run.PSObject.Properties['contextRequests']){@($Run.contextRequests)}else{@()}}) 12)`r`n`r`nFirst non-empty line MUST be exactly VERDICT: PASS or VERDICT: FAIL. Then explain evidence briefly."
}


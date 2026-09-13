function Get-SCRecentEvents([int]$Count=12,[int]$BudgetChars=4000) {
    $path=Get-SCPath 'events.jsonl';if(-not(Test-Path $path)){return @()};$remaining=$BudgetChars;$selected=New-Object Collections.ArrayList
    $lines=@(Get-Content -LiteralPath $path|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Select-Object -Last $Count)
    for($i=$lines.Count-1;$i-ge 0-and$remaining-gt 0;$i--){$line=[string]$lines[$i];$take=[Math]::Min($line.Length,$remaining);$fragment=if($take-gt 0){$line.Substring(0,$take)}else{''};try{$evt=$fragment|ConvertFrom-Json}catch{$evt=[ordered]@{type='truncated_event';message=$fragment}};[void]$selected.Insert(0,$evt);$remaining-=$take}
    return @($selected)
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
    $state=Get-SCState;$cfg=Get-SCConfig;$compilationId=New-SCId 'compile';$retrieved=Get-SCRetrievalPacket $Task;$dependencies=@(Get-SCDependencySummary $Task);$eventCount=if($cfg.PSObject.Properties['recentEventCount']){[int]$cfg.recentEventCount}else{12};$eventBudget=if($cfg.PSObject.Properties['recentEventBudgetChars']){[int]$cfg.recentEventBudgetChars}else{4000}
    $readSet=[ordered]@{projectGoalHash=Get-SCHashString ([string]$state.goal);activePlanId=$state.activePlanId;taskId=$Task.id;taskDefinitionHash=Get-SCTaskDefinitionHash $Task;dependencies=@($dependencies|ForEach-Object{[ordered]@{id=$_.id;status=$_.status;definitionHash=$_.definitionHash;latestRunId=$_.latestRunId;latestValidationId=$_.latestValidationId}});files=@($retrieved.items|ForEach-Object{[ordered]@{path=$_.path;sha256=$_.sha256;authority=$_.authority}})}
    $inputFingerprint=Get-SCHashString (ConvertTo-SCJson $readSet 20)
    $contract=@('Perform only this bounded task.','Treat durable state and project files as authoritative.','Report files changed, commands run, failures, and unresolved risks.','Do not claim verification you did not perform.','If required state or evidence is missing, emit CONTEXT_REQUEST: <specific missing state> rather than guessing.')
    $ir=[ordered]@{schemaVersion=1;compilationId=$compilationId;compiledAt=(Get-Date).ToUniversalTime().ToString('o');project=[ordered]@{goal=$state.goal;root=Get-SCRoot;activePlanId=$state.activePlanId;stateRevision=$state.revision};task=[ordered]@{id=$Task.id;title=$Task.title;instruction=$Task.instruction;role=$Task.role;acceptance=@($Task.acceptance);dependsOn=@($Task.dependsOn);relations=if($Task.PSObject.Properties['relations']){@($Task.relations)}else{@()}};dependencies=$dependencies;sources=[ordered]@{retrieved=$retrieved;recentEvents=@(Get-SCRecentEvents $eventCount $eventBudget)};outputContract=$contract}
    $receipt=[ordered]@{schemaVersion=1;id=$compilationId;taskId=$Task.id;compiledAt=$ir.compiledAt;inputFingerprint=$inputFingerprint;readSet=$readSet;retrievalStats=[ordered]@{budgetChars=$retrieved.budgetChars;usedChars=$retrieved.usedChars;budgetExhausted=$retrieved.budgetExhausted;unmatchedSelectors=@($retrieved.unmatchedSelectors);itemCount=@($retrieved.items).Count;truncatedCount=@($retrieved.items|Where-Object{$_.truncated}).Count};ir=$ir}
    Write-SCJson (Get-SCPath ("compilations/{0}.json"-f$compilationId)) $receipt;Set-SCProperty $Task 'latestCompilationId' $compilationId;Save-SCTask $Task
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

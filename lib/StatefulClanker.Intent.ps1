function Ensure-SCIntentLayout {
    Assert-SCInitialized
    $dir=Get-SCPath 'intent'
    $history=Get-SCPath 'intent/history'
    if(-not(Test-Path -LiteralPath $dir)){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    if(-not(Test-Path -LiteralPath $history)){New-Item -ItemType Directory -Force -Path $history|Out-Null}
    $escalations=Get-SCPath 'intent/escalations.jsonl'
    if(-not(Test-Path -LiteralPath $escalations)){''|Set-Content -LiteralPath $escalations -Encoding UTF8}
}
function New-SCIntentContract {
    $state=Get-SCState
    return [ordered]@{
        schemaVersion=1
        revision=0
        updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        objective=[string]$state.goal
        requirements=@()
        constraints=@()
        invariants=@()
        nonGoals=@()
        decisions=@()
        preferences=@()
        openQuestions=@()
        successDefinition=''
        authority=[ordered]@{owner='orchestrator';workers='read-only'}
    }
}
function Get-SCIntentContract {
    Ensure-SCIntentLayout
    $path=Get-SCPath 'intent/contract.json'
    $contract=Read-SCJson $path
    if($null-eq$contract){
        $contract=New-SCIntentContract
        Write-SCJson $path $contract
        Write-SCJson (Get-SCPath 'intent/history/revision-0000.json') $contract
        Add-SCEvent 'intent.initialized' 'Initialized authoritative intent contract.' @{revision=0}
    }
    return $contract
}
function Get-SCIntentHash($Contract=$null) {
    if($null-eq$Contract){$Contract=Get-SCIntentContract}
    return Get-SCHashString (ConvertTo-SCJson $Contract 24)
}
function Assert-SCIntentShape($Contract) {
    if($null-eq$Contract){throw 'Intent contract is empty.'}
    foreach($field in @('objective','requirements','constraints','invariants','nonGoals','decisions','preferences','openQuestions','successDefinition')){
        if(-not$Contract.PSObject.Properties[$field]){throw "Intent contract missing required field '$field'."}
    }
}
function Save-SCIntentRevision($Contract,[string]$Reason) {
    Assert-SCIntentShape $Contract
    Ensure-SCIntentLayout
    $current=Get-SCIntentContract
    $next=[int]$current.revision+1
    Set-SCProperty $Contract 'schemaVersion' 1
    Set-SCProperty $Contract 'revision' $next
    Set-SCProperty $Contract 'updatedAt' ((Get-Date).ToUniversalTime().ToString('o'))
    Set-SCProperty $Contract 'authority' ([ordered]@{owner='orchestrator';workers='read-only'})
    $historyPath=Get-SCPath ("intent/history/revision-{0:d4}.json"-f$next)
    Write-SCJson $historyPath $Contract
    Write-SCJson (Get-SCPath 'intent/contract.json') $Contract
    $state=Get-SCState
    $direction=if($state.PSObject.Properties['directionRevision']){[int]$state.directionRevision}else{0}
    Set-SCProperty $state 'directionRevision' ($direction+1)
    Set-SCProperty $state 'intentRevision' $next
    Save-SCState $state
    Add-SCEvent 'intent.revised' "Intent contract revised to $next." @{revision=$next;reason=$Reason;hash=(Get-SCIntentHash $Contract)}
    return $Contract
}
function Replace-SCIntentContract([string]$Path,[string]$Reason) {
    if([string]::IsNullOrWhiteSpace($Path)){throw '-Path required.'}
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Intent file not found: $Path"}
    $contract=Read-SCJson (Resolve-Path -LiteralPath $Path).Path
    $saved=Save-SCIntentRevision $contract $Reason
    Write-Host "Intent revision $($saved.revision) committed."
}
function Show-SCIntent([string]$Mode='show') {
    $contract=Get-SCIntentContract
    switch(([string]$Mode).ToLowerInvariant()){
        'show' { $contract|ConvertTo-SCJson -Depth 24|Write-Host;break }
        'history' {
            Get-ChildItem -LiteralPath (Get-SCPath 'intent/history') -Filter 'revision-*.json' -File|Sort-Object Name|ForEach-Object {
                $c=Read-SCJson $_.FullName
                [pscustomobject]@{revision=$c.revision;updatedAt=$c.updatedAt;objective=$c.objective;path=$_.Name}
            }|Format-Table -AutoSize
            break
        }
        'escalations' {
            Get-Content -LiteralPath (Get-SCPath 'intent/escalations.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json}|Select-Object ts,type,taskId,message|Format-Table -AutoSize
            break
        }
        default { throw "Unknown intent subcommand: $Mode" }
    }
}

# Loaded after StatefulClanker.Execution.ps1. This deliberately overrides the
# original context-only capture function so worker intent ambiguity uses the same
# fail-closed, non-advancing path as a context miss.
function Capture-SCContextRequests($Task,$Run,$Compilation) {
    $requests=@();$context=@();$questions=@();$conflicts=@()
    foreach($line in @(([string]$Run.stdout)-split"`r?`n")){
        if($line-match'^\s*CONTEXT_(?:REQUEST|MISS):\s*(.+?)\s*$'){$context+=$Matches[1];$requests+="CONTEXT: $($Matches[1])";continue}
        if($line-match'^\s*INTENT_QUESTION:\s*(.+?)\s*$'){$questions+=$Matches[1];$requests+="INTENT_QUESTION: $($Matches[1])";continue}
        if($line-match'^\s*INTENT_CONFLICT:\s*(.+?)\s*$'){$conflicts+=$Matches[1];$requests+="INTENT_CONFLICT: $($Matches[1])";continue}
    }
    Set-SCProperty $Run 'contextRequests' @($context)
    Set-SCProperty $Run 'intentQuestions' @($questions)
    Set-SCProperty $Run 'intentConflicts' @($conflicts)
    if($context.Count-gt 0){
        Ensure-SCTelemetryLayout
        foreach($request in $context){$record=[ordered]@{ts=(Get-Date).ToUniversalTime().ToString('o');taskId=$Task.id;runId=$Run.id;compilationId=$Compilation.id;inputFingerprint=$Compilation.inputFingerprint;request=$request};((ConvertTo-SCJson $record 8) -replace "`r?`n",'')|Add-Content -LiteralPath (Get-SCPath 'telemetry/context-faults.jsonl') -Encoding UTF8}
        Add-SCEvent 'context.fault' 'Worker requested missing context.' @{taskId=$Task.id;runId=$Run.id;compilationId=$Compilation.id;requests=@($context)}
    }
    if($questions.Count-gt 0-or$conflicts.Count-gt 0){
        Ensure-SCIntentLayout
        foreach($q in $questions){$record=[ordered]@{ts=(Get-Date).ToUniversalTime().ToString('o');type='question';taskId=$Task.id;runId=$Run.id;compilationId=$Compilation.id;intentRevision=$Compilation.readSet.intentRevision;message=$q};((ConvertTo-SCJson $record 8)-replace"`r?`n",'')|Add-Content -LiteralPath (Get-SCPath 'intent/escalations.jsonl') -Encoding UTF8}
        foreach($c in $conflicts){$record=[ordered]@{ts=(Get-Date).ToUniversalTime().ToString('o');type='conflict';taskId=$Task.id;runId=$Run.id;compilationId=$Compilation.id;intentRevision=$Compilation.readSet.intentRevision;message=$c};((ConvertTo-SCJson $record 8)-replace"`r?`n",'')|Add-Content -LiteralPath (Get-SCPath 'intent/escalations.jsonl') -Encoding UTF8}
        Add-SCEvent 'intent.escalated' 'Worker escalated authoritative intent.' @{taskId=$Task.id;runId=$Run.id;compilationId=$Compilation.id;questions=@($questions);conflicts=@($conflicts)}
    }
    return @($requests)
}

# Prompt construction uses the exact persisted compilation receipt instead of
# serializing the live PowerShell object graph again. The persisted receipt is the
# provenance-bearing snapshot that actually defines this invocation.
function Get-SCPersistedCompilationText($Compilation) {
    $path=Get-SCPath ("compilations/{0}.json"-f$Compilation.id)
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing compilation receipt: $($Compilation.id)"}
    return Get-Content -Raw -LiteralPath $path
}
function New-SCWorkerPrompt($Compilation) {
    $compiled=Get-SCPersistedCompilationText $Compilation
    return "You are a cold-start StatefulClanker worker. The compiled receipt below is the exact temporary projection for this invocation. The project intent contract inside it is orchestrator-owned and READ-ONLY: never modify, weaken, or reinterpret it. Raise INTENT_QUESTION or INTENT_CONFLICT instead of guessing or changing intent.`r`n`r`nSTATEFULCLANKER COMPILED RECEIPT`r`n=================================`r`n$compiled`r`n`r`nComplete only this bounded task."
}
function New-SCReviewPrompt($Task,$Run,$Compilation,[string]$Stage) {
    $rule=if($Stage-eq'critic'){'Check omissions, contradictions, risky assumptions, regressions, whether the worker addressed the bounded task, and especially whether it preserved the authoritative intent contract.'}else{'Judge acceptance criteria and intent-contract compliance from the compiled evidence and worker receipt. Do not trust the worker claim without evidence.'}
    $compiled=Get-SCPersistedCompilationText $Compilation
    $worker=ConvertTo-SCJson ([ordered]@{runId=$Run.id;exitCode=$Run.exitCode;stdout=$Run.stdout;stderr=$Run.stderr;contextRequests=if($Run.PSObject.Properties['contextRequests']){@($Run.contextRequests)}else{@()};intentQuestions=if($Run.PSObject.Properties['intentQuestions']){@($Run.intentQuestions)}else{@()};intentConflicts=if($Run.PSObject.Properties['intentConflicts']){@($Run.intentConflicts)}else{@()}}) 12
    return "You are the $Stage in StatefulClanker. You did not perform the work.`r`n$rule`r`n`r`nCOMPILED RECEIPT:`r`n$compiled`r`n`r`nWORKER RECEIPT:`r`n$worker`r`n`r`nFirst non-empty line MUST be exactly VERDICT: PASS or VERDICT: FAIL. Then explain evidence briefly."
}

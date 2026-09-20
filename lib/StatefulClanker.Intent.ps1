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
    $directives=Get-SCCurrentDirectiveSnapshot
    return [ordered]@{
        schemaVersion=2
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
        directiveRevision=[int]$directives.revision
        directiveHash=[string]$directives.hash
        authority=[ordered]@{owner='orchestrator';workers='read-only';humanDirectives='latest direct human word wins within each directive scope'}
    }
}
function Get-SCIntentContract {
    Ensure-SCIntentLayout
    $path=Get-SCPath 'intent/contract.json'
    $contract=Read-SCJson $path
    if($null-eq$contract){
        # Concurrent cycles can all observe a missing contract at once. Bootstrap
        # under the cross-process state lock and re-check after acquiring it, so
        # only the first cycle writes the initial contract and every other cycle
        # reads that same persisted copy instead of clobbering it with its own
        # freshly time-stamped one (which would fail every sibling's freshness
        # check on the intent hash).
        #
        # The returned value is always re-read from disk rather than handed back
        # as the in-memory object that was just written. ConvertFrom-Json parses
        # an ISO-8601 string like 'updatedAt' into a [DateTime], and ConvertTo-Json
        # trims a trailing-zero fractional-second digit when serializing it back
        # (".5811720Z" -> ".581172Z"). Handing back the pre-serialization string
        # would let this cycle hash a byte sequence its own later re-read can never
        # reproduce, so its own freshness check would fail against its own write.
        Invoke-SCLocked {
            $existing=Read-SCJson $path
            if($null-ne$existing){return}
            $created=New-SCIntentContract
            Write-SCJson $path $created
            Write-SCJson (Get-SCPath 'intent/history/revision-0000.json') $created
            Add-SCEvent 'intent.initialized' 'Initialized authoritative intent contract.' @{revision=0;directiveRevision=$created.directiveRevision;directiveHash=$created.directiveHash}
        } | Out-Null
        $contract=Read-SCJson $path
    } else {
        # Migration metadata only: old contracts predate current-directive separation.
        # Do not create a semantic intent revision merely to add these fields.
        $changed=$false
        if(-not$contract.PSObject.Properties['directiveRevision']){Set-SCProperty $contract 'directiveRevision' 0;$changed=$true}
        if(-not$contract.PSObject.Properties['directiveHash']){Set-SCProperty $contract 'directiveHash' (Get-SCHashString (ConvertTo-SCJson @() 16));$changed=$true}
        if($changed){Set-SCProperty $contract 'schemaVersion' 2;Write-SCJson $path $contract}
    }
    return $contract
}
function Get-SCIntentHash($Contract=$null) {
    if($null-eq$Contract){$Contract=Get-SCIntentContract}
    return Get-SCHashString (ConvertTo-SCJson $Contract 24)
}
function Assert-SCIntentShape($Contract) {
    if($null-eq$Contract){throw 'Intent contract is empty.'}
    $required = @('objective','requirements','constraints','invariants','nonGoals','decisions','preferences','openQuestions','successDefinition')
    $missing = @()
    foreach($field in $required){
        if(-not$Contract.PSObject.Properties[$field]){$missing += $field}
    }
    if($missing.Count -gt 0){
        $fieldsList = ($missing | ForEach-Object { "'$_'" }) -join ', '
        throw "Intent contract missing required field(s): $fieldsList. Required contract fields are: $($required -join ', ')."
    }
}
function Save-SCIntentRevision($Contract,[string]$Reason) {
    Assert-SCIntentShape $Contract
    Ensure-SCIntentLayout
    $current=Get-SCIntentContract
    $directives=Get-SCCurrentDirectiveSnapshot
    $next=[int]$current.revision+1
    Set-SCProperty $Contract 'schemaVersion' 2
    Set-SCProperty $Contract 'revision' $next
    Set-SCProperty $Contract 'updatedAt' ((Get-Date).ToUniversalTime().ToString('o'))
    Set-SCProperty $Contract 'directiveRevision' ([int]$directives.revision)
    Set-SCProperty $Contract 'directiveHash' ([string]$directives.hash)
    Set-SCProperty $Contract 'authority' ([ordered]@{owner='orchestrator';workers='read-only';humanDirectives='latest direct human word wins within each directive scope'})
    $historyPath=Get-SCPath ("intent/history/revision-{0:d4}.json"-f$next)
    Write-SCJson $historyPath $Contract
    Write-SCJson (Get-SCPath 'intent/contract.json') $Contract
    $state=Get-SCState
    $direction=if($state.PSObject.Properties['directionRevision']){[int]$state.directionRevision}else{0}
    Set-SCProperty $state 'directionRevision' ($direction+1)
    Set-SCProperty $state 'intentRevision' $next
    Set-SCProperty $state 'directiveReconciledRevision' ([int]$directives.revision)
    Set-SCProperty $state 'directiveReconciliationRequired' $false
    Set-SCProperty $state 'pendingDirectiveIds' @()
    Save-SCState $state
    Add-SCEvent 'intent.revised' "Intent contract revised to $next and reconciled with human directives." @{revision=$next;reason=$Reason;hash=(Get-SCIntentHash $Contract);directiveRevision=$directives.revision;directiveHash=$directives.hash}
    return $Contract
}
function Replace-SCIntentContract([string]$Path,[string]$Reason) {
    if([string]::IsNullOrWhiteSpace($Path)){throw '-Path required.'}
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Intent file not found: $Path"}
    $contract=Read-SCJson (Resolve-Path -LiteralPath $Path).Path
    $saved=Save-SCIntentRevision $contract $Reason
    Write-Host "Intent revision $($saved.revision) committed; reconciled directive revision $($saved.directiveRevision)."
}
function Show-SCIntent([string]$Mode='show') {
    $contract=Get-SCIntentContract
    switch(([string]$Mode).ToLowerInvariant()){
        'show' { $contract|ConvertTo-SCJson -Depth 24|Write-Host;break }
        'history' {
            Get-ChildItem -LiteralPath (Get-SCPath 'intent/history') -Filter 'revision-*.json' -File|Sort-Object Name|ForEach-Object {
                $c=Read-SCJson $_.FullName
                [pscustomobject]@{revision=$c.revision;updatedAt=$c.updatedAt;directiveRevision=if($c.PSObject.Properties['directiveRevision']){$c.directiveRevision}else{$null};objective=$c.objective;path=$_.Name}
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

function Capture-SCContextRequests($Task,$Run,$Compilation) {
    $requests=@();$context=@();$questions=@();$conflicts=@()
    foreach($line in @(([string]$Run.stdout)-split"`r?`n")){
        if($line-match'^\s*CONTEXT_(?:REQUEST|MISS):\s*(.+?)\s*$'){$context+=$Matches[1];$requests+="CONTEXT: $($Matches[1])";continue}
        if($line-match'^\s*INTENT_QUESTION:\s*(.+?)\s*$'){$questions+=$Matches[1];$requests+="INTENT_QUESTION: $($Matches[1])";continue}
        if($line-match'^\s*INTENT_CONFLICT:\s*(.+?)\s*$'){$conflicts+=$Matches[1];$requests+="INTENT_CONFLICT: $($Matches[1])";continue}
    }
    Set-SCProperty $Run 'contextRequests' @($context)
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

function Get-SCPersistedCompilationText($Compilation) {
    $path=Get-SCPath ("compilations/{0}.json"-f$Compilation.id)
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing compilation receipt: $($Compilation.id)"}
    return Get-Content -Raw -LiteralPath $path
}
function New-SCWorkerPrompt($Compilation) {
    $compiled=Get-SCPersistedCompilationText $Compilation
    return "You are a cold-start StatefulClanker worker. The compiled receipt below is the exact temporary projection for this invocation. CURRENT HUMAN DIRECTIVES are the latest direct human authority and supersede historical wording in their scopes. The normalized intent contract is orchestrator-owned and READ-ONLY: never modify, weaken, or silently reinterpret it. If a directive and intent clause appear inconsistent, emit INTENT_CONFLICT. If either remains materially ambiguous after inspecting the current directive/source, emit INTENT_QUESTION rather than guessing.`r`n`r`nSTATEFULCLANKER COMPILED RECEIPT`r`n=================================`r`n$compiled`r`n`r`nComplete only this bounded task."
}
function New-SCReviewPrompt($Task,$Run,$Compilation,[string]$Stage) {
    $rule=if($Stage-eq'critic'){'Check omissions, contradictions, risky assumptions, regressions, whether the worker addressed the bounded task, and especially whether it preserved current human directives plus the reconciled intent contract.'}else{'Judge acceptance criteria and compliance with current human directives plus reconciled intent from the compiled evidence and worker receipt. Do not trust the worker claim without evidence.'}
    $compiled=Get-SCPersistedCompilationText $Compilation
    $worker=ConvertTo-SCJson ([ordered]@{
        runId=$Run.id;exitCode=$Run.exitCode;stdout=$Run.stdout;stderr=$Run.stderr
        workerSessionId=if($Run.PSObject.Properties['workerSessionId']){$Run.workerSessionId}else{$null}
        candidatePreflight=if($Run.PSObject.Properties['candidatePreflight']){$Run.candidatePreflight}else{$null}
        candidateClaim=if($Run.PSObject.Properties['candidateClaim']){$Run.candidateClaim}else{$null}
        contextRequests=if($Run.PSObject.Properties['contextRequests']){@($Run.contextRequests)}else{@()}
    }) 14
    return "You are the $Stage in StatefulClanker. You did not perform the work.`r`n$rule`r`n`r`nCOMPILED RECEIPT:`r`n$compiled`r`n`r`nWORKER RECEIPT:`r`n$worker`r`n`r`nFirst non-empty line MUST be exactly VERDICT: PASS or VERDICT: FAIL. Then explain evidence briefly."
}

$script:SCInvokeProviderBase=${function:Invoke-SCProvider}
function Invoke-SCProvider($Task,[string]$Prompt,[string]$Stage,[string]$ProviderOverride,[string]$ParentAgentId=$null,$Compilation=$null) {
    $raw=& $script:SCInvokeProviderBase $Task $Prompt $Stage $ProviderOverride $ParentAgentId $Compilation
    $normalized=[ordered]@{
        schemaVersion=[int]$raw.schemaVersion
        id=[string]$raw.id
        agentId=[string]$raw.agentId
        taskId=[string]$raw.taskId
        stage=[string]$raw.stage
        provider=[string]$raw.provider
        compilationId=if($null-eq$raw.compilationId){$null}else{[string]$raw.compilationId}
        inputFingerprint=if($null-eq$raw.inputFingerprint){$null}else{[string]$raw.inputFingerprint}
        command=[string]$raw.command
        args=@($raw.args|ForEach-Object{[string]$_})
        promptPath=[string]$raw.promptPath
        startedAt=[string]$raw.startedAt
        endedAt=[string]$raw.endedAt
        durationSeconds=[double]$raw.durationSeconds
        exitCode=[int]$raw.exitCode
        stdout=[string]$raw.stdout
        stderr=[string]$raw.stderr
        verdict=$null
    }
    return [pscustomobject]$normalized
}

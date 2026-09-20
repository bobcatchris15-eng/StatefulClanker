function Resolve-SCProvider($Task,[string]$Override,[string]$Stage='worker') {
    $cfg=Get-SCConfig;$def=if($cfg.PSObject.Properties['defaultProvider']){[string]$cfg.defaultProvider}else{''}
    $prioritized=@();if($cfg.PSObject.Properties['providers']-and$cfg.providers){
        foreach($p in $cfg.providers.PSObject.Properties){
            $entry=$p.Value;$dis=($entry.PSObject.Properties['disabled']-and[bool]$entry.disabled)
            if(-not$dis){
                $pri=if($entry.PSObject.Properties['priority']-and$null-ne$entry.priority){[int]$entry.priority}elseif($p.Name-eq$def){0}else{100}
                $prioritized+=[pscustomobject]@{Name=$p.Name;Priority=$pri;IsDefault=($p.Name-eq$def);Config=$entry}
            }
        }
    }
    $prioritized=@($prioritized|Sort-Object Priority,{if($_.IsDefault){0}else{1}},Name)
    if($Override){
        $property=if($cfg.providers){$cfg.providers.PSObject.Properties[$Override]}else{$null}
        if($null-eq$property){throw "Provider '$Override' not configured."}
        if($property.Value.PSObject.Properties['disabled']-and[bool]$property.Value.disabled){throw "Provider '$Override' is currently disabled in .statefulclanker/config.json."}
        return [ordered]@{name=$Override;config=$property.Value}
    }
    $candidate=$null
    $taskProvider=$null
    $taskSize='small'
    if($Task){
        if($Task -is [System.Collections.IDictionary]){
            if($Task.Contains('provider')-and$Task['provider']){$taskProvider=[string]$Task['provider']}
            if($Task.Contains('size')-and$Task['size']){$taskSize=[string]$Task['size']}
        }else{
            if($Task.PSObject.Properties['provider']-and$Task.provider){$taskProvider=[string]$Task.provider}
            if($Task.PSObject.Properties['size']-and$Task.size){$taskSize=[string]$Task.size}
        }
    }
    if($Stage-eq'critic'-and$cfg.PSObject.Properties['criticProvider']-and$cfg.criticProvider){$candidate=[string]$cfg.criticProvider}
    elseif($Stage-eq'validator'-and$cfg.PSObject.Properties['validatorProvider']-and$cfg.validatorProvider){$candidate=[string]$cfg.validatorProvider}
    elseif($taskProvider){$candidate=$taskProvider}
    elseif($Stage-eq'worker'-and$cfg.PSObject.Properties['providerBySize']-and$cfg.providerBySize){
        $route=$cfg.providerBySize.PSObject.Properties[$taskSize]
        if($route-and-not[string]::IsNullOrWhiteSpace([string]$route.Value)){$candidate=[string]$route.Value}
    }
    if($candidate){
        $prop=if($cfg.providers){$cfg.providers.PSObject.Properties[$candidate]}else{$null}
        if($prop-and-not($prop.Value.PSObject.Properties['disabled']-and[bool]$prop.Value.disabled)){return [ordered]@{name=$candidate;config=$prop.Value}}
    }
    if($prioritized.Count-gt 0){$top=$prioritized[0];return [ordered]@{name=$top.Name;config=$top.Config}}
    if($candidate){throw "Provider '$candidate' is configured but disabled, and no other enabled providers are available."}
    throw "No enabled provider available. Configure or enable at least one provider in .statefulclanker/config.json."
}
function Expand-SCArg([string]$Arg,[string]$Prompt,[string]$PromptFile,$Task) { $Arg.Replace('{prompt}',$Prompt).Replace('{promptFile}',$PromptFile).Replace('{projectRoot}',(Get-SCRoot)).Replace('{taskId}',[string]$Task.id) }

<# Command-line budget for the executable being launched.

   cmd.exe (and .bat/.cmd shims, which run through it) cap the whole command line at
   8191 characters. Everything else goes through CreateProcess, which caps at 32767.
   These are hard OS limits, not guidance. #>
function Get-SCCommandLineLimit([string]$Exe) {
    $leaf = try { [IO.Path]::GetFileName($Exe) } catch { [string]$Exe }
    if ($leaf -match '(?i)^cmd(\.exe)?$' -or $leaf -match '(?i)\.(bat|cmd)$') { return 8191 }
    return 32767
}

<# A one-shot prompt is a compiled context, not a sentence.

   Passing it as a command-line argument ({prompt}) is a latent failure: with the
   shipped budgets a realistic packet is tens of thousands of characters, and the
   process simply refuses to start. The observed failure is "The command line is too
   long" with exit 1, which looks like a broken provider rather than a prompt that
   did not fit. Fail here instead, naming the fix.

   The prompt file is ALWAYS written, so every provider can use {promptFile} or
   stdin regardless of how it is configured. #>
function Assert-SCPromptFits([string]$Exe,[string[]]$ArgList,[string]$ProviderName,[string]$PromptFile) {
    # NOT named $Args: that is a PowerShell automatic variable, and a parameter of
    # that name silently never receives the caller's value.
    $limit = Get-SCCommandLineLimit $Exe
    $length = ([string]$Exe).Length + 1
    foreach($a in $ArgList){ $length += ([string]$a).Length + 3 }
    if($length -le $limit){return}
    throw @"
Provider '$ProviderName' passes the prompt on the command line, and this prompt does not fit.

  command line : $length characters
  OS limit     : $limit characters ($([IO.Path]::GetFileName($Exe)))

A compiled context is tens of thousands of characters, so {prompt} will keep failing
as soon as retrieval grows. Switch the provider to deliver the prompt out of band:

  "mode": "stdin"                       and drop {prompt} from args   (most CLIs)
  "args": [..., "{promptFile}", ...]    if the CLI takes a file path

The prompt was still written in full to:
  $PromptFile
"@
}
function Invoke-SCProvider($Task,[string]$Prompt,[string]$Stage,[string]$ProviderOverride,[string]$ParentAgentId=$null,$Compilation=$null) {
    $providerRecord=Resolve-SCProvider $Task $ProviderOverride $Stage;$receiptId=New-SCId $Stage;$agentId=New-SCId 'agent';$promptPath=Get-SCPath ("prompts/{0}.txt"-f$receiptId);$Prompt|Set-Content -LiteralPath $promptPath -Encoding UTF8
    $exe=[string]$providerRecord.config.command;$args=@();foreach($arg in @($providerRecord.config.args)){$args+=Expand-SCArg ([string]$arg) $Prompt $promptPath $Task}
    $stdoutPath=Get-SCPath ("runs/{0}.stdout.txt"-f$receiptId);$stderrPath=Get-SCPath ("runs/{0}.stderr.txt"-f$receiptId);$started=(Get-Date).ToUniversalTime()
    $compilationId=if($Compilation){$Compilation.id}else{$null};$fingerprint=if($Compilation){$Compilation.inputFingerprint}else{$null};$retrievedChars=0;if($Compilation-and$Compilation.ir.sources.retrieved){$retrievedChars=[int]$Compilation.ir.sources.retrieved.usedChars}
    $taskRole=if($Task.PSObject.Properties['role']-and$Task.role){[string]$Task.role}else{'worker'}
    $telemetry=[ordered]@{schemaVersion=2;agentId=$agentId;receiptId=$receiptId;parentAgentId=$ParentAgentId;taskId=$Task.id;taskTitle=$Task.title;stage=$Stage;role=$taskRole;provider=$providerRecord.name;model=$null;lifecycle='running';processId=$PID;startedAt=$started.ToString('o');heartbeatAt=$started.ToString('o');endedAt=$null;durationSeconds=$null;promptChars=$Prompt.Length;retrievedChars=$retrievedChars;compilationId=$compilationId;inputFingerprint=$fingerprint;command=$exe;args=$args;exitCode=$null;verdict=$null;stdoutPath=$stdoutPath;stderrPath=$stderrPath;error=$null}
    Save-SCActiveTelemetry $telemetry;Add-SCTelemetryEvent 'agent.started' $telemetry;$stdout='';$stderr='';$exitCode=-1
    $mode=if($providerRecord.config.PSObject.Properties['mode']){[string]$providerRecord.config.mode}else{''}
    try{
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $exe)) {
            throw "Executable '$exe' not found on PATH or filesystem."
        }
        if($mode-eq'stdin'){
            # Pipe the prompt file to the provider's stdin: no OS length limit, and
            # no shell quoting of arbitrary prompt text.
            Get-Content -Raw -LiteralPath $promptPath | & $exe @args 1> $stdoutPath 2> $stderrPath
        }else{
            Assert-SCPromptFits $exe $args $providerRecord.name $promptPath
            & $exe @args 1> $stdoutPath 2> $stderrPath
        }
        $exitCode=$LASTEXITCODE;if($null-eq$exitCode){$exitCode=0};if(Test-Path $stdoutPath){$stdout=Get-Content -Raw -LiteralPath $stdoutPath};if(Test-Path $stderrPath){$stderr=Get-Content -Raw -LiteralPath $stderrPath}
        if($exitCode -ne 0 -and [string]::IsNullOrWhiteSpace($stderr)){
            $stderr = "Process '$exe' exited with code $exitCode without emitting standard error output."
            $telemetry.error = $stderr
            $stderr | Set-Content -LiteralPath $stderrPath -Encoding UTF8
        }
    }catch{
        $stderr = "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
        $telemetry.error = $stderr
        $exitCode = -1
        try { $stderr | Set-Content -LiteralPath $stderrPath -Encoding UTF8 } catch {}
    }
    $ended=(Get-Date).ToUniversalTime();$telemetry.lifecycle=if($exitCode-eq 0){'completed'}else{'failed'};$telemetry.exitCode=$exitCode;$telemetry.endedAt=$ended.ToString('o');$telemetry.heartbeatAt=$telemetry.endedAt;$telemetry.durationSeconds=[math]::Round(($ended-$started).TotalSeconds,3);Complete-SCTelemetry $telemetry
    return [ordered]@{schemaVersion=2;id=$receiptId;agentId=$agentId;taskId=$Task.id;stage=$Stage;provider=$providerRecord.name;compilationId=$compilationId;inputFingerprint=$fingerprint;command=$exe;args=$args;promptPath=$promptPath;startedAt=$started.ToString('o');endedAt=$ended.ToString('o');durationSeconds=$telemetry.durationSeconds;exitCode=$exitCode;stdout=$stdout;stderr=$stderr}
}
function Capture-SCContextRequests($Task,$Run,$Compilation) {
    $requests=@();foreach($line in @(([string]$Run.stdout)-split"`r?`n")){if($line-match'^\s*CONTEXT_(?:REQUEST|MISS):\s*(.+?)\s*$'){$requests+=$Matches[1]}}
    Set-SCProperty $Run 'contextRequests' @($requests)
    if($requests.Count-gt 0){
        Ensure-SCTelemetryLayout
        foreach($request in $requests){$record=[ordered]@{ts=(Get-Date).ToUniversalTime().ToString('o');taskId=$Task.id;runId=$Run.id;compilationId=$Compilation.id;inputFingerprint=$Compilation.inputFingerprint;request=$request};((ConvertTo-SCJson $record 8) -replace "`r?`n",'')|Add-Content -LiteralPath (Get-SCPath 'telemetry/context-faults.jsonl') -Encoding UTF8}
        Add-SCEvent 'context.fault' "Worker requested missing context." @{taskId=$Task.id;runId=$Run.id;compilationId=$Compilation.id;requests=@($requests)}
    }
    return @($requests)
}
<# Verdict parsing. Three rules, in order:
     1. Nonzero exit is always FAIL.
     2. A verdict must be its OWN line. Decoration is allowed (markdown bold, a
        bullet, trailing punctuation) but prose is not: a reviewer writing
        "do not emit VERDICT: PASS unless tests ran" has not voted.
     3. Any FAIL among the verdict lines wins, and no verdict line at all is FAIL.
   Rule 2 replaces the original "first non-empty line must be exactly VERDICT: X",
   which failed closed on any reviewer that wrote a preamble first and produced
   false FAILs on work that had actually passed.
   Rule 3 is why this does not simply take the last match: a reviewer that votes
   FAIL and then discusses a PASS must not flip the gate open. Ambiguity fails. #>
function Get-SCVerdict([string]$Text,[int]$ExitCode) { if($ExitCode-ne 0){return 'ERROR'};$seen=@();foreach($line in @($Text-split"`r?`n")){$trimmed=$line.Trim();if($trimmed-match'^[\s>*_#`~\-\[\]()."'':]*VERDICT\s*:\s*(PASS|FAIL|ERROR)[\s*_`~.!,:;''"\[\]()]*$'){$seen+=$Matches[1].ToUpperInvariant()}};if($seen-contains'ERROR'){return 'ERROR'};if($seen-contains'FAIL'){return 'FAIL'};if($seen-contains'PASS'){return 'PASS'};return 'FAIL' }
function Set-SCTelemetryVerdict([string]$AgentId,[string]$Verdict) { $path=Get-SCPath ("telemetry/runs/{0}.json"-f$AgentId);$record=Read-SCJson $path;if($record){$record.verdict=$Verdict;Write-SCJson $path $record} }
# Pulls a short, human-readable excerpt out of a critic/validator's raw stdout so a
# rejection reads as "why" and not just "rejected" -- strips the VERDICT: line itself
# (it's redundant with the task status) and blank lines, keeps the last non-empty
# lines (a reviewer's explanation usually lands right before its verdict line), and
# caps length so it stays terminal/event-log friendly.
function Get-SCReasonExcerpt([string]$Text,[int]$MaxLen=240) {
    if([string]::IsNullOrWhiteSpace($Text)){return ''}
    $lines=@($Text-split"`r?`n"|Where-Object{$_.Trim()-and$_.Trim()-notmatch'^[\s>*_#`~\-\[\]()."'':]*VERDICT\s*:'})
    if($lines.Count-eq0){return ''}
    $excerpt=($lines|Select-Object -Last 3)-join' '
    $excerpt=$excerpt.Trim()
    if($excerpt.Length-gt$MaxLen){$excerpt=$excerpt.Substring(0,$MaxLen).TrimEnd()+'...'}
    return $excerpt
}
function Invoke-SCReview($Task,$Run,$Compilation,[string]$Stage) {
    Add-SCEvent "$Stage.started" "$Stage review started for $($Task.id)" @{taskId=$Task.id;stage=$Stage;compilationId=$Compilation.id}
    $receipt=Invoke-SCProvider $Task (New-SCReviewPrompt $Task $Run $Compilation $Stage) $Stage $null $Run.agentId $Compilation;$receipt.verdict=Get-SCVerdict ([string]$receipt.stdout) ([int]$receipt.exitCode);Set-SCTelemetryVerdict $receipt.agentId $receipt.verdict;$dir=if($Stage-eq'critic'){'critiques'}else{'validations'};Write-SCJson (Get-SCPath ("{0}/{1}.json"-f$dir,$receipt.id)) $receipt;Add-SCEvent "$Stage.finished" "$Stage review finished for $($Task.id): $($receipt.verdict)" @{taskId=$Task.id;receiptId=$receipt.id;agentId=$receipt.agentId;verdict=$receipt.verdict;compilationId=$Compilation.id};return $receipt
}
function New-SCCompletionProposal($Task,$Run,$Compilation) {
    $proposal=[ordered]@{schemaVersion=1;id=New-SCId 'proposal';taskId=$Task.id;kind='task_completion';status='pending';createdAt=(Get-Date).ToUniversalTime().ToString('o');committedAt=$null;rejectedAt=$null;base=[ordered]@{compilationId=$Compilation.id;inputFingerprint=$Compilation.inputFingerprint;taskDefinitionHash=$Compilation.readSet.taskDefinitionHash;taskControlRevision=$Compilation.readSet.taskControlRevision};evidence=[ordered]@{runId=$Run.id;criticId=$null;criticVerdict=$null;validationId=$null;validationVerdict=$null};rejectionReasons=@()}
    Write-SCJson (Get-SCPath ("proposals/{0}.json"-f$proposal.id)) $proposal;Set-SCProperty $Task 'latestProposalId' $proposal.id;Save-SCTask $Task;Add-SCEvent 'state.proposed' "Proposed completion for $($Task.id)." @{taskId=$Task.id;proposalId=$proposal.id;compilationId=$Compilation.id};return $proposal
}
function Save-SCProposal($Proposal){Write-SCJson (Get-SCPath ("proposals/{0}.json"-f$Proposal.id)) $Proposal}
function Reject-SCProposal($Proposal,$Reasons) {$Proposal.status='rejected';$Proposal.rejectedAt=(Get-Date).ToUniversalTime().ToString('o');$Proposal.rejectionReasons=@($Reasons);Save-SCProposal $Proposal;Add-SCEvent 'state.proposal_rejected' "Rejected $($Proposal.id): $(@($Reasons)-join'; ')" @{taskId=$Proposal.taskId;proposalId=$Proposal.id;reasons=@($Reasons)}}
function Add-SCProgressRecord($Task,$Compilation,[bool]$Advanced,[string]$Outcome,[string]$Reason) {
    $record=[ordered]@{schemaVersion=1;id=New-SCId 'progress';ts=(Get-Date).ToUniversalTime().ToString('o');taskId=$Task.id;compilationId=if($Compilation){$Compilation.id}else{$null};inputFingerprint=if($Compilation){$Compilation.inputFingerprint}else{$null};advanced=$Advanced;outcome=$Outcome;reason=$Reason;taskStatus=$Task.status;attemptCount=if($Task.PSObject.Properties['attemptCount']){$Task.attemptCount}else{$null}}
    Write-SCJson (Get-SCPath ("progress/{0}.json"-f$record.id)) $record
    if(-not$Advanced-and$Compilation){
        $cfg=Get-SCConfig;$threshold=if($cfg.PSObject.Properties['stagnationWarningThreshold']){[int]$cfg.stagnationWarningThreshold}else{2};$same=@(Get-ChildItem -LiteralPath (Get-SCPath 'progress') -Filter '*.json' -File|ForEach-Object{Read-SCJson $_.FullName}|Where-Object{$_.taskId-eq$Task.id-and-not[bool]$_.advanced-and$_.inputFingerprint-eq$Compilation.inputFingerprint})
        if($same.Count-ge$threshold){Add-SCEvent 'task.stagnation.warning' "Task $($Task.id) has $($same.Count) non-advancing attempts against the same compiled input." @{taskId=$Task.id;inputFingerprint=$Compilation.inputFingerprint;count=$same.Count}}
    }
    return $record
}
function Stop-SCForStaleCompilation($Task,$Compilation,[string]$Outcome,[string]$Message,$Proposal=$null) {
    $fresh=Test-SCCompilationFreshness $Compilation 'commit';if($fresh.fresh){return $false}
    if($Proposal-and[string]$Proposal.status-eq'pending'){Reject-SCProposal $Proposal @($fresh.reasons)}
    $current=Get-SCTask ([string]$Task.id)
    if(@('running','reviewing','validating')-contains[string]$current.status){$current.status='needs_rework';$current.blockReason=$Message;Save-SCTask $current}
    Add-SCEvent 'context.stale' $Message @{taskId=$current.id;compilationId=$Compilation.id;status=$current.status;reasons=@($fresh.reasons)}
    Add-SCProgressRecord $current $Compilation $false $Outcome ($fresh.reasons -join '; ')|Out-Null
    Write-Warning $Message
    return $true
}
function Commit-SCProposal($Task,$Proposal,$Compilation) {
    $cfg=Get-SCConfig;$gateReasons=@();if([bool]$cfg.criticEnabled-and[string]$Proposal.evidence.criticVerdict-ne'PASS'){$gateReasons+='required critic did not pass'};if([bool]$cfg.validatorEnabled-and[string]$Proposal.evidence.validationVerdict-ne'PASS'){$gateReasons+='required validator did not pass'}
    if($gateReasons.Count-gt 0){Reject-SCProposal $Proposal $gateReasons;$Task.status='needs_rework';$Task.blockReason='Required review gate did not pass.';Save-SCTask $Task;Add-SCProgressRecord $Task $Compilation $false 'review-gate-rejected' ($gateReasons -join '; ')|Out-Null;return $false}
    if(Stop-SCForStaleCompilation $Task $Compilation 'stale-before-commit' 'Compiled state became stale before commit.' $Proposal){return $false}
    $Task=Get-SCTask ([string]$Task.id);$Proposal.status='committed';$Proposal.committedAt=(Get-Date).ToUniversalTime().ToString('o');Save-SCProposal $Proposal;$Task.status='complete';$Task.blockReason=$null;Save-SCTask $Task;Add-SCEvent 'state.committed' "Committed completion proposal $($Proposal.id)." @{taskId=$Task.id;proposalId=$Proposal.id;compilationId=$Compilation.id};Add-SCEvent 'task.completed' "Completed $($Task.id) after validated commit." @{taskId=$Task.id;runId=$Proposal.evidence.runId;proposalId=$Proposal.id};Add-SCProgressRecord $Task $Compilation $true 'committed' 'Validated proposal committed.'|Out-Null;Add-SCCompletedTaskCount|Out-Null;Update-SCReadiness;return $true
}
function Invoke-SCTask([string]$RequestedTaskId,[string]$ProviderOverride) {
    Assert-SCInitialized;Assert-SCNotHeld;Update-SCReadiness
    $state=Get-SCState;$cfg=Get-SCConfig
    if($state.activePlanId-and[bool]$cfg.requireHumanApprovalForPlan-and-not[bool]$state.planApproved){throw 'Active plan requires approval.'}
    $task=if($RequestedTaskId){Get-SCTask $RequestedTaskId}else{Get-SCTasks|Where-Object{$_.status-eq'ready'-and-not$_.humanGate}|Sort-Object createdAt|Select-Object -First 1}
    if($null-eq$task){throw 'No runnable ready task.'};if($task.status-ne'ready'){throw "Task $($task.id) is $($task.status), not ready."};if($task.humanGate){throw 'Task requires human gate.'}

    $task.status='running'
    $attempt=if($task.PSObject.Properties['attemptCount']){[int]$task.attemptCount+1}else{1}
    Set-SCProperty $task 'attemptCount' $attempt
    $workerSessionId=New-SCId 'wsess'
    Set-SCProperty $task 'activeWorkerSessionId' $workerSessionId
    Set-SCProperty $task 'latestWorkerSessionId' $workerSessionId
    $task.blockReason=$null;Save-SCTask $task
    Add-SCEvent 'run.started' 'Worker cycle started' @{taskId=$task.id;attempt=$attempt;workerSessionId=$workerSessionId}

    $compilation=New-SCCompilation $task;$fresh=Test-SCCompilationFreshness $compilation 'dispatch'
    if(-not$fresh.fresh){
        $task=Get-SCTask $task.id;$task.status='needs_rework';$task.blockReason='Compiled context became stale before dispatch.';Set-SCProperty $task 'activeWorkerSessionId' $null;Save-SCTask $task
        Add-SCProgressRecord $task $compilation $false 'stale-before-dispatch' ($fresh.reasons -join '; ')|Out-Null
        Add-SCEvent 'context.stale' $task.blockReason @{taskId=$task.id;compilationId=$compilation.id;reasons=@($fresh.reasons)}
        Write-Warning $task.blockReason;return
    }

    $basePrompt=New-SCWorkerPrompt $compilation
    $continuation=$null
    $run=$null;$proposal=$null
    while($true){
        $task=Get-SCTask $task.id
        $task.status='running';$task.blockReason=$null;Save-SCTask $task

        $run=Invoke-SCProvider $task $basePrompt 'run' $ProviderOverride $null $compilation $workerSessionId $continuation
        $continuation=$null
        $contextRequests=@(Capture-SCContextRequests $task $run $compilation)
        Write-SCJson (Get-SCPath ("runs/{0}.json"-f$run.id)) $run
        $task=Get-SCTask $task.id;$task.latestRunId=$run.id;Save-SCTask $task

        if(Stop-SCForStaleCompilation $task $compilation 'stale-after-worker' 'Compiled state became stale while the worker was running.'){
            Close-SCWorkerSession $workerSessionId 'stale';$task=Get-SCTask $task.id;Set-SCProperty $task 'activeWorkerSessionId' $null;Save-SCTask $task;return
        }

        if([int]$run.exitCode-ne0){
            $task=Get-SCTask $task.id
            $routeUnavailable=($run.PSObject.Properties['routeDeferred'] -and [bool]$run.routeDeferred) -or ($run.PSObject.Properties['routeExhausted'] -and [bool]$run.routeExhausted)
            if($routeUnavailable){
                $task.status='blocked'
                $task.blockReason=if($run.stderr){"Inference routing unavailable: "+([string]$run.stderr).Trim()}else{'Inference routing unavailable; all eligible endpoints failed or are cooling down.'}
                Set-SCProperty $task 'activeWorkerSessionId' $null;Save-SCTask $task;Close-SCWorkerSession $workerSessionId 'routing-deferred'
                Add-SCEvent 'routing.deferred' $task.blockReason @{taskId=$task.id;runId=$run.id;workerSessionId=$workerSessionId;compilationId=$compilation.id;retryAfter=if($run.PSObject.Properties['retryAfter']){$run.retryAfter}else{$null};routeHistory=if($run.PSObject.Properties['routeHistory']){@($run.routeHistory)}else{@()}}
                Add-SCProgressRecord $task $compilation $false 'routing-unavailable' $task.blockReason|Out-Null
                Write-Warning $task.blockReason;return
            }
            $task.status='failed';$task.blockReason="Worker exited $($run.exitCode)";Set-SCProperty $task 'activeWorkerSessionId' $null;Save-SCTask $task;Close-SCWorkerSession $workerSessionId 'failed'
            Add-SCEvent 'run.failed' $task.blockReason @{taskId=$task.id;runId=$run.id;agentId=$run.agentId;workerSessionId=$workerSessionId;compilationId=$compilation.id}
            Add-SCProgressRecord $task $compilation $false 'worker-failed' $task.blockReason|Out-Null;Write-Warning $task.blockReason;return
        }

        Add-SCEvent 'run.finished' "Worker finished $($run.id)" @{taskId=$task.id;runId=$run.id;agentId=$run.agentId;workerSessionId=$workerSessionId;compilationId=$compilation.id}
        if($contextRequests.Count-gt0){
            $task=Get-SCTask $task.id;$task.status='needs_rework';$task.blockReason='Worker requested missing context; completion was not proposed.';Set-SCProperty $task 'activeWorkerSessionId' $null;Save-SCTask $task;Close-SCWorkerSession $workerSessionId 'context-fault'
            Add-SCProgressRecord $task $compilation $false 'context-fault' ($contextRequests -join '; ')|Out-Null;Write-Warning $task.blockReason;return
        }

        $resumable=($run.PSObject.Properties['workerSessionResumable'] -and [bool]$run.workerSessionResumable)
        $preflight=$null
        if($resumable){
            $preflight=Get-SCWorkerCandidatePreflight $workerSessionId $task
            $preflightEvidence=[ordered]@{
                material=[bool]$preflight.material
                requiresArtifact=[bool]$preflight.requiresArtifact
                reason=$preflight.reason
                missingArtifacts=@($preflight.missingArtifacts)
                candidateCheckpointId=$preflight.candidateCheckpointId
                candidateNumber=[int]$preflight.candidateNumber
            }
            Set-SCProperty $run 'candidatePreflight' $preflightEvidence
            if($preflight.session -and $preflight.session.PSObject.Properties['candidateClaim']){
                Set-SCProperty $run 'candidateClaim' $preflight.session.candidateClaim
            }
            Write-SCJson (Get-SCPath ("runs/{0}.json"-f$run.id)) $run
            if(-not[bool]$preflight.material){
                $noArtifactCount=Add-SCWorkerNoArtifact $workerSessionId ([string]$preflight.reason)
                if($noArtifactCount-eq1){
                    $continuation="CANDIDATE PREFLIGHT REJECTED. No critic was run because StatefulClanker's deterministic evidence gate found no required material artifact change. Reason: $($preflight.reason). This task expects implementation artifacts. Inspect the current worktree, perform the requested work, verify it, and submit a new candidate. Do not merely restate the intended implementation."
                    Add-SCEvent 'worker.session_repair' "Returning no-artifact candidate to the same worker session." @{taskId=$task.id;workerSessionId=$workerSessionId;candidateNumber=$preflight.candidateNumber;reason=$preflight.reason}
                    Add-SCProgressRecord $task $compilation $false 'candidate-preflight-repair' ([string]$preflight.reason)|Out-Null
                    continue
                }
                $task=Get-SCTask $task.id;$task.status='needs_rework';$task.blockReason="Worker session submitted $noArtifactCount completion candidates without required artifacts. Latest: $($preflight.reason)";Set-SCProperty $task 'activeWorkerSessionId' $null;Save-SCTask $task;Close-SCWorkerSession $workerSessionId 'no-artifact'
                Add-SCProgressRecord $task $compilation $false 'candidate-no-artifact' $task.blockReason|Out-Null
                Add-SCEvent 'worker.session_abandoned' $task.blockReason @{taskId=$task.id;workerSessionId=$workerSessionId;noArtifactCount=$noArtifactCount}
                Write-Warning $task.blockReason;return
            }
        }

        $task=Get-SCTask $task.id
        $proposal=New-SCCompletionProposal $task $run $compilation
        if($preflight){
            Set-SCProperty $proposal.evidence 'workerSessionId' $workerSessionId
            Set-SCProperty $proposal.evidence 'candidateNumber' ([int]$preflight.candidateNumber)
            Set-SCProperty $proposal.evidence 'candidateCheckpointId' $preflight.candidateCheckpointId
            Set-SCProperty $proposal.evidence 'candidatePreflight' $preflightEvidence
            if($run.PSObject.Properties['candidateClaim']){Set-SCProperty $proposal.evidence 'candidateClaim' $run.candidateClaim}
            Save-SCProposal $proposal
        }

        if([bool]$cfg.criticEnabled){
            $task.status='reviewing';Save-SCTask $task
            $critique=Invoke-SCReview $task $run $compilation 'critic'
            $proposal.evidence.criticId=$critique.id;$proposal.evidence.criticVerdict=$critique.verdict;Save-SCProposal $proposal
            $task=Get-SCTask $task.id;$task.latestCritiqueId=$critique.id;Save-SCTask $task

            if($critique.verdict-eq'ERROR'){
                $errDetail=if($critique.stderr){$critique.stderr.Trim()}else{'Critic review encountered an infrastructure error.'}
                $routeUnavailable=($critique.PSObject.Properties['routeDeferred'] -and [bool]$critique.routeDeferred) -or ($critique.PSObject.Properties['routeExhausted'] -and [bool]$critique.routeExhausted)
                $task.status=if($routeUnavailable){'blocked'}else{'needs_rework'}
                $task.blockReason=if($routeUnavailable){"Critic inference routing unavailable: $errDetail"}else{"Critic infrastructure error: $errDetail"}
                Set-SCProperty $task 'activeWorkerSessionId' $null;Save-SCTask $task;Close-SCWorkerSession $workerSessionId 'critic-error'
                Add-SCProgressRecord $task $compilation $false 'critic-error' $task.blockReason|Out-Null
                Add-SCEvent 'critic.error' $task.blockReason @{taskId=$task.id;receiptId=$critique.id;workerSessionId=$workerSessionId;error=$errDetail}
                Write-Warning $task.blockReason;return
            }

            if($critique.verdict-ne'PASS'){
                $reasonExcerpt=Get-SCReasonExcerpt ([string]$critique.stdout)
                $reason=if($reasonExcerpt){"critic rejected worker result: $reasonExcerpt"}else{'critic rejected worker result'}
                Reject-SCProposal $proposal @($reason)
                $criticRejectCount=if($task.PSObject.Properties['criticRejectCount']){[int]$task.criticRejectCount+1}else{1}
                Set-SCProperty $task 'criticRejectCount' $criticRejectCount

                if($criticRejectCount-ge3){
                    $task.status='blocked'
                    $task.blockReason=if($reasonExcerpt){"Critic rejected this task scope $criticRejectCount times; plan-graph repair required. Latest: $reasonExcerpt"}else{"Critic rejected this task scope $criticRejectCount times; plan-graph repair required."}
                    Set-SCProperty $task 'activeWorkerSessionId' $null;Save-SCTask $task;Close-SCWorkerSession $workerSessionId 'plan-repair'
                    Add-SCProgressRecord $task $compilation $false 'critic-rejected' $task.blockReason|Out-Null
                    if($criticRejectCount-eq3){
                        $repairMessage="CLANKER PLAN REPAIR REQUIRED for task '$($task.id)' ($($task.title)): the critic has rejected this scope three times. Latest reason: "+$(if($reasonExcerpt){$reasonExcerpt}else{'no detailed critic reason was captured'})+". Do not retry the task unchanged. Inspect the critic evidence plus current Intent/directives; decompose it into smaller independently verifiable plan nodes, add missing clarification/context where that resolves the failure, or ask the human a specific question if intent is genuinely ambiguous. Then rebuild the affected plan-graph dependencies/relations and acceptance criteria before releasing replacement work."
                        Add-SCEvent 'task.plan_repair_required' $repairMessage @{taskId=$task.id;title=$task.title;workerSessionId=$workerSessionId;criticRejectCount=$criticRejectCount;latestCritiqueId=$critique.id;latestReason=$reasonExcerpt;attemptCount=$task.attemptCount}
                    }
                    Write-Warning $task.blockReason;return
                }

                if($resumable){
                    if(Stop-SCForStaleCompilation $task $compilation 'stale-after-critic' 'Compiled state became stale during critic review.' $proposal){Close-SCWorkerSession $workerSessionId 'stale';return}
                    $feedback=[string]$critique.stdout
                    if($feedback.Length-gt6000){$feedback=$feedback.Substring(0,6000)}
                    $continuation="CRITIC REJECTED CANDIDATE $criticRejectCount. Repair the existing work in this same worker session; do not restart from the task description and do not discard correct work. Critic feedback follows:"+[Environment]::NewLine+$feedback+[Environment]::NewLine+"Inspect the current worktree, address the specific review failures, run appropriate verification, and submit a replacement candidate."
                    $task=Get-SCTask $task.id;$task.status='running';$task.blockReason=$null;Save-SCTask $task
                    Add-SCProgressRecord $task $compilation $false 'critic-repair-same-session' $reason|Out-Null
                    Add-SCEvent 'worker.session_repair' "Returning critic rejection to worker session $workerSessionId." @{taskId=$task.id;workerSessionId=$workerSessionId;criticRejectCount=$criticRejectCount;critiqueId=$critique.id}
                    continue
                }

                $task.status='needs_rework';$task.blockReason=if($reasonExcerpt){"Critic rejected worker result: $reasonExcerpt"}else{'Critic rejected worker result.'}
                Set-SCProperty $task 'activeWorkerSessionId' $null;Save-SCTask $task;Close-SCWorkerSession $workerSessionId 'critic-rejected-nonresumable'
                Add-SCProgressRecord $task $compilation $false 'critic-rejected' $task.blockReason|Out-Null
                Write-Warning $task.blockReason;return
            }

            if(Stop-SCForStaleCompilation $task $compilation 'stale-after-critic' 'Compiled state became stale during critic review.' $proposal){Close-SCWorkerSession $workerSessionId 'stale';return}
            $task=Get-SCTask $task.id
        }
        break
    }

    if([bool]$cfg.validatorEnabled){
        $task.status='validating';Save-SCTask $task
        $validation=Invoke-SCReview $task $run $compilation 'validator'
        $proposal.evidence.validationId=$validation.id;$proposal.evidence.validationVerdict=$validation.verdict;Save-SCProposal $proposal
        $task=Get-SCTask $task.id;$task.latestValidationId=$validation.id;Save-SCTask $task
        if($validation.verdict-eq'ERROR'){
            $errDetail=if($validation.stderr){$validation.stderr.Trim()}else{'Validator review encountered an infrastructure error.'}
            $routeUnavailable=($validation.PSObject.Properties['routeDeferred'] -and [bool]$validation.routeDeferred) -or ($validation.PSObject.Properties['routeExhausted'] -and [bool]$validation.routeExhausted)
            $task.status=if($routeUnavailable){'blocked'}else{'needs_rework'}
            $task.blockReason=if($routeUnavailable){"Validator inference routing unavailable: $errDetail"}else{"Validator infrastructure error: $errDetail"}
            Set-SCProperty $task 'activeWorkerSessionId' $null;Save-SCTask $task;Close-SCWorkerSession $workerSessionId 'validator-error'
            Add-SCProgressRecord $task $compilation $false 'validator-error' $task.blockReason|Out-Null
            Add-SCEvent 'validator.error' $task.blockReason @{taskId=$task.id;receiptId=$validation.id;workerSessionId=$workerSessionId;error=$errDetail}
            Write-Warning $task.blockReason;return
        }
        if($validation.verdict-ne'PASS'){
            $reasonExcerpt=Get-SCReasonExcerpt ([string]$validation.stdout)
            $reason=if($reasonExcerpt){"validator rejected worker result: $reasonExcerpt"}else{'validator rejected worker result'}
            Reject-SCProposal $proposal @($reason)
            $task.status='needs_rework';$task.blockReason=if($reasonExcerpt){"Validator rejected worker result: $reasonExcerpt"}else{'Validator rejected worker result.'}
            Set-SCProperty $task 'activeWorkerSessionId' $null;Save-SCTask $task;Close-SCWorkerSession $workerSessionId 'validator-rejected'
            Add-SCProgressRecord $task $compilation $false 'validator-rejected' $task.blockReason|Out-Null
            Write-Warning $task.blockReason;return
        }
    }

    $task=Get-SCTask $task.id
    if(Commit-SCProposal $task $proposal $compilation){
        Close-SCWorkerSession $workerSessionId 'completed'
        $task=Get-SCTask $task.id;Set-SCProperty $task 'activeWorkerSessionId' $null;Save-SCTask $task
        Write-Host "Task complete: $($task.id)"
    }else{
        Close-SCWorkerSession $workerSessionId 'not-committed'
        Write-Warning "Task not committed: $($task.id)"
    }
    Invoke-SCProjectReviewIfDue 'interval'|Out-Null
}
function Retry-SCTask([string]$Id) {
    if(-not$Id){throw '-TaskId required.'}
    $task=Get-SCTask $Id
    $was=$task.status

    if ($task.latestRunId -and $task.latestCompilationId) {
        $alreadyCritiqued = $false
        if ($task.latestCritiqueId) {
            try {
                $c = Read-SCJson (Get-SCPath ("critiques/{0}.json" -f $task.latestCritiqueId))
                if ($c -and $c.compilationId -eq $task.latestCompilationId) {
                    $alreadyCritiqued = $true
                }
            } catch {}
        }
        if (-not $alreadyCritiqued) {
            try {
                $run = Read-SCJson (Get-SCPath ("runs/{0}.json" -f $task.latestRunId))
                $comp = Read-SCJson (Get-SCPath ("compilations/{0}.json" -f $task.latestCompilationId))
                if ($run -and $comp) {
                    $preflightRejected=($run.PSObject.Properties['candidatePreflight'] -and $run.candidatePreflight -and -not[bool]$run.candidatePreflight.material)
                    $successfulWorker=([int]$run.exitCode-eq0 -and -not($run.PSObject.Properties['routeDeferred'] -and [bool]$run.routeDeferred) -and -not($run.PSObject.Properties['routeExhausted'] -and [bool]$run.routeExhausted))
                    if($successfulWorker -and -not$preflightRejected){
                        Write-Host "Running critic against previous unreviewed candidate before retrying $($task.id)..."
                        $task.status='reviewing'; Save-SCTask $task
                        $critique = Invoke-SCReview $task $run $comp 'critic'
                        $task = Get-SCTask $task.id
                        $task.latestCritiqueId = $critique.id
                        Save-SCTask $task
                    }
                }
            } catch {
                Write-Warning "Failed to run critic during retry: $($_.Exception.Message)"
            }
        }
    }

    $task=Get-SCTask $Id
    Advance-SCTaskControlRevision $task|Out-Null
    $task.status='ready'
    $task.blockReason=$null
    Save-SCTask $task
    if($was-eq'complete'-or$was-eq'stale'){Invalidate-SCDependents $Id 'upstream task retried'}
    Update-SCReadiness
    Add-SCEvent 'task.retried' "Retry $Id" @{taskId=$Id;previousStatus=$was;controlRevision=$task.controlRevision}
    Write-Host 'Task reset to ready.'
}
function Complete-SCTask([string]$Id) { if(-not$Id){throw '-TaskId required.'};$task=Get-SCTask $Id;$was=$task.status;Advance-SCTaskControlRevision $task|Out-Null;$task.status='complete';$task.blockReason=$null;Save-SCTask $task;Add-SCEvent 'task.completed.manual' "Completed $Id manually" @{taskId=$Id;previousStatus=$was;authority='human';controlRevision=$task.controlRevision};Add-SCProgressRecord $task $null $true 'human-commit' 'Human explicitly committed task completion.'|Out-Null;Update-SCReadiness;Write-Host 'Task completed.' }
function Block-SCTask([string]$Id,[string]$Why) { if(-not$Id){throw '-TaskId required.'};if(-not$Why){throw '-Reason required.'};$task=Get-SCTask $Id;$was=$task.status;Advance-SCTaskControlRevision $task|Out-Null;$task.status='blocked';$task.blockReason=$Why;Save-SCTask $task;if($was-eq'complete'){Invalidate-SCDependents $Id 'upstream task blocked after completion'};Add-SCEvent 'task.blocked' $Why @{taskId=$Id;previousStatus=$was;controlRevision=$task.controlRevision};Write-Host 'Task blocked.' }
function Show-SCProviders { $cfg=Get-SCConfig;$rows=@();foreach($property in $cfg.providers.PSObject.Properties){$rows+=[pscustomobject]@{name=$property.Name;command=$property.Value.command;mode=$property.Value.mode}};$rows|Format-Table -AutoSize }
function Show-SCTelemetry([string]$Mode,[string]$Id) { if([string]::IsNullOrWhiteSpace($Mode)){$Mode='active'};switch($Mode.ToLowerInvariant()){'active'{@(Get-SCActiveTelemetry)|Select-Object agentId,taskId,stage,provider,lifecycle,compilationId,startedAt|Format-Table -AutoSize;break};'history'{@(Get-SCTelemetryRuns 100)|Select-Object agentId,taskId,stage,provider,lifecycle,exitCode,verdict,durationSeconds,compilationId,startedAt|Format-Table -AutoSize;break};'faults'{@(Get-SCContextFaults 100)|Select-Object ts,taskId,runId,compilationId,request|Format-Table -AutoSize;break};'show'{if(-not$Id){throw '-RunId required (agent id).'};$record=Read-SCJson (Get-SCPath ("telemetry/runs/{0}.json"-f$Id));if(-not$record){throw "Unknown telemetry run: $Id"};ConvertTo-SCJson $record 14|Write-Host;break};default{throw "Unknown telemetry subcommand: $Mode"}} }
function Show-SCContext([string]$Mode,[string]$Id) { if([string]::IsNullOrWhiteSpace($Mode)){$Mode='faults'};switch($Mode.ToLowerInvariant()){'faults'{@(Get-SCContextFaults 100)|ConvertTo-SCJson -Depth 12|Write-Host;break};'show'{if(-not$Id){throw '-CompilationId required.'};$record=Read-SCJson (Get-SCPath ("compilations/{0}.json"-f$Id));if(-not$record){throw "Unknown compilation: $Id"};ConvertTo-SCJson $record 24|Write-Host;break};default{throw "Unknown context subcommand: $Mode"}} }
function Show-SCProgress([string]$Mode) { if([string]::IsNullOrWhiteSpace($Mode)){$Mode='history'};if($Mode.ToLowerInvariant()-ne'history'){throw "Unknown progress subcommand: $Mode"};@(Get-ChildItem -LiteralPath (Get-SCPath 'progress') -Filter '*.json' -File|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 100|ForEach-Object{Read-SCJson $_.FullName})|Select-Object ts,taskId,advanced,outcome,attemptCount,inputFingerprint|Format-Table -AutoSize }


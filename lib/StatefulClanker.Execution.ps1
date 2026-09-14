function Resolve-SCProvider($Task,[string]$Override,[string]$Stage='worker') {
    $cfg=Get-SCConfig;$name=$null;if($Override){$name=$Override}elseif($Stage-eq'critic'-and$cfg.PSObject.Properties['criticProvider']-and$cfg.criticProvider){$name=[string]$cfg.criticProvider}elseif($Stage-eq'validator'-and$cfg.PSObject.Properties['validatorProvider']-and$cfg.validatorProvider){$name=[string]$cfg.validatorProvider}elseif($Task.provider){$name=[string]$Task.provider}else{$name=[string]$cfg.defaultProvider};$property=$cfg.providers.PSObject.Properties[$name];if($null-eq$property){throw "Provider '$name' not configured."};return [ordered]@{name=$name;config=$property.Value}
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
    $telemetry=[ordered]@{schemaVersion=2;agentId=$agentId;receiptId=$receiptId;parentAgentId=$ParentAgentId;taskId=$Task.id;taskTitle=$Task.title;stage=$Stage;provider=$providerRecord.name;model=$null;lifecycle='running';processId=$null;startedAt=$started.ToString('o');heartbeatAt=$started.ToString('o');endedAt=$null;durationSeconds=$null;promptChars=$Prompt.Length;retrievedChars=$retrievedChars;compilationId=$compilationId;inputFingerprint=$fingerprint;command=$exe;args=$args;exitCode=$null;verdict=$null;stdoutPath=$stdoutPath;stderrPath=$stderrPath;error=$null}
    Save-SCActiveTelemetry $telemetry;Add-SCTelemetryEvent 'agent.started' $telemetry;$stdout='';$stderr='';$exitCode=-1
    $mode=if($providerRecord.config.PSObject.Properties['mode']){[string]$providerRecord.config.mode}else{''}
    try{
        if($mode-eq'stdin'){
            # Pipe the prompt file to the provider's stdin: no OS length limit, and
            # no shell quoting of arbitrary prompt text.
            Get-Content -Raw -LiteralPath $promptPath | & $exe @args 1> $stdoutPath 2> $stderrPath
        }else{
            Assert-SCPromptFits $exe $args $providerRecord.name $promptPath
            & $exe @args 1> $stdoutPath 2> $stderrPath
        }
        $exitCode=$LASTEXITCODE;if($null-eq$exitCode){$exitCode=0};if(Test-Path $stdoutPath){$stdout=Get-Content -Raw -LiteralPath $stdoutPath};if(Test-Path $stderrPath){$stderr=Get-Content -Raw -LiteralPath $stderrPath}
    }catch{$stderr=$_|Out-String;$telemetry.error=$stderr;$exitCode=-1}
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
function Get-SCVerdict([string]$Text,[int]$ExitCode) { if($ExitCode-ne 0){return 'FAIL'};$seen=@();foreach($line in @($Text-split"`r?`n")){$trimmed=$line.Trim();if($trimmed-match'^[\s>*_#`~\-\[\]()."'':]*VERDICT\s*:\s*(PASS|FAIL)[\s*_`~.!,:;''"\[\]()]*$'){$seen+=$Matches[1].ToUpperInvariant()}};if($seen-contains'FAIL'){return 'FAIL'};if($seen-contains'PASS'){return 'PASS'};return 'FAIL' }
function Set-SCTelemetryVerdict([string]$AgentId,[string]$Verdict) { $path=Get-SCPath ("telemetry/runs/{0}.json"-f$AgentId);$record=Read-SCJson $path;if($record){$record.verdict=$Verdict;Write-SCJson $path $record} }
function Invoke-SCReview($Task,$Run,$Compilation,[string]$Stage) {
    $receipt=Invoke-SCProvider $Task (New-SCReviewPrompt $Task $Run $Compilation $Stage) $Stage $null $Run.agentId $Compilation;$receipt.verdict=Get-SCVerdict ([string]$receipt.stdout) ([int]$receipt.exitCode);Set-SCTelemetryVerdict $receipt.agentId $receipt.verdict;$dir=if($Stage-eq'critic'){'critiques'}else{'validations'};Write-SCJson (Get-SCPath ("{0}/{1}.json"-f$dir,$receipt.id)) $receipt;Add-SCEvent "$Stage.finished" "$Stage $($receipt.id): $($receipt.verdict)" @{taskId=$Task.id;receiptId=$receipt.id;agentId=$receipt.agentId;verdict=$receipt.verdict;compilationId=$Compilation.id};return $receipt
}
function New-SCCompletionProposal($Task,$Run,$Compilation) {
    $proposal=[ordered]@{schemaVersion=1;id=New-SCId 'proposal';taskId=$Task.id;kind='task_completion';status='pending';createdAt=(Get-Date).ToUniversalTime().ToString('o');committedAt=$null;rejectedAt=$null;base=[ordered]@{compilationId=$Compilation.id;inputFingerprint=$Compilation.inputFingerprint;taskDefinitionHash=$Compilation.readSet.taskDefinitionHash;taskControlRevision=$Compilation.readSet.taskControlRevision};evidence=[ordered]@{runId=$Run.id;criticId=$null;criticVerdict=$null;validationId=$null;validationVerdict=$null};rejectionReasons=@()}
    Write-SCJson (Get-SCPath ("proposals/{0}.json"-f$proposal.id)) $proposal;Set-SCProperty $Task 'latestProposalId' $proposal.id;Save-SCTask $Task;Add-SCEvent 'state.proposed' "Proposed completion for $($Task.id)." @{taskId=$Task.id;proposalId=$proposal.id;compilationId=$Compilation.id};return $proposal
}
function Save-SCProposal($Proposal){Write-SCJson (Get-SCPath ("proposals/{0}.json"-f$Proposal.id)) $Proposal}
function Reject-SCProposal($Proposal,$Reasons) {$Proposal.status='rejected';$Proposal.rejectedAt=(Get-Date).ToUniversalTime().ToString('o');$Proposal.rejectionReasons=@($Reasons);Save-SCProposal $Proposal;Add-SCEvent 'state.proposal_rejected' "Rejected $($Proposal.id)." @{taskId=$Proposal.taskId;proposalId=$Proposal.id;reasons=@($Reasons)}}
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
    Assert-SCInitialized;Assert-SCNotHeld;Update-SCReadiness;$state=Get-SCState;$cfg=Get-SCConfig;if($state.activePlanId-and[bool]$cfg.requireHumanApprovalForPlan-and-not[bool]$state.planApproved){throw 'Active plan requires approval.'}
    $task=if($RequestedTaskId){Get-SCTask $RequestedTaskId}else{Get-SCTasks|Where-Object{$_.status-eq'ready'-and-not$_.humanGate}|Sort-Object createdAt|Select-Object -First 1};if($null-eq$task){throw 'No runnable ready task.'};if($task.status-ne'ready'){throw "Task $($task.id) is $($task.status), not ready."};if($task.humanGate){throw 'Task requires human gate.'}
    $task.status='running';$attempt=if($task.PSObject.Properties['attemptCount']){[int]$task.attemptCount+1}else{1};Set-SCProperty $task 'attemptCount' $attempt;$task.blockReason=$null;Save-SCTask $task;Add-SCEvent 'run.started' 'Worker cycle started' @{taskId=$task.id;attempt=$attempt}
    $compilation=New-SCCompilation $task;$fresh=Test-SCCompilationFreshness $compilation 'dispatch'
    if(-not$fresh.fresh){$task=Get-SCTask $task.id;$task.status='needs_rework';$task.blockReason='Compiled context became stale before dispatch.';Save-SCTask $task;Add-SCProgressRecord $task $compilation $false 'stale-before-dispatch' ($fresh.reasons -join '; ')|Out-Null;Add-SCEvent 'context.stale' $task.blockReason @{taskId=$task.id;compilationId=$compilation.id;reasons=@($fresh.reasons)};Write-Warning $task.blockReason;return}
    $run=Invoke-SCProvider $task (New-SCWorkerPrompt $compilation) 'run' $ProviderOverride $null $compilation;$contextRequests=@(Capture-SCContextRequests $task $run $compilation);Write-SCJson (Get-SCPath ("runs/{0}.json"-f$run.id)) $run;$task=Get-SCTask $task.id;$task.latestRunId=$run.id;Save-SCTask $task
    if(Stop-SCForStaleCompilation $task $compilation 'stale-after-worker' 'Compiled state became stale while the worker was running.'){return}
    if([int]$run.exitCode-ne 0){$task=Get-SCTask $task.id;$task.status='failed';$task.blockReason="Worker exited $($run.exitCode)";Save-SCTask $task;Add-SCEvent 'run.failed' $task.blockReason @{taskId=$task.id;runId=$run.id;agentId=$run.agentId;compilationId=$compilation.id};Add-SCProgressRecord $task $compilation $false 'worker-failed' $task.blockReason|Out-Null;Write-Warning $task.blockReason;return};Add-SCEvent 'run.finished' "Worker finished $($run.id)" @{taskId=$task.id;runId=$run.id;agentId=$run.agentId;compilationId=$compilation.id}
    if($contextRequests.Count-gt 0){$task=Get-SCTask $task.id;$task.status='needs_rework';$task.blockReason='Worker requested missing context; completion was not proposed.';Save-SCTask $task;Add-SCProgressRecord $task $compilation $false 'context-fault' ($contextRequests -join '; ')|Out-Null;Write-Warning $task.blockReason;return}
    $task=Get-SCTask $task.id;$proposal=New-SCCompletionProposal $task $run $compilation
    if([bool]$cfg.criticEnabled){$task.status='reviewing';Save-SCTask $task;$critique=Invoke-SCReview $task $run $compilation 'critic';$proposal.evidence.criticId=$critique.id;$proposal.evidence.criticVerdict=$critique.verdict;Save-SCProposal $proposal;$task=Get-SCTask $task.id;$task.latestCritiqueId=$critique.id;Save-SCTask $task;if($critique.verdict-ne'PASS'){Reject-SCProposal $proposal @('critic rejected worker result');$task.status='needs_rework';$task.blockReason='Critic rejected worker result.';Save-SCTask $task;Add-SCProgressRecord $task $compilation $false 'critic-rejected' $task.blockReason|Out-Null;Write-Warning $task.blockReason;return};if(Stop-SCForStaleCompilation $task $compilation 'stale-after-critic' 'Compiled state became stale during critic review.' $proposal){return};$task=Get-SCTask $task.id}
    if([bool]$cfg.validatorEnabled){$task.status='validating';Save-SCTask $task;$validation=Invoke-SCReview $task $run $compilation 'validator';$proposal.evidence.validationId=$validation.id;$proposal.evidence.validationVerdict=$validation.verdict;Save-SCProposal $proposal;$task=Get-SCTask $task.id;$task.latestValidationId=$validation.id;Save-SCTask $task;if($validation.verdict-ne'PASS'){Reject-SCProposal $proposal @('validator rejected worker result');$task.status='needs_rework';$task.blockReason='Validator rejected worker result.';Save-SCTask $task;Add-SCProgressRecord $task $compilation $false 'validator-rejected' $task.blockReason|Out-Null;Write-Warning $task.blockReason;return}}
    $task=Get-SCTask $task.id;if(Commit-SCProposal $task $proposal $compilation){Write-Host "Task complete: $($task.id)"}else{Write-Warning "Task not committed: $($task.id)"}
    Invoke-SCProjectReviewIfDue 'interval'|Out-Null
}
function Retry-SCTask([string]$Id) { if(-not$Id){throw '-TaskId required.'};$task=Get-SCTask $Id;$was=$task.status;Advance-SCTaskControlRevision $task|Out-Null;$task.status='ready';$task.blockReason=$null;Save-SCTask $task;if($was-eq'complete'-or$was-eq'stale'){Invalidate-SCDependents $Id 'upstream task retried'};Update-SCReadiness;Add-SCEvent 'task.retried' "Retry $Id" @{taskId=$Id;previousStatus=$was;controlRevision=$task.controlRevision};Write-Host 'Task reset to ready.' }
function Complete-SCTask([string]$Id) { if(-not$Id){throw '-TaskId required.'};$task=Get-SCTask $Id;$was=$task.status;Advance-SCTaskControlRevision $task|Out-Null;$task.status='complete';$task.blockReason=$null;Save-SCTask $task;Add-SCEvent 'task.completed.manual' "Completed $Id manually" @{taskId=$Id;previousStatus=$was;authority='human';controlRevision=$task.controlRevision};Add-SCProgressRecord $task $null $true 'human-commit' 'Human explicitly committed task completion.'|Out-Null;Update-SCReadiness;Write-Host 'Task completed.' }
function Block-SCTask([string]$Id,[string]$Why) { if(-not$Id){throw '-TaskId required.'};if(-not$Why){throw '-Reason required.'};$task=Get-SCTask $Id;$was=$task.status;Advance-SCTaskControlRevision $task|Out-Null;$task.status='blocked';$task.blockReason=$Why;Save-SCTask $task;if($was-eq'complete'){Invalidate-SCDependents $Id 'upstream task blocked after completion'};Add-SCEvent 'task.blocked' $Why @{taskId=$Id;previousStatus=$was;controlRevision=$task.controlRevision};Write-Host 'Task blocked.' }
function Show-SCProviders { $cfg=Get-SCConfig;$rows=@();foreach($property in $cfg.providers.PSObject.Properties){$rows+=[pscustomobject]@{name=$property.Name;command=$property.Value.command;mode=$property.Value.mode}};$rows|Format-Table -AutoSize }
function Show-SCTelemetry([string]$Mode,[string]$Id) { if([string]::IsNullOrWhiteSpace($Mode)){$Mode='active'};switch($Mode.ToLowerInvariant()){'active'{@(Get-SCActiveTelemetry)|Select-Object agentId,taskId,stage,provider,lifecycle,compilationId,startedAt|Format-Table -AutoSize;break};'history'{@(Get-SCTelemetryRuns 100)|Select-Object agentId,taskId,stage,provider,lifecycle,exitCode,verdict,durationSeconds,compilationId,startedAt|Format-Table -AutoSize;break};'faults'{@(Get-SCContextFaults 100)|Select-Object ts,taskId,runId,compilationId,request|Format-Table -AutoSize;break};'show'{if(-not$Id){throw '-RunId required (agent id).'};$record=Read-SCJson (Get-SCPath ("telemetry/runs/{0}.json"-f$Id));if(-not$record){throw "Unknown telemetry run: $Id"};ConvertTo-SCJson $record 14|Write-Host;break};default{throw "Unknown telemetry subcommand: $Mode"}} }
function Show-SCContext([string]$Mode,[string]$Id) { if([string]::IsNullOrWhiteSpace($Mode)){$Mode='faults'};switch($Mode.ToLowerInvariant()){'faults'{@(Get-SCContextFaults 100)|ConvertTo-SCJson -Depth 12|Write-Host;break};'show'{if(-not$Id){throw '-CompilationId required.'};$record=Read-SCJson (Get-SCPath ("compilations/{0}.json"-f$Id));if(-not$record){throw "Unknown compilation: $Id"};ConvertTo-SCJson $record 24|Write-Host;break};default{throw "Unknown context subcommand: $Mode"}} }
function Show-SCProgress([string]$Mode) { if([string]::IsNullOrWhiteSpace($Mode)){$Mode='history'};if($Mode.ToLowerInvariant()-ne'history'){throw "Unknown progress subcommand: $Mode"};@(Get-ChildItem -LiteralPath (Get-SCPath 'progress') -Filter '*.json' -File|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 100|ForEach-Object{Read-SCJson $_.FullName})|Select-Object ts,taskId,advanced,outcome,attemptCount,inputFingerprint|Format-Table -AutoSize }

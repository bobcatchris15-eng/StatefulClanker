<# Resident autofill supervisor.

   It does not plan, reinterpret intent, or bypass gates. It only keeps the
   already-authorized ready queue moving up to maxConcurrent, using the same
   worktree-isolated worker cycles as explicit parallel execution. #>

function Get-SCAutofillDir { Get-SCPath 'autofill' }
function Ensure-SCAutofillLayout { $d=Get-SCAutofillDir;if(-not(Test-Path -LiteralPath $d)){New-Item -ItemType Directory -Force -Path $d|Out-Null} }
function Get-SCAutofillStatusPath { Ensure-SCAutofillLayout;Join-Path (Get-SCAutofillDir) 'supervisor.json' }
function Get-SCAutofillStopPath { Ensure-SCAutofillLayout;Join-Path (Get-SCAutofillDir) 'stop.request' }
function Get-SCAutofillPausePath { Ensure-SCAutofillLayout;Join-Path (Get-SCAutofillDir) 'pause.request' }
function Get-SCAutofillTriggerPath { Ensure-SCAutofillLayout;Join-Path (Get-SCAutofillDir) 'trigger.request' }
function Test-SCProcessAlive([int]$ProcessId) { if($ProcessId-le0){return $false};try{$p=Get-Process -Id $ProcessId -ErrorAction Stop;return(-not$p.HasExited)}catch{return $false} }
function Get-SCAutofillStatus {
    $path=Get-SCAutofillStatusPath;if(-not(Test-Path -LiteralPath $path)){return $null}
    try{$s=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json}catch{return $null}
    if($s.PSObject.Properties['pid']-and(Test-SCProcessAlive ([int]$s.pid))){return $s}
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue;return $null
}
function Test-SCAutofillEnabled {
    $cfg=Get-SCConfig;if($cfg.PSObject.Properties['autofillEnabled']){return [bool]$cfg.autofillEnabled};return $true
}
function Get-SCAutofillIntervalSeconds([int]$Override=0) {
    if($Override-gt0){return [Math]::Max(1,$Override)}
    $cfg=Get-SCConfig
    if($cfg.PSObject.Properties['autofillIntervalSeconds']-and[int]$cfg.autofillIntervalSeconds-gt0){return [Math]::Max(30,[int]$cfg.autofillIntervalSeconds)}
    return 300
}
function Get-SCAutofillMutexName { 'Local\StatefulClanker-Autofill-'+(Get-SCHashString ((Get-SCStateRoot).ToLowerInvariant())).Substring(0,32) }
function Write-SCAutofillStatus($Record) { Ensure-SCAutofillLayout;Write-SCJson (Get-SCAutofillStatusPath) $Record }
function Request-SCAutofillStop { Ensure-SCAutofillLayout;(Get-Date).ToUniversalTime().ToString('o')|Set-Content -LiteralPath (Get-SCAutofillStopPath) -Encoding UTF8;Write-Host 'Autofill stop requested.' }
function Request-SCAutofillPause { Ensure-SCAutofillLayout;(Get-Date).ToUniversalTime().ToString('o')|Set-Content -LiteralPath (Get-SCAutofillPausePath) -Encoding UTF8;Write-Host 'Autofill pause requested.' }
function Request-SCAutofillResume { Ensure-SCAutofillLayout;Remove-Item -LiteralPath (Get-SCAutofillPausePath) -Force -ErrorAction SilentlyContinue;Request-SCAutofillTrigger;Write-Host 'Autofill resumed.' }
function Request-SCAutofillTrigger { Ensure-SCAutofillLayout;(Get-Date).ToUniversalTime().ToString('o')|Set-Content -LiteralPath (Get-SCAutofillTriggerPath) -Encoding UTF8;Write-Host 'Autofill immediate dispatch requested.' }
function Get-SCBusyTaskIds { @((Get-SCTasks|Where-Object{@('running','reviewing','validating')-contains[string]$_.status})|ForEach-Object{[string]$_.id}) }
function Get-SCAutofillQueueSummary {
    $tasks=@(Get-SCTasks);$retryable=@(Get-SCRetryableTasks);$retryIds=@($retryable|ForEach-Object{[string]$_.id})
    $now=[datetimeoffset]::UtcNow
    $routingDeferred=@($tasks|Where-Object{
        if([string]$_.status-ne'ready'-or-not($_.PSObject.Properties['routingNotBefore']-and$_.routingNotBefore)){return $false}
        [datetimeoffset]$retryAt=[datetimeoffset]::MinValue
        return [datetimeoffset]::TryParse([string]$_.routingNotBefore,[ref]$retryAt) -and $retryAt-gt$now
    })
    $dependencyPending=@($tasks|Where-Object{[string]$_.status-eq'pending'})
    $terminalStalled=@($tasks|Where-Object{
        @('needs_rework','stale','blocked','failed')-contains[string]$_.status -and $retryIds-notcontains[string]$_.id
    })
    return [ordered]@{dependencyPending=@($dependencyPending);routingDeferred=@($routingDeferred);retriable=@($retryable);terminalStalled=@($terminalStalled)}
}
function Test-SCAutofillMainTreeReady {
    $root=Get-SCStateRoot
    if(-not(Test-SCGitAvailable)){return [ordered]@{ok=$false;reason='git is not available'}}
    if(-not(Test-SCGitRepo $root)){return [ordered]@{ok=$false;reason='project is not a git repository'}}
    $dirtySummary=Get-SCWorktreeDirtySummary $root
    if($dirtySummary){return [ordered]@{ok=$false;reason=[string]$dirtySummary.message;dirtyPaths=@($dirtySummary.paths);dirtyCount=[int]$dirtySummary.count}}
    return [ordered]@{ok=$true;reason=$null}
}

function Invoke-SCAutofillSupervisor([int]$IntervalSeconds=0,[string]$Provider,[string]$HarnessPath,[string]$Endpoint=$null,[string]$Connection=$null,[switch]$NoMerge) {
    Assert-SCInitialized
    if(-not(Test-SCAutofillEnabled)){Write-Host 'Autofill is disabled in project config.';return}
    $interval=Get-SCAutofillIntervalSeconds $IntervalSeconds
    $mutex=New-Object Threading.Mutex($false,(Get-SCAutofillMutexName));$owned=$false
    try{$owned=$mutex.WaitOne(0)}catch{$owned=$false}
    if(-not$owned){Write-Host 'Autofill supervisor is already running for this project.';$mutex.Dispose();return}
    $stopPath=Get-SCAutofillStopPath;$pausePath=Get-SCAutofillPausePath;$triggerPath=Get-SCAutofillTriggerPath
    Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pausePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $triggerPath -Force -ErrorAction SilentlyContinue
    $started=(Get-Date).ToUniversalTime().ToString('o');$running=@();$lastDispatch=[datetime]::MinValue;$lastBlock=$null
    $limit=Get-SCMaxConcurrent;$state='starting';$reason=$null;$readyCount=0;$slots=$limit
    Write-SCAutofillStatus ([ordered]@{schemaVersion=1;pid=$PID;startedAt=$started;updatedAt=$started;state=$state;paused=$false;intervalSeconds=$interval;maxConcurrent=$limit;ownedActive=0;activeTasks=@();readyCount=0;slots=$slots;lastDispatchAt=$null;blockReason=$null})
    Add-SCEvent 'autofill.started' "Autofill supervisor started; interval ${interval}s." @{pid=$PID;intervalSeconds=$interval;maxConcurrent=$limit}
    try {
        while($true){
            $now=Get-Date;$results=@();$still=@()
            foreach($r in @($running)){
                if($r.process.HasExited){try{$results+=,(Complete-SCParallelChild (Get-SCStateRoot) $r -NoMerge:$NoMerge)}catch{Write-Warning "Autofill could not finalize $($r.taskId): $($_.Exception.Message)"};try{$r.process.Dispose()}catch{}}
                else{$still+=,$r}
            }
            $running=@($still)
            if($results.Count-gt0){Invoke-SCParallelPostMergeReview $results}

            $stopRequested=Test-Path -LiteralPath $stopPath
            if($stopRequested-and$running.Count-eq0){break}

            $isPaused=Test-Path -LiteralPath $pausePath
            if($isPaused){
                $state='paused';$reason='autofill is paused by request';$busyNow=@(Get-SCBusyTaskIds)
                Write-SCAutofillStatus ([ordered]@{schemaVersion=1;pid=$PID;startedAt=$started;updatedAt=(Get-Date).ToUniversalTime().ToString('o');state=$state;paused=$true;intervalSeconds=$interval;maxConcurrent=$limit;ownedActive=$running.Count;activeTasks=$busyNow;readyCount=$readyCount;slots=$slots;lastDispatchAt=if($lastDispatch-eq[datetime]::MinValue){$null}else{$lastDispatch.ToUniversalTime().ToString('o')};blockReason=$reason})
                Start-Sleep -Seconds 2
                continue
            }

            $isTriggered=Test-Path -LiteralPath $triggerPath
            if($isTriggered){Remove-Item -LiteralPath $triggerPath -Force -ErrorAction SilentlyContinue}

            $limit=Get-SCMaxConcurrent
            $busy=@(Get-SCBusyTaskIds)
            $ownedIds=@($running|ForEach-Object{[string]$_.taskId})
            $all=@($busy+$ownedIds|Select-Object -Unique)
            $slots=[Math]::Max(0,$limit-$all.Count)

            $readyCandidates=@(Get-SCDispatchableTasks|Where-Object{$all-notcontains[string]$_.id})
            $retryCandidates=@(Get-SCRetryableTasks|Where-Object{$all-notcontains[string]$_.id})
            $readyCount=$readyCandidates.Count
            $retryCount=$retryCandidates.Count

            $reason=$null
            try{Assert-SCDispatchAuthority;Assert-SCNotHeld}catch{$reason=$_.Exception.Message}
            if(-not$reason){$tree=Test-SCAutofillMainTreeReady;if(-not$tree.ok){$reason=[string]$tree.reason}}

            if(-not$stopRequested-and-not$reason-and$slots-gt0){
                $lastDispatch=$now
                $dispatched=0
                $dispatchPlan=if(Get-Command Select-SCImplementationDispatchPlan -ErrorAction SilentlyContinue){Select-SCImplementationDispatchPlan $readyCandidates $slots $all}else{[pscustomobject]@{tasks=@($readyCandidates|Select-Object -First $slots);formations=@();deferred=@()}}
                $dispatchWave=@($dispatchPlan.tasks)
                foreach($formation in @($dispatchPlan.formations)){Add-SCEvent 'dispatch.formation' "Dispatch selected $($formation.kind) formation $($formation.id)." @{formationId=$formation.id;kind=$formation.kind;state=$formation.state;launched=@($formation.launched);members=@($formation.members);slots=$slots}}
                foreach($deferredFormation in @($dispatchPlan.deferred)){Add-SCEvent 'dispatch.formation_deferred' "Deferred formation $($deferredFormation.formationId): $($deferredFormation.reason)" @{formationId=$deferredFormation.formationId;taskIds=@($deferredFormation.taskIds);reason=$deferredFormation.reason;slots=$slots}}
                foreach($task in @($dispatchWave)){
                    try{
                        $wt=New-SCWorktree (Get-SCStateRoot) $task.id
                        $run=Start-SCCycleProcess (Get-SCStateRoot) $wt $task.id $Provider $HarnessPath $Endpoint $Connection
                        $running+=,$run
                        $dispatched++
                        Add-SCEvent 'autofill.dispatched' "Autofill dispatched $($task.id)." @{taskId=$task.id;activeAfter=$running.Count;maxConcurrent=$limit;queue='ready'}
                    }catch{
                        Write-Warning "Autofill could not start $($task.id): $($_.Exception.Message)"
                        try{Remove-SCWorktree (Get-SCStateRoot) $task.id}catch{}
                    }
                }

                $remainingSlots=$slots-$dispatched
                if($remainingSlots-gt 0){
                    foreach($task in @($retryCandidates|Select-Object -First $remainingSlots)){
                        try{
                            Write-Host "Autofill retrying $($task.id) from retry queue..."
                            Retry-SCTask $task.id
                            $wt=New-SCWorktree (Get-SCStateRoot) $task.id
                            $run=Start-SCCycleProcess (Get-SCStateRoot) $wt $task.id $Provider $HarnessPath $Endpoint $Connection
                            $running+=,$run
                            Add-SCEvent 'autofill.dispatched' "Autofill dispatched $($task.id) from retry queue." @{taskId=$task.id;activeAfter=$running.Count;maxConcurrent=$limit;queue='retry'}
                        }catch{
                            Write-Warning "Autofill could not retry $($task.id): $($_.Exception.Message)"
                            try{Remove-SCWorktree (Get-SCStateRoot) $task.id}catch{}
                        }
                    }
                }

                $busy=@(Get-SCBusyTaskIds)
                $ownedIds=@($running|ForEach-Object{[string]$_.taskId})
                $all=@($busy+$ownedIds|Select-Object -Unique)
                $slots=[Math]::Max(0,$limit-$all.Count)
                $readyCandidates=@(Get-SCDispatchableTasks|Where-Object{$all-notcontains[string]$_.id})
                $retryCandidates=@(Get-SCRetryableTasks|Where-Object{$all-notcontains[string]$_.id})
                $readyCount=$readyCandidates.Count
                $retryCount=$retryCandidates.Count
            }

            if($reason){
                $state='blocked'
                if($lastBlock-ne$reason){Add-SCEvent 'autofill.blocked' $reason @{maxConcurrent=$limit};$lastBlock=$reason}
            }else{
                if($stopRequested){
                    $state='draining'
                    $lastBlock=$null
                }elseif($running.Count-gt0 -or $busy.Count-gt0){
                    $state='running'
                    $lastBlock=$null
                }elseif($readyCount-gt0 -or $retryCount-gt0){
                    $state='running'
                    $lastBlock=$null
                }else{
                    $queue=Get-SCAutofillQueueSummary
                    $dependencyPending=@($queue.dependencyPending);$routingDeferred=@($queue.routingDeferred);$terminalStalled=@($queue.terminalStalled)
                    if($terminalStalled.Count-gt0){
                        $stalled=$terminalStalled
                        $stalledDetails=@($stalled|ForEach-Object{
                            [ordered]@{
                                id=[string]$_.id;title=[string]$_.title;status=[string]$_.status
                                humanGate=[bool]$_.humanGate
                                attemptCount=if($_.PSObject.Properties['attemptCount']){[int]$_.attemptCount}else{0}
                                criticRejectCount=if($_.PSObject.Properties['criticRejectCount']){[int]$_.criticRejectCount}else{0};validatorRejectCount=if($_.PSObject.Properties['validatorRejectCount']){[int]$_.validatorRejectCount}else{0}
                                blockReason=if($_.PSObject.Properties['blockReason']){[string]$_.blockReason}else{$null}
                                latestRunId=if($_.PSObject.Properties['latestRunId']){$_.latestRunId}else{$null}
                                latestProposalId=if($_.PSObject.Properties['latestProposalId']){$_.latestProposalId}else{$null}
                                latestCritiqueId=if($_.PSObject.Properties['latestCritiqueId']){$_.latestCritiqueId}else{$null}
                                latestValidationId=if($_.PSObject.Properties['latestValidationId']){$_.latestValidationId}else{$null}
                            }
                        })
                        $stalledNames=(@($stalled|Select-Object -First 3|ForEach-Object{"$($_.id) ($($_.status))"})) -join ', '
                        if($stalled.Count-gt3){$stalledNames+=" (+$($stalled.Count-3) more)"}
                        $reason="CONTROL-PLANE RECOVERY REQUIRED: Autofill has $($dependencyPending.Count) dependency-pending, $($routingDeferred.Count) routing-deferred, $($queue.retriable.Count) retriable, and $($stalled.Count) terminal-stalled task(s): $stalledNames. Investigate and repair before asking the human. Read task_recovery_context for each affected task and inspect current project files/tests as needed. Repair actual implementation defects when present; otherwise repair stale/incorrect task scope, acceptance, retrieval, dependencies, or other task-graph metadata and retry. If concrete current evidence shows the requested work already satisfies current Human Directives and reconciled Intent but validator/review bookkeeping is wrong, use task_recover_complete as the last resort. Never override a human-gated task or unresolved human intent. Ask the human only when a genuine authority/design decision remains after investigation. Trigger/resume Autofill after recovery."
                        $state='blocked'
                        if($lastBlock-ne$reason){Add-SCEvent 'autofill.stalled' $reason @{stalledCount=$stalled.Count;stalledTasks=@($stalledDetails);recoveryPolicy='control-plane-first'};$lastBlock=$reason}
                    }elseif($dependencyPending.Count-gt0-or$routingDeferred.Count-gt0){
                        $state='waiting'
                        $reason="Autofill waiting: $($dependencyPending.Count) dependency-pending, $($routingDeferred.Count) routing-deferred, $($queue.retriable.Count) retriable, and 0 terminal-stalled task(s). Routing-deferred work will be reconsidered when its cooldown expires; complete dependencies or adjust the task graph before retrying dependency-pending work."
                        $lastBlock=$null
                    }else{
                        $state='idle'
                        $lastBlock=$null
                    }
                }
            }
            $busyNow=@(Get-SCBusyTaskIds)
            Write-SCAutofillStatus ([ordered]@{schemaVersion=1;pid=$PID;startedAt=$started;updatedAt=(Get-Date).ToUniversalTime().ToString('o');state=$state;paused=$false;intervalSeconds=$interval;maxConcurrent=$limit;activeWorkers=$all.Count;ownedActive=$running.Count;activeTasks=$busyNow;readyCount=$readyCount;retryCount=$retryCount;slots=$slots;lastDispatchAt=if($lastDispatch-eq[datetime]::MinValue){$null}else{$lastDispatch.ToUniversalTime().ToString('o')};blockReason=$reason})

            $waitLimit = if($running.Count -gt 0){ 2 } else { $interval }
            for($w = 0; $w -lt $waitLimit; $w += 1){
                Start-Sleep -Seconds 1
                if((Test-Path -LiteralPath $stopPath) -or (Test-Path -LiteralPath $pausePath) -or (Test-Path -LiteralPath $triggerPath)){
                    break
                }
            }
        }
    } finally {
        Add-SCEvent 'autofill.stopped' 'Autofill supervisor stopped.' @{pid=$PID}
        Remove-Item -LiteralPath (Get-SCAutofillStatusPath) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $pausePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $triggerPath -Force -ErrorAction SilentlyContinue
        if($owned){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()
    }
}

function Show-SCAutofillStatus {
    $s=Get-SCAutofillStatus
    if($null-eq$s){Write-Host 'Autofill: stopped';return}
    $retryTxt = if($s.PSObject.Properties['retryCount'] -and $s.retryCount -gt 0){ ", $($s.retryCount) retry" } else { "" }
    Write-Host "Autofill: $($s.state)  PID $($s.pid)  active $(@($s.activeTasks).Count)/$($s.maxConcurrent)  ready $($s.readyCount)$retryTxt  slots $($s.slots)  interval $($s.intervalSeconds)s"
    if($s.PSObject.Properties['blockReason']-and$s.blockReason){Write-Host "Blocked: $($s.blockReason)"}
}

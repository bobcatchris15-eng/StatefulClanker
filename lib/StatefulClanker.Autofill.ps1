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
function Test-SCAutofillMainTreeReady {
    $root=Get-SCStateRoot
    if(-not(Test-SCGitAvailable)){return [ordered]@{ok=$false;reason='git is not available'}}
    if(-not(Test-SCGitRepo $root)){return [ordered]@{ok=$false;reason='project is not a git repository'}}
    $old=$ErrorActionPreference;try{$ErrorActionPreference='Continue';$dirty=& git -C $root status --porcelain 2>$null|Out-String}finally{$ErrorActionPreference=$old}
    if([string]::IsNullOrWhiteSpace($dirty)){return [ordered]@{ok=$true;reason=$null}}
    $dirtyLines=@($dirty -split "`r?`n"|Where-Object{
        if([string]::IsNullOrWhiteSpace($_)){return $false}
        $line=$_.Trim()
        $filePart=if($line.Length -gt 3){$line.Substring(3).Trim()}else{$line}
        if($filePart -match '^\.statefulclanker[/\\]?' -or $filePart -eq '.statefulclanker'){return $false}
        return $true
    })
    if($dirtyLines.Count -gt 0){
        $preview=(@($dirtyLines|Select-Object -First 5)) -join ', '
        if($dirtyLines.Count -gt 5){$preview+=" (+$($dirtyLines.Count - 5) more)"}
        return [ordered]@{ok=$false;reason="main worktree has uncommitted changes: $preview"}
    }
    return [ordered]@{ok=$true;reason=$null}
}

function Invoke-SCAutofillSupervisor([int]$IntervalSeconds=0,[string]$Provider,[string]$HarnessPath,[switch]$NoMerge) {
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
            $external=@($busy|Where-Object{$ownedIds-notcontains$_})
            $slots=[Math]::Max(0,$limit-$all.Count)
            $candidates=@(Get-SCDispatchableTasks|Where-Object{$all-notcontains[string]$_.id})
            $readyCount=$candidates.Count

            $reason=$null
            try{Assert-SCDispatchAuthority;Assert-SCNotHeld}catch{$reason=$_.Exception.Message}
            if(-not$reason){$tree=Test-SCAutofillMainTreeReady;if(-not$tree.ok){$reason=[string]$tree.reason}}
            if(-not$reason-and$external.Count-gt0){$reason="non-autofill task(s) already active: $($external -join ', ')"}

            if(-not$stopRequested-and-not$reason-and$slots-gt0-and$readyCount-gt0){
                $lastDispatch=$now
                foreach($task in @($candidates|Select-Object -First $slots)){
                    try{
                        $wt=New-SCWorktree (Get-SCStateRoot) $task.id
                        $run=Start-SCCycleProcess (Get-SCStateRoot) $wt $task.id $Provider $HarnessPath
                        $running+=,$run
                        Add-SCEvent 'autofill.dispatched' "Autofill dispatched $($task.id)." @{taskId=$task.id;activeAfter=$running.Count;maxConcurrent=$limit}
                    }catch{
                        Write-Warning "Autofill could not start $($task.id): $($_.Exception.Message)"
                        try{Remove-SCWorktree (Get-SCStateRoot) $task.id}catch{}
                    }
                }
                $busy=@(Get-SCBusyTaskIds)
                $ownedIds=@($running|ForEach-Object{[string]$_.taskId})
                $all=@($busy+$ownedIds|Select-Object -Unique)
                $slots=[Math]::Max(0,$limit-$all.Count)
                $candidates=@(Get-SCDispatchableTasks|Where-Object{$all-notcontains[string]$_.id})
                $readyCount=$candidates.Count
            }

            if($reason){
                $state='blocked'
                if($lastBlock-ne$reason){Add-SCEvent 'autofill.blocked' $reason @{maxConcurrent=$limit};$lastBlock=$reason}
            }else{
                $lastBlock=$null
                if($stopRequested){
                    $state='draining'
                }elseif($running.Count-gt0){
                    $state='running'
                }elseif($readyCount-gt0){
                    $state='running'
                }else{
                    $stalled=@(Get-SCTasks|Where-Object{@('needs_rework','stale','blocked')-contains[string]$_.status})
                    if($stalled.Count-gt0){
                        $stalledNames=(@($stalled|Select-Object -First 3|ForEach-Object{"$($_.id) ($($_.status))"})) -join ', '
                        if($stalled.Count-gt3){$stalledNames+=" (+$($stalled.Count-3) more)"}
                        $reason="no ready tasks; $($stalled.Count) task(s) require intervention/retry: $stalledNames"
                        $state='blocked'
                        if($lastBlock-ne$reason){Add-SCEvent 'autofill.stalled' $reason @{stalledCount=$stalled.Count};$lastBlock=$reason}
                    }else{
                        $state='idle'
                    }
                }
            }
            $busyNow=@(Get-SCBusyTaskIds)
            Write-SCAutofillStatus ([ordered]@{schemaVersion=1;pid=$PID;startedAt=$started;updatedAt=(Get-Date).ToUniversalTime().ToString('o');state=$state;paused=$false;intervalSeconds=$interval;maxConcurrent=$limit;ownedActive=$running.Count;activeTasks=$busyNow;readyCount=$readyCount;slots=$slots;lastDispatchAt=if($lastDispatch-eq[datetime]::MinValue){$null}else{$lastDispatch.ToUniversalTime().ToString('o')};blockReason=$reason})
            Start-Sleep -Seconds 2
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
    Write-Host "Autofill: $($s.state)  PID $($s.pid)  active $(@($s.activeTasks).Count)/$($s.maxConcurrent)  ready $($s.readyCount)  slots $($s.slots)  interval $($s.intervalSeconds)s"
    if($s.PSObject.Properties['blockReason']-and$s.blockReason){Write-Host "Blocked: $($s.blockReason)"}
}

<# Parallel execution: run several ready tasks at once, each in its own git worktree.

   Tasks declare what they READ (retrieval, evidence) but never what they WRITE, so
   the scheduler cannot know whether two ready tasks will touch the same file. Each
   cycle therefore gets an isolated worktree. Durable state remains canonical in the
   main tree and is serialized across processes by the Core state mutex. #>

function Test-SCGitAvailable {
    return [bool](Get-Command git -ErrorAction SilentlyContinue)
}

function Invoke-SCGitCapture([string]$WorkingPath,[string[]]$Arguments) {
    $oldPreference=$ErrorActionPreference
    $text='';$code=-1
    try {
        $ErrorActionPreference='Continue'
        $text=(& git -C $WorkingPath @Arguments 2>&1 | Out-String)
        $code=$LASTEXITCODE
    } finally {
        $ErrorActionPreference=$oldPreference
        $global:LASTEXITCODE=0
    }
    return [ordered]@{exitCode=[int]$code;output=[string]$text}
}

function Test-SCGitRepo([string]$Path) {
    if (-not (Test-SCGitAvailable)) { return $false }
    $res = Invoke-SCGitCapture $Path @('rev-parse', '--is-inside-work-tree')
    return ($res.exitCode -eq 0 -and $res.output -match 'true')
}

function Get-SCWorktreeRoot([string]$StateRoot) {
    Join-Path (Join-Path $StateRoot '.statefulclanker') 'worktrees'
}

function Get-SCDispatchableTasks {
    Update-SCReadiness
    $now=[datetimeoffset]::UtcNow
    return @(Get-SCTasks |
        Where-Object {
            if($_.status-ne'ready' -or [bool]$_.humanGate){return $false}
            if($_.PSObject.Properties['routingNotBefore'] -and $_.routingNotBefore){
                $at=[datetimeoffset]::MinValue
                if([datetimeoffset]::TryParse([string]$_.routingNotBefore,[ref]$at) -and $at-gt$now){return $false}
            }
            return $true
        } |
        Sort-Object createdAt)
}

function Get-SCRetryableTasks {
    $tasks = @(Get-SCTasks)
    $cfg = Get-SCConfig
    $maxAttempts = if($cfg.PSObject.Properties['maxTaskAttempts'] -and $cfg.maxTaskAttempts){ [int]$cfg.maxTaskAttempts } else { 5 }
    $map = @{}
    foreach($t in $tasks){ if($t.id){ $map[[string]$t.id] = $t } }
    $retryable = @()
    foreach($t in $tasks){
        if(@('needs_rework','stale','failed') -notcontains [string]$t.status){ continue }
        if([bool]$t.humanGate){ continue }
        $attempts = if ($t.PSObject.Properties['attemptCount']) { [int]$t.attemptCount } else { 0 }
        if($attempts -ge $maxAttempts){ continue }

        $depsMet = $true
        foreach($dep in @($t.dependsOn)){
            if([string]::IsNullOrWhiteSpace([string]$dep)){ continue }
            if(-not $map.ContainsKey([string]$dep) -or $map[[string]$dep].status -ne 'complete'){
                $depsMet = $false
                break
            }
        }
        if($depsMet){
            $retryable += ,$t
        }
    }
    return @($retryable | Sort-Object updatedAt)
}

function Close-SCFailedTaskWorkerSession($Task,[string]$Status='failed') {
    if($null-eq$Task){return}
    $sessionId=if($Task.PSObject.Properties['activeWorkerSessionId']){[string]$Task.activeWorkerSessionId}else{$null}
    Set-SCProperty $Task 'activeWorkerSessionId' $null
    Save-SCTask $Task
    if($sessionId-and(Get-Command Close-SCWorkerSession -ErrorAction SilentlyContinue)){try{Close-SCWorkerSession $sessionId $Status}catch{}}
}

function Get-SCMaxConcurrent([int]$Override = 0) {
    if ($Override -gt 0) { return $Override }
    $cfg = Get-SCConfig
    if ($cfg.PSObject.Properties['maxConcurrent'] -and $cfg.maxConcurrent) {
        return [Math]::Max(1, [int]$cfg.maxConcurrent)
    }
    return 1
}

function Test-SCBranchExists([string]$StateRoot,[string]$Branch) {
    $res = Invoke-SCGitCapture $StateRoot @('show-ref', '--verify', '--quiet', "refs/heads/$Branch")
    return ($res.exitCode -eq 0)
}
function Remove-SCBranchIfExists([string]$StateRoot,[string]$Branch) {
    if (-not (Test-SCBranchExists $StateRoot $Branch)) { return }
    $result=Invoke-SCGitCapture $StateRoot @('branch','-D',$Branch)
    if ($result.exitCode -ne 0) { throw "git branch cleanup failed for $Branch : $($result.output)" }
}

function New-SCWorktree([string]$StateRoot, [string]$TaskId) {
    $root = Get-SCWorktreeRoot $StateRoot
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
    $slug = ($TaskId -replace '[^A-Za-z0-9_.-]', '-')
    $path = Join-Path $root $slug
    $branch = "sc/task/$slug"

    if (Test-Path -LiteralPath $path) { Remove-SCWorktree $StateRoot $TaskId }
    Remove-SCBranchIfExists $StateRoot $branch

    $result=Invoke-SCGitCapture $StateRoot @('worktree','add','-b',$branch,$path,'HEAD')
    if ($result.exitCode -ne 0) { throw "git worktree add failed for $TaskId : $($result.output)" }
    return [ordered]@{ taskId = $TaskId; path = (Resolve-Path -LiteralPath $path).Path; branch = $branch }
}

function Remove-SCWorktree([string]$StateRoot, [string]$TaskId, [switch]$KeepBranch) {
    $slug = ($TaskId -replace '[^A-Za-z0-9_.-]', '-')
    $path = Join-Path (Get-SCWorktreeRoot $StateRoot) $slug
    $branch = "sc/task/$slug"
    if (Test-Path -LiteralPath $path) {
        $result=Invoke-SCGitCapture $StateRoot @('worktree','remove','--force',$path)
        if ($result.exitCode -ne 0 -and (Test-Path -LiteralPath $path)) {
            Remove-Item -Recurse -Force -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }
    & git -C $StateRoot worktree prune 2>$null | Out-Null
    if (-not $KeepBranch) { Remove-SCBranchIfExists $StateRoot $branch }
}

function Save-SCWorktreeWork($Worktree, [string]$Message) {
    & git -C $Worktree.path add -A 2>$null | Out-Null
    $status = & git -C $Worktree.path status --porcelain 2>$null | Out-String
    if ([string]::IsNullOrWhiteSpace($status)) { return $false }
    $result=Invoke-SCGitCapture $Worktree.path @('-c','user.name=StatefulClanker','-c','user.email=statefulclanker@localhost','commit','-m',$Message)
    if ($result.exitCode -ne 0) { throw "git commit failed in $($Worktree.path): $($result.output)" }
    return $true
}

function Merge-SCWorktreeBranch([string]$StateRoot, $Worktree) {
    $result=Invoke-SCGitCapture $StateRoot @('merge','--no-ff','--no-edit',[string]$Worktree.branch)
    if ($result.exitCode -ne 0) {
        & git -C $StateRoot merge --abort 2>$null | Out-Null
        return [ordered]@{ merged = $false; reason = 'merge conflict'; detail = $result.output.Trim() }
    }
    return [ordered]@{ merged = $true; reason = $null; detail = $result.output.Trim() }
}

function Start-SCCycleProcess([string]$StateRoot, $Worktree, [string]$TaskId, [string]$Provider, [string]$HarnessPath, [string]$Endpoint=$null, [string]$Connection=$null) {
    $logDir = Join-Path (Join-Path $StateRoot '.statefulclanker') 'parallel'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $slug = ($TaskId -replace '[^A-Za-z0-9_.-]', '-')
    $logPath = Join-Path $logDir "$slug-$stamp.log"

    $cli = @('run', '-TaskId', $TaskId, '-StateRoot', $StateRoot)
    if ($Provider) { $cli += @('-Provider', $Provider) }
    if ($Endpoint) { $cli += @('-Endpoint', $Endpoint) }
    if ($Connection) { $cli += @('-Connection', $Connection) }

    $pwshPath = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($pwshPath)) { $pwshPath = 'pwsh' }
    $quoted = ((@('-NoProfile', '-NonInteractive', '-File', $HarnessPath) + $cli) |
        ForEach-Object { if ($_ -match '[ \t"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '

    $proc = Start-Process -FilePath $pwshPath -ArgumentList $quoted -WorkingDirectory $Worktree.path `
        -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err" -WindowStyle Hidden -PassThru

    return [ordered]@{
        taskId = $TaskId; worktree = $Worktree; process = $proc
        logPath = $logPath; startedAt = (Get-Date); provider = $Provider; endpoint = $Endpoint; connection = $Connection
    }
}

function Get-SCParallelChildOutput($Run) {
    $stdout = if (Test-Path -LiteralPath $Run.logPath) { Get-Content -Raw -LiteralPath $Run.logPath } else { '' }
    $errPath = "$($Run.logPath).err"
    $stderr = if (Test-Path -LiteralPath $errPath) { Get-Content -Raw -LiteralPath $errPath } else { '' }
    return [ordered]@{ stdout=[string]$stdout; stderr=[string]$stderr }
}

function Complete-SCParallelChild([string]$StateRoot, $Run, [switch]$NoMerge) {
    $task = Get-SCTask $Run.taskId
    $child=$null
    $entry = [ordered]@{ taskId = $Run.taskId; status = $task.status; committed = $false; merged = $false; reason = $null; logPath = $Run.logPath }
    if ($Run.process.ExitCode -ne 0) {
        $child=Get-SCParallelChildOutput $Run
        $err = [string]$child.stderr + "`n" + [string]$child.stdout
        Write-Warning "parallel child $($Run.taskId) exited $($Run.process.ExitCode). STDOUT: $($child.stdout) STDERR: $($child.stderr)"
        
        $isTransient = $false
        if ($err -match '(?i)quota exhausted|insufficient_quota|rate limit|429 too many requests') {
            $isTransient = $true
            if ($Run.provider) {
                $cfg = Get-SCConfig
                if ($cfg.providers -and $cfg.providers.PSObject.Properties.Match($Run.provider).Count -gt 0) {
                    $p = $cfg.providers.($Run.provider)
                    if (-not $p.PSObject.Properties['disabled']) { $p | Add-Member -NotePropertyName 'disabled' -NotePropertyValue $true } else { $p.disabled = $true }
                    Write-SCJson (Get-SCPath 'config.json') $cfg
                    Write-Warning "Provider '$($Run.provider)' disabled due to quota/rate limit error."
                }
            }
        } elseif ($err -match '(?i)timeout|transient|connection refused|502 bad gateway|503 service unavailable|504 gateway timeout') {
            $isTransient = $true
        }

        if ($isTransient) {
            $task.status = 'ready'
            $task.blockReason = $null
            Save-SCTask $task
            Add-SCEvent 'task.retried.transient' "Retrying task $($task.id) due to transient error." @{taskId=$task.id}
            $entry.reason = "Transient error, task requeued."
            $entry.status = 'ready'
            Remove-SCWorktree $StateRoot $Run.taskId
            return $entry
        }

        if (@('running','reviewing','validating') -contains $task.status) {
            $workerSessionId=if($task.PSObject.Properties['activeWorkerSessionId']){[string]$task.activeWorkerSessionId}else{$null}
            $detail=@(([string]$child.stderr -split "\r?\n")+([string]$child.stdout -split "\r?\n") |
                Where-Object{-not[string]::IsNullOrWhiteSpace($_)} | Select-Object -Last 4) -join ' | '
            if($detail.Length-gt320){$detail=$detail.Substring(0,317)+'...'}
            $task.status = 'failed'
            $task.blockReason = "Worker crashed with exit code $($Run.process.ExitCode)"+$(if($detail){": $detail"}else{''})
            Close-SCFailedTaskWorkerSession $task 'crashed'
            Add-SCEvent 'run.failed' $task.blockReason @{
                taskId=$task.id
                exitCode=[int]$Run.process.ExitCode
                provider=$Run.provider
                workerSessionId=$workerSessionId
                logPath=$Run.logPath
                detail=$detail
            }
        }
    }
    if ($task.status -ne 'complete') {
        if (-not $child) { $child=Get-SCParallelChildOutput $Run }
        $entry.reason = if ($task.blockReason) { [string]$task.blockReason } else { "cycle ended as '$($task.status)'" }
        $preservedBranch = $null
        try {
            $hasWork = Save-SCWorktreeWork $Run.worktree "failed $($Run.taskId) attempt: $($entry.reason)"
            if ($hasWork) {
                $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
                $slug = ($Run.taskId -replace '[^A-Za-z0-9_.-]', '-')
                $failBranch = "failed/$slug/$stamp"
                & git -C $StateRoot branch $failBranch $Run.worktree.branch 2>$null | Out-Null
                $preservedBranch = $failBranch
                Add-SCEvent 'worktree.failed.preserved' "Preserved worktree snapshot for failed $($Run.taskId)." @{ taskId = $Run.taskId; branch = $failBranch }
            }
        } catch {}
        if ($preservedBranch) {
            $entry.reason = if ($entry.reason) { "$($entry.reason) (work preserved on $preservedBranch)" } else { "work preserved on $preservedBranch" }
            Remove-SCWorktree $StateRoot $Run.taskId -KeepBranch
        } else {
            Remove-SCWorktree $StateRoot $Run.taskId
        }
        return $entry
    }
    try {
        $entry.committed = Save-SCWorktreeWork $Run.worktree "$($Run.taskId): $($task.title)"
        if (-not $entry.committed) {
            $entry.reason = 'validated but changed no files - check the provider could actually write'
            Remove-SCWorktree $StateRoot $Run.taskId
            return $entry
        }
    } catch {
        $entry.reason = $_.Exception.Message
        Remove-SCWorktree $StateRoot $Run.taskId
        return $entry
    }
    if ($NoMerge) {
        $entry.reason = "left on branch $($Run.worktree.branch)"
        Remove-SCWorktree $StateRoot $Run.taskId -KeepBranch
        return $entry
    }
    $merge = Merge-SCWorktreeBranch $StateRoot $Run.worktree
    $entry.merged = $merge.merged
    if (-not $merge.merged) {
        $entry.reason = "$($merge.reason) - work kept on branch $($Run.worktree.branch)"
        $current = Get-SCTask $Run.taskId
        $current.status = 'needs_rework'
        $current.blockReason = "Merge conflict against the main tree; work preserved on $($Run.worktree.branch)."
        Save-SCTask $current
        Add-SCEvent 'merge.conflict' $current.blockReason @{ taskId = $Run.taskId; branch = $Run.worktree.branch }
        Remove-SCWorktree $StateRoot $Run.taskId -KeepBranch
    } else {
        Add-SCEvent 'merge.completed' "Merged $($Run.worktree.branch)." @{ taskId = $Run.taskId; branch = $Run.worktree.branch }
        Remove-SCWorktree $StateRoot $Run.taskId
    }
    return $entry
}

function Invoke-SCParallelPostMergeReview($Results) {
    $mergedCount = @($Results | Where-Object { $_.merged }).Count
    if ($mergedCount -gt 1) {
        Write-Host ''
        Write-Warning "$mergedCount branches were merged. Merging cleanly is not the same as still working: two changes that each passed alone can break together with no textual conflict."
    }
    $afterMerge = [bool](Get-SCProjectReviewSetting 'projectReviewAfterMultiMerge' $true)
    if ($mergedCount -gt 1 -and $afterMerge -and (Get-SCProjectReviewInterval) -gt 0) {
        Invoke-SCProjectReview 'multi-merge' | Out-Null
    } elseif ($mergedCount -gt 0) {
        Invoke-SCProjectReviewIfDue 'interval' | Out-Null
    }
}

function Invoke-SCParallel([int]$Limit=0, [string]$Provider, [string]$Endpoint=$null, [string]$Connection=$null, [switch]$NoMerge, [switch]$NoProjectReview) {
    Assert-SCInitialized
    $stateRoot = Get-SCStateRoot
    $cfg = Get-SCConfig

    if (-not (Test-SCGitAvailable)) { throw 'parallel execution requires git on PATH' }
    if (-not (Test-SCGitRepo $stateRoot)) { throw "$stateRoot is not a git repository" }
    $dirtySummary=Get-SCWorktreeDirtySummary $stateRoot
    if($dirtySummary){throw [string]$dirtySummary.message}

    $candidates = @(Get-SCDispatchableTasks)
    if ($candidates.Count -eq 0) { Write-Host 'No runnable ready tasks.'; return }

    $limit = if ($Limit -gt 0) { $Limit } else { Get-SCMaxConcurrent }
    $HarnessPath = Join-Path $script:StatefulClankerHome 'StatefulClanker.ps1'

    $batch = @($candidates | Select-Object -First $limit)
    Write-Host "Dispatching $($batch.Count) of $($candidates.Count) ready task(s), limit $limit."

    $running = @()
    foreach ($task in $batch) {
        try {
            $wt = New-SCWorktree $stateRoot $task.id
            $running += Start-SCCycleProcess $stateRoot $wt $task.id $Provider $HarnessPath $Endpoint $Connection
            Write-Host "  started $($task.id) in $($wt.path)"
        } catch {
            Write-Warning "  could not start $($task.id): $($_.Exception.Message)"
            Remove-SCWorktree $stateRoot $task.id
        }
    }
    if ($running.Count -eq 0) { Write-Warning 'Nothing started.'; return }

    Write-Host 'Waiting for cycles to finish...'
    foreach ($r in $running) { $r.process.WaitForExit() }
    foreach ($r in $running) {
        if ($r.process.ExitCode -ne 0) {
            $child=Get-SCParallelChildOutput $r
            Write-Warning "parallel child $($r.taskId) exited $($r.process.ExitCode). STDOUT: $($child.stdout) STDERR: $($child.stderr)"
        }
    }

    $results = @()
    foreach ($r in $running) {
        $task = Get-SCTask $r.taskId
        $entry = [ordered]@{ taskId = $r.taskId; status = $task.status; committed = $false; merged = $false; reason = $null; logPath = $r.logPath }
        if ($task.status -ne 'complete') {
            $child=Get-SCParallelChildOutput $r
            $entry.reason = if ($task.blockReason) { [string]$task.blockReason } else { "cycle ended as '$($task.status)'" }
            Write-Warning "parallel child $($r.taskId) exited $($r.process.ExitCode) without completing task. STDOUT: $($child.stdout) STDERR: $($child.stderr)"
            $preservedBranch = $null
            try {
                $hasWork = Save-SCWorktreeWork $r.worktree "failed $($r.taskId) attempt: $($entry.reason)"
                if ($hasWork) {
                    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
                    $slug = ($r.taskId -replace '[^A-Za-z0-9_.-]', '-')
                    $failBranch = "failed/$slug/$stamp"
                    & git -C $stateRoot branch $failBranch $r.worktree.branch 2>$null | Out-Null
                    $preservedBranch = $failBranch
                    Add-SCEvent 'worktree.failed.preserved' "Preserved worktree snapshot for failed $($r.taskId)." @{ taskId = $r.taskId; branch = $failBranch }
                }
            } catch {}
            if ($preservedBranch) {
                $entry.reason = if ($entry.reason) { "$($entry.reason) (work preserved on $preservedBranch)" } else { "work preserved on $preservedBranch" }
                Remove-SCWorktree $stateRoot $r.taskId -KeepBranch
            } else {
                Remove-SCWorktree $stateRoot $r.taskId
            }
            $results += $entry
            continue
        }
        try {
            $entry.committed = Save-SCWorktreeWork $r.worktree "$($r.taskId): $($task.title)"
            if (-not $entry.committed) {
                $entry.reason = 'validated but changed no files - check the provider could actually write'
                Remove-SCWorktree $stateRoot $r.taskId
                $results += $entry
                continue
            }
        } catch {
            $entry.reason = $_.Exception.Message
            Remove-SCWorktree $stateRoot $r.taskId
            $results += $entry
            continue
        }
        if ($NoMerge) {
            $entry.reason = "left on branch $($r.worktree.branch)"
            Remove-SCWorktree $stateRoot $r.taskId -KeepBranch
            $results += $entry
            continue
        }
        $merge = Merge-SCWorktreeBranch $stateRoot $r.worktree
        $entry.merged = $merge.merged
        if (-not $merge.merged) {
            $entry.reason = "$($merge.reason) - work kept on branch $($r.worktree.branch)"
            $current = Get-SCTask $r.taskId
            $current.status = 'needs_rework'
            $current.blockReason = "Merge conflict against the main tree; work preserved on $($r.worktree.branch)."
            Save-SCTask $current
            Add-SCEvent 'merge.conflict' $current.blockReason @{ taskId = $r.taskId; branch = $r.worktree.branch }
            Remove-SCWorktree $stateRoot $r.taskId -KeepBranch
        } else {
            Add-SCEvent 'merge.completed' "Merged $($r.worktree.branch)." @{ taskId = $r.taskId; branch = $r.worktree.branch }
            Remove-SCWorktree $stateRoot $r.taskId
        }
        $results += $entry
    }

    Write-Host ''
    foreach ($e in $results) {
        $flag = if ($e.merged) { 'MERGED  ' } elseif ($e.status -eq 'complete') { 'HELD    ' } else { 'FAILED  ' }
        $suffix = if ($e.reason) { " - $($e.reason)" } else { '' }
        Write-Host "$flag $($e.taskId) [$($e.status)]$suffix"
    }

    $mergedCount = @($results | Where-Object { $_.merged }).Count
    if ($mergedCount -gt 1) {
        Write-Host ''
        Write-Warning "$mergedCount branches were merged. Merging cleanly is not the same as still working: two changes that each passed alone can break together with no textual conflict."
    }

    $afterMerge = [bool](Get-SCProjectReviewSetting 'projectReviewAfterMultiMerge' $true)
    if ($mergedCount -gt 1 -and $afterMerge -and (Get-SCProjectReviewInterval) -gt 0) {
        Invoke-SCProjectReview 'multi-merge' | Out-Null
    } elseif ($mergedCount -gt 0) {
        Invoke-SCProjectReviewIfDue 'interval' | Out-Null
    }
    return $results
}

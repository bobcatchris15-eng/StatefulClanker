<# Parallel execution: run several ready tasks at once, each in its own git worktree.

   Tasks declare what they READ (retrieval, evidence) but never what they WRITE, so
   the scheduler cannot know whether two ready tasks will touch the same file. Each
   cycle therefore gets an isolated worktree. Durable state remains canonical in the
   main tree and is serialized across processes by the Core state mutex. #>

function Test-SCGitAvailable {
    return [bool](Get-Command git -ErrorAction SilentlyContinue)
}

function Test-SCGitRepo([string]$Path) {
    if (-not (Test-SCGitAvailable)) { return $false }
    & git -C $Path rev-parse --is-inside-work-tree 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-SCWorktreeRoot([string]$StateRoot) {
    Join-Path (Join-Path $StateRoot '.statefulclanker') 'worktrees'
}

function Get-SCDispatchableTasks {
    Update-SCReadiness
    return @(Get-SCTasks |
        Where-Object { $_.status -eq 'ready' -and -not $_.humanGate } |
        Sort-Object createdAt)
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
    & git -C $StateRoot show-ref --verify --quiet "refs/heads/$Branch"
    return ($LASTEXITCODE -eq 0)
}
function Remove-SCBranchIfExists([string]$StateRoot,[string]$Branch) {
    if (-not (Test-SCBranchExists $StateRoot $Branch)) { return }
    $output = & git -C $StateRoot branch -D $Branch 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "git branch cleanup failed for $Branch : $output" }
}

function New-SCWorktree([string]$StateRoot, [string]$TaskId) {
    $root = Get-SCWorktreeRoot $StateRoot
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
    $slug = ($TaskId -replace '[^A-Za-z0-9_.-]', '-')
    $path = Join-Path $root $slug
    $branch = "sc/task/$slug"

    if (Test-Path -LiteralPath $path) { Remove-SCWorktree $StateRoot $TaskId }
    Remove-SCBranchIfExists $StateRoot $branch

    $out = & git -C $StateRoot worktree add -b $branch $path HEAD 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "git worktree add failed for $TaskId : $out" }
    return [ordered]@{ taskId = $TaskId; path = (Resolve-Path -LiteralPath $path).Path; branch = $branch }
}

function Remove-SCWorktree([string]$StateRoot, [string]$TaskId, [switch]$KeepBranch) {
    $slug = ($TaskId -replace '[^A-Za-z0-9_.-]', '-')
    $path = Join-Path (Get-SCWorktreeRoot $StateRoot) $slug
    $branch = "sc/task/$slug"
    if (Test-Path -LiteralPath $path) {
        $out = & git -C $StateRoot worktree remove --force $path 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -and (Test-Path -LiteralPath $path)) {
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
    $out = & git -C $Worktree.path -c user.name='StatefulClanker' -c user.email='statefulclanker@localhost' commit -m $Message 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "git commit failed in $($Worktree.path): $out" }
    return $true
}

function Merge-SCWorktreeBranch([string]$StateRoot, $Worktree) {
    $out = & git -C $StateRoot merge --no-ff --no-edit $Worktree.branch 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        & git -C $StateRoot merge --abort 2>$null | Out-Null
        return [ordered]@{ merged = $false; reason = 'merge conflict'; detail = $out.Trim() }
    }
    return [ordered]@{ merged = $true; reason = $null; detail = $out.Trim() }
}

function Start-SCCycleProcess([string]$StateRoot, $Worktree, [string]$TaskId, [string]$Provider, [string]$HarnessPath) {
    $logDir = Join-Path (Join-Path $StateRoot '.statefulclanker') 'parallel'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $slug = ($TaskId -replace '[^A-Za-z0-9_.-]', '-')
    $logPath = Join-Path $logDir "$slug-$stamp.log"

    $cli = @('run', '-TaskId', $TaskId, '-StateRoot', $StateRoot)
    if ($Provider) { $cli += @('-Provider', $Provider) }

    $pwshPath = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($pwshPath)) { $pwshPath = 'pwsh' }
    $quoted = ((@('-NoProfile', '-NonInteractive', '-File', $HarnessPath) + $cli) |
        ForEach-Object { if ($_ -match '[ \t"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '

    $proc = Start-Process -FilePath $pwshPath -ArgumentList $quoted -WorkingDirectory $Worktree.path `
        -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err" -WindowStyle Hidden -PassThru

    return [ordered]@{
        taskId = $TaskId; worktree = $Worktree; process = $proc
        logPath = $logPath; startedAt = (Get-Date)
    }
}

function Get-SCParallelChildOutput($Run) {
    $stdout = if (Test-Path -LiteralPath $Run.logPath) { Get-Content -Raw -LiteralPath $Run.logPath } else { '' }
    $errPath = "$($Run.logPath).err"
    $stderr = if (Test-Path -LiteralPath $errPath) { Get-Content -Raw -LiteralPath $errPath } else { '' }
    return [ordered]@{ stdout=[string]$stdout; stderr=[string]$stderr }
}

function Invoke-SCParallel([int]$MaxConcurrent = 0, [string]$Provider, [string]$HarnessPath, [switch]$NoMerge) {
    Assert-SCInitialized
    Assert-SCNotHeld
    $stateRoot = Get-SCStateRoot

    if (-not (Test-SCGitAvailable)) { throw 'Parallel execution needs git on PATH.' }
    if (-not (Test-SCGitRepo $stateRoot)) {
        throw "Parallel execution needs the project to be a git repository (worktree isolation). '$stateRoot' is not one. Run: git init"
    }
    $dirty = & git -C $stateRoot status --porcelain 2>$null | Out-String
    if (-not [string]::IsNullOrWhiteSpace($dirty)) {
        throw "The working tree has uncommitted changes. Commit or stash them first: parallel runs merge branches into this checkout, and a dirty tree makes that unsafe.`n$($dirty.Trim())"
    }

    $limit = Get-SCMaxConcurrent $MaxConcurrent
    $candidates = @(Get-SCDispatchableTasks)
    if ($candidates.Count -eq 0) { Write-Host 'No dispatchable ready tasks.'; return }

    $batch = @($candidates | Select-Object -First $limit)
    Write-Host "Dispatching $($batch.Count) of $($candidates.Count) ready task(s), limit $limit."

    $running = @()
    foreach ($task in $batch) {
        try {
            $wt = New-SCWorktree $stateRoot $task.id
            $running += Start-SCCycleProcess $stateRoot $wt $task.id $Provider $HarnessPath
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
            Remove-SCWorktree $stateRoot $r.taskId
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

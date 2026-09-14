<# Parallel execution: run several ready tasks at once, each in its own git worktree.

   Why worktrees rather than one shared checkout:

   Tasks declare what they READ (retrieval, evidence) but never what they WRITE, so
   the scheduler cannot know whether two ready tasks will edit the same file. On a
   shared tree that is silent corruption - both workers report success and one
   overwrites the other. A worktree gives each cycle its own checkout, which turns
   collision from a silent data race into an explicit merge-time question.

   Durable state is NOT isolated. Every cycle reads and writes the one canonical
   .statefulclanker in the main tree, serialised by the state mutex in Core. That is
   deliberate: the task graph, receipts and proposals are the shared record. #>

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

<# Tasks eligible to start right now: ready, not human-gated, and not already
   claimed by a running cycle. #>
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

function New-SCWorktree([string]$StateRoot, [string]$TaskId) {
    $root = Get-SCWorktreeRoot $StateRoot
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
    $slug = ($TaskId -replace '[^A-Za-z0-9_.-]', '-')
    $path = Join-Path $root $slug
    $branch = "sc/task/$slug"

    if (Test-Path -LiteralPath $path) { Remove-SCWorktree $StateRoot $TaskId }
    # A branch left behind by a previous crashed run would block the add.
    & git -C $StateRoot branch -D $branch 2>$null | Out-Null

    $out = & git -C $StateRoot worktree add -b $branch $path HEAD 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "git worktree add failed for $TaskId : $out" }
    return [ordered]@{ taskId = $TaskId; path = (Resolve-Path -LiteralPath $path).Path; branch = $branch }
}

function Remove-SCWorktree([string]$StateRoot, [string]$TaskId, [switch]$KeepBranch) {
    $slug = ($TaskId -replace '[^A-Za-z0-9_.-]', '-')
    $path = Join-Path (Get-SCWorktreeRoot $StateRoot) $slug
    if (Test-Path -LiteralPath $path) {
        & git -C $StateRoot worktree remove --force $path 2>$null | Out-Null
        if (Test-Path -LiteralPath $path) { Remove-Item -Recurse -Force -LiteralPath $path -ErrorAction SilentlyContinue }
    }
    & git -C $StateRoot worktree prune 2>$null | Out-Null
    if (-not $KeepBranch) { & git -C $StateRoot branch -D "sc/task/$slug" 2>$null | Out-Null }
}

<# Commit whatever the worker changed inside its worktree.

   Returns $false when the worker produced no file changes at all, which is worth
   distinguishing: a cycle whose critic and validator passed but which touched
   nothing is usually a provider that could not write (a headless permission gate),
   not a task that needed no work. #>
function Save-SCWorktreeWork($Worktree, [string]$Message) {
    & git -C $Worktree.path add -A 2>$null | Out-Null
    $status = & git -C $Worktree.path status --porcelain 2>$null | Out-String
    if ([string]::IsNullOrWhiteSpace($status)) { return $false }
    $out = & git -C $Worktree.path -c user.name='StatefulClanker' -c user.email='statefulclanker@localhost' commit -m $Message 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "git commit failed in $($Worktree.path): $out" }
    return $true
}

<# Merge a passing task branch into the main checkout.

   Merging cleanly is NOT the same as still being correct: two changes that each
   passed alone can break together with no textual conflict - a renamed function one
   worker updated only within its own files, two files now declaring the same thing,
   a caller left pointing at a changed signature. Git resolves text; nothing checked
   semantics. The caller must re-validate after the merges land. #>
function Merge-SCWorktreeBranch([string]$StateRoot, $Worktree) {
    $out = & git -C $StateRoot merge --no-ff --no-edit $Worktree.branch 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        & git -C $StateRoot merge --abort 2>$null | Out-Null
        return [ordered]@{ merged = $false; reason = 'merge conflict'; detail = $out.Trim() }
    }
    return [ordered]@{ merged = $true; reason = $null; detail = $out.Trim() }
}

<# Dispatch one task's full cycle as a detached process bound to its worktree. #>
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
    # Quote explicitly: Start-Process -ArgumentList joins an array WITHOUT quoting,
    # so any path containing a space is split into separate arguments.
    $quoted = ((@('-NoProfile', '-NonInteractive', '-File', $HarnessPath) + $cli) |
        ForEach-Object { if ($_ -match '[ \t"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '

    $proc = Start-Process -FilePath $pwshPath -ArgumentList $quoted -WorkingDirectory $Worktree.path `
        -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err" -WindowStyle Hidden -PassThru

    return [ordered]@{
        taskId = $TaskId; worktree = $Worktree; process = $proc
        logPath = $logPath; startedAt = (Get-Date)
    }
}

function Invoke-SCParallel([int]$MaxConcurrent = 0, [string]$Provider, [string]$HarnessPath, [switch]$NoMerge) {
    Assert-SCInitialized
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

    # Commit and merge only the cycles whose task actually reached 'complete'.
    $results = @()
    foreach ($r in $running) {
        $task = Get-SCTask $r.taskId
        $entry = [ordered]@{ taskId = $r.taskId; status = $task.status; committed = $false; merged = $false; reason = $null; logPath = $r.logPath }
        if ($task.status -ne 'complete') {
            $entry.reason = if ($task.blockReason) { [string]$task.blockReason } else { "cycle ended as '$($task.status)'" }
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
            # Keep the branch: the work passed its own review and is recoverable.
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
        Write-Warning "$mergedCount branches were merged. Merging cleanly is not the same as still working: run your own full test suite now. Two changes that each passed alone can break together with no textual conflict."
    }
    return $results
}

<# Periodic PROJECT-level review.

   The per-task critic and validator each judge one task against one compiled
   context. Nothing looks at the project as a whole, so N tasks that each passed
   their own review can still leave the project broken - most obviously after a
   parallel batch, where two changes that merged cleanly can break together with no
   textual conflict.

   This runs a project critic and a project validator every N completed tasks, and
   after any multi-branch merge. On FAIL it halts dispatch and queues a human-gated
   remediation task, so the queue stops piling work onto a broken base.

   A reviewer with no way to run the project is an LLM reading a diff. The single
   most valuable thing here is `projectValidateCommand`: its exit code and output go
   into the packet as real evidence. #>

function Get-SCProjectReviewSetting([string]$Name, $Default) {
    $cfg = Get-SCConfig
    if ($cfg.PSObject.Properties[$Name] -and $null -ne $cfg.$Name) { return $cfg.$Name }
    return $Default
}

function Get-SCProjectReviewInterval {
    return [int](Get-SCProjectReviewSetting 'projectReviewEveryTasks' 5)
}

# ------------------------------------------------------------------- hold ----

function Get-SCProjectHold {
    $state = Get-SCState
    if ($state.PSObject.Properties['projectHold'] -and $state.projectHold -and [bool]$state.projectHold.active) {
        return $state.projectHold
    }
    return $null
}

function Set-SCProjectHold([string]$Reason, [string]$ReviewId) {
    Invoke-SCLocked {
        $state = Get-SCState
        Set-SCProperty $state 'projectHold' ([ordered]@{
                active = $true; reason = $Reason; reviewId = $ReviewId
                since = (Get-Date).ToUniversalTime().ToString('o')
            })
        Save-SCState $state
    }
    Add-SCEvent 'project.hold.set' $Reason @{ reviewId = $ReviewId }
}

function Clear-SCProjectHold {
    $hold = Get-SCProjectHold
    Invoke-SCLocked {
        $state = Get-SCState
        Set-SCProperty $state 'projectHold' ([ordered]@{ active = $false; reason = $null; reviewId = $null; since = $null })
        Save-SCState $state
    }
    if ($hold) {
        Add-SCEvent 'project.hold.cleared' 'Project hold cleared by human.' @{ previousReason = $hold.reason; authority = 'human' }
        Write-Host "Cleared project hold: $($hold.reason)"
    } else {
        Write-Host 'No project hold was set.'
    }
}

<# Called at the start of every dispatch path. A hold means the last project review
   said the project is broken; adding more work on top of that is how a small
   integration failure becomes an unrecoverable one. #>
function Assert-SCNotHeld {
    $hold = Get-SCProjectHold
    if ($hold) {
        throw "Project is on hold after a failed project review ($($hold.reviewId)): $($hold.reason)`nInspect with: StatefulClanker.ps1 review show -RunId $($hold.reviewId)`nRelease with: StatefulClanker.ps1 hold clear"
    }
}

# --------------------------------------------------------------- counting ----

function Add-SCCompletedTaskCount {
    Invoke-SCLocked {
        $state = Get-SCState
        $count = 0
        if ($state.PSObject.Properties['tasksSinceProjectReview']) { $count = [int]$state.tasksSinceProjectReview }
        Set-SCProperty $state 'tasksSinceProjectReview' ($count + 1)
        Save-SCState $state
        return ($count + 1)
    }
}

function Reset-SCCompletedTaskCount {
    Invoke-SCLocked {
        $state = Get-SCState
        Set-SCProperty $state 'tasksSinceProjectReview' 0
        Save-SCState $state
    }
}

function Test-SCProjectReviewDue {
    $interval = Get-SCProjectReviewInterval
    if ($interval -le 0) { return $false }
    $state = Get-SCState
    $count = 0
    if ($state.PSObject.Properties['tasksSinceProjectReview']) { $count = [int]$state.tasksSinceProjectReview }
    return ($count -ge $interval)
}

# --------------------------------------------------------------- evidence ----

<# Run the project's own test/build command. This is the difference between a
   project validator that knows something and one that is guessing. #>
function Invoke-SCProjectValidateCommand {
    $command = [string](Get-SCProjectReviewSetting 'projectValidateCommand' $null)
    if ([string]::IsNullOrWhiteSpace($command)) {
        return [ordered]@{
            configured = $false; command = $null; exitCode = $null; timedOut = $false
            output = 'No projectValidateCommand is configured, so the project was NOT executed. Judge from the evidence below only, and say explicitly that you could not verify the project actually runs.'
        }
    }
    $timeout = [int](Get-SCProjectReviewSetting 'projectValidateTimeoutSeconds' 600)
    $outPath = Join-Path ([IO.Path]::GetTempPath()) ("sc-pv-{0}.txt" -f [Guid]::NewGuid().ToString('N'))
    $errPath = "$outPath.err"
    $root = Get-SCRoot
    $exitCode = $null
    $timedOut = $false
    try {
        $job = Start-Job -ScriptBlock {
            param($Cmd, $Wd, $Out, $Err)
            Set-Location -LiteralPath $Wd
            # cmd /c so the setting can be any ordinary shell line.
            & cmd.exe /d /c $Cmd 1> $Out 2> $Err
            if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        } -ArgumentList $command, $root, $outPath, $errPath
        if (Wait-Job -Job $job -Timeout $timeout) {
            $exitCode = [int](Receive-Job -Job $job)
        } else {
            $timedOut = $true
            Stop-Job -Job $job -ErrorAction SilentlyContinue
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    } catch {
        return [ordered]@{ configured = $true; command = $command; exitCode = -1; timedOut = $false; output = "Could not run it: $($_.Exception.Message)" }
    }
    $text = ''
    foreach ($p in @($outPath, $errPath)) {
        if (Test-Path -LiteralPath $p) {
            $raw = Get-Content -Raw -LiteralPath $p
            if ($null -ne $raw) { $text += [string]$raw }
        }
    }
    Remove-Item -LiteralPath $outPath, $errPath -Force -ErrorAction SilentlyContinue
    $budget = [int](Get-SCProjectReviewSetting 'projectValidateOutputChars' 12000)
    if ($text.Length -gt $budget) {
        # Keep both ends: the command line and the failure summary usually sit at
        # opposite ends of a test log.
        $head = $text.Substring(0, [int]($budget * 0.4))
        $tail = $text.Substring($text.Length - [int]($budget * 0.6))
        $text = "$head`r`n... [truncated $($text.Length - $budget) chars] ...`r`n$tail"
    }
    return [ordered]@{ configured = $true; command = $command; exitCode = $exitCode; timedOut = $timedOut; output = $text }
}

function Get-SCRecentCompletedTasks([int]$Limit = 12) {
    return @(Get-SCTasks |
        Where-Object { $_.status -eq 'complete' } |
        Sort-Object updatedAt -Descending |
        Select-Object -First $Limit |
        ForEach-Object {
            [ordered]@{ id = $_.id; title = $_.title; acceptance = @($_.acceptance); attemptCount = $_.attemptCount; updatedAt = $_.updatedAt }
        })
}

function Get-SCProjectDiffStat {
    $root = Get-SCStateRoot
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return 'git is not available.' }
    $oldPreference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        & git -C $root rev-parse --is-inside-work-tree 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return 'Not a git repository.' }
        $stat = & git -C $root log --oneline -15 2>$null | Out-String
        $recent=@(& git -C $root rev-list --max-count=6 HEAD 2>$null)
        if($recent.Count -gt 1){$base=$recent[-1];$files=& git -C $root diff --stat $base HEAD 2>$null | Out-String}
        elseif($recent.Count -eq 1){$files=& git -C $root show --stat --oneline --format='' HEAD 2>$null | Out-String}
        else{$files=''}
        return "Recent commits:`r`n$stat`r`nChanged files (recent history):`r`n$files"
    } finally { $ErrorActionPreference=$oldPreference }
}
function New-SCProjectReviewPacket([string]$Trigger, $ValidateResult) {
    $state = Get-SCState
    $tasks = @(Get-SCTasks)
    return [ordered]@{
        schemaVersion = 1
        trigger       = $Trigger
        compiledAt    = (Get-Date).ToUniversalTime().ToString('o')
        project       = [ordered]@{
            goal = $state.goal; activePlanId = $state.activePlanId; planApproved = $state.planApproved
            directionRevision = $state.directionRevision; root = Get-SCRoot
        }
        taskSummary   = [ordered]@{
            total = $tasks.Count
            complete = @($tasks | Where-Object { $_.status -eq 'complete' }).Count
            needsRework = @($tasks | Where-Object { $_.status -eq 'needs_rework' }).Count
            blocked = @($tasks | Where-Object { $_.status -eq 'blocked' }).Count
            stale = @($tasks | Where-Object { $_.status -eq 'stale' }).Count
        }
        recentlyCompleted = @(Get-SCRecentCompletedTasks 12)
        projectValidate   = $ValidateResult
        repository        = Get-SCProjectDiffStat
        recentProgress    = @(Get-ChildItem -LiteralPath (Get-SCPath 'progress') -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 15 |
            ForEach-Object { $r = Read-SCJson $_.FullName; [ordered]@{ taskId = $r.taskId; advanced = $r.advanced; outcome = $r.outcome } })
        recentContextFaults = @(Get-SCContextFaults 10)
    }
}

function New-SCProjectReviewPrompt($Packet, [string]$Stage) {
    $rule = if ($Stage -eq 'critic') {
        @'
You are the PROJECT CRITIC. You did not perform any of the work.
Look at the project as a whole, not at one task:
- Do the completed tasks contradict each other, or duplicate each other?
- Has the work drifted from the stated goal?
- Is there accumulating risk, dead code, or an abandoned half-migration?
- Do repeated needs_rework or non-advancing progress records suggest the plan is wrong?
'@
    } else {
        @'
You are the PROJECT VALIDATOR. You did not perform any of the work.
Judge whether the project as a whole is still sound:
- Does it still satisfy the stated goal?
- Does the project actually still build and pass its own checks?
Weigh the projectValidate result heavily: it is the only direct evidence that the
project runs. If no command was configured, say plainly that you could not verify it
and do not infer success from the absence of failure.
'@
    }
    return @"
$rule

Report concrete problems with specific task ids or files. Do not restate the packet.

The FIRST line of your reply must be exactly one of:
VERDICT: PASS
VERDICT: FAIL

Then explain. FAIL if the project is broken, contradictory, or has drifted from its
goal. PASS if it is coherent and, where you could verify it, working.

PROJECT REVIEW PACKET:
$(ConvertTo-SCJson $Packet 20)
"@
}

# --------------------------------------------------------------- execution ----

<# Reviews are dispatched through a synthetic task so Invoke-SCProvider's telemetry,
   receipts and prompt capture all work unchanged. #>
function New-SCProjectReviewPseudoTask([string]$ReviewId) {
    return [pscustomobject]@{ id = $ReviewId; title = 'Project review'; provider = $null }
}

function New-SCRemediationTask($Review, $Findings) {
    $id = 'remediate-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $instruction = @"
A periodic PROJECT review failed. Fix what it found.

This task was created by the harness, not by a human, so treat the findings as a
report to verify rather than as ground truth. If they are wrong, say so and emit a
CONTEXT_REQUEST rather than making speculative changes.

REVIEW FINDINGS ($($Review.id)):
$Findings
"@
    # Built directly rather than through Add-SCTask, which reads its arguments from
    # the CLI script scope and is not callable as a function.
    $task = New-SCTaskObject $id 'Fix what the project review found' $instruction `
        @('The project review passes on the next run.') @() @() @() @() $null 'worker' $true
    Save-SCTask $task
    Add-SCEvent 'task.created' 'Remediation task created by a failed project review.' @{ taskId = $id; reviewId = $Review.id; humanGate = $true }
    return $task
}

function Invoke-SCProjectReview([string]$Trigger = 'interval', [switch]$Force) {
    Assert-SCInitialized
    if (-not $Force -and (Get-SCProjectReviewInterval) -le 0) { return $null }

    $criticEnabled = [bool](Get-SCProjectReviewSetting 'projectCriticEnabled' $true)
    $validatorEnabled = [bool](Get-SCProjectReviewSetting 'projectValidatorEnabled' $true)
    if (-not $criticEnabled -and -not $validatorEnabled) { return $null }

    $reviewId = New-SCId 'review'
    Write-Host "Project review $reviewId (trigger: $Trigger)..."

    $validate = Invoke-SCProjectValidateCommand
    if ($validate.configured) {
        $verdictText = if ($validate.timedOut) { 'TIMED OUT' } elseif ($validate.exitCode -eq 0) { 'exit 0' } else { "exit $($validate.exitCode)" }
        Write-Host "  projectValidateCommand: $verdictText"
    }
    $packet = New-SCProjectReviewPacket $Trigger $validate
    $pseudo = New-SCProjectReviewPseudoTask $reviewId

    $stages = @()
    if ($criticEnabled) { $stages += 'critic' }
    if ($validatorEnabled) { $stages += 'validator' }

    $outcomes = @()
    foreach ($stage in $stages) {
        $receipt = Invoke-SCProvider $pseudo (New-SCProjectReviewPrompt $packet $stage) $stage $null $null $null
        $receipt.verdict = Get-SCVerdict ([string]$receipt.stdout) ([int]$receipt.exitCode)
        Set-SCTelemetryVerdict $receipt.agentId $receipt.verdict
        $outcomes += [ordered]@{ stage = $stage; verdict = $receipt.verdict; receiptId = $receipt.id; output = [string]$receipt.stdout }
        Write-Host "  project $stage : $($receipt.verdict)"
    }

    $failed = @($outcomes | Where-Object { $_.verdict -ne 'PASS' })
    $review = [ordered]@{
        schemaVersion = 1; id = $reviewId; ts = (Get-Date).ToUniversalTime().ToString('o')
        trigger = $Trigger; passed = ($failed.Count -eq 0)
        projectValidate = [ordered]@{ configured = $validate.configured; command = $validate.command; exitCode = $validate.exitCode; timedOut = $validate.timedOut }
        stages = @($outcomes | ForEach-Object { [ordered]@{ stage = $_.stage; verdict = $_.verdict; receiptId = $_.receiptId } })
        packet = $packet
    }
    Write-SCJson (Get-SCPath ("reviews/{0}.json" -f $reviewId)) $review
    Reset-SCCompletedTaskCount

    if ($failed.Count -eq 0) {
        Add-SCEvent 'project.review.passed' "Project review $reviewId passed." @{ reviewId = $reviewId; trigger = $Trigger }
        Write-Host "Project review $reviewId PASSED."
        return $review
    }

    $findings = ($failed | ForEach-Object { "[$($_.stage)]`r`n$($_.output)" }) -join "`r`n`r`n"
    $reason = "Project $((($failed | ForEach-Object { $_.stage }) -join ' and ')) failed."
    Add-SCEvent 'project.review.failed' $reason @{ reviewId = $reviewId; trigger = $Trigger; stages = @($failed | ForEach-Object { $_.stage }) }
    Write-Warning "Project review $reviewId FAILED: $reason"

    if ([bool](Get-SCProjectReviewSetting 'projectReviewRemediationTask' $true)) {
        try {
            $task = New-SCRemediationTask $review $findings
            Write-Host "  queued remediation task $($task.id) (human-gated: release it with 'task retry' after you have read the review)"
        } catch { Write-Warning "  could not queue a remediation task: $($_.Exception.Message)" }
    }
    Set-SCProjectHold $reason $reviewId
    Write-Warning "Dispatch is now HELD. Inspect: StatefulClanker.ps1 review show -RunId $reviewId   Release: StatefulClanker.ps1 hold clear"
    return $review
}

<# Called after a cycle finishes. Managed worktree children must not run this: the
   scheduler runs one review for the whole batch instead of N of them. #>
function Invoke-SCProjectReviewIfDue([string]$Trigger = 'interval') {
    if ($script:SCManagedChild) { return $null }
    if (-not (Test-SCProjectReviewDue)) { return $null }
    return Invoke-SCProjectReview $Trigger
}

function Show-SCProjectReviews([string]$Mode, [string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Mode)) { $Mode = 'history' }
    $dir = Get-SCPath 'reviews'
    switch ($Mode.ToLowerInvariant()) {
        'history' {
            if (-not (Test-Path $dir)) { Write-Host 'No project reviews yet.'; return }
            @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 50 | ForEach-Object { Read-SCJson $_.FullName } |
                ForEach-Object { [pscustomobject]@{ id = $_.id; ts = $_.ts; trigger = $_.trigger; passed = $_.passed; validateExit = $_.projectValidate.exitCode } }) |
                Format-Table -AutoSize
            break
        }
        'show' {
            if (-not $Id) { throw '-RunId <reviewId> required.' }
            $record = Read-SCJson (Join-Path $dir ("{0}.json" -f $Id))
            if (-not $record) { throw "Unknown review: $Id" }
            ConvertTo-SCJson $record 24 | Write-Host
            break
        }
        default { throw "Unknown review subcommand: $Mode" }
    }
}

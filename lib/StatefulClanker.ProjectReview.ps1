<# Periodic PROJECT-level review.

   The per-task validator judges one task against one compiled context.
   Nothing in that task-local gate looks at the project as a whole, so N tasks
   that each passed their own validation can still leave the project broken - most obviously after a
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

function New-SCProjectReviewPrompt($Packet) {
    return @"
You are the PROJECT REVIEWER. You did not perform any of the work.

Inspect the project as a whole rather than re-reviewing one task:
- Does the current implementation still match the stated goal and authority?
- Do completed tasks contradict or duplicate one another?
- Is there accumulating dead code, abandoned migration machinery, or architectural drift?
- Do repeated needs_rework/non-advancing records expose a plan or integration problem?
- Does the deterministic projectValidate evidence support or contradict the current state?

The projectValidate result is direct execution evidence. Do not override a failing
deterministic check with optimism. Conversely, your semantic concerns are findings to
investigate, not authority to freeze the entire project by themselves.

Report concrete problems with specific task ids or files. Do not restate the packet.

The FIRST line of your reply must be exactly one of:
VERDICT: PASS
VERDICT: FAIL

Use FAIL when you found a concrete semantic/integration problem worth investigation.
A semantic FAIL is advisory unless deterministic evidence independently fails.

PROJECT REVIEW PACKET:
$(ConvertTo-SCModelText $Packet 20)
"@
}

# --------------------------------------------------------------- execution ----

<# Reviews are dispatched through a synthetic task so Invoke-SCProvider's telemetry,
   receipts and prompt capture all work unchanged. #>
function New-SCProjectReviewPseudoTask([string]$ReviewId) {
    return [pscustomobject]@{ id = $ReviewId; title = 'Project review'; provider = $null }
}

function Invoke-SCProjectReview(
    [string]$Trigger = 'interval',
    [switch]$Force,
    [string]$ProviderOverride = $null,
    [string]$EndpointOverride = $null,
    [string]$ConnectionOverride = $null
) {
    Assert-SCInitialized
    if (-not $Force -and (Get-SCProjectReviewInterval) -le 0) { return $null }
    if (-not [bool](Get-SCProjectReviewSetting 'projectReviewerEnabled' $true)) { return $null }

    $reviewId = New-SCId 'review'
    Write-Host "Project review $reviewId (trigger: $Trigger)..."

    $validate = Invoke-SCProjectValidateCommand
    if ($validate.configured) {
        $verdictText = if ($validate.timedOut) { 'TIMED OUT' } elseif ($validate.exitCode -eq 0) { 'exit 0' } else { "exit $($validate.exitCode)" }
        Write-Host "  projectValidateCommand: $verdictText"
    }

    $packet = New-SCProjectReviewPacket $Trigger $validate
    $pseudo = New-SCProjectReviewPseudoTask $reviewId
    $receipt=$null
    $reviewerVerdict='ERROR'
    $reviewerOutput=''
    try {
        $receipt = Invoke-SCProvider $pseudo (New-SCProjectReviewPrompt $packet) 'reviewer' $ProviderOverride $null $null $null $null $EndpointOverride $ConnectionOverride
        $reviewerVerdict = Get-SCVerdict ([string]$receipt.stdout) ([int]$receipt.exitCode)
        $reviewerOutput = [string]$receipt.stdout
        Set-SCTelemetryVerdict $receipt.agentId $reviewerVerdict
    } catch {
        $reviewerOutput = $_ | Out-String
        Write-Warning "  project reviewer unavailable: $($_.Exception.Message)"
    }
    Write-Host "  project reviewer : $reviewerVerdict"

    $semanticFindings = ($reviewerVerdict -ne 'PASS')
    $hardFailure = [bool]$validate.configured -and ([bool]$validate.timedOut -or [int]$validate.exitCode -ne 0)
    $review = [ordered]@{
        schemaVersion = 2
        id = $reviewId
        ts = (Get-Date).ToUniversalTime().ToString('o')
        trigger = $Trigger
        passed = (-not $hardFailure -and -not $semanticFindings)
        hardFailure = $hardFailure
        advisoryFindings = $semanticFindings
        projectValidate = [ordered]@{
            configured = $validate.configured
            command = $validate.command
            exitCode = $validate.exitCode
            timedOut = $validate.timedOut
        }
        stages = @([ordered]@{
            stage = 'reviewer'
            verdict = $reviewerVerdict
            receiptId = if($receipt){$receipt.id}else{$null}
        })
        packet = $packet
    }
    Write-SCJson (Get-SCPath ("reviews/{0}.json" -f $reviewId)) $review
    Reset-SCCompletedTaskCount

    if ($semanticFindings) {
        Add-SCEvent 'project.review.findings' "Project reviewer $reviewId reported findings; dispatch remains available unless deterministic validation also failed." @{
            reviewId=$reviewId; trigger=$Trigger; verdict=$reviewerVerdict; hardFailure=$hardFailure; output=$reviewerOutput
        }
        Write-Warning "Project reviewer $reviewId reported findings. They are advisory; investigate them before treating them as project truth."
    }

    if ($hardFailure) {
        $reason = if($validate.timedOut) {
            'Deterministic project validation timed out.'
        } else {
            "Deterministic project validation failed with exit $($validate.exitCode)."
        }
        Add-SCEvent 'project.review.failed' $reason @{
            reviewId=$reviewId; trigger=$Trigger; hardFailure=$true; validateExit=$validate.exitCode; timedOut=$validate.timedOut
        }
        Set-SCProjectHold $reason $reviewId
        Write-Warning "Project review $reviewId HARD FAILED: $reason"
        Write-Warning "Dispatch is HELD on deterministic evidence. Inspect: StatefulClanker.ps1 review show -RunId $reviewId   Release after repair: StatefulClanker.ps1 hold clear"
        return $review
    }

    if (-not $semanticFindings) {
        Add-SCEvent 'project.review.passed' "Project review $reviewId passed." @{ reviewId=$reviewId; trigger=$Trigger }
        Write-Host "Project review $reviewId PASSED."
    } else {
        Write-Host "Project review $reviewId completed with advisory findings; dispatch continues."
    }
    return $review
}

<# Called after a cycle finishes. Managed worktree children must not run this: the
   scheduler runs one review for the whole batch instead of N of them. #>
function Invoke-SCProjectReviewIfDue([string]$Trigger = 'interval',[string]$ProviderOverride=$null,[string]$EndpointOverride=$null,[string]$ConnectionOverride=$null) {
    if ($script:SCManagedChild) { return $null }
    if (-not (Test-SCProjectReviewDue)) { return $null }
    return Invoke-SCProjectReview $Trigger -ProviderOverride $ProviderOverride -EndpointOverride $EndpointOverride -ConnectionOverride $ConnectionOverride
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

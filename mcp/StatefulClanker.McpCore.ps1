<# StatefulClanker MCP core: tool definitions and dispatch, shared by the stdio
   and HTTP hosts. Hosts own transport only; everything below is transport-free. #>

$script:McpVersion = '0.5.0'
$script:McpProtocol = '2025-06-18'
$script:McpHarness = Join-Path (Split-Path -Parent $PSScriptRoot) 'StatefulClanker.ps1'
$script:McpDefaultProject = $null

function Set-McpDefaultProject([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $script:McpDefaultProject = (Resolve-Path -LiteralPath $Path).Path
}

function Get-McpProject($Arguments) {
    $candidate = $null
    if ($Arguments -and $Arguments.PSObject.Properties['project'] -and $Arguments.project) {
        $candidate = [string]$Arguments.project
    } elseif ($script:McpDefaultProject) {
        $candidate = $script:McpDefaultProject
    } else {
        throw 'No project selected. Pass "project", or start the server with -ProjectPath.'
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        throw "Project path does not exist: $candidate"
    }
    return (Resolve-Path -LiteralPath $candidate).Path
}

function Get-McpStateDir([string]$Project) { Join-Path $Project '.statefulclanker' }

function Assert-McpInitialized([string]$Project) {
    if (-not (Test-Path -LiteralPath (Join-Path (Get-McpStateDir $Project) 'state.json'))) {
        throw "Not a StatefulClanker project (no .statefulclanker/state.json): $Project. Call project_init first."
    }
}

function Read-McpJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -Raw -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Read-McpJsonDir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Filter '*.json' -File | ForEach-Object { Read-McpJson $_.FullName })
}

function Read-McpJsonl([string]$Path, [int]$Limit = 100) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path | Where-Object { $_ } | Select-Object -Last $Limit | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
}

function Get-McpArgLimit($Arguments, [int]$Default = 100) {
    if ($Arguments -and $Arguments.PSObject.Properties['limit'] -and $null -ne $Arguments.limit) {
        return [Math]::Min(500, [Math]::Max(1, [int]$Arguments.limit))
    }
    return $Default
}

function Get-McpArgRequired($Arguments, [string]$Name) {
    if (-not $Arguments -or -not $Arguments.PSObject.Properties[$Name] -or [string]::IsNullOrWhiteSpace([string]$Arguments.$Name)) {
        throw "Required argument missing: $Name"
    }
    return [string]$Arguments.$Name
}

function Get-McpArgOptional($Arguments, [string]$Name) {
    if (-not $Arguments -or -not $Arguments.PSObject.Properties[$Name] -or $null -eq $Arguments.$Name) { return $null }
    $value = [string]$Arguments.$Name
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}

function Get-McpArgArray($Arguments, [string]$Name) {
    if (-not $Arguments -or -not $Arguments.PSObject.Properties[$Name] -or $null -eq $Arguments.$Name) { return @() }
    return @($Arguments.$Name | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
}

function New-McpTextResult($Value) {
    @{ content = @(@{ type = 'text'; text = ($Value | ConvertTo-Json -Depth 30) }) }
}

function Get-McpConfigFlag([string]$Project, [string]$Name, [bool]$Default) {
    $cfg = Read-McpJson (Join-Path (Get-McpStateDir $Project) 'config.json')
    if ($null -eq $cfg -or -not $cfg.PSObject.Properties['mcp'] -or $null -eq $cfg.mcp) { return $Default }
    if (-not $cfg.mcp.PSObject.Properties[$Name] -or $null -eq $cfg.mcp.$Name) { return $Default }
    return [bool]$cfg.mcp.$Name
}

<# Tools that bypass the validation gate are opt-in. The project's own invariant is
   that worker output proposes state and does not certify it, and that human approval
   is a first-class transition. An agent that can approve its own plan and manually
   complete its own tasks erases both gates, so these stay off unless asked for. #>
function Assert-McpHumanAuthority([string]$Project, [string]$Tool) {
    if (Get-McpConfigFlag $Project 'allowHumanAuthorityTools' $false) { return }
    $cfgPath = Join-Path (Get-McpStateDir $Project) 'config.json'
    throw "Tool '$Tool' bypasses the validation gate and is disabled by default. Set mcp.allowHumanAuthorityTools = true in $cfgPath to enable it, or perform this commit from the CLI, where it is recorded as human authority."
}

<# Run the CLI inside the project directory and capture its output. Writes must go
   through the CLI: Add-SCTask and friends take no parameters, they read $Title /
   $Instruction / etc. from StatefulClanker.ps1's script scope. #>
<# Quote one argument for a Windows command line (CommandLineToArgvW rules). #>
function ConvertTo-McpWindowsArg($Value) {
    $text = [string]$Value
    if ($text -eq '') { return '""' }
    if ($text -notmatch '[ \t"]') { return $text }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $text.ToCharArray()) {
        if ($ch -eq '\') {
            $slashes++
        } elseif ($ch -eq '"') {
            [void]$sb.Append('\' * ($slashes * 2 + 1))
            [void]$sb.Append('"')
            $slashes = 0
            continue
        } else {
            if ($slashes -gt 0) { [void]$sb.Append('\' * $slashes); $slashes = 0 }
        }
        if ($ch -ne '\') { [void]$sb.Append($ch) }
    }
    if ($slashes -gt 0) { [void]$sb.Append('\' * ($slashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-McpPwshPath {
    $self = (Get-Process -Id $PID).Path
    if (-not [string]::IsNullOrWhiteSpace($self)) { return $self }
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command powershell -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'Could not locate a PowerShell host to run the StatefulClanker CLI.'
}

<# Quote a value as a PowerShell single-quoted literal. #>
function ConvertTo-McpPsLiteral($Value) {
    if ($Value -is [array]) {
        if (@($Value).Count -eq 0) { return '@()' }
        return '@(' + ((@($Value) | ForEach-Object { ConvertTo-McpPsLiteral $_ }) -join ',') + ')'
    }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

<# $CliArgs elements are either a bare token (command word or -Flag) or, for a value,
   a string / string[]. Array values MUST be emitted as a PowerShell array literal:
   pwsh -File passes arguments as literal tokens with no expression parsing, so a
   comma-joined string arrives as ONE element and silently collapses acceptance
   criteria and retrieval selectors into a single bogus entry. #>
function Invoke-McpHarness([string]$Project, [object[]]$CliArgs) {
    $outPath = Join-Path ([IO.Path]::GetTempPath()) ("sc-mcp-{0}.out" -f [Guid]::NewGuid().ToString('N'))
    $errPath = "$outPath.err"
    $code = 0

    $parts = @(ConvertTo-McpPsLiteral $script:McpHarness)
    foreach ($item in $CliArgs) {
        if ($item -is [string] -and ($item.StartsWith('-') -or $item -match '^[a-z]+$')) {
            $parts += $item
        } else {
            $parts += ConvertTo-McpPsLiteral $item
        }
    }
    $command = '& ' + ($parts -join ' ')

    # Run as a CHILD process rather than in-process. The CLI reports through
    # Write-Host, which does not reach stdout and so cannot be captured in-process,
    # and $LASTEXITCODE is never set by a pure-PowerShell call, which is a hard error
    # under StrictMode. A child gives real stdout, a real exit code, and CWD isolation.
    $pwshPath = Get-McpPwshPath
    Push-Location -LiteralPath $Project
    try {
        & $pwshPath -NoProfile -NonInteractive -Command $command 1> $outPath 2> $errPath
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    } catch {
        $code = -1
        ($_ | Out-String) | Add-Content -LiteralPath $errPath -Encoding UTF8
    } finally {
        Pop-Location
    }

    $stdout = ''
    if (Test-Path -LiteralPath $outPath) {
        $raw = Get-Content -Raw -LiteralPath $outPath
        if ($null -ne $raw) { $stdout = [string]$raw }
    }
    $stderr = ''
    if (Test-Path -LiteralPath $errPath) {
        $raw = Get-Content -Raw -LiteralPath $errPath
        if ($null -ne $raw) { $stderr = [string]$raw }
    }
    Remove-Item -LiteralPath $outPath, $errPath -Force -ErrorAction SilentlyContinue

    if ($code -ne 0) {
        $detail = (@($stderr, $stdout) -join ' ').Trim()
        throw "StatefulClanker CLI failed (exit $code): $detail"
    }
    return [ordered]@{ exitCode = $code; stdout = $stdout.Trim(); stderr = $stderr.Trim(); command = $command }
}

<# Provider configuration lives only in config.json and has no CLI command, so
   without these a freshly installed server can be connected but never actually run
   anything: the first run_start fails on an unconfigured or wrong provider. #>
function Set-McpProvider([string]$Project, $Arguments) {
    Assert-McpInitialized $Project
    $cfgPath = Join-Path (Get-McpStateDir $Project) 'config.json'
    $cfg = Read-McpJson $cfgPath
    if ($null -eq $cfg) { throw "Missing config.json in $Project" }

    $name = Get-McpArgRequired $Arguments 'name'
    $command = Get-McpArgRequired $Arguments 'command'
    $providerArgs = @(Get-McpArgArray $Arguments 'args')
    if ($providerArgs.Count -eq 0) { throw 'args is required: it must contain {prompt} or {promptFile} so the task text reaches the worker.' }

    $mode = Get-McpArgOptional $Arguments 'mode'
    if (-not $mode) { $mode = if (($providerArgs -join ' ') -match '\{promptFile\}') { 'prompt-file' } else { 'inline' } }

    $joined = $providerArgs -join ' '
    if ($joined -notmatch '\{prompt\}' -and $joined -notmatch '\{promptFile\}') {
        throw "Provider args must contain the {prompt} or {promptFile} placeholder, otherwise the worker receives no task. Got: $joined"
    }
    if (-not (Get-Command $command -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $command)) {
        throw "Command not found on PATH: $command. Install it first, or give a full path."
    }

    if (-not $cfg.PSObject.Properties['providers'] -or $null -eq $cfg.providers) {
        $cfg | Add-Member -NotePropertyName providers -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $cfg.providers | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{
            command = $command; args = $providerArgs; mode = $mode
        }) -Force

    $assigned = @()
    foreach ($pair in @(@('setDefault', 'defaultProvider'), @('setCritic', 'criticProvider'), @('setValidator', 'validatorProvider'))) {
        if ($Arguments -and $Arguments.PSObject.Properties[$pair[0]] -and [bool]$Arguments.$($pair[0])) {
            $cfg | Add-Member -NotePropertyName $pair[1] -NotePropertyValue $name -Force
            $assigned += $pair[1]
        }
    }

    $cfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    return [ordered]@{ provider = $name; command = $command; args = $providerArgs; mode = $mode; assignedTo = $assigned; configPath = $cfgPath }
}

<# Dispatch a trivial prompt and report whether the provider is actually usable.
   Worth its own tool because the two realistic failures are both silent-ish: an
   expired CLI login exits nonzero with an auth message, and a permission-gated
   headless CLI exits ZERO having produced nothing at all. #>
function Test-McpProvider([string]$Project, $Arguments) {
    Assert-McpInitialized $Project
    $cfg = Read-McpJson (Join-Path (Get-McpStateDir $Project) 'config.json')
    $name = Get-McpArgOptional $Arguments 'name'
    if (-not $name) {
        if (-not $cfg.PSObject.Properties['defaultProvider'] -or -not $cfg.defaultProvider) { throw 'No provider named and no defaultProvider configured.' }
        $name = [string]$cfg.defaultProvider
    }
    if (-not $cfg.PSObject.Properties['providers'] -or -not $cfg.providers.PSObject.Properties[$name]) {
        throw "Provider '$name' is not configured. Use provider_set first."
    }
    $entry = $cfg.providers.$name

    $timeout = 90
    if ($Arguments -and $Arguments.PSObject.Properties['timeoutSeconds'] -and $Arguments.timeoutSeconds) {
        $timeout = [Math]::Min(300, [Math]::Max(10, [int]$Arguments.timeoutSeconds))
    }

    $probe = 'Reply with exactly this text and nothing else: STATEFULCLANKER_PROVIDER_OK'
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("sc-probe-{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    $promptFile = Join-Path $tempDir 'prompt.txt'
    $probe | Set-Content -LiteralPath $promptFile -Encoding UTF8
    $outPath = Join-Path $tempDir 'out.txt'
    $errPath = Join-Path $tempDir 'err.txt'

    $expanded = @()
    foreach ($a in @($entry.args)) {
        $expanded += ([string]$a).Replace('{prompt}', $probe).Replace('{promptFile}', $promptFile).Replace('{projectRoot}', $Project).Replace('{taskId}', 'provider-probe')
    }

    $exitCode = $null
    $timedOut = $false
    try {
        # Run through a job using the native call operator rather than Start-Process:
        # Start-Process -ArgumentList joins an array WITHOUT quoting, so the probe
        # prompt (and any path containing a space) is split into separate arguments.
        $job = Start-Job -ScriptBlock {
            param($Exe, $Argv, $Out, $Err, $Wd)
            Set-Location -LiteralPath $Wd
            & $Exe @Argv 1> $Out 2> $Err
            if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        } -ArgumentList ([string]$entry.command), $expanded, $outPath, $errPath, $Project

        if (Wait-Job -Job $job -Timeout $timeout) {
            $exitCode = [int](Receive-Job -Job $job)
        } else {
            $timedOut = $true
            Stop-Job -Job $job -ErrorAction SilentlyContinue
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    } catch {
        return [ordered]@{ provider = $name; usable = $false; diagnosis = "Could not start '$($entry.command)': $($_.Exception.Message)" }
    }

    $stdout = ''; $stderr = ''
    if (Test-Path -LiteralPath $outPath) { $raw = Get-Content -Raw -LiteralPath $outPath; if ($null -ne $raw) { $stdout = [string]$raw } }
    if (Test-Path -LiteralPath $errPath) { $raw = Get-Content -Raw -LiteralPath $errPath; if ($null -ne $raw) { $stderr = [string]$raw } }
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue

    $combined = "$stdout $stderr"
    $usable = $false
    $diagnosis = ''
    if ($timedOut) {
        $diagnosis = "No response within ${timeout}s. The command may be waiting for interactive input; headless/print mode is required."
    } elseif ($exitCode -ne 0) {
        if ($combined -match '(?i)auth|login|oauth|credential|api[_ -]?key|token') {
            $diagnosis = "Exited $exitCode with an authentication error. Sign the CLI in, then retry. Detail: $(($combined.Trim() -split "`n")[0])"
        } else {
            $diagnosis = "Exited $exitCode. Detail: $(($combined.Trim() -split "`n")[0])"
        }
    } elseif ([string]::IsNullOrWhiteSpace($stdout)) {
        $diagnosis = "Exited 0 but produced NO output. Usually a permission gate: the CLI could not prompt in headless mode and auto-denied its tools. Detail: $(($combined.Trim() -split "`n")[0])"
    } elseif ($stdout -match 'STATEFULCLANKER_PROVIDER_OK') {
        $usable = $true
        $diagnosis = 'Provider responded correctly.'
    } else {
        $usable = $true
        $diagnosis = 'Provider responded, though not with the exact probe text. Usable, but check it is in non-interactive print mode.'
    }

    return [ordered]@{
        provider   = $name
        command    = [string]$entry.command
        usable     = $usable
        exitCode   = $exitCode
        timedOut   = $timedOut
        diagnosis  = $diagnosis
        stdoutHead = if ($stdout.Length -gt 400) { $stdout.Substring(0, 400) } else { $stdout }
        stderrHead = if ($stderr.Length -gt 400) { $stderr.Substring(0, 400) } else { $stderr }
    }
}

function Get-McpRunRecordPath([string]$Project) { Join-Path (Get-McpStateDir $Project) 'mcp\run.json' }

function Get-McpBusyTasks([string]$Project) {
    @(Read-McpJsonDir (Join-Path (Get-McpStateDir $Project) 'tasks') |
        Where-Object { @('running', 'reviewing', 'validating') -contains [string]$_.status })
}

<# A full cycle is worker + critic + validator in one synchronous CLI call. That is
   tens of seconds at best and unbounded with a slow provider, so it cannot be a
   blocking MCP call. Spawn detached, return a handle, let the caller poll. #>
function Get-McpLockPath([string]$Project) { Join-Path (Get-McpStateDir $Project) 'mcp\run.lock' }

<# Claim the single-cycle lock atomically, or return $null.

   Task status is NOT a usable lock: the detached process does not flip a task to
   'running' until it has started, so two run_start calls milliseconds apart both see
   an idle project and both launch. Observed in testing — two cycles on one task,
   fighting over the same state. CreateNew is an atomic filesystem operation and does
   not have that window. #>
function Enter-McpRunLock([string]$Project) {
    $lockPath = Get-McpLockPath $Project
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $stream = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $payload = [Text.Encoding]::UTF8.GetBytes(("{0}|{1}" -f $PID, (Get-Date).ToUniversalTime().ToString('o')))
                $stream.Write($payload, 0, $payload.Length)
            } finally { $stream.Dispose() }
            return $lockPath
        } catch [IO.IOException] {
            # Held. If the holder is gone, the lock is stale (crash, kill, reboot).
            $holder = $null
            try { $holder = (Get-Content -Raw -LiteralPath $lockPath).Split('|')[0] } catch { }
            $alive = $false
            if ($holder) { $alive = [bool](Get-Process -Id ([int]$holder) -ErrorAction SilentlyContinue) }
            if ($alive) { return $null }
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        }
    }
    return $null
}

function Exit-McpRunLock([string]$Project) {
    Remove-Item -LiteralPath (Get-McpLockPath $Project) -Force -ErrorAction SilentlyContinue
}

function Start-McpRun([string]$Project, [string]$TaskId, [string]$Provider) {
    Assert-McpInitialized $Project
    $stateDir = Get-McpStateDir $Project
    $mcpDir = Join-Path $stateDir 'mcp'
    if (-not (Test-Path -LiteralPath $mcpDir)) { New-Item -ItemType Directory -Force -Path $mcpDir | Out-Null }

    # The harness has no locking of any kind and maxConcurrent is dead config, so two
    # cycles interleave writes to state.json and corrupt each other.
    # @() is load-bearing: a function returning an array unrolls to a scalar on one
    # element, and StrictMode makes .Count on that scalar a hard error.
    $busy = @(Get-McpBusyTasks $Project)
    if ($busy.Count -gt 0) {
        $ids = ($busy | ForEach-Object { $_.id }) -join ', '
        throw "A cycle is already in flight for task(s): $ids. Poll run_status, or clear it with task_retry."
    }
    if (-not (Enter-McpRunLock $Project)) {
        throw 'Another cycle is already starting or running in this project. Poll run_status until inFlight is false.'
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $logPath = Join-Path $mcpDir ("run-{0}-{1}.log" -f $stamp, [Guid]::NewGuid().ToString('N').Substring(0, 6))
    $cli = @('run')
    if ($TaskId) { $cli += @('-TaskId', $TaskId) }
    if ($Provider) { $cli += @('-Provider', $Provider) }

    $pwshPath = Get-McpPwshPath
    # Quote explicitly: Start-Process -ArgumentList joins an array WITHOUT quoting, so
    # any path containing a space (C:\My Projects\...) is split into separate
    # arguments and the cycle dies on a bogus path.
    $psArgs = ((@('-NoProfile', '-NonInteractive', '-File', $script:McpHarness) + $cli) |
        ForEach-Object { ConvertTo-McpWindowsArg $_ }) -join ' '

    try {
        $proc = Start-Process -FilePath $pwshPath -ArgumentList $psArgs -WorkingDirectory $Project `
            -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err" `
            -WindowStyle Hidden -PassThru
    } catch {
        Exit-McpRunLock $Project
        throw
    }

    # Hand the lock to the cycle process. The MCP server may be restarted or shut down
    # while a cycle runs; staleness must track the process actually doing the work.
    try {
        ("{0}|{1}" -f $proc.Id, (Get-Date).ToUniversalTime().ToString('o')) |
            Set-Content -LiteralPath (Get-McpLockPath $Project) -Encoding UTF8 -NoNewline
    } catch { }

    $record = [ordered]@{
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
        taskId    = if ($TaskId) { $TaskId } else { '(next ready task)' }
        provider  = if ($Provider) { $Provider } else { '(config default)' }
        processId = $proc.Id
        logPath   = $logPath
        note      = 'Cycle runs detached. Poll run_status until inFlight is false.'
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Get-McpRunRecordPath $Project) -Encoding UTF8
    return $record
}

<# Parallel batch. Shares the single-flight lock with run_start: one BATCH at a
   time, several workers inside it. The harness scheduler owns worktree creation,
   merging and cleanup; this only launches and tracks it. #>
function Start-McpParallelRun([string]$Project, $Arguments) {
    Assert-McpInitialized $Project
    $stateDir = Get-McpStateDir $Project
    $mcpDir = Join-Path $stateDir 'mcp'
    if (-not (Test-Path -LiteralPath $mcpDir)) { New-Item -ItemType Directory -Force -Path $mcpDir | Out-Null }

    $busy = @(Get-McpBusyTasks $Project)
    if ($busy.Count -gt 0) {
        $ids = ($busy | ForEach-Object { $_.id }) -join ', '
        throw "Work is already in flight for task(s): $ids. Poll run_status, or clear with task_retry."
    }
    if (-not (Enter-McpRunLock $Project)) {
        throw 'Another run is already starting or running in this project. Poll run_status until inFlight is false.'
    }

    $maxConcurrent = 0
    if ($Arguments -and $Arguments.PSObject.Properties['maxConcurrent'] -and $Arguments.maxConcurrent) {
        $maxConcurrent = [Math]::Min(16, [Math]::Max(1, [int]$Arguments.maxConcurrent))
    }
    if ($maxConcurrent -gt 0) {
        $cli = @('run', '-Parallel', [string]$maxConcurrent)
    } else {
        # 'run parallel' selects the mode without pinning a limit, so the harness
        # falls back to maxConcurrent from config.json.
        $cli = @('run', 'parallel')
    }
    $provider = Get-McpArgOptional $Arguments 'provider'
    if ($provider) { $cli += @('-Provider', $provider) }
    if ($Arguments -and $Arguments.PSObject.Properties['noMerge'] -and [bool]$Arguments.noMerge) { $cli += '-NoMerge' }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $logPath = Join-Path $mcpDir ("parallel-{0}-{1}.log" -f $stamp, [Guid]::NewGuid().ToString('N').Substring(0, 6))
    $pwshPath = Get-McpPwshPath
    $psArgs = ((@('-NoProfile', '-NonInteractive', '-File', $script:McpHarness) + $cli) |
        ForEach-Object { ConvertTo-McpWindowsArg $_ }) -join ' '

    try {
        $proc = Start-Process -FilePath $pwshPath -ArgumentList $psArgs -WorkingDirectory $Project `
            -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err" `
            -WindowStyle Hidden -PassThru
    } catch {
        Exit-McpRunLock $Project
        throw
    }
    try {
        ("{0}|{1}" -f $proc.Id, (Get-Date).ToUniversalTime().ToString('o')) |
            Set-Content -LiteralPath (Get-McpLockPath $Project) -Encoding UTF8 -NoNewline
    } catch { }

    $record = [ordered]@{
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
        mode = 'parallel'
        maxConcurrent = if ($maxConcurrent -gt 0) { $maxConcurrent } else { '(config maxConcurrent)' }
        processId = $proc.Id
        logPath = $logPath
        note = 'Each task runs in its own git worktree and is merged back if it passes. Poll run_status until inFlight is false, then read the log for MERGED/HELD/FAILED per task.'
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Get-McpRunRecordPath $Project) -Encoding UTF8
    return $record
}

function Get-McpRunStatus([string]$Project) {
    Assert-McpInitialized $Project
    $stateDir = Get-McpStateDir $Project
    $last = Read-McpJson (Get-McpRunRecordPath $Project)
    $busy = @(Get-McpBusyTasks $Project)
    $active = @(Read-McpJsonDir (Join-Path $stateDir 'telemetry\active'))

    $alive = $false
    if ($last -and $last.PSObject.Properties['processId'] -and $last.processId) {
        $alive = [bool](Get-Process -Id ([int]$last.processId) -ErrorAction SilentlyContinue)
    }
    $tail = ''
    if ($last -and $last.PSObject.Properties['logPath'] -and $last.logPath -and (Test-Path -LiteralPath $last.logPath)) {
        $tail = ((Get-Content -LiteralPath $last.logPath -Tail 20) -join "`n")
    }
    $errTail = ''
    if ($last -and $last.PSObject.Properties['logPath'] -and $last.logPath -and (Test-Path -LiteralPath "$($last.logPath).err")) {
        $errTail = ((Get-Content -LiteralPath "$($last.logPath).err" -Tail 20) -join "`n")
    }
    $inFlight = ($busy.Count -gt 0 -or $alive)
    # Nothing else releases the lock: the cycle is the plain CLI and knows nothing
    # about it. Polling is the cleanup point.
    if (-not $inFlight) { Exit-McpRunLock $Project }

    return [ordered]@{
        inFlight     = $inFlight
        processAlive = $alive
        lastRun      = $last
        busyTasks    = @($busy | ForEach-Object { [ordered]@{ id = $_.id; status = $_.status; attemptCount = $_.attemptCount } })
        activeAgents = @($active | ForEach-Object { [ordered]@{ agentId = $_.agentId; taskId = $_.taskId; stage = $_.stage; provider = $_.provider; startedAt = $_.startedAt } })
        logTail      = $tail
        errorTail    = $errTail
    }
}

function Get-McpToolList {
    $projectProp = @{ project = @{ type = 'string'; description = 'Absolute path to the StatefulClanker project. Optional when the server was started with -ProjectPath.' } }
    @(
        # ---- project ----
        @{ name = 'project_init'; description = 'Initialize or migrate durable StatefulClanker state in a directory.'; inputSchema = @{ type = 'object'; properties = $projectProp } },
        @{ name = 'project_use'; description = 'Set the default project path for subsequent calls in this session.'; inputSchema = @{ type = 'object'; properties = @{ project = @{ type = 'string' } }; required = @('project') } },
        @{ name = 'project_status'; description = 'Read canonical project state, goal, plan approval, and task summary.'; inputSchema = @{ type = 'object'; properties = $projectProp } },
        @{ name = 'goal_set'; description = 'Set or replace the project goal.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ text = @{ type = 'string' } }); required = @('text') } },

        # ---- tasks ----
        @{ name = 'task_list'; description = 'List task graph state, including compilation/proposal pointers and semantic relations.'; inputSchema = @{ type = 'object'; properties = $projectProp } },
        @{ name = 'task_show'; description = 'Read one task in full.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ taskId = @{ type = 'string' } }); required = @('taskId') } },
        @{ name = 'task_add'; description = 'Add a task to the graph. Retrieval selectors are files/dirs/globs relative to the project root.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{
            taskId      = @{ type = 'string'; description = 'Optional stable id. Generated when omitted.' }
            title       = @{ type = 'string' }
            instruction = @{ type = 'string'; description = 'What the cold-start worker must do. Must stand alone.' }
            accept      = @{ type = 'array'; items = @{ type = 'string' }; description = 'Observable acceptance criteria.' }
            retrieval   = @{ type = 'array'; items = @{ type = 'string' }; description = 'Files/dirs/globs to compile into the worker context.' }
            evidence    = @{ type = 'array'; items = @{ type = 'string' } }
            dependsOn   = @{ type = 'array'; items = @{ type = 'string' }; description = 'Scheduling dependencies.' }
            relation    = @{ type = 'array'; items = @{ type = 'string' }; description = 'Semantic relations as type:target, e.g. discovered_from:cache-design.' }
            provider    = @{ type = 'string' }
            humanGate   = @{ type = 'boolean'; description = 'Require a human to release this task before it can run.' }
        }); required = @('title', 'instruction') } },
        @{ name = 'task_retry'; description = 'Reset a task to ready and invalidate affected dependents. Advances the task control revision.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ taskId = @{ type = 'string' } }); required = @('taskId') } },
        @{ name = 'task_block'; description = 'Block a task with a reason. Advances the task control revision.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ taskId = @{ type = 'string' }; reason = @{ type = 'string' } }); required = @('taskId', 'reason') } },
        @{ name = 'task_complete'; description = 'HUMAN AUTHORITY: mark a task complete WITHOUT critic/validator review. Disabled unless mcp.allowHumanAuthorityTools is true.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ taskId = @{ type = 'string' } }); required = @('taskId') } },

        # ---- plans ----
        @{ name = 'plan_import'; description = 'Import a JSON plan/task graph from a file path.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ path = @{ type = 'string' } }); required = @('path') } },
        @{ name = 'plan_approve'; description = 'HUMAN AUTHORITY: approve the active plan so tasks may run. Disabled unless mcp.allowHumanAuthorityTools is true.'; inputSchema = @{ type = 'object'; properties = $projectProp } },

        # ---- execution ----
        @{ name = 'run_start'; description = 'Start one compile -> worker -> critic -> validator -> commit cycle DETACHED. Returns immediately; poll run_status. Refuses if a cycle is already in flight.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ taskId = @{ type = 'string'; description = 'Omit to run the next ready task.' }; provider = @{ type = 'string' } }) } },
        @{ name = 'run_parallel'; description = 'Start SEVERAL ready tasks at once, each in its own git worktree, then merge the ones that pass. Detached; poll run_status. Requires the project to be a git repo with a clean working tree.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ maxConcurrent = @{ type = 'integer'; minimum = 1; maximum = 16; description = 'Defaults to maxConcurrent in config.json.' }; provider = @{ type = 'string' }; noMerge = @{ type = 'boolean'; description = 'Commit each task to its own branch but do not merge. Use to review before integrating.' } }) } },
        @{ name = 'run_status'; description = 'Poll the detached cycle: whether it is in flight, which agents are active, and the tail of its log.'; inputSchema = @{ type = 'object'; properties = $projectProp } },

        # ---- observation ----
        @{ name = 'direction_add'; description = 'Record human direction durably and advance the project direction revision, staling older compilations.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ message = @{ type = 'string' } }); required = @('message') } },
        @{ name = 'provider_list'; description = 'List configured worker providers and which one is default/critic/validator.'; inputSchema = @{ type = 'object'; properties = $projectProp } },
        @{ name = 'provider_set'; description = 'Add or update a worker provider (the CLI that actually does the work) and optionally make it the default/critic/validator. Required before the first run_start.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{
            name        = @{ type = 'string'; description = 'Short id, e.g. claude, opencode, agy.' }
            command     = @{ type = 'string'; description = 'Executable to run. Must be on PATH or a full path.' }
            args        = @{ type = 'array'; items = @{ type = 'string' }; description = 'Arguments. MUST include {prompt} or {promptFile}. Also supports {projectRoot} and {taskId}.' }
            mode        = @{ type = 'string'; enum = @('inline', 'prompt-file'); description = 'Inferred from the placeholder when omitted.' }
            setDefault  = @{ type = 'boolean' }
            setCritic   = @{ type = 'boolean' }
            setValidator = @{ type = 'boolean' }
        }); required = @('name', 'command', 'args') } },
        @{ name = 'provider_test'; description = 'Dispatch a trivial probe prompt to a provider and report whether it is actually usable. Catches expired logins and headless permission gates before a real cycle wastes an attempt.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ name = @{ type = 'string'; description = 'Defaults to the configured default provider.' }; timeoutSeconds = @{ type = 'integer'; minimum = 10; maximum = 300 } }) } },
        @{ name = 'telemetry_active'; description = 'List currently active subagents.'; inputSchema = @{ type = 'object'; properties = $projectProp } },
        @{ name = 'telemetry_history'; description = 'List historical subagent telemetry.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ limit = @{ type = 'integer'; minimum = 1; maximum = 500 } }) } },
        @{ name = 'telemetry_run'; description = 'Get one historical subagent run by agentId.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ agentId = @{ type = 'string' } }); required = @('agentId') } },
        @{ name = 'context_faults'; description = 'Read recent explicit missing-context requests emitted by workers.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ limit = @{ type = 'integer'; minimum = 1; maximum = 500 } }) } },
        @{ name = 'compilation_get'; description = 'Read one durable compiled-context receipt including read set and exact worker IR.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ compilationId = @{ type = 'string' } }); required = @('compilationId') } },
        @{ name = 'proposal_get'; description = 'Read one candidate/committed/rejected state-transition proposal.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ proposalId = @{ type = 'string' } }); required = @('proposalId') } },
        @{ name = 'progress_history'; description = 'Read recent task progress/stagnation records: whether each cycle actually advanced the project.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ limit = @{ type = 'integer'; minimum = 1; maximum = 500 } }) } },
        @{ name = 'events_recent'; description = 'Read the recent append-only project event log.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ limit = @{ type = 'integer'; minimum = 1; maximum = 500 } }) } }
    )
}

function Invoke-McpTool([string]$Name, $Arguments) {
    # project_use is the one tool that does not require an existing project on disk.
    if ($Name -eq 'project_use') {
        $path = Get-McpArgRequired $Arguments 'project'
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Project path does not exist: $path" }
        Set-McpDefaultProject $path
        return New-McpTextResult ([ordered]@{ project = $script:McpDefaultProject; initialized = (Test-Path -LiteralPath (Join-Path (Get-McpStateDir $script:McpDefaultProject) 'state.json')) })
    }

    $project = Get-McpProject $Arguments
    $stateDir = Get-McpStateDir $project

    switch ($Name) {
        'project_init' {
            $r = Invoke-McpHarness $project @('init')
            return New-McpTextResult ([ordered]@{ project = $project; output = $r.stdout })
        }
        'project_status' {
            Assert-McpInitialized $project
            $state = Read-McpJson (Join-Path $stateDir 'state.json')
            $tasks = Read-McpJsonDir (Join-Path $stateDir 'tasks')
            $run = Get-McpRunStatus $project
            return New-McpTextResult ([ordered]@{
                project        = $project
                state          = $state
                cycleInFlight  = $run.inFlight
                humanAuthority = (Get-McpConfigFlag $project 'allowHumanAuthorityTools' $false)
                tasks          = @($tasks | Sort-Object createdAt | ForEach-Object { [ordered]@{ id = $_.id; status = $_.status; title = $_.title; attemptCount = $_.attemptCount; humanGate = $_.humanGate; blockReason = $_.blockReason } })
            })
        }
        'goal_set' {
            Assert-McpInitialized $project
            $text = Get-McpArgRequired $Arguments 'text'
            $r = Invoke-McpHarness $project @('goal', '-Message', $text)
            return New-McpTextResult ([ordered]@{ goal = $text; output = $r.stdout })
        }
        'task_list' {
            Assert-McpInitialized $project
            return New-McpTextResult (@(Read-McpJsonDir (Join-Path $stateDir 'tasks') | Sort-Object createdAt))
        }
        'task_show' {
            Assert-McpInitialized $project
            $id = Get-McpArgRequired $Arguments 'taskId'
            $task = Read-McpJson (Join-Path $stateDir ("tasks\{0}.json" -f $id))
            if (-not $task) { throw "Unknown taskId: $id" }
            return New-McpTextResult $task
        }
        'task_add' {
            Assert-McpInitialized $project
            $cli = @('task', 'add')
            $cli += @('-Title', (Get-McpArgRequired $Arguments 'title'))
            $cli += @('-Instruction', (Get-McpArgRequired $Arguments 'instruction'))
            $id = Get-McpArgOptional $Arguments 'taskId'
            if ($id) { $cli += @('-TaskId', $id) }
            $provider = Get-McpArgOptional $Arguments 'provider'
            if ($provider) { $cli += @('-Provider', $provider) }
            foreach ($pair in @(@('accept', '-Accept'), @('retrieval', '-Retrieval'), @('evidence', '-Evidence'), @('dependsOn', '-DependsOn'), @('relation', '-Relation'))) {
                $values = @(Get-McpArgArray $Arguments $pair[0])
                if ($values.Count -gt 0) { $cli += $pair[1]; $cli += (, $values) }
            }
            if ($Arguments -and $Arguments.PSObject.Properties['humanGate'] -and [bool]$Arguments.humanGate) { $cli += '-HumanGate' }
            $r = Invoke-McpHarness $project $cli
            return New-McpTextResult ([ordered]@{ taskId = $r.stdout; created = $true })
        }
        'task_retry' {
            Assert-McpInitialized $project
            $id = Get-McpArgRequired $Arguments 'taskId'
            $r = Invoke-McpHarness $project @('task', 'retry', '-TaskId', $id)
            return New-McpTextResult ([ordered]@{ taskId = $id; output = $r.stdout })
        }
        'task_block' {
            Assert-McpInitialized $project
            $id = Get-McpArgRequired $Arguments 'taskId'
            $reason = Get-McpArgRequired $Arguments 'reason'
            $r = Invoke-McpHarness $project @('block', '-TaskId', $id, '-Reason', $reason)
            return New-McpTextResult ([ordered]@{ taskId = $id; output = $r.stdout })
        }
        'task_complete' {
            Assert-McpInitialized $project
            Assert-McpHumanAuthority $project 'task_complete'
            $id = Get-McpArgRequired $Arguments 'taskId'
            $r = Invoke-McpHarness $project @('complete', '-TaskId', $id)
            return New-McpTextResult ([ordered]@{ taskId = $id; authority = 'human'; output = $r.stdout })
        }
        'plan_import' {
            Assert-McpInitialized $project
            $path = Get-McpArgRequired $Arguments 'path'
            $r = Invoke-McpHarness $project @('plan', 'import', '-Path', $path)
            return New-McpTextResult ([ordered]@{ imported = $path; output = $r.stdout })
        }
        'plan_approve' {
            Assert-McpInitialized $project
            Assert-McpHumanAuthority $project 'plan_approve'
            $r = Invoke-McpHarness $project @('plan', 'approve')
            return New-McpTextResult ([ordered]@{ approved = $true; authority = 'human'; output = $r.stdout })
        }
        'run_start' {
            $record = Start-McpRun $project (Get-McpArgOptional $Arguments 'taskId') (Get-McpArgOptional $Arguments 'provider')
            return New-McpTextResult $record
        }
        'run_parallel' {
            $record = Start-McpParallelRun $project $Arguments
            return New-McpTextResult $record
        }
        'run_status' {
            return New-McpTextResult (Get-McpRunStatus $project)
        }
        'direction_add' {
            Assert-McpInitialized $project
            $message = Get-McpArgRequired $Arguments 'message'
            Invoke-McpHarness $project @('event', '-Message', $message) | Out-Null
            return New-McpTextResult ([ordered]@{ recorded = $true; invalidatesOlderCompilations = $true })
        }
        'provider_list' {
            Assert-McpInitialized $project
            $cfg = Read-McpJson (Join-Path $stateDir 'config.json')
            $rows = @()
            if ($cfg -and $cfg.PSObject.Properties['providers'] -and $cfg.providers) {
                foreach ($p in $cfg.providers.PSObject.Properties) {
                    $rows += [ordered]@{ name = $p.Name; command = $p.Value.command; mode = $p.Value.mode }
                }
            }
            return New-McpTextResult ([ordered]@{ defaultProvider = $cfg.defaultProvider; criticProvider = $cfg.criticProvider; validatorProvider = $cfg.validatorProvider; providers = @($rows) })
        }
        'provider_set' {
            return New-McpTextResult (Set-McpProvider $project $Arguments)
        }
        'provider_test' {
            return New-McpTextResult (Test-McpProvider $project $Arguments)
        }
        'telemetry_active' {
            Assert-McpInitialized $project
            return New-McpTextResult (@(Read-McpJsonDir (Join-Path $stateDir 'telemetry\active') | Sort-Object startedAt))
        }
        'telemetry_history' {
            Assert-McpInitialized $project
            $limit = Get-McpArgLimit $Arguments
            return New-McpTextResult (@(Read-McpJsonDir (Join-Path $stateDir 'telemetry\runs') | Sort-Object startedAt -Descending | Select-Object -First $limit))
        }
        'telemetry_run' {
            Assert-McpInitialized $project
            $id = Get-McpArgRequired $Arguments 'agentId'
            $r = Read-McpJson (Join-Path $stateDir ("telemetry\runs\{0}.json" -f $id))
            if (-not $r) { throw "Unknown agentId: $id" }
            return New-McpTextResult $r
        }
        'context_faults' {
            Assert-McpInitialized $project
            return New-McpTextResult (@(Read-McpJsonl (Join-Path $stateDir 'telemetry\context-faults.jsonl') (Get-McpArgLimit $Arguments)))
        }
        'compilation_get' {
            Assert-McpInitialized $project
            $id = Get-McpArgRequired $Arguments 'compilationId'
            $r = Read-McpJson (Join-Path $stateDir ("compilations\{0}.json" -f $id))
            if (-not $r) { throw "Unknown compilationId: $id" }
            return New-McpTextResult $r
        }
        'proposal_get' {
            Assert-McpInitialized $project
            $id = Get-McpArgRequired $Arguments 'proposalId'
            $r = Read-McpJson (Join-Path $stateDir ("proposals\{0}.json" -f $id))
            if (-not $r) { throw "Unknown proposalId: $id" }
            return New-McpTextResult $r
        }
        'progress_history' {
            Assert-McpInitialized $project
            $limit = Get-McpArgLimit $Arguments
            return New-McpTextResult (@(Read-McpJsonDir (Join-Path $stateDir 'progress') | Sort-Object ts -Descending | Select-Object -First $limit))
        }
        'events_recent' {
            Assert-McpInitialized $project
            $limit = Get-McpArgLimit $Arguments
            return New-McpTextResult (@(Read-McpJsonl (Join-Path $stateDir 'events.jsonl') $limit))
        }
        default { throw "Unknown tool: $Name" }
    }
}

<# Handle one JSON-RPC request object and return the response object, or $null for
   notifications. Transport-free so both hosts share it. #>
function Invoke-McpRpc($Request) {
    $method = [string]$Request.method
    $id = $null
    if ($Request.PSObject.Properties['id']) { $id = $Request.id }

    switch ($method) {
        'initialize' {
            return [ordered]@{ jsonrpc = '2.0'; id = $id; result = [ordered]@{
                protocolVersion = $script:McpProtocol
                capabilities    = @{ tools = @{} }
                serverInfo      = @{ name = 'statefulclanker'; version = $script:McpVersion }
            } }
        }
        'notifications/initialized' { return $null }
        'ping' { return [ordered]@{ jsonrpc = '2.0'; id = $id; result = @{} } }
        'tools/list' { return [ordered]@{ jsonrpc = '2.0'; id = $id; result = @{ tools = Get-McpToolList } } }
        'tools/call' {
            $toolName = [string]$Request.params.name
            $toolArgs = $null
            if ($Request.params.PSObject.Properties['arguments']) { $toolArgs = $Request.params.arguments }
            try {
                return [ordered]@{ jsonrpc = '2.0'; id = $id; result = (Invoke-McpTool $toolName $toolArgs) }
            } catch {
                # Tool failures are results with isError, not protocol errors. A protocol
                # error tells the client the call was malformed; this one was well-formed
                # and the tool refused, which the model should see and react to.
                return [ordered]@{ jsonrpc = '2.0'; id = $id; result = @{
                    isError = $true
                    content = @(@{ type = 'text'; text = ("Tool '{0}' failed: {1}" -f $toolName, $_.Exception.Message) })
                } }
            }
        }
        default {
            if ($null -eq $id) { return $null }
            return [ordered]@{ jsonrpc = '2.0'; id = $id; error = [ordered]@{ code = -32601; message = "Method not found: $method" } }
        }
    }
}

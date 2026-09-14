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

    $pwshPath = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($pwshPath)) { $pwshPath = 'pwsh' }
    $psArgs = @('-NoProfile', '-NonInteractive', '-File', $script:McpHarness) + $cli

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
        @{ name = 'run_status'; description = 'Poll the detached cycle: whether it is in flight, which agents are active, and the tail of its log.'; inputSchema = @{ type = 'object'; properties = $projectProp } },

        # ---- observation ----
        @{ name = 'direction_add'; description = 'Record human direction durably and advance the project direction revision, staling older compilations.'; inputSchema = @{ type = 'object'; properties = ($projectProp + @{ message = @{ type = 'string' } }); required = @('message') } },
        @{ name = 'provider_list'; description = 'List configured worker providers.'; inputSchema = @{ type = 'object'; properties = $projectProp } },
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

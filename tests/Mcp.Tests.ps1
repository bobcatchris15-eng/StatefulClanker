<# MCP server tests: stdio round-trip, argument fidelity, gating, and locking.

   Runs against a throwaway project and the mock provider, so no model, network, or
   credentials are needed. Invoked by tests/Smoke.ps1; also runnable standalone. #>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$mcpStdio = Join-Path $repo 'mcp\StatefulClanker.Mcp.ps1'
$mockCmd = Join-Path $PSScriptRoot 'MockProvider.cmd'

function Get-PwshPath {
    $self = (Get-Process -Id $PID).Path
    if (-not [string]::IsNullOrWhiteSpace($self)) { return $self }
    return (Get-Command pwsh).Source
}

<# Send JSON-RPC lines to the stdio server and return one parsed object per line. #>
function Invoke-McpLines([string]$Project, [string[]]$Lines) {
    $inputPath = Join-Path ([IO.Path]::GetTempPath()) ("mcp-in-{0}.txt" -f [Guid]::NewGuid().ToString('N'))
    $outPath = "$inputPath.out"
    ($Lines -join "`n") | Set-Content -LiteralPath $inputPath -Encoding UTF8
    $pwsh = Get-PwshPath
    Get-Content -LiteralPath $inputPath | & $pwsh -NoProfile -File $mcpStdio -ProjectPath $Project 1> $outPath 2>$null
    $raw = @(Get-Content -LiteralPath $outPath | Where-Object { $_ })
    Remove-Item -LiteralPath $inputPath, $outPath -Force -ErrorAction SilentlyContinue
    if ($raw.Count -eq 0) { throw "MCP server returned no output for: $($Lines -join ' | ')" }
    # The comma keeps this an array: a function returning @() unrolls to $null, and
    # the caller's [0] then fails with a misleading "cannot index into a null array".
    return , @($raw | ForEach-Object { $_ | ConvertFrom-Json })
}

<# Build one JSON-RPC line. Use this rather than hand-concatenating JSON: Windows
   paths need doubled backslashes and getting that wrong yields a parse error whose
   symptom is a confusing null-result several lines later. #>
function New-McpCall([int]$Id, [string]$Tool, [hashtable]$Arguments) {
    if ($null -eq $Arguments) { $Arguments = @{} }
    return (@{ jsonrpc = '2.0'; id = $Id; method = 'tools/call'; params = @{ name = $Tool; arguments = $Arguments } } |
        ConvertTo-Json -Depth 12 -Compress)
}

function Get-ToolPayload($Response) {
    if ($null -eq $Response) { throw 'Expected a response object, got $null (fewer responses than requests).' }
    if ($Response.PSObject.Properties['error'] -and $Response.error) {
        throw "Server returned a protocol error $($Response.error.code): $($Response.error.message)"
    }
    if ($null -eq $Response.result) {
        throw "Response carried no result: $($Response | ConvertTo-Json -Depth 8 -Compress)"
    }
    if ($Response.result.PSObject.Properties['isError'] -and $Response.result.isError) {
        throw "Tool returned isError: $($Response.result.content[0].text)"
    }
    return ($Response.result.content[0].text | ConvertFrom-Json)
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "MCP TEST FAILED: $Message" }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-mcp-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
try {
    'evidence for retrieval' | Set-Content -LiteralPath (Join-Path $temp 'evidence.txt') -Encoding UTF8

    Write-Host '  MCP 1: protocol handshake and tool listing'
    $r = Invoke-McpLines $temp @(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    )
    Assert-True ($r.Count -eq 2) "Expected 2 responses, got $($r.Count)."
    Assert-True ($r[0].result.serverInfo.name -eq 'statefulclanker') 'Bad serverInfo.'
    Assert-True (@($r[1].result.tools).Count -ge 20) 'Expected the full tool surface.'
    $toolNames = @($r[1].result.tools | ForEach-Object { $_.name })
    foreach ($required in @('project_init', 'goal_set', 'task_add', 'run_start', 'run_status', 'task_retry', 'direction_add')) {
        Assert-True ($toolNames -contains $required) "Missing control tool: $required"
    }

    Write-Host '  MCP 2: request id is echoed on every failure path'
    # A response carrying id:null leaves a client that correlates by id waiting forever.
    $r = Invoke-McpLines $temp @(
        '{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"does_not_exist","arguments":{}}}',
        '{"jsonrpc":"2.0","id":42,"method":"no/such/method"}'
    )
    Assert-True ($r[0].id -eq 41) "Tool error dropped the request id (got '$($r[0].id)')."
    Assert-True ([bool]$r[0].result.isError) 'Unknown tool should return isError, not a protocol error.'
    Assert-True ($r[1].id -eq 42) "Method error dropped the request id (got '$($r[1].id)')."
    Assert-True ($r[1].error.code -eq -32601) 'Unknown method should be -32601.'

    Write-Host '  MCP 3: drive a project from nothing via tools only'
    $r = Invoke-McpLines $temp @(
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_init","arguments":{}}}',
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"goal_set","arguments":{"text":"Exercise the MCP control plane."}}}'
    )
    Get-ToolPayload $r[0] | Out-Null
    Get-ToolPayload $r[1] | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $temp '.statefulclanker\state.json')) 'project_init did not create state.'

    # Keep the compatibility CLI path explicit. Automatic dispatch belongs to the
    # compiled endpoint router; this test intentionally exercises the opt-in CLI escape hatch.
    $cfgPath = Join-Path $temp '.statefulclanker\config.json'
    $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    $cfg.validatorEnabled = $false
    $cfg.providers | Add-Member -NotePropertyName mock -NotePropertyValue ([pscustomobject]@{
            command = 'cmd.exe'; args = @('/d', '/c', $mockCmd); mode = 'prompt-file'
        }) -Force
    $cfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cfgPath -Encoding UTF8

    Write-Host '  MCP 3b: provider_set validates before writing config'
    # Without provider configuration over MCP there is no way to reach a working
    # first run from a chat session: the setting lives only in config.json and has
    # no CLI command.
    $r = Invoke-McpLines $temp @(
        (New-McpCall 1 'provider_set' @{ name = 'ghost'; command = 'definitely-not-installed-xyz'; args = @('-p') }),
        # stdin pipes the prompt, so {prompt} in args is a contradiction.
        (New-McpCall 2 'provider_set' @{ name = 'contradiction'; command = 'cmd.exe'; args = @('/c', '{prompt}'); mode = 'stdin' }),
        # prompt-file without the placeholder means the worker gets no task at all.
        (New-McpCall 3 'provider_set' @{ name = 'nofile'; command = 'cmd.exe'; args = @('/c', 'echo'); mode = 'prompt-file' }),
        # No placeholder and no mode is the normal case: default to stdin.
        (New-McpCall 4 'provider_set' @{ name = 'viastdin'; command = 'cmd.exe'; args = @('/d', '/c', 'more.com') })
    )
    Assert-True ([bool]$r[0].result.isError) 'provider_set must reject a command that is not installed.'
    Assert-True ([bool]$r[1].result.isError) 'mode stdin with {prompt} in args must be rejected.'
    Assert-True ([bool]$r[2].result.isError) 'mode prompt-file without {promptFile} must be rejected.'
    $stdinSet = Get-ToolPayload $r[3]
    Assert-True ($stdinSet.mode -eq 'stdin') "Args with no placeholder should default to stdin, got '$($stdinSet.mode)'."

    Write-Host '  MCP 3c: provider_set writes a usable compatibility backend, provider_test probes it'
    $r = Invoke-McpLines $temp @(
        (New-McpCall 1 'provider_set' @{
            name = 'mock'; command = 'cmd.exe'; args = @('/d', '/c', $mockCmd, '{promptFile}')
        }),
        (New-McpCall 2 'provider_list' @{})
    )
    $set = Get-ToolPayload $r[0]
    Assert-True ($set.mode -eq 'prompt-file') "mode should be inferred from {promptFile}, got '$($set.mode)'."
    Assert-True ($set.routing -like '*compatibility backend*') 'provider_set should not recreate legacy default/critic/validator routing roles.'
    $providers = Get-ToolPayload $r[1]
    Assert-True (@($providers.providers | Where-Object name -eq 'mock').Count -eq 1) 'Configured compatibility provider was not persisted.'

    $probe = Get-ToolPayload (Invoke-McpLines $temp @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"provider_test","arguments":{"name":"mock","timeoutSeconds":60}}}'))[0]
    Assert-True ($null -ne $probe.diagnosis -and $probe.diagnosis.Length -gt 0) 'provider_test returned no diagnosis.'
    Assert-True ($probe.provider -eq 'mock') 'provider_test probed the wrong provider.'

    Write-Host '  MCP 4: array arguments survive the CLI bridge intact'
    # pwsh -File passes args as literal tokens with no expression parsing, so a
    # comma-joined array arrives as ONE element and silently collapses every
    # acceptance criterion and retrieval selector into a single bogus entry.
    $r = Invoke-McpLines $temp @(
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"task_add","arguments":{"taskId":"mcp-task","title":"MCP task","instruction":"Return a successful bounded result.","accept":["first criterion with spaces","second criterion"],"retrieval":["evidence.txt"]}}}',
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"task_show","arguments":{"taskId":"mcp-task"}}}'
    )
    Get-ToolPayload $r[0] | Out-Null
    $task = Get-ToolPayload $r[1]
    Assert-True (@($task.acceptance).Count -eq 2) "Acceptance criteria collapsed: $(@($task.acceptance) -join ' | ')"
    Assert-True ($task.acceptance[0] -eq 'first criterion with spaces') 'Acceptance criterion text was mangled.'
    Assert-True (@($task.retrieval) -contains 'evidence.txt') 'Retrieval selector lost.'

    Write-Host '  MCP 5: validation-bypassing tools are gated by default'
    $r = Invoke-McpLines $temp @(
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"task_complete","arguments":{"taskId":"mcp-task"}}}',
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"plan_approve","arguments":{}}}'
    )
    Assert-True ([bool]$r[0].result.isError) 'task_complete must be gated by default.'
    Assert-True ([bool]$r[1].result.isError) 'plan_approve must be gated by default.'
    $stillPending = Get-ToolPayload (Invoke-McpLines $temp @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"task_show","arguments":{"taskId":"mcp-task"}}}'))[0]
    Assert-True ($stillPending.status -ne 'complete') 'Gated task_complete still mutated the task.'

    Write-Host '  MCP 6: run_start is async and single-flight'
    $started = Get-Date
    $r = Invoke-McpLines $temp @(
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_start","arguments":{"taskId":"mcp-task","provider":"mock"}}}',
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_start","arguments":{"taskId":"mcp-task","provider":"mock"}}}'
    )
    Get-ToolPayload $r[0] | Out-Null
    Assert-True ([bool]$r[1].result.isError) 'A second concurrent run_start must be refused: the harness has no locking.'

    Write-Host '  MCP 7: poll the detached cycle to completion'
    $deadline = (Get-Date).AddSeconds(90)
    $status = $null
    while ((Get-Date) -lt $deadline) {
        $status = Get-ToolPayload (Invoke-McpLines $temp @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_status","arguments":{}}}'))[0]
        if (-not $status.inFlight) { break }
        Start-Sleep -Milliseconds 800
    }
    Assert-True ($null -ne $status -and -not $status.inFlight) 'Detached cycle did not finish within 90s.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $temp '.statefulclanker\mcp\run.lock'))) 'run_status did not release the single-flight lock.'

    $final = Get-ToolPayload (Invoke-McpLines $temp @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"task_show","arguments":{"taskId":"mcp-task"}}}'))[0]
    Assert-True ($final.status -eq 'complete') "Expected complete after mock cycle, got '$($final.status)'."
    Assert-True ([bool]$final.latestProposalId) 'Committed task carries no proposal pointer.'

    Write-Host '  MCP 8: observation tools read the receipts the cycle produced'
    $progress = Get-ToolPayload (Invoke-McpLines $temp @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"progress_history","arguments":{"limit":5}}}'))[0]
    Assert-True (@($progress).Count -ge 1) 'No progress records surfaced.'
    Assert-True (@($progress | Where-Object { $_.advanced }).Count -ge 1) 'No advancing progress record.'

    Write-Host 'PASS: MCP control plane (handshake, id echo, arg fidelity, gating, async run, polling)'
} finally {
    Set-Location $repo
    # run_status waits for the detached cycle to finish and release its lock.
    # Avoid a machine-wide CIM process scan here: it can hang independently of
    # StatefulClanker and turn a passing MCP suite into a stuck smoke test.
    Remove-Item -Recurse -Force -LiteralPath $temp -ErrorAction SilentlyContinue
}

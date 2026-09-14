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
    return @($raw | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-ToolPayload($Response) {
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

    # Point the freshly-created project at the mock provider.
    $cfgPath = Join-Path $temp '.statefulclanker\config.json'
    $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    $cfg.defaultProvider = 'mock'; $cfg.criticProvider = 'mock'; $cfg.validatorProvider = 'mock'
    $cfg.providers | Add-Member -NotePropertyName mock -NotePropertyValue ([pscustomobject]@{
            command = 'cmd.exe'; args = @('/d', '/c', $mockCmd); mode = 'prompt-file'
        }) -Force
    $cfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cfgPath -Encoding UTF8

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
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_start","arguments":{"taskId":"mcp-task"}}}',
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_start","arguments":{"taskId":"mcp-task"}}}'
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
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$temp*" } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    Remove-Item -Recurse -Force -LiteralPath $temp -ErrorAction SilentlyContinue
}

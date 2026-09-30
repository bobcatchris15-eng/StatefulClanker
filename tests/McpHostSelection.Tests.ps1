<# Real Windows PowerShell MCP host selection and isolated child compilation. #>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$legacy = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$core = (Get-Process -Id $PID).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ('mcp-host-' + [guid]::NewGuid().ToString('N'))
$oldLocal = $env:LOCALAPPDATA
$oldRouter = $env:SC_ROUTER_ROOT
New-Item -ItemType Directory -Path $temp | Out-Null
function Assert-True($Condition, $Message) { if (-not $Condition) { throw "MCP HOST FAILED: $Message" } }
try {
    $probe = Join-Path $temp 'probe.ps1'
    @'
param($Repo, $Mode, $Fixture)
$ErrorActionPreference = 'Stop'
. (Join-Path $Repo 'mcp/StatefulClanker.McpCore.ps1')
if ($Mode -eq 'missing') {
    function Get-Command { return $null }
} elseif ($Mode -eq 'unsupported') {
    function Get-Command { [pscustomobject]@{ Source = $Fixture } }
} elseif ($Mode -eq 'self') {
    function Get-Command { throw 'Supported current host should not resolve another executable.' }
}
if ($Mode -eq 'missing' -or $Mode -eq 'unsupported') {
    try { $selected = Get-McpPwshPath; throw "Accepted unsupported host: $selected" }
    catch { if ($_.Exception.Message -notmatch 'PowerShell 7.*Install.*PATH') { throw }; Write-Output "PASS: $Mode rejected" }
} else {
    $selected = Get-McpPwshPath
    $version = & $selected -NoProfile -Command '$PSVersionTable.PSVersion.Major'
    if ([int]$version -lt 7) { throw "Selected unsupported child version $version from $selected" }
    if ($Mode -eq 'self' -and $selected -ne (Get-Process -Id $PID).Path) { throw 'Did not reuse supported current host.' }
    if ($Mode -eq 'legacy') {
        function Get-Command { throw 'Validated executable should be cached.' }
        if ((Get-McpPwshPath) -ne $selected) { throw 'Cached selection changed.' }
    }
    Write-Output "PASS: $Mode child version $version"
}
'@ | Set-Content $probe
    foreach ($case in @(@($legacy,'legacy'), @($core,'self'), @($legacy,'missing'), @($legacy,'unsupported'))) {
        $fixture = Join-Path $temp 'old-pwsh.cmd'
        '@echo 6' | Set-Content $fixture
        $output = & $case[0] -NoProfile -File $probe $repo $case[1] $fixture 2>&1
        Assert-True ($LASTEXITCODE -eq 0) ($output -join "`n")
        Write-Host ($output -join "`n")
    }

    # A real 5.1 stdio server must launch the CLI and detached worker on Core 7.
    $project = Join-Path $temp 'project'
    New-Item -ItemType Directory $project | Out-Null
    'HOST-SELECTION-RETRIEVAL-MARKER' | Set-Content (Join-Path $project 'evidence.txt')
    $env:SC_ROUTER_ROOT = Join-Path $temp 'router'
    $env:LOCALAPPDATA = Join-Path $temp 'local'
    function Call-LegacyMcp($Tool, $Arguments) {
        $request = @{ jsonrpc='2.0'; id=1; method='tools/call'; params=@{name=$Tool; arguments=$Arguments}} | ConvertTo-Json -Depth 12 -Compress
        $raw = $request | & $legacy -NoProfile -File (Join-Path $repo 'mcp/StatefulClanker.Mcp.ps1') -ProjectPath $project
        Assert-True ($LASTEXITCODE -eq 0) "5.1 stdio server failed: $raw"
        $response = ($raw -join "`n") | ConvertFrom-Json
        Assert-True (-not $response.error) "Protocol error: $raw"
        Assert-True (-not $response.result.isError) "Tool error: $raw"
        return ($response.result.content[0].text | ConvertFrom-Json)
    }
    Call-LegacyMcp 'project_init' @{} | Out-Null
    Call-LegacyMcp 'provider_set' @{name='mock'; command='cmd.exe'; args=@('/d','/c',(Join-Path $PSScriptRoot 'MockProvider.cmd'),'{promptFile}')} | Out-Null
    Call-LegacyMcp 'task_add' @{taskId='host-test'; title='Host test'; instruction='Return a bounded result'; accept=@('Result returned'); retrieval=@('evidence.txt')} | Out-Null
    Call-LegacyMcp 'run_start' @{taskId='host-test'; provider='mock'} | Out-Null
    $deadline = (Get-Date).AddSeconds(90)
    do {
        Start-Sleep -Milliseconds 500
        $status = Call-LegacyMcp 'run_status' @{}
    } while ($status.inFlight -and (Get-Date) -lt $deadline)
    Assert-True (-not $status.inFlight) 'Detached compatibility worker did not finish.'
    $compilations = @(Get-ChildItem (Join-Path $project '.statefulclanker/compilations') -Filter '*.json')
    Assert-True ($compilations.Count -gt 0) 'No compilation receipt was produced.'
    $receipts = ($compilations | Get-Content -Raw) -join "`n"
    Assert-True ($receipts -match 'HOST-SELECTION-RETRIEVAL-MARKER') 'Context did not traverse GetRelativePath and retrieve the evidence.'
    $task = Call-LegacyMcp 'task_show' @{taskId='host-test'}
    Assert-True ($task.status -eq 'complete') "Compatibility worker failed: $($task.status)"
    Write-Host 'PASS: real 5.1 MCP -> Core CLI/worker -> context compilation -> completed mock task.'
} finally {
    $env:LOCALAPPDATA = $oldLocal
    $env:SC_ROUTER_ROOT = $oldRouter
    Remove-Item -LiteralPath $temp -Recurse -Force
}

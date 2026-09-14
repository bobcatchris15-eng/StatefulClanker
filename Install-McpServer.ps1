<# Emit MCP client registration for this StatefulClanker checkout.

   Prints the config snippet for a given client, and with -Write will patch the
   client's config file in place (creating a .bak first). Nothing is written
   without -Write.

   Examples:
     .\Install-McpServer.ps1                       # show the generic stdio snippet
     .\Install-McpServer.ps1 -Client claude-code
     .\Install-McpServer.ps1 -Client claude-desktop -ProjectPath C:\work\myproj -Write
     .\Install-McpServer.ps1 -Transport http -Port 7337
#>
[CmdletBinding()]
param(
    [ValidateSet('generic', 'claude-code', 'claude-desktop', 'opencode', 'vscode', 'antigravity', 'cursor')]
    [string]$Client = 'generic',
    [ValidateSet('stdio', 'http')]
    [string]$Transport = 'stdio',
    [string]$ProjectPath,
    [int]$Port = 7337,
    [switch]$Write
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repo = $PSScriptRoot
$stdioServer = Join-Path $repo 'mcp\StatefulClanker.Mcp.ps1'
$httpServer = Join-Path $repo 'mcp\StatefulClanker.McpHttp.ps1'

foreach ($required in @($stdioServer, $httpServer)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing $required. Run this from a full checkout." }
}

$pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue)
if ($pwshPath) { $pwshPath = $pwshPath.Source } else { $pwshPath = 'powershell' }

if ([string]::IsNullOrWhiteSpace($ProjectPath)) { $ProjectPath = (Get-Location).Path }
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path

if ($Transport -eq 'http') {
    Write-Host ''
    Write-Host 'HTTP transport is started manually, not launched by the client:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  pwsh -NoProfile -File `"$httpServer`" -ProjectPath `"$ProjectPath`" -Port $Port"
    Write-Host ''
    Write-Host 'It prints a bearer token on startup and writes it to'
    Write-Host "  $(Join-Path $env:LOCALAPPDATA 'StatefulClanker\mcp-http.json')"
    Write-Host ''
    Write-Host "Endpoint: http://127.0.0.1:$Port/mcp"
    Write-Host 'Header:   Authorization: Bearer <token>'
    Write-Host ''
    Write-Host 'Note: the listener binds to loopback only. A connector that is fetched by a' -ForegroundColor Yellow
    Write-Host 'remote/server-side backend cannot reach 127.0.0.1 on your machine; that needs' -ForegroundColor Yellow
    Write-Host 'a client that fetches locally, or a tunnel you set up yourself.' -ForegroundColor Yellow
    return
}

$serverEntry = [ordered]@{
    command = $pwshPath
    args    = @('-NoProfile', '-NonInteractive', '-File', $stdioServer, '-ProjectPath', $ProjectPath)
}

function Show-Snippet($Object, [string]$Label) {
    Write-Host ''
    Write-Host $Label -ForegroundColor Cyan
    Write-Host ''
    ($Object | ConvertTo-Json -Depth 10)
    Write-Host ''
}

switch ($Client) {
    'claude-code' {
        Write-Host ''
        Write-Host 'Register with Claude Code:' -ForegroundColor Cyan
        Write-Host ''
        Write-Host "  claude mcp add statefulclanker --scope user -- `"$pwshPath`" -NoProfile -NonInteractive -File `"$stdioServer`" -ProjectPath `"$ProjectPath`""
        Write-Host ''
        return
    }
    'opencode' {
        Show-Snippet ([ordered]@{ mcp = [ordered]@{ statefulclanker = [ordered]@{
            type    = 'local'
            command = @($pwshPath) + $serverEntry.args
            enabled = $true
        } } }) 'Add to opencode.json:'
        return
    }
    'vscode' {
        Show-Snippet ([ordered]@{ servers = [ordered]@{ statefulclanker = $serverEntry } }) 'Add to .vscode/mcp.json:'
        return
    }
    'cursor' {
        Show-Snippet ([ordered]@{ mcpServers = [ordered]@{ statefulclanker = $serverEntry } }) 'Add to ~/.cursor/mcp.json (or .cursor/mcp.json in a project):'
        return
    }
    'antigravity' {
        Show-Snippet ([ordered]@{ mcpServers = [ordered]@{ statefulclanker = $serverEntry } }) 'Antigravity / other mcpServers-style clients:'
        Write-Host 'NOTE: the exact config file location for this client is not verified here.' -ForegroundColor Yellow
        Write-Host 'Look for an "MCP servers" setting in the app and paste the block above.' -ForegroundColor Yellow
        Write-Host 'Most desktop harnesses use this same mcpServers shape.' -ForegroundColor Yellow
        Write-Host ''
        return
    }
}

$config = [ordered]@{ mcpServers = [ordered]@{ statefulclanker = $serverEntry } }

if ($Client -eq 'claude-desktop') {
    $target = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
    Show-Snippet $config "Claude Desktop config ($target):"
    if (-not $Write) {
        Write-Host 'Re-run with -Write to patch that file in place (a .bak is kept).' -ForegroundColor Yellow
        return
    }
    $dir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $existing = [ordered]@{}
    if (Test-Path -LiteralPath $target) {
        Copy-Item -LiteralPath $target -Destination "$target.bak" -Force
        Write-Host "Backed up existing config to $target.bak"
        $raw = Get-Content -Raw -LiteralPath $target
        if (-not [string]::IsNullOrWhiteSpace($raw)) { $existing = $raw | ConvertFrom-Json -AsHashtable }
    }
    if (-not $existing.ContainsKey('mcpServers') -or $null -eq $existing['mcpServers']) { $existing['mcpServers'] = @{} }
    $existing['mcpServers']['statefulclanker'] = $serverEntry
    ($existing | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $target -Encoding UTF8
    Write-Host "Wrote $target" -ForegroundColor Green
    Write-Host 'Restart Claude Desktop to pick it up.'
    return
}

Show-Snippet $config 'Generic MCP stdio server entry:'
Write-Host 'Every tool also accepts a "project" argument, so one registration can drive'
Write-Host 'many projects; -ProjectPath only sets the default.'

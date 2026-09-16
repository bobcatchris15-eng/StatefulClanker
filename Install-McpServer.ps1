<# Emit MCP client registration for this StatefulClanker install.

   The normal Windows-first registration does NOT pin a project. While the desktop
   app is running, the stdio bridge forwards into its resident MCP host and follows
   whichever project is active in the app. -ProjectPath remains available for
   headless/legacy use when an explicit fixed default is desired.
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
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing $required. Run this from a full install/checkout." }
}

$pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue)
if ($pwshPath) { $pwshPath = $pwshPath.Source } else { $pwshPath = 'powershell' }

$resolvedProject = $null
if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
    $resolvedProject = (Resolve-Path -LiteralPath $ProjectPath).Path
}

if ($Transport -eq 'http') {
    Write-Host ''
    Write-Host 'Resident Streamable HTTP transport:' -ForegroundColor Cyan
    Write-Host ''
    if($resolvedProject) {
        Write-Host "  pwsh -NoProfile -File `"$httpServer`" -ProjectPath `"$resolvedProject`" -Port $Port"
        Write-Host 'This pins a default project for headless use.'
    } else {
        Write-Host "  pwsh -NoProfile -File `"$httpServer`" -Port $Port"
        Write-Host 'With the Windows app running, project selection follows its active project.'
    }
    Write-Host ''
    Write-Host "Connection details: $(Join-Path $env:LOCALAPPDATA 'StatefulClanker\mcp-http.json')"
    Write-Host "Endpoint: http://127.0.0.1:$Port/mcp"
    Write-Host 'Header:   Authorization: Bearer <token>'
    Write-Host ''
    Write-Host 'The listener is loopback-only. Remote/server-side connectors cannot reach it' -ForegroundColor Yellow
    Write-Host 'unless you deliberately provide a tunnel.' -ForegroundColor Yellow
    return
}

$stdioArgs = @('-NoProfile', '-NonInteractive', '-File', $stdioServer)
if($resolvedProject){$stdioArgs += @('-ProjectPath',$resolvedProject)}
$serverEntry = [ordered]@{ command = $pwshPath; args = $stdioArgs }

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
        $tail=($stdioArgs|ForEach-Object{"`"$_`""}) -join ' '
        Write-Host "  claude mcp add statefulclanker --scope user -- `"$pwshPath`" $tail"
        Write-Host ''
        if(-not$resolvedProject){Write-Host 'This registration follows the active project selected in the StatefulClanker app.'}
        return
    }
    'opencode' {
        Show-Snippet ([ordered]@{ mcp = [ordered]@{ statefulclanker = [ordered]@{
            type='local'; command=@($pwshPath)+$stdioArgs; enabled=$true
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
        Write-Host 'Use the app integration surface or the client MCP settings to paste the block.' -ForegroundColor Yellow
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
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            if($PSVersionTable.PSVersion.Major-ge 7){$existing = $raw | ConvertFrom-Json -AsHashtable}
            else {
                $obj=$raw|ConvertFrom-Json;$existing=[ordered]@{};foreach($p in $obj.PSObject.Properties){$existing[$p.Name]=$p.Value}
            }
        }
    }
    if (-not $existing.Contains('mcpServers') -or $null -eq $existing['mcpServers']) { $existing['mcpServers'] = @{} }
    $existing['mcpServers']['statefulclanker'] = $serverEntry
    ($existing | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $target -Encoding UTF8
    Write-Host "Wrote $target" -ForegroundColor Green
    Write-Host 'Restart Claude Desktop to pick it up.'
    return
}

Show-Snippet $config 'Generic MCP stdio server entry:'
if($resolvedProject){
    Write-Host "This registration pins the default project to: $resolvedProject"
} else {
    Write-Host 'When the StatefulClanker app is running, this stdio bridge follows its active project.'
    Write-Host 'Every tool can still pass an explicit "project" argument when needed.'
}

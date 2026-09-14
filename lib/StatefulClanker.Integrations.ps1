<# Integration catalogue: which MCP client apps StatefulClanker can register itself
   with, and which local agent CLIs it can dispatch work to.

   One source of truth, consumed by Install-McpServer.ps1, the tray app, and the
   MCP tools. Everything here is data plus small pure helpers; no UI. #>

function Get-SCPwshPath {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command powershell -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return 'pwsh'
}

function Get-SCInstallRoot {
    # lib/ lives directly under the install root.
    return (Split-Path -Parent $PSScriptRoot)
}

<# MCP client applications.

   configFormat:
     mcpServers  - { "mcpServers": { "<name>": { command, args } } }   (most apps)
     servers     - { "servers":    { "<name>": { command, args } } }   (VS Code)
     opencode    - { "mcp": { "<name>": { type:'local', command:[...] } } }
     command     - not a JSON file; the app is registered via its own CLI

   `verified` marks whether the config path has been confirmed. Unverified entries
   still emit a correct snippet, but the UI must say the location is a best guess
   rather than silently write to a path that may be wrong. #>
function Get-SCIntegrationTargets {
    @(
        [ordered]@{
            id = 'claude-desktop'; name = 'Claude Desktop'; configFormat = 'mcpServers'; verified = $true
            path = (Join-Path $env:APPDATA 'Claude\claude_desktop_config.json')
            detect = @((Join-Path $env:APPDATA 'Claude'), (Join-Path $env:LOCALAPPDATA 'AnthropicClaude'))
            note = 'Restart Claude Desktop after registering.'
        },
        [ordered]@{
            id = 'claude-code'; name = 'Claude Code (CLI)'; configFormat = 'command'; verified = $true
            path = $null
            detect = @()
            detectCommand = 'claude'
            note = 'Registered with: claude mcp add'
        },
        [ordered]@{
            id = 'vscode'; name = 'VS Code'; configFormat = 'servers'; verified = $true
            path = (Join-Path $env:APPDATA 'Code\User\mcp.json')
            detect = @((Join-Path $env:APPDATA 'Code'))
            note = 'Also works per-project as .vscode/mcp.json.'
        },
        [ordered]@{
            id = 'cursor'; name = 'Cursor'; configFormat = 'mcpServers'; verified = $true
            path = (Join-Path $env:USERPROFILE '.cursor\mcp.json')
            detect = @((Join-Path $env:USERPROFILE '.cursor'), (Join-Path $env:LOCALAPPDATA 'Programs\cursor'))
            note = 'Restart Cursor after registering.'
        },
        [ordered]@{
            id = 'windsurf'; name = 'Windsurf'; configFormat = 'mcpServers'; verified = $false
            path = (Join-Path $env:USERPROFILE '.codeium\windsurf\mcp_config.json')
            detect = @((Join-Path $env:USERPROFILE '.codeium\windsurf'))
            note = 'Config path not verified here; confirm in the app settings.'
        },
        [ordered]@{
            id = 'opencode'; name = 'Opencode'; configFormat = 'opencode'; verified = $false
            path = (Join-Path $env:USERPROFILE '.config\opencode\opencode.json')
            detect = @((Join-Path $env:USERPROFILE '.config\opencode'))
            detectCommand = 'opencode'
            note = 'Also accepts a project-local opencode.json.'
        },
        [ordered]@{
            id = 'antigravity'; name = 'Antigravity'; configFormat = 'mcpServers'; verified = $false
            path = (Join-Path $env:USERPROFILE '.antigravity\mcp.json')
            detect = @((Join-Path $env:USERPROFILE '.antigravity'), (Join-Path $env:USERPROFILE '.config\antigravity'))
            detectCommand = 'agy'
            note = 'Config path NOT verified. Check the app MCP settings and paste the snippet if it differs.'
        },
        [ordered]@{
            id = 'generic'; name = 'Other (copy snippet)'; configFormat = 'mcpServers'; verified = $true
            path = $null
            detect = @()
            note = 'Copy the JSON and paste it into the app MCP settings.'
        }
    )
}

function Test-SCIntegrationInstalled($Target) {
    foreach ($p in @($Target.detect)) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $true }
    }
    if ($Target.Contains('detectCommand') -and $Target.detectCommand) {
        if (Get-Command $Target.detectCommand -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function New-SCServerEntry([string]$ProjectPath, [string]$InstallRoot) {
    if (-not $InstallRoot) { $InstallRoot = Get-SCInstallRoot }
    $server = Join-Path $InstallRoot 'mcp\StatefulClanker.Mcp.ps1'
    $serverArgs = @('-NoProfile', '-NonInteractive', '-File', $server)
    if ($ProjectPath) { $serverArgs += @('-ProjectPath', $ProjectPath) }
    return [ordered]@{ command = (Get-SCPwshPath); args = $serverArgs }
}

function New-SCIntegrationSnippet($Target, [string]$ProjectPath, [string]$InstallRoot, [string]$ServerName = 'statefulclanker') {
    $entry = New-SCServerEntry $ProjectPath $InstallRoot
    switch ($Target.configFormat) {
        'servers' { return [ordered]@{ servers = [ordered]@{ $ServerName = $entry } } }
        'opencode' {
            return [ordered]@{ mcp = [ordered]@{ $ServerName = [ordered]@{
                type = 'local'; command = (@($entry.command) + $entry.args); enabled = $true } } }
        }
        'command' {
            $quoted = (@($entry.command) + $entry.args | ForEach-Object { if ($_ -match '[ \t]') { '"' + $_ + '"' } else { $_ } }) -join ' '
            return "claude mcp add $ServerName --scope user -- $quoted"
        }
        default { return [ordered]@{ mcpServers = [ordered]@{ $ServerName = $entry } } }
    }
}

function Test-SCIntegrationRegistered($Target, [string]$ServerName = 'statefulclanker') {
    if ($Target.configFormat -eq 'command') {
        if (-not (Get-Command 'claude' -ErrorAction SilentlyContinue)) { return $false }
        try {
            $listed = & claude mcp list 2>$null | Out-String
            return ($listed -match [regex]::Escape($ServerName))
        } catch { return $false }
    }
    if (-not $Target.path -or -not (Test-Path -LiteralPath $Target.path)) { return $false }
    try {
        $raw = Get-Content -Raw -LiteralPath $Target.path
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $cfg = $raw | ConvertFrom-Json
        $root = switch ($Target.configFormat) { 'servers' { 'servers' } 'opencode' { 'mcp' } default { 'mcpServers' } }
        if (-not $cfg.PSObject.Properties[$root] -or $null -eq $cfg.$root) { return $false }
        return [bool]$cfg.$root.PSObject.Properties[$ServerName]
    } catch { return $false }
}

<# Merge the server entry into the app's config, preserving everything else and
   keeping a timestamped backup. Never rewrites a file it could not parse. #>
function Register-SCIntegration($Target, [string]$ProjectPath, [string]$InstallRoot, [string]$ServerName = 'statefulclanker') {
    if ($Target.configFormat -eq 'command') {
        if (-not (Get-Command 'claude' -ErrorAction SilentlyContinue)) { throw 'The claude CLI is not on PATH.' }
        $entry = New-SCServerEntry $ProjectPath $InstallRoot
        $cliArgs = @('mcp', 'add', $ServerName, '--scope', 'user', '--') + @($entry.command) + $entry.args
        & claude @cliArgs 2>&1 | Out-String | Write-Verbose
        if ($LASTEXITCODE -ne 0) { throw "claude mcp add exited $LASTEXITCODE" }
        return [ordered]@{ target = $Target.id; method = 'claude mcp add'; backup = $null }
    }
    if (-not $Target.path) { throw "$($Target.name) has no config file to write; copy the snippet instead." }

    $dir = Split-Path -Parent $Target.path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $existing = $null
    $backup = $null
    if (Test-Path -LiteralPath $Target.path) {
        $raw = Get-Content -Raw -LiteralPath $Target.path
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try {
                $existing = $raw | ConvertFrom-Json -AsHashtable
            } catch {
                throw "$($Target.path) is not valid JSON. Fix or move it first; refusing to overwrite a file that cannot be parsed."
            }
        }
        $backup = "$($Target.path).$((Get-Date).ToString('yyyyMMddHHmmss')).bak"
        Copy-Item -LiteralPath $Target.path -Destination $backup -Force
    }
    if ($null -eq $existing) { $existing = @{} }

    $entry = New-SCServerEntry $ProjectPath $InstallRoot
    $root = switch ($Target.configFormat) { 'servers' { 'servers' } 'opencode' { 'mcp' } default { 'mcpServers' } }
    if (-not $existing.ContainsKey($root) -or $null -eq $existing[$root]) { $existing[$root] = @{} }

    if ($Target.configFormat -eq 'opencode') {
        $existing[$root][$ServerName] = @{ type = 'local'; command = (@($entry.command) + $entry.args); enabled = $true }
    } else {
        $existing[$root][$ServerName] = @{ command = $entry.command; args = $entry.args }
    }

    ($existing | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $Target.path -Encoding UTF8
    return [ordered]@{ target = $Target.id; method = $Target.path; backup = $backup }
}

function Unregister-SCIntegration($Target, [string]$ServerName = 'statefulclanker') {
    if ($Target.configFormat -eq 'command') {
        if (-not (Get-Command 'claude' -ErrorAction SilentlyContinue)) { throw 'The claude CLI is not on PATH.' }
        & claude mcp remove $ServerName --scope user 2>&1 | Out-String | Write-Verbose
        return $true
    }
    if (-not $Target.path -or -not (Test-Path -LiteralPath $Target.path)) { return $false }
    $raw = Get-Content -Raw -LiteralPath $Target.path
    if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
    $cfg = $raw | ConvertFrom-Json -AsHashtable
    $root = switch ($Target.configFormat) { 'servers' { 'servers' } 'opencode' { 'mcp' } default { 'mcpServers' } }
    if (-not $cfg.ContainsKey($root) -or -not $cfg[$root].ContainsKey($ServerName)) { return $false }
    Copy-Item -LiteralPath $Target.path -Destination "$($Target.path).$((Get-Date).ToString('yyyyMMddHHmmss')).bak" -Force
    [void]$cfg[$root].Remove($ServerName)
    ($cfg | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $Target.path -Encoding UTF8
    return $true
}

<# Local agent CLIs that can act as workers.

   `verified` means the exact invocation was confirmed against the real CLI on a
   machine. UNVERIFIED presets are starting points, not contracts - the shipped
   example config's agy entry was wrong, which is exactly the failure this flag
   exists to advertise. The UI must route every preset through provider_test
   before anyone relies on it. #>
function Get-SCProviderPresets {
    @(
        [ordered]@{ id = 'claude'; name = 'Claude Code'; command = 'claude'
            args = @('-p', '{prompt}'); mode = 'inline'; verified = $true
            note = 'Must be signed in. Add --permission-mode acceptEdits to let it write files.' },
        [ordered]@{ id = 'agy'; name = 'Antigravity (agy)'; command = 'agy'
            args = @('--mode', 'accept-edits', '-p', '{prompt}'); mode = 'inline'; verified = $true
            note = 'Verified working. accept-edits lets it write files without prompting.' },
        [ordered]@{ id = 'opencode'; name = 'Opencode'; command = 'opencode'
            args = @('run', '{prompt}'); mode = 'inline'; verified = $false
            note = 'UNVERIFIED. The repo example used "run --format json {promptFile}"; check opencode --help.' },
        [ordered]@{ id = 'aider'; name = 'Aider'; command = 'aider'
            args = @('--message', '{prompt}', '--yes'); mode = 'inline'; verified = $false
            note = 'UNVERIFIED. --yes auto-confirms edits. Check aider --help.' },
        [ordered]@{ id = 'goose'; name = 'Goose'; command = 'goose'
            args = @('run', '-t', '{prompt}'); mode = 'inline'; verified = $false
            note = 'UNVERIFIED. Check goose run --help.' },
        [ordered]@{ id = 'openhands'; name = 'OpenHands'; command = 'openhands'
            args = @('-t', '{prompt}'); mode = 'inline'; verified = $false
            note = 'UNVERIFIED. OpenHands CLI flags vary by version; check openhands --help.' },
        [ordered]@{ id = 'pi'; name = 'Pi'; command = 'pi'
            args = @('-p', '{prompt}'); mode = 'inline'; verified = $false
            note = 'UNVERIFIED. Confirm the non-interactive flag with pi --help.' },
        [ordered]@{ id = 'codex'; name = 'Codex CLI'; command = 'codex'
            args = @('exec', '{prompt}'); mode = 'inline'; verified = $false
            note = 'UNVERIFIED. Check codex exec --help.' },
        [ordered]@{ id = 'gemini'; name = 'Gemini CLI'; command = 'gemini'
            args = @('-p', '{prompt}'); mode = 'inline'; verified = $false
            note = 'UNVERIFIED. Check gemini --help.' },
        [ordered]@{ id = 'cursor-agent'; name = 'Cursor Agent'; command = 'cursor-agent'
            args = @('-p', '{prompt}'); mode = 'inline'; verified = $false
            note = 'UNVERIFIED. Check cursor-agent --help.' },
        [ordered]@{ id = 'custom'; name = 'Custom command...'; command = ''
            args = @('-p', '{prompt}'); mode = 'inline'; verified = $false
            note = 'Any CLI that accepts a prompt non-interactively. Must include {prompt} or {promptFile}.' }
    )
}

function Test-SCProviderInstalled($Preset) {
    if (-not $Preset.command) { return $false }
    return [bool](Get-Command $Preset.command -ErrorAction SilentlyContinue)
}

<# Integration catalogue: which MCP client apps StatefulClanker can register itself
   with, and which local agent CLIs it can dispatch work to.

   One source of truth, consumed by Install-McpServer.ps1, the tray app, and the
   MCP tools. Everything here is data plus small pure helpers; no UI. #>

function ConvertTo-SCMutableMap($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $h = @{}; foreach ($k in $Value.Keys) { $h[[string]$k] = ConvertTo-SCMutableMap $Value[$k] }; return $h
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $a = @(); foreach ($item in $Value) { $a += ,(ConvertTo-SCMutableMap $item) }; return $a
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}; foreach ($prop in $Value.PSObject.Properties) { $h[$prop.Name] = ConvertTo-SCMutableMap $prop.Value }; return $h
    }
    return $Value
}

function ConvertFrom-SCJsonMap([string]$Json) {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return ($Json | ConvertFrom-Json -AsHashtable) }
    return ConvertTo-SCMutableMap ($Json | ConvertFrom-Json)
}

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
function Get-SCBundledPiCommand {
    $bundled=Join-Path (Get-SCInstallRoot) 'pi\pi.cmd'
    if(Test-Path -LiteralPath $bundled){return $bundled}
    return 'pi'
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
                $existing = ConvertFrom-SCJsonMap $raw
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
    $cfg = ConvertFrom-SCJsonMap $raw
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
   before anyone relies on it.

   Every preset uses mode 'stdin' and carries NO {prompt} in args. A one-shot prompt
   is a compiled context, not a sentence: passing it as a command-line argument fails
   outright once retrieval grows, because cmd.exe caps a command line at 8191
   characters and CreateProcess at 32767. Measured: an 11k-character prompt - a small
   one - already fails with "The command line is too long". stdin has no such limit
   and needs no shell quoting of arbitrary prompt text. #>
function Get-SCProviderPresets {
    @(
        [ordered]@{ id = 'claude'; name = 'Claude Code'; command = 'claude'
            args = @('-p'); mode = 'stdin'; verified = $true
            note = 'Prompt is piped to stdin. Must be signed in. Add --permission-mode acceptEdits to let it write files.' },
        [ordered]@{ id = 'agy'; name = 'Antigravity (agy)'; command = 'agy'
            args = @('--mode', 'accept-edits'); mode = 'stdin'; verified = $true
            note = 'Verified: prompt piped to stdin, and NO -p flag - agy rejects a bare -p ("flag needs an argument"). accept-edits lets it write files without prompting.' },
        [ordered]@{ id = 'opencode'; name = 'Opencode'; command = 'opencode'
            args = @('run'); mode = 'stdin'; verified = $false
            note = 'UNVERIFIED. The repo example used "run --format json {promptFile}"; check opencode --help.' },
        [ordered]@{ id = 'aider'; name = 'Aider'; command = 'aider'
            args = @('--yes'); mode = 'stdin'; verified = $false
            note = 'UNVERIFIED. --yes auto-confirms edits. Check aider --help.' },
        [ordered]@{ id = 'goose'; name = 'Goose'; command = 'goose'
            args = @('run'); mode = 'stdin'; verified = $false
            note = 'UNVERIFIED. Check goose run --help.' },
        [ordered]@{ id = 'openhands'; name = 'OpenHands'; command = 'openhands'
            args = @(); mode = 'stdin'; verified = $false
            note = 'UNVERIFIED. OpenHands CLI flags vary by version; check openhands --help.' },
        [ordered]@{ id = 'pi'; name = 'Pi (bundled)'; command = (Get-SCBundledPiCommand)
            args = @('-p'); mode = 'stdin'; verified = $true
            note = 'Bundled @mariozechner/pi-coding-agent. Print mode consumes stdin. Its machine-local models.json is regenerated from StatefulClanker connections/endpoints before launch; API secrets stay in StatefulClanker DPAPI storage.' },
        [ordered]@{ id = 'codex'; name = 'Codex CLI'; command = 'codex'
            args = @('exec'); mode = 'stdin'; verified = $false
            note = 'UNVERIFIED. Check codex exec --help.' },
        [ordered]@{ id = 'gemini'; name = 'Gemini CLI'; command = 'gemini'
            args = @('-p'); mode = 'stdin'; verified = $false
            note = 'UNVERIFIED. Check gemini --help.' },
        [ordered]@{ id = 'cursor-agent'; name = 'Cursor Agent'; command = 'cursor-agent'
            args = @('-p'); mode = 'stdin'; verified = $false
            note = 'UNVERIFIED. Check cursor-agent --help.' },
        [ordered]@{ id = 'custom'; name = 'Custom command...'; command = ''
            args = @('-p'); mode = 'stdin'; verified = $false
            note = 'Any CLI that accepts a prompt non-interactively. Must include {prompt} or {promptFile}.' }
    )
}

function Test-SCProviderInstalled($Preset) {
    if (-not $Preset.command) { return $false }
    return [bool](Get-Command $Preset.command -ErrorAction SilentlyContinue)
}

<# StatefulClanker tray application.

   Lives in the notification area. Closing the window hides it; Exit from the tray
   menu really exits. Provides:
     - Projects     : pick/create the default project
     - Integrations : register the MCP server with client apps in one click
     - Providers    : configure and TEST the local agent CLIs that do the work
     - Server       : host the loopback HTTP MCP endpoint

   WinForms via PowerShell, matching the existing Cockpit. No build step.

   Layout is Dock-based throughout, never absolute pixels. This machine renders the
   form ~1.5x its nominal size under DPI scaling, which silently pushed absolutely
   positioned buttons underneath a Fill-anchored grid. Docked layout is DPI-safe.
   Docking is processed from the END of the Controls collection backwards, so the
   Fill control must be added FIRST and edge-docked controls after it. #>
param([switch]$ShowWindow)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\StatefulClanker.Integrations.ps1')

$harness = Join-Path $root 'StatefulClanker.ps1'
$httpServer = Join-Path $root 'mcp\StatefulClanker.McpHttp.ps1'
$cockpit = Join-Path $root 'desktop\StatefulClanker.Cockpit.ps1'
$stdioServer = Join-Path $root 'mcp\StatefulClanker.Mcp.ps1'
$appDataDir = Join-Path $env:LOCALAPPDATA 'StatefulClanker'
$settingsPath = Join-Path $appDataDir 'tray.json'
if (-not (Test-Path -LiteralPath $appDataDir)) { New-Item -ItemType Directory -Force -Path $appDataDir | Out-Null }

# ---------------------------------------------------------------- settings ----
function Read-Settings {
    $defaults = [ordered]@{ defaultProject = ''; httpPort = 7337; autoStartHttp = $false }
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $raw = Get-Content -Raw -LiteralPath $settingsPath
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $loaded = $raw | ConvertFrom-Json
                foreach ($k in @($defaults.Keys)) {
                    if ($loaded.PSObject.Properties[$k] -and $null -ne $loaded.$k) { $defaults[$k] = $loaded.$k }
                }
            }
        } catch { }
    }
    return $defaults
}
function Write-Settings($Settings) {
    try { $Settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $settingsPath -Encoding UTF8 } catch { }
}
$script:settings = Read-Settings

function Get-Project { [string]$script:settings.defaultProject }
function Test-ProjectReady {
    $p = Get-Project
    return ($p -and (Test-Path -LiteralPath (Join-Path $p '.statefulclanker\state.json')))
}

# -------------------------------------------------------------------- icon ----
function New-TrayIcon([bool]$Active) {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([Drawing.Color]::Transparent)
    $back = if ($Active) { [Drawing.Color]::FromArgb(56, 142, 60) } else { [Drawing.Color]::FromArgb(69, 90, 100) }
    $brush = New-Object Drawing.SolidBrush $back
    $g.FillEllipse($brush, 1, 1, 30, 30)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::White), 2.5
    $g.DrawLine($pen, 11, 9, 8, 9);  $g.DrawLine($pen, 8, 9, 8, 23);  $g.DrawLine($pen, 8, 23, 11, 23)
    $g.DrawLine($pen, 21, 9, 24, 9); $g.DrawLine($pen, 24, 9, 24, 23); $g.DrawLine($pen, 24, 23, 21, 23)
    $white = New-Object Drawing.SolidBrush ([Drawing.Color]::White)
    $g.FillEllipse($white, 14, 14, 5, 5)
    $white.Dispose(); $pen.Dispose(); $brush.Dispose(); $g.Dispose()
    return [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# --------------------------------------------------------------- http host ----
$script:httpProcess = $null
function Test-HttpRunning { return ($null -ne $script:httpProcess -and -not $script:httpProcess.HasExited) }
function Start-HttpServer {
    if (Test-HttpRunning) { return $true }
    if (-not (Test-ProjectReady)) { throw 'Select an initialized project first (Projects tab).' }
    $psArgs = @('-NoProfile', '-NonInteractive', '-File', $httpServer,
        '-ProjectPath', (Get-Project), '-Port', [string]$script:settings.httpPort)
    $quoted = ($psArgs | ForEach-Object { if ($_ -match '[ \t]') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $script:httpProcess = Start-Process -FilePath (Get-SCPwshPath) -ArgumentList $quoted -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 900
    if ($script:httpProcess.HasExited) {
        $script:httpProcess = $null
        throw "The HTTP server exited immediately. Port $($script:settings.httpPort) may already be in use."
    }
    return $true
}
function Stop-HttpServer {
    if (Test-HttpRunning) { try { $script:httpProcess.Kill() } catch { } }
    $script:httpProcess = $null
}
function Get-HttpDetails {
    $p = Join-Path $appDataDir 'mcp-http.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -Raw -LiteralPath $p | ConvertFrom-Json) } catch { return $null }
}

# ----------------------------------------------------------- layout helpers ----
function New-Header([string]$Text) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $Text; $l.Dock = 'Top'; $l.Height = 30
    $l.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
    $l.Padding = New-Object Windows.Forms.Padding 0, 4, 0, 0
    return $l
}
function New-Note([string]$Text, [int]$Height = 46) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $Text; $l.Dock = 'Top'; $l.Height = $Height
    $l.ForeColor = [Drawing.Color]::DimGray
    return $l
}
function New-ButtonBar {
    $p = New-Object Windows.Forms.FlowLayoutPanel
    $p.Dock = 'Top'; $p.Height = 44; $p.FlowDirection = 'LeftToRight'; $p.WrapContents = $false
    $p.Padding = New-Object Windows.Forms.Padding 0, 6, 0, 0
    return $p
}
function Add-Button($Bar, [string]$Text, [int]$Width = 130) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text; $b.Width = $Width; $b.Height = 30
    $b.Margin = New-Object Windows.Forms.Padding 0, 0, 8, 0
    [void]$Bar.Controls.Add($b)
    return $b
}
function New-Grid {
    $g = New-Object Windows.Forms.DataGridView
    $g.Dock = 'Fill'; $g.ReadOnly = $true; $g.AllowUserToAddRows = $false; $g.AllowUserToResizeRows = $false
    $g.SelectionMode = 'FullRowSelect'; $g.MultiSelect = $false
    $g.AutoSizeColumnsMode = 'Fill'; $g.RowHeadersVisible = $false
    $g.BackgroundColor = [Drawing.Color]::White; $g.BorderStyle = 'FixedSingle'
    return $g
}
function New-Output([int]$Height = 0) {
    $t = New-Object Windows.Forms.TextBox
    $t.Multiline = $true; $t.ReadOnly = $true; $t.ScrollBars = 'Vertical'
    $t.Font = New-Object Drawing.Font('Consolas', 9)
    if ($Height -gt 0) { $t.Dock = 'Bottom'; $t.Height = $Height } else { $t.Dock = 'Fill' }
    return $t
}

# ------------------------------------------------------------------ window ----
$form = New-Object Windows.Forms.Form
$form.Text = 'StatefulClanker'
$form.ClientSize = New-Object Drawing.Size 960, 620
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object Drawing.Size 780, 540
$form.AutoScaleMode = 'Dpi'
try { $form.Icon = New-TrayIcon $false } catch { }

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$form.Controls.Add($tabs)

$status = New-Object Windows.Forms.StatusStrip
$statusLabel = New-Object Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = 'Ready'
[void]$status.Items.Add($statusLabel)
$form.Controls.Add($status)
function Set-Status([string]$Text) { $statusLabel.Text = $Text; $status.Refresh() }

function New-Tab([string]$Text) {
    $t = New-Object Windows.Forms.TabPage
    $t.Text = $Text
    $t.Padding = New-Object Windows.Forms.Padding 14
    $t.BackColor = [Drawing.Color]::White
    [void]$tabs.TabPages.Add($t)
    return $t
}

# ---- Projects ----------------------------------------------------------------
$tabProjects = New-Tab '  Projects  '
$txtProjectStatus = New-Output            # Fill - added first
$tabProjects.Controls.Add($txtProjectStatus)

$projBar = New-ButtonBar
$btnInit = Add-Button $projBar 'Initialize project' 150
$btnCockpit = Add-Button $projBar 'Open Cockpit' 130
$btnRefreshProj = Add-Button $projBar 'Refresh' 100

$projNote = New-Note 'This is your code, not the StatefulClanker install. Durable agent state lives in a .statefulclanker folder inside it. Every MCP tool also accepts a "project" argument, so this is only the default.' 48

$projRow = New-Object Windows.Forms.Panel
$projRow.Dock = 'Top'; $projRow.Height = 32
$btnBrowse = New-Object Windows.Forms.Button
$btnBrowse.Text = 'Browse...'; $btnBrowse.Dock = 'Right'; $btnBrowse.Width = 110
$txtProject = New-Object Windows.Forms.TextBox
$txtProject.Dock = 'Fill'; $txtProject.Text = (Get-Project)
$projRow.Controls.Add($txtProject)
$projRow.Controls.Add($btnBrowse)

$tabProjects.Controls.Add($projBar)
$tabProjects.Controls.Add($projNote)
$tabProjects.Controls.Add($projRow)
$tabProjects.Controls.Add((New-Header 'Default project'))

# ---- Integrations ------------------------------------------------------------
$tabIntegrations = New-Tab '  Integrations  '
$gridInt = New-Grid
$tabIntegrations.Controls.Add($gridInt)

# Connection details for the selected app. Apps that cannot be written to
# automatically still need the exact command or URL to be pasted in by hand, so this
# is always visible rather than hidden behind the Copy button.
$txtConnection = New-Output 150
$txtConnection.Dock = 'Bottom'
$tabIntegrations.Controls.Add($txtConnection)

$lblIntNote = New-Note '' 44
$lblIntNote.Dock = 'Bottom'
$tabIntegrations.Controls.Add($lblIntNote)

$intBar = New-ButtonBar
$intBar.Dock = 'Bottom'
$btnRegister = Add-Button $intBar 'Register' 110
$btnUnregister = Add-Button $intBar 'Remove' 100
$btnCopySnippet = Add-Button $intBar 'Copy config' 120
$btnCopyUrlInt = Add-Button $intBar 'Copy URL + token' 150
$btnRefreshInt = Add-Button $intBar 'Refresh' 90
$tabIntegrations.Controls.Add($intBar)

$tabIntegrations.Controls.Add((New-Header 'Add the StatefulClanker MCP server to a chat app'))

# ---- Providers ---------------------------------------------------------------
$tabProviders = New-Tab '  Providers  '
$gridProv = New-Grid
$tabProviders.Controls.Add($gridProv)

$txtProvOut = New-Output 150
$tabProviders.Controls.Add($txtProvOut)

$provBar = New-ButtonBar
$provBar.Dock = 'Bottom'
$btnSaveProv = Add-Button $provBar 'Save provider' 130
$btnTestProv = Add-Button $provBar 'Test provider' 130
$chkDefault = New-Object Windows.Forms.CheckBox
$chkDefault.Text = 'Worker'; $chkDefault.Width = 80; $chkDefault.Checked = $true; $chkDefault.Margin = New-Object Windows.Forms.Padding 12, 6, 4, 0
[void]$provBar.Controls.Add($chkDefault)
$chkCritic = New-Object Windows.Forms.CheckBox
$chkCritic.Text = 'Critic'; $chkCritic.Width = 70; $chkCritic.Checked = $true; $chkCritic.Margin = New-Object Windows.Forms.Padding 0, 6, 4, 0
[void]$provBar.Controls.Add($chkCritic)
$chkValidator = New-Object Windows.Forms.CheckBox
$chkValidator.Text = 'Validator'; $chkValidator.Width = 90; $chkValidator.Checked = $true; $chkValidator.Margin = New-Object Windows.Forms.Padding 0, 6, 0, 0
[void]$provBar.Controls.Add($chkValidator)
$tabProviders.Controls.Add($provBar)

$argsRow = New-Object Windows.Forms.Panel
$argsRow.Dock = 'Bottom'; $argsRow.Height = 50; $argsRow.Padding = New-Object Windows.Forms.Padding 0, 4, 0, 0
$txtArgs = New-Object Windows.Forms.TextBox
$txtArgs.Dock = 'Top'
$lblArgsHelp = New-Object Windows.Forms.Label
$lblArgsHelp.Dock = 'Top'; $lblArgsHelp.Height = 20; $lblArgsHelp.ForeColor = [Drawing.Color]::DimGray
$lblArgsHelp.Text = 'Arguments - flags only, space separated. The prompt is piped to the provider on stdin. Use {promptFile} only if the CLI wants a path.'
$lblArgs = New-Object Windows.Forms.Label
$lblArgs.Dock = 'Top'; $lblArgs.Height = 18; $lblArgs.Text = 'Arguments'
$argsRow.Controls.Add($lblArgsHelp)
$argsRow.Controls.Add($txtArgs)
$argsRow.Controls.Add($lblArgs)
$tabProviders.Controls.Add($argsRow)

$cmdRow = New-Object Windows.Forms.Panel
$cmdRow.Dock = 'Bottom'; $cmdRow.Height = 44; $cmdRow.Padding = New-Object Windows.Forms.Padding 0, 4, 0, 0
$txtCmd = New-Object Windows.Forms.TextBox
$txtCmd.Dock = 'Top'
$lblCmd = New-Object Windows.Forms.Label
$lblCmd.Dock = 'Top'; $lblCmd.Height = 18; $lblCmd.Text = 'Command'
$cmdRow.Controls.Add($txtCmd)
$cmdRow.Controls.Add($lblCmd)
$tabProviders.Controls.Add($cmdRow)

$tabProviders.Controls.Add((New-Header 'Local agent CLIs that do the actual work'))

# ---- Server ------------------------------------------------------------------
$tabServer = New-Tab '  Server  '
$txtSrvOut = New-Output
$tabServer.Controls.Add($txtSrvOut)

$srvBar2 = New-ButtonBar
$srvBar2.Dock = 'Bottom'
$btnCopyUrl = Add-Button $srvBar2 'Copy URL' 120
$btnCopyToken = Add-Button $srvBar2 'Copy token' 120
$tabServer.Controls.Add($srvBar2)

$srvBar = New-ButtonBar
$lblPort = New-Object Windows.Forms.Label
$lblPort.Text = 'Port'; $lblPort.Width = 36; $lblPort.Margin = New-Object Windows.Forms.Padding 0, 12, 4, 0
[void]$srvBar.Controls.Add($lblPort)
$numPort = New-Object Windows.Forms.NumericUpDown
$numPort.Width = 90; $numPort.Minimum = 1024; $numPort.Maximum = 65535
$numPort.Value = [int]$script:settings.httpPort
$numPort.Margin = New-Object Windows.Forms.Padding 0, 8, 12, 0
[void]$srvBar.Controls.Add($numPort)
$btnHttpToggle = Add-Button $srvBar 'Start server' 130
$chkAutoHttp = New-Object Windows.Forms.CheckBox
$chkAutoHttp.Text = 'Start automatically with the tray app'; $chkAutoHttp.Width = 280
$chkAutoHttp.Checked = [bool]$script:settings.autoStartHttp
$chkAutoHttp.Margin = New-Object Windows.Forms.Padding 8, 12, 0, 0
[void]$srvBar.Controls.Add($chkAutoHttp)

$srvNote = New-Note 'Apps that launch a local command (Claude Desktop, Claude Code, Cursor, VS Code) do NOT need this - use the Integrations tab. This is only for clients that want a URL. It binds to loopback and requires the bearer token.' 50

$tabServer.Controls.Add($srvBar)
$tabServer.Controls.Add($srvNote)
$tabServer.Controls.Add((New-Header 'HTTP MCP endpoint (for apps that take a URL)'))

# ------------------------------------------------------------ refresh logic ----
$script:integrationTargets = @()
function Update-IntegrationsGrid {
    $script:integrationTargets = @(Get-SCIntegrationTargets)
    $table = New-Object Data.DataTable
    foreach ($c in @('App', 'Detected', 'Registered', 'Config location')) { [void]$table.Columns.Add($c) }
    foreach ($t in $script:integrationTargets) {
        $detected = if (Test-SCIntegrationInstalled $t) { 'yes' } else { '-' }
        $registered = if (Test-SCIntegrationRegistered $t) { 'YES' } else { '-' }
        $where = if ($t.path) { $t.path } elseif ($t.configFormat -eq 'command') { 'claude mcp add' } else { 'copy snippet' }
        if (-not $t.verified -and $t.path) { $where = "$where   (unverified path)" }
        [void]$table.Rows.Add($t.name, $detected, $registered, $where)
    }
    $gridInt.DataSource = $table
    if ($gridInt.Columns.Count -ge 4) {
        $gridInt.Columns[0].FillWeight = 24; $gridInt.Columns[1].FillWeight = 12
        $gridInt.Columns[2].FillWeight = 13; $gridInt.Columns[3].FillWeight = 51
    }
}
function Get-SelectedTarget {
    if ($gridInt.SelectedRows.Count -eq 0) { return $null }
    return $script:integrationTargets[$gridInt.SelectedRows[0].Index]
}

$script:providerRows = @()
function Update-ProvidersGrid {
    $configured = @{}
    $defaultName = ''; $criticName = ''; $validatorName = ''
    if (Test-ProjectReady) {
        try {
            $cfg = Get-Content -Raw -LiteralPath (Join-Path (Get-Project) '.statefulclanker\config.json') | ConvertFrom-Json
            if ($cfg.PSObject.Properties['providers'] -and $cfg.providers) {
                foreach ($p in $cfg.providers.PSObject.Properties) { $configured[$p.Name] = $p.Value }
            }
            if ($cfg.PSObject.Properties['defaultProvider']) { $defaultName = [string]$cfg.defaultProvider }
            if ($cfg.PSObject.Properties['criticProvider']) { $criticName = [string]$cfg.criticProvider }
            if ($cfg.PSObject.Properties['validatorProvider']) { $validatorName = [string]$cfg.validatorProvider }
        } catch { }
    }
    $rows = @()
    foreach ($p in @(Get-SCProviderPresets)) {
        if ($p.id -eq 'custom') { continue }
        $rows += [ordered]@{ id = $p.id; name = $p.name; command = $p.command; args = $p.args; verified = $p.verified; note = $p.note }
    }
    foreach ($k in $configured.Keys) {
        if (@($rows | ForEach-Object { $_.id }) -contains $k) { continue }
        $rows += [ordered]@{ id = $k; name = $k; command = [string]$configured[$k].command; args = @($configured[$k].args); verified = $true; note = 'Configured in this project.' }
    }
    $script:providerRows = $rows

    $table = New-Object Data.DataTable
    foreach ($c in @('Provider', 'Command', 'Installed', 'Configured', 'Roles', 'Preset')) { [void]$table.Columns.Add($c) }
    foreach ($r in $rows) {
        $installed = if ($r.command -and (Get-Command $r.command -ErrorAction SilentlyContinue)) { 'yes' } else { '-' }
        $isCfg = if ($configured.ContainsKey($r.id)) { 'YES' } else { '-' }
        $roles = @()
        if ($defaultName -eq $r.id) { $roles += 'worker' }
        if ($criticName -eq $r.id) { $roles += 'critic' }
        if ($validatorName -eq $r.id) { $roles += 'validator' }
        $preset = if ($r.verified) { 'verified' } else { 'UNVERIFIED' }
        [void]$table.Rows.Add($r.name, $r.command, $installed, $isCfg, ($roles -join ','), $preset)
    }
    $gridProv.DataSource = $table
    if ($gridProv.Columns.Count -ge 6) {
        $gridProv.Columns[0].FillWeight = 22; $gridProv.Columns[1].FillWeight = 18
        $gridProv.Columns[2].FillWeight = 12; $gridProv.Columns[3].FillWeight = 13
        $gridProv.Columns[4].FillWeight = 20; $gridProv.Columns[5].FillWeight = 15
    }
}

function Update-ProjectStatus {
    if (-not (Get-Project)) { $txtProjectStatus.Text = 'No project selected. Choose a folder above.'; return }
    if (-not (Test-ProjectReady)) {
        $txtProjectStatus.Text = "Not initialized:`r`n$(Get-Project)`r`n`r`nClick 'Initialize project'."
        return
    }
    try {
        Push-Location -LiteralPath (Get-Project)
        try { $txtProjectStatus.Text = (& (Get-SCPwshPath) -NoProfile -File $harness status 2>&1 | Out-String) }
        finally { Pop-Location }
    } catch { $txtProjectStatus.Text = "Could not read status: $($_.Exception.Message)" }
}

function Update-ServerTab {
    if (Test-HttpRunning) {
        $btnHttpToggle.Text = 'Stop server'
        $d = Get-HttpDetails
        if ($d) {
            $health = ([string]$d.url) -replace '/mcp$', '/health'
            $txtSrvOut.Text = "RUNNING`r`n`r`nEndpoint : $($d.url)`r`nHeader   : Authorization: Bearer $($d.token)`r`nProject  : $($d.project)`r`nPID      : $($d.pid)`r`n`r`nHealth (no auth): $health`r`n`r`nNote: a loopback URL only works for a client that makes the request from THIS machine. A connector fetched by a vendor's own backend cannot reach 127.0.0.1 here."
        } else { $txtSrvOut.Text = 'RUNNING (details file not yet written)' }
    } else {
        $btnHttpToggle.Text = 'Start server'
        $txtSrvOut.Text = "STOPPED`r`n`r`nMost apps do not need this. Use the Integrations tab for anything that launches a local command."
    }
}

function Update-All {
    Update-IntegrationsGrid
    Update-ProvidersGrid
    Update-ProjectStatus
    Update-ServerTab
    if (Get-Command Update-ConnectionDetails -ErrorAction SilentlyContinue) { Update-ConnectionDetails }
}

# ----------------------------------------------------------------- handlers ----
$btnBrowse.Add_Click({
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select the project folder (your code, not the StatefulClanker install)'
    if ($txtProject.Text -and (Test-Path -LiteralPath $txtProject.Text)) { $dlg.SelectedPath = $txtProject.Text }
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtProject.Text = $dlg.SelectedPath
        $script:settings.defaultProject = $dlg.SelectedPath
        Write-Settings $script:settings
        Update-All; Update-TrayState
        Set-Status "Project: $($dlg.SelectedPath)"
    }
})
$txtProject.Add_Leave({
    if ($txtProject.Text -ne (Get-Project)) {
        $script:settings.defaultProject = $txtProject.Text
        Write-Settings $script:settings
        Update-All; Update-TrayState
    }
})
$btnRefreshProj.Add_Click({ Update-All; Set-Status 'Refreshed.' })

$btnInit.Add_Click({
    if (-not $txtProject.Text) { [void][Windows.Forms.MessageBox]::Show('Choose a project folder first.', 'StatefulClanker'); return }
    try {
        Set-Status 'Initializing...'
        Push-Location -LiteralPath $txtProject.Text
        try { $out = & (Get-SCPwshPath) -NoProfile -File $harness init 2>&1 | Out-String } finally { Pop-Location }
        $script:settings.defaultProject = $txtProject.Text
        Write-Settings $script:settings
        Update-All; Update-TrayState
        Set-Status 'Initialized.'
        [void][Windows.Forms.MessageBox]::Show($out.Trim(), 'StatefulClanker')
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Initialize failed') }
})

$btnCockpit.Add_Click({
    if (-not (Test-ProjectReady)) { [void][Windows.Forms.MessageBox]::Show('Initialize the project first.', 'StatefulClanker'); return }
    [void](Start-Process -FilePath (Get-SCPwshPath) -ArgumentList @('-NoProfile', '-File', "`"$cockpit`"", '-ProjectPath', "`"$(Get-Project)`"") -WindowStyle Hidden)
})

<# Show the exact connection details for the selected app. Both transports are
   listed because which one an app wants is not something we can detect: apps that
   launch a local command take the stdio block, apps that want a URL take the HTTP
   block, and several only accept details typed in by hand. #>
function Update-ConnectionDetails {
    $t = Get-SelectedTarget
    if (-not $t) { $txtConnection.Text = ''; return }

    $snippet = New-SCIntegrationSnippet $t (Get-Project) $root
    $lines = @()
    $lines += "=== $($t.name) ==="
    $lines += ''

    if ($snippet -is [string]) {
        $lines += 'Run this command:'
        $lines += $snippet
    } else {
        $lines += 'STDIO (apps that launch a local command). Paste into the app MCP config:'
        $lines += ($snippet | ConvertTo-Json -Depth 10)
    }

    $lines += ''
    $lines += 'HTTP (apps that want a URL):'
    $d = Get-HttpDetails
    if (Test-HttpRunning -and $d) {
        $lines += "  URL    : $($d.url)"
        $lines += "  Header : Authorization: Bearer $($d.token)"
        $lines += "  Health : $((([string]$d.url) -replace '/mcp$','/health'))"
    } else {
        $lines += "  Not running. Start it on the Server tab; it will listen on"
        $lines += "  http://127.0.0.1:$([int]$script:settings.httpPort)/mcp and print a bearer token."
    }
    $lines += ''
    $lines += 'A loopback URL only works for a client that makes the request from THIS'
    $lines += 'machine. A connector fetched by a vendor backend cannot reach 127.0.0.1 here.'

    if (-not (Get-Project)) {
        $lines += ''
        $lines += 'NOTE: no default project selected, so the config omits -ProjectPath.'
        $lines += 'The session can still call project_use to choose one.'
    }
    $txtConnection.Text = ($lines -join "`r`n")
}

$gridInt.Add_SelectionChanged({
    $t = Get-SelectedTarget
    if ($t) {
        $extra = if (-not $t.verified) { "`r`nThis config location is a best guess - confirm it in the app, or copy the config below." } else { '' }
        $lblIntNote.Text = "$($t.note)$extra"
    }
    Update-ConnectionDetails
})

$btnCopyUrlInt.Add_Click({
    $d = Get-HttpDetails
    if ((Test-HttpRunning) -and $d) {
        [Windows.Forms.Clipboard]::SetText("$($d.url)`r`nAuthorization: Bearer $($d.token)")
        Set-Status 'URL and token copied.'
    } else {
        Set-Status 'HTTP server is not running - start it on the Server tab.'
    }
})

$btnRegister.Add_Click({
    $t = Get-SelectedTarget
    if (-not $t) { return }
    if (-not (Get-Project)) { [void][Windows.Forms.MessageBox]::Show('Choose a project first (Projects tab).', 'StatefulClanker'); return }
    if ($t.configFormat -ne 'command' -and -not $t.path) {
        [void][Windows.Forms.MessageBox]::Show('This target has no config file. Use Copy snippet and paste it into the app.', 'StatefulClanker'); return
    }
    if (-not $t.verified) {
        $answer = [Windows.Forms.MessageBox]::Show(
            "The config location for $($t.name) is not verified:`r`n`r`n$($t.path)`r`n`r`nWrite there anyway? An existing file is backed up first.",
            'Unverified location', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }
    try {
        Set-Status "Registering with $($t.name)..."
        $r = Register-SCIntegration $t (Get-Project) $root
        Update-IntegrationsGrid
        $msg = "Registered with $($t.name).`r`n`r`nWritten to: $($r.method)"
        if ($r.backup) { $msg += "`r`nBackup: $($r.backup)" }
        $msg += "`r`n`r`n$($t.note)"
        Set-Status "Registered with $($t.name)."
        [void][Windows.Forms.MessageBox]::Show($msg, 'StatefulClanker')
    } catch {
        Set-Status 'Registration failed.'
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Registration failed')
    }
})

$btnUnregister.Add_Click({
    $t = Get-SelectedTarget
    if (-not $t) { return }
    try {
        $removed = Unregister-SCIntegration $t
        Update-IntegrationsGrid
        Set-Status $(if ($removed) { "Removed from $($t.name)." } else { 'Nothing to remove.' })
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Remove failed') }
})

$btnCopySnippet.Add_Click({
    $t = Get-SelectedTarget
    if (-not $t) { return }
    $snippet = New-SCIntegrationSnippet $t (Get-Project) $root
    $text = if ($snippet -is [string]) { $snippet } else { $snippet | ConvertTo-Json -Depth 10 }
    [Windows.Forms.Clipboard]::SetText($text)
    Set-Status 'Snippet copied to clipboard.'
})
$btnRefreshInt.Add_Click({ Update-All; Set-Status 'Refreshed.' })

$gridProv.Add_SelectionChanged({
    if ($gridProv.SelectedRows.Count -eq 0) { return }
    $r = $script:providerRows[$gridProv.SelectedRows[0].Index]
    $txtCmd.Text = [string]$r.command
    $txtArgs.Text = (@($r.args) -join ' ')
    $warn = if (-not $r.verified) { "UNVERIFIED PRESET - test it before relying on it.`r`n`r`n" } else { '' }
    $txtProvOut.Text = "$warn$($r.note)"
})

$btnSaveProv.Add_Click({
    if (-not (Test-ProjectReady)) { [void][Windows.Forms.MessageBox]::Show('Initialize a project first.', 'StatefulClanker'); return }
    if ($gridProv.SelectedRows.Count -eq 0) { [void][Windows.Forms.MessageBox]::Show('Select a provider row first.', 'StatefulClanker'); return }
    $r = $script:providerRows[$gridProv.SelectedRows[0].Index]
    $cmd = $txtCmd.Text.Trim()
    $argList = @($txtArgs.Text -split '\r?\n|\s+' | Where-Object { $_ })
    if (-not $cmd) { [void][Windows.Forms.MessageBox]::Show('Command is required.', 'StatefulClanker'); return }
    $joinedArgs = ($argList -join ' ')
    if ($joinedArgs -match '\{prompt\}') {
        [void][Windows.Forms.MessageBox]::Show("{prompt} puts the whole compiled context on the command line, which fails once retrieval grows (cmd.exe caps at 8191 characters).`r`n`r`nDrop {prompt} and leave the arguments as flags only - the prompt is piped to the provider on stdin.", 'StatefulClanker'); return
    }
    try {
        $cfgPath = Join-Path (Get-Project) '.statefulclanker\config.json'
        $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
        $mode = if ($joinedArgs -match '\{promptFile\}') { 'prompt-file' } else { 'stdin' }
        if (-not $cfg.PSObject.Properties['providers'] -or $null -eq $cfg.providers) {
            $cfg | Add-Member -NotePropertyName providers -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $cfg.providers | Add-Member -NotePropertyName $r.id -NotePropertyValue ([pscustomobject]@{ command = $cmd; args = $argList; mode = $mode }) -Force
        if ($chkDefault.Checked) { $cfg | Add-Member -NotePropertyName defaultProvider -NotePropertyValue $r.id -Force }
        if ($chkCritic.Checked) { $cfg | Add-Member -NotePropertyName criticProvider -NotePropertyValue $r.id -Force }
        if ($chkValidator.Checked) { $cfg | Add-Member -NotePropertyName validatorProvider -NotePropertyValue $r.id -Force }
        $cfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cfgPath -Encoding UTF8
        Update-ProvidersGrid
        Set-Status "Saved provider '$($r.id)'."
        $txtProvOut.Text = "Saved '$($r.id)'.`r`n`r`nNow click Test provider. Presets can be wrong, and the two failures you will actually hit are quiet: an expired login exits nonzero, and a permission-gated CLI exits ZERO having done nothing at all."
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Save failed') }
})

$btnTestProv.Add_Click({
    if (-not (Test-ProjectReady)) { [void][Windows.Forms.MessageBox]::Show('Initialize a project first.', 'StatefulClanker'); return }
    if ($gridProv.SelectedRows.Count -eq 0) { return }
    $r = $script:providerRows[$gridProv.SelectedRows[0].Index]
    $btnTestProv.Enabled = $false
    Set-Status "Testing $($r.id)... dispatching a real probe prompt"
    $txtProvOut.Text = "Testing '$($r.id)'. This dispatches a real prompt and can take up to 90 seconds..."
    $form.Refresh()
    try {
        $call = @{ jsonrpc = '2.0'; id = 1; method = 'tools/call'; params = @{ name = 'provider_test'; arguments = @{ name = $r.id; timeoutSeconds = 90 } } } | ConvertTo-Json -Depth 10 -Compress
        $out = $call | & (Get-SCPwshPath) -NoProfile -File $stdioServer -ProjectPath (Get-Project) 2>&1
        $line = @($out | Where-Object { $_ })[0]
        $parsed = $line | ConvertFrom-Json
        if ($parsed.result.PSObject.Properties['isError'] -and $parsed.result.isError) {
            $txtProvOut.Text = $parsed.result.content[0].text
            Set-Status 'Test failed.'
        } else {
            $payload = $parsed.result.content[0].text | ConvertFrom-Json
            $verdict = if ($payload.usable) { 'USABLE' } else { 'NOT USABLE' }
            $txtProvOut.Text = "$verdict`r`n`r`n$($payload.diagnosis)`r`n`r`nexit code : $($payload.exitCode)`r`ntimed out : $($payload.timedOut)`r`n`r`n--- stdout ---`r`n$($payload.stdoutHead)`r`n--- stderr ---`r`n$($payload.stderrHead)"
            Set-Status "$($r.id): $verdict"
        }
    } catch {
        $txtProvOut.Text = "Test failed: $($_.Exception.Message)"
        Set-Status 'Test failed.'
    } finally { $btnTestProv.Enabled = $true }
})

$btnHttpToggle.Add_Click({
    try {
        if (Test-HttpRunning) { Stop-HttpServer; Set-Status 'HTTP server stopped.' }
        else {
            $script:settings.httpPort = [int]$numPort.Value
            Write-Settings $script:settings
            [void](Start-HttpServer)
            Set-Status "HTTP server on port $($script:settings.httpPort)."
        }
        Update-ServerTab; Update-TrayState; Update-ConnectionDetails
    } catch {
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'HTTP server')
        Update-ServerTab; Update-TrayState; Update-ConnectionDetails
    }
})
$chkAutoHttp.Add_CheckedChanged({
    $script:settings.autoStartHttp = [bool]$chkAutoHttp.Checked
    Write-Settings $script:settings
})
$btnCopyUrl.Add_Click({
    $d = Get-HttpDetails
    if ($d -and (Test-HttpRunning)) { [Windows.Forms.Clipboard]::SetText([string]$d.url); Set-Status 'URL copied.' }
    else { Set-Status 'Server is not running.' }
})
$btnCopyToken.Add_Click({
    $d = Get-HttpDetails
    if ($d -and (Test-HttpRunning)) { [Windows.Forms.Clipboard]::SetText([string]$d.token); Set-Status 'Token copied.' }
    else { Set-Status 'Server is not running.' }
})

# --------------------------------------------------------------------- tray ----
$notify = New-Object Windows.Forms.NotifyIcon
$notify.Icon = New-TrayIcon $false
$notify.Text = 'StatefulClanker'
$notify.Visible = $true

$menu = New-Object Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Open StatefulClanker')
$miCockpit = $menu.Items.Add('Open Cockpit')
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$miHttp = $menu.Items.Add('Start HTTP server')
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$miExit = $menu.Items.Add('Exit')
$notify.ContextMenuStrip = $menu

function Update-TrayState {
    $running = Test-HttpRunning
    $miHttp.Text = if ($running) { 'Stop HTTP server' } else { 'Start HTTP server' }
    $project = if (Get-Project) { Split-Path -Leaf (Get-Project) } else { 'no project' }
    $httpText = if ($running) { "HTTP :$($script:settings.httpPort)" } else { 'HTTP off' }
    $text = "StatefulClanker - $project - $httpText"
    # NotifyIcon.Text throws above 63 characters.
    if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + '...' }
    $notify.Text = $text
    try { $notify.Icon = New-TrayIcon $running } catch { }
}

function Show-Main {
    $form.Show()
    $form.WindowState = 'Normal'
    [void]$form.Activate()
    Update-All
}

$miOpen.Add_Click({ Show-Main })
$miCockpit.Add_Click({ $btnCockpit.PerformClick() })
$miHttp.Add_Click({ $btnHttpToggle.PerformClick() })
$miExit.Add_Click({
    Stop-HttpServer
    $notify.Visible = $false
    [Windows.Forms.Application]::Exit()
})
$notify.Add_DoubleClick({ Show-Main })

# Closing the window hides it; the tray icon keeps the app alive.
$form.Add_FormClosing({
    param($eventSender, $e)
    if ($e.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        $form.Hide()
        Set-Status 'Ready'
    }
})

# ---------------------------------------------------------------- start-up ----
Update-All
Update-TrayState
$tabs.SelectedIndex = 0

if ([bool]$script:settings.autoStartHttp -and (Test-ProjectReady)) {
    try { [void](Start-HttpServer); Update-ServerTab; Update-TrayState } catch { }
}

if ($ShowWindow -or -not (Test-ProjectReady)) { Show-Main }

[Windows.Forms.Application]::EnableVisualStyles()
[Windows.Forms.Application]::Run((New-Object Windows.Forms.ApplicationContext))

Stop-HttpServer
$notify.Visible = $false
$notify.Dispose()

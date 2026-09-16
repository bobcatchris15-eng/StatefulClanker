<# Integration catalogue tests: config merging, snippet shapes, and the safety
   properties that matter when writing into somebody else's application config. #>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'lib\StatefulClanker.Integrations.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "INTEGRATION TEST FAILED: $Message" }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('sc-int-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
try {
    $proj = Join-Path $temp 'proj'
    New-Item -ItemType Directory -Force -Path $proj | Out-Null

    Write-Host '  INT 1: catalogue is well formed'
    $targets = @(Get-SCIntegrationTargets)
    Assert-True ($targets.Count -ge 6) 'Expected several integration targets.'
    foreach ($t in $targets) {
        foreach ($key in @('id', 'name', 'configFormat', 'verified', 'note')) {
            Assert-True ($t.Contains($key)) "Target $($t.id) is missing '$key'."
        }
        Assert-True (@('mcpServers', 'servers', 'opencode', 'command') -contains $t.configFormat) "Target $($t.id) has an unknown configFormat."
    }
    $presets = @(Get-SCProviderPresets)
    Assert-True ($presets.Count -ge 6) 'Expected several provider presets.'
    foreach ($p in $presets) {
        if ($p.id -eq 'custom') { continue }
        $joinedArgs = (@($p.args) -join ' ')
        Assert-True ($joinedArgs -notmatch '\{prompt\}') "Preset $($p.id) passes {prompt} on the command line."
        Assert-True (@('stdin', 'prompt-file') -contains $p.mode) "Preset $($p.id) has mode '$($p.mode)'."
        if ($p.mode -eq 'prompt-file') { Assert-True ($joinedArgs -match '\{promptFile\}') "Preset $($p.id) is prompt-file mode but has no {promptFile}." }
        Assert-True ([bool]$p.command) "Preset $($p.id) has no command."
    }

    Write-Host '  INT 2: each client format produces its own shape'
    foreach ($case in @(@('claude-desktop', 'mcpServers'), @('vscode', 'servers'), @('opencode', 'mcp'))) {
        $t = $targets | Where-Object { $_.id -eq $case[0] }
        $snippet = New-SCIntegrationSnippet $t $proj $repo
        Assert-True ($snippet.Contains($case[1])) "$($case[0]) should emit a '$($case[1])' root."
        $inner = $snippet[$case[1]]
        Assert-True ($inner.Contains('statefulclanker')) "$($case[0]) should register under the 'statefulclanker' name."
    }
    $codeTarget = $targets | Where-Object { $_.id -eq 'claude-code' }
    $cmdSnippet = New-SCIntegrationSnippet $codeTarget $proj $repo
    Assert-True ($cmdSnippet -is [string] -and $cmdSnippet -like 'claude mcp add*') 'claude-code should emit a CLI command string.'

    Write-Host '  INT 3: registering preserves unrelated config and keeps a backup'
    $cfgPath = Join-Path $temp 'app_config.json'
    '{"mcpServers":{"other":{"command":"node","args":["x.js"]}},"userSetting":{"keep":true}}' | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    $fake = [ordered]@{ id = 'fake'; name = 'Fake App'; configFormat = 'mcpServers'; verified = $true; path = $cfgPath; detect = @(); note = '' }

    Assert-True (-not (Test-SCIntegrationRegistered $fake)) 'Should not report registered before registering.'
    $r = Register-SCIntegration $fake $proj $repo
    Assert-True (Test-SCIntegrationRegistered $fake) 'Should report registered afterwards.'
    Assert-True (Test-Path -LiteralPath $r.backup) 'A backup of the original config should be kept.'

    $after = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    Assert-True ($null -ne $after.mcpServers.'other') 'An unrelated MCP server was destroyed.'
    Assert-True ([bool]$after.userSetting.keep) 'An unrelated user setting was destroyed.'
    Assert-True ([bool]$after.mcpServers.statefulclanker.command) 'Our own entry was not written.'
    Assert-True ((@($after.mcpServers.statefulclanker.args) -join ' ') -match 'StatefulClanker\.Mcp\.ps1') 'Entry does not point at the stdio server.'

    Write-Host '  INT 4: unregistering removes only our entry'
    Assert-True (Unregister-SCIntegration $fake) 'Unregister should report success.'
    $after2 = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    Assert-True ($null -eq $after2.mcpServers.PSObject.Properties['statefulclanker']) 'Our entry should be gone.'
    Assert-True ($null -ne $after2.mcpServers.'other') 'Unregister destroyed an unrelated server.'

    Write-Host '  INT 5: refuses to overwrite a config it cannot parse'
    $broken = '{ not valid json at all'
    $broken | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    $threw = $false
    try { Register-SCIntegration $fake $proj $repo } catch { $threw = $true }
    Assert-True $threw 'Registering into unparseable JSON must throw.'
    Assert-True ((Get-Content -Raw -LiteralPath $cfgPath).Trim() -eq $broken) 'The unparseable file must be left untouched.'

    Write-Host '  INT 6: paths with spaces survive the server entry'
    $spaced = Join-Path $temp 'My Project Folder'
    New-Item -ItemType Directory -Force -Path $spaced | Out-Null
    $entry = New-SCServerEntry $spaced $repo
    Assert-True (@($entry.args) -contains $spaced) 'The project path should be its own argument, not split on spaces.'

    Write-Host 'PASS: integrations (catalogue, per-app shapes, safe merge, safe removal)'
} finally {
    Remove-Item -Recurse -Force -LiteralPath $temp -ErrorAction SilentlyContinue
}

# Keep these at the tail so tests/Smoke.ps1 automatically exercises the new
# authority/event model without duplicating its top-level test runner plumbing.
Write-Host '  INT 7: current directives + durable control inbox'
& (Join-Path $PSScriptRoot 'DirectivesEventing.Tests.ps1')
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "Directive/event tests failed (exit $LASTEXITCODE)." }

Write-Host '  INT 8: modern MCP discovery/resources/control tools'
& (Join-Path $PSScriptRoot 'McpModern.Tests.ps1')
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "Modern MCP tests failed (exit $LASTEXITCODE)." }

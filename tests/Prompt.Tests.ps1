<# Prompt delivery tests.

   A one-shot prompt is a compiled context, not a sentence. Passing it as a
   command-line argument is a latent failure: cmd.exe caps a command line at 8191
   characters and CreateProcess at 32767, and with the shipped retrieval budgets a
   realistic packet passes both. Measured: an 11k-character prompt - a small one -
   fails with "The command line is too long" and exit 1, which reads like a broken
   provider rather than a prompt that did not fit. #>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$harness = Join-Path $repo 'StatefulClanker.ps1'
. (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
. (Join-Path $repo 'lib\StatefulClanker.Execution.ps1')
. (Join-Path $repo 'lib\StatefulClanker.Integrations.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "PROMPT TEST FAILED: $Message" }
}

Write-Host '  PROMPT 1: command-line limits are per-host'
Assert-True ((Get-SCCommandLineLimit 'cmd.exe') -eq 8191) 'cmd.exe must use the 8191 limit.'
Assert-True ((Get-SCCommandLineLimit 'C:\x\run.bat') -eq 8191) '.bat runs through cmd, so 8191.'
Assert-True ((Get-SCCommandLineLimit 'C:\x\run.cmd') -eq 8191) '.cmd runs through cmd, so 8191.'
Assert-True ((Get-SCCommandLineLimit 'claude.exe') -eq 32767) 'A normal exe uses the CreateProcess limit.'

Write-Host '  PROMPT 2: an oversized inline prompt is refused with an actionable message'
$big = 'x' * 12000
$threw = $false
$message = ''
try { Assert-SCPromptFits 'cmd.exe' @('/d', '/c', 'echo', $big) 'inline' 'C:\tmp\p.txt' }
catch { $threw = $true; $message = $_.Exception.Message }
Assert-True $threw 'A 12k inline prompt against cmd.exe must be refused.'
# The message has to teach the fix; the raw OS error does not.
Assert-True ($message -match 'stdin') 'The refusal should point at stdin.'
Assert-True ($message -match 'promptFile') 'The refusal should point at {promptFile}.'
Assert-True ($message -match 'C:\\tmp\\p.txt') 'The refusal should say where the full prompt was written.'

Write-Host '  PROMPT 3: an ordinary prompt is not refused'
$ok = $true
try { Assert-SCPromptFits 'cmd.exe' @('/d', '/c', 'echo', 'a short prompt') 'inline' 'p.txt' } catch { $ok = $false }
Assert-True $ok 'A small inline prompt must still be allowed.'

Write-Host '  PROMPT 4: every shipped preset delivers the prompt out of band'
foreach ($p in @(Get-SCProviderPresets)) {
    $joined = (@($p.args) -join ' ')
    Assert-True ($joined -notmatch '\{prompt\}') "Preset '$($p.id)' still passes {prompt} on the command line."
    Assert-True (@('stdin', 'prompt-file') -contains $p.mode) "Preset '$($p.id)' has mode '$($p.mode)'; expected stdin or prompt-file."
    if ($p.mode -eq 'prompt-file') {
        Assert-True ($joined -match '\{promptFile\}') "Preset '$($p.id)' is prompt-file mode but never references {promptFile}."
    }
}

Write-Host '  PROMPT 5: stdin carries a prompt that the command line could not'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('sc-prompt-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
Push-Location $temp
try {
    $line = 'const value = computeSomethingReasonablyOrdinary(input, options);'
    Set-Content -LiteralPath 'big.txt' -Value (($line + "`n") * 400) -Encoding UTF8
    & $harness init | Out-Null
    $cfgPath = Join-Path $temp '.statefulclanker\config.json'
    $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    $cfg.criticEnabled = $false; $cfg.validatorEnabled = $false
    $cfg.defaultProvider = 'viastdin'
    # more.com simply echoes whatever it is fed, so stdout length proves delivery.
    $cfg.providers | Add-Member -NotePropertyName viastdin -NotePropertyValue ([pscustomobject]@{
            command = 'more.com'; args = @(); mode = 'stdin' }) -Force
    $cfg.providers | Add-Member -NotePropertyName viainline -NotePropertyValue ([pscustomobject]@{
            command = 'cmd.exe'; args = @('/d', '/c', 'echo', '{prompt}'); mode = 'inline' }) -Force
    $cfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cfgPath -Encoding UTF8

    & $harness task add -TaskId big -Title 'Big' -Instruction 'Work on it.' -Accept 'ok' -Retrieval @('big.txt') | Out-Null
    & $harness run -TaskId big 2>&1 | Out-Null

    $promptFile = Get-ChildItem -LiteralPath (Join-Path $temp '.statefulclanker\prompts') -Filter 'run-*.txt' |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $size = (Get-Item -LiteralPath $promptFile.FullName).Length
    Assert-True ($size -gt 8191) "This test needs a prompt over the cmd limit; got $size. Raise the retrieval fixture."

    $run = Get-ChildItem -LiteralPath (Join-Path $temp '.statefulclanker\runs') -Filter 'run-*.json' |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $record = Get-Content -Raw -LiteralPath $run.FullName | ConvertFrom-Json
    Assert-True ($record.exitCode -eq 0) "stdin delivery should succeed, got exit $($record.exitCode): $($record.stderr)"
    Assert-True (([string]$record.stdout).Length -gt 8191) 'The provider did not receive the whole prompt on stdin.'

    Write-Host '  PROMPT 6: the prompt file is always written, whatever the mode'
    Assert-True (Test-Path -LiteralPath $promptFile.FullName) 'The prompt file must always exist for inspection.'

    Write-Host '  PROMPT 7: the same prompt inline is refused before the OS sees it'
    & $harness task retry -TaskId big | Out-Null
    & $harness run -TaskId big -Provider viainline 2>&1 | Out-Null
    $run2 = Get-ChildItem -LiteralPath (Join-Path $temp '.statefulclanker\runs') -Filter 'run-*.json' |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $record2 = Get-Content -Raw -LiteralPath $run2.FullName | ConvertFrom-Json
    Assert-True ($record2.exitCode -ne 0) 'An oversized inline prompt must fail.'
    Assert-True (([string]$record2.stderr) -match 'does not fit') `
        "Expected the harness's own refusal, not the raw OS error. Got: $($record2.stderr)"
} finally {
    Pop-Location
    Set-Location $repo
    Remove-Item -Recurse -Force -LiteralPath $temp -ErrorAction SilentlyContinue
}

Write-Host 'PASS: prompt delivery (limits, refusal, stdin, preset hygiene)'

$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$source=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Tray\EmbeddedTerminalPanel.cs')

function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "EMBEDDED TERMINAL FOCUS TEST FAILED: $Message"}}

Assert-True ($source.Contains('PreviewMouseDown += (_, _) => FocusTerminal()')) 'Explicit terminal click-to-focus behavior is missing.'
Assert-True (-not $source.Contains('_elementHost.Enter += (_, _) => BeginInvoke(new Action(FocusTerminal))')) 'ElementHost Enter must not schedule FocusTerminal; it recurses through the WPF focus bridge.'
Assert-True (-not $source.Contains('_elementHost.GotFocus += (_, _) => BeginInvoke(new Action(FocusTerminal))')) 'ElementHost GotFocus must not schedule FocusTerminal; it recurses through the WPF focus bridge.'

Write-Host 'PASS: terminal focus uses explicit interaction without ElementHost focus-event recursion.'

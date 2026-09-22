$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "OVERVIEW UI TEST FAILED: $Message"}}

$program=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Tray\Program.cs')
$terminal=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Tray\EmbeddedTerminalPanel.cs')
$widgets=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Tray\CockpitWidgets.cs')

$start=$program.IndexOf('    TabPage BuildOverview()')
$end=$program.IndexOf('    Control BuildTargetPoolPanel()',$start)
Assert-True ($start-ge0-and$end-gt$start) 'Could not isolate BuildOverview.'
$overview=$program.Substring($start,$end-$start)

Assert-True ($overview.Contains('BLINKENLIGHTS // ACTIVE WORKER ENDPOINTS')) 'Blinkenlights are not a primary Overview pane.'
Assert-True ($overview.Contains('stars.Panel2.Controls.Add(_terminal)')) 'Embedded TUI is not a primary Overview pane.'
Assert-True ($overview.Contains('_overviewReadout')) 'Compact hardware readout is missing.'
Assert-True (-not$overview.Contains('usageCard')) 'Usage card crept back into Overview.'
Assert-True (-not$overview.Contains('PROJECT AUTHORITY')) 'Large authority card crept back into Overview.'
Assert-True (-not$overview.Contains('AutoScroll = true')) 'Overview reintroduced scroll-bar chrome.'

Assert-True ($program.Contains('SplitterWidth = 2')) 'Quiet splitter widened again.'
Assert-True ($program.Contains('FillRectangle(brush, SplitterRectangle)')) 'Splitter is not explicitly dark-painted.'
Assert-True ($widgets.Contains('NEXT ENDPOINT IN QUEUE')) 'Next endpoint readout is missing.'
Assert-True ($widgets.Contains('RoutingQueueInspector')) 'Next endpoint does not read live machine routing state.'

Assert-True ($terminal.Contains('IsReadOnly = false')) 'Terminal became read-only.'
Assert-True ($terminal.Contains('Win32InputMode = true')) 'Terminal lost Win32 key-record mode.'
Assert-True ($terminal.Contains('INPUT_CAPTURE.TabKey | EasyTerminalControl.INPUT_CAPTURE.DirectionKeys')) 'Terminal lost Tab/arrow capture.'
Assert-True ($terminal.Contains('PreviewMouseDown += (_, _) => FocusTerminal()')) 'Terminal click-to-focus hook is missing.'
Assert-True ($terminal.Contains('ConsoleHasKeyboardFocus')) 'Terminal keyboard-focus diagnostic is missing.'
Assert-True ($terminal.Contains('Keys.PageUp') -and $terminal.Contains('Keys.Home') -and $terminal.Contains('Keys.Escape')) 'Special navigation keys are not claimed by the ElementHost bridge.'
Assert-True ($terminal.Contains('Pi (bundled)')) 'Bundled Pi is missing from the embedded TUI presets.'

Write-Host 'PASS: Overview is blinkenlights + interactive TUI with compact machine readouts and next-endpoint telemetry.'

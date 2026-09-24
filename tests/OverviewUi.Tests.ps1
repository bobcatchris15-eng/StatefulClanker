$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "OVERVIEW UI TEST FAILED: $Message"}}

$program=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Tray\Program.cs')
$terminal=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Tray\EmbeddedTerminalPanel.cs')
$widgets=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Tray\CockpitWidgets.cs')
$connections=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Tray\ApiConnectionsUi.cs')

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

Assert-True ($program.Contains('SplitterWidth = 1')) 'Quiet splitter is not a precision 1px seam.'
Assert-True ($program.Contains('FillRectangle(brush, SplitterRectangle)')) 'Splitter is not explicitly dark-painted.'
Assert-True ($program.Contains('sealed class PrecisionTabControl')) 'Native tab chrome was not replaced by the precision-painted tab strip.'
Assert-True ($program.Contains('_tabs.TabPages.Add(BuildProviders())')) 'CLI Backends page exists but is not exposed in the main tab strip.'
Assert-True ($program.Contains('const int Cols = 16')) 'Blinkenlight bank is not using the dense square-lamp grid.'
Assert-True ($program.Contains('g.FillRectangle(fill, rect)')) 'Blinkenlights are not square filled lamps.'
$bankStart=$program.IndexOf('sealed class AgentBlinkenBank')
$bankEnd=$program.IndexOf('sealed class BlinkenRack',$bankStart)
Assert-True ($bankStart-ge0-and$bankEnd-gt$bankStart) 'Could not isolate AgentBlinkenBank.'
$bank=$program.Substring($bankStart,$bankEnd-$bankStart)
Assert-True (-not$bank.Contains('FillEllipse')) 'Blinkenlight bank still draws circular lamps or faux fasteners.'
Assert-True (-not$bank.Contains('screwBrush')) 'Blinkenlight bank still has decorative fasteners.'
Assert-True (-not$bank.Contains('RoundedRect')) 'Blinkenlight bank still uses rounded card geometry.'
Assert-True ($widgets.Contains('BackColor=Theme.Recess')) 'Overview readout is not seated in the recessed monocoque surface.'
Assert-True ($widgets.Contains('NEXT ENDPOINT IN QUEUE')) 'Next endpoint readout is missing.'
Assert-True ($widgets.Contains('RoutingQueueInspector')) 'Next endpoint does not read live machine routing state.'

Assert-True ($terminal.Contains('IsReadOnly = false')) 'Terminal became read-only.'
Assert-True ($terminal.Contains('Win32InputMode = false')) 'Terminal must use VT text input for interactive TUIs.'
Assert-True ($terminal.Contains('INPUT_CAPTURE.TabKey | EasyTerminalControl.INPUT_CAPTURE.DirectionKeys')) 'Terminal lost Tab/arrow capture.'
Assert-True ($terminal.Contains('PreviewMouseDown += (_, _) => FocusTerminal()')) 'Terminal click-to-focus hook is missing.'
Assert-True ($terminal.Contains('ConsoleHasKeyboardFocus')) 'Terminal keyboard-focus diagnostic is missing.'
Assert-True ($terminal.Contains('Keys.PageUp') -and $terminal.Contains('Keys.Home') -and $terminal.Contains('Keys.Escape')) 'Special navigation keys are not claimed by the ElementHost bridge.'
Assert-True ($terminal.Contains('Pi (bundled)')) 'Bundled Pi is missing from the embedded TUI presets.'
Assert-True ($terminal.Contains('StartBundledPi()') -and $terminal.Contains('StartGoose()') -and $terminal.Contains('StartAgy()') -and $terminal.Contains('StartOpenCode()')) 'Direct harness launch methods are missing from the embedded terminal.'

Write-Host '  UI REFRESH: live telemetry must not rebuild editable configuration surfaces'
Assert-True ($program.Contains('await RefreshAllAsync(false)')) 'The 3-second timer is still doing a full configuration refresh.'
Assert-True ($program.Contains('if (!refreshConfiguration) return;')) 'Live refresh has no guard before editable configuration grids are rebuilt.'
Assert-True ($connections.Contains('_modelSelectionDirty')) 'Connections page does not protect unsaved endpoint selection.'
Assert-True ($connections.Contains('RefreshProjectMarkers() => LoadModels(false)')) 'Background endpoint-marker refresh can still discard unsaved model selections.'

Write-Host 'PASS: Overview uses precision seams, square blinkenlights, interactive harness TUI, and non-destructive live refresh.'

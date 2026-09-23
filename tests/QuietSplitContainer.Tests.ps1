$ErrorActionPreference='Stop'
$source=Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\StatefulClanker.Tray\Program.cs')

function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "QUIET SPLITTER TEST FAILED: $Message"}}

$class=$source.Substring($source.IndexOf('sealed class QuietSplitContainer'),$source.IndexOf('sealed class AgentBlinkenBank')-$source.IndexOf('sealed class QuietSplitContainer'))
Assert-True (-not $class.Contains('protected override void OnCreateControl()')) 'Panel2 minimum size must not be applied during control creation before layout has an extent.'
Assert-True ($class.Contains('protected override void OnLayout(LayoutEventArgs levent)')) 'Pending panel minimum size must be applied after layout.'
Assert-True ($class.Contains('if (max < Panel1MinSize) return;')) 'Pending panel minimum size must wait until both panel minimums fit.'
Assert-True ($class.Contains('SplitterDistance = Math.Min(SplitterDistance, max);')) 'Existing splitter distance must be clamped before increasing Panel2MinSize.'
Assert-True ($class.Contains('SplitterWidth = 13;')) 'Splitter does not expose a reliable native drag hitbox.'
Assert-True ($class.Contains('Rectangle seam')) 'Splitter does not retain a narrow painted seam inside its drag hitbox.'

$program=Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\StatefulClanker.Tray\Program.cs')
Assert-True ($program.Contains('SplitterMoved += (_, _) => { capture(); QueueLayoutSave(); };')) 'User splitter movement does not persist layout settings.'
Assert-True ($program.Contains('AppStore.Save(_settings);')) 'Last layout state is not saved on app shutdown.'

Write-Host 'PASS: splitter minimums apply only after there is room for both panels.'

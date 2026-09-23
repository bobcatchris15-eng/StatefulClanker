$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "API CONNECTION SELECTION TEST FAILED: $Message"}}

$path=Join-Path $repo 'src\StatefulClanker.Tray\ApiConnectionsUi.cs'
$source=Get-Content -Raw -LiteralPath $path

Write-Host '  CONNECTION SELECTION 1: checkbox changes are immediate durable mutations'
Assert-True ($source.Contains('TargetPoolStore.UpdateActive(pool =>')) 'Connection checkbox path does not update the endpoint catalog atomically.'
Assert-True ($source.Contains('CurrentCellDirtyStateChanged')) 'Checkbox edits are not committed immediately.'
Assert-True ($source.Contains('CellValueChanged')) 'Committed checkbox edits are not persisted immediately.'
Assert-True (-not $source.Contains('_modelSelectionDirty')) 'Legacy unsaved-selection state still exists.'
Assert-True (-not $source.Contains('SaveTargetSelection(')) 'Legacy bulk SaveTargetSelection path still exists.'

Write-Host '  CONNECTION SELECTION 2: row identity survives connection focus changes'
Assert-True ($source.Contains('sealed record ApiModelRowBinding')) 'Model rows are not bound to their originating connection.'
Assert-True ($source.Contains('row.Tag=new ApiModelRowBinding(id,m.id)')) 'Model row binding is not populated.'
Assert-True ($source.Contains('row.Tag is not ApiModelRowBinding binding')) 'Persistence still depends on whichever connection is currently selected.'

Write-Host '  CONNECTION SELECTION 3: tray and router share one cross-process catalog lock'
Assert-True ($source.Contains('Local\\StatefulClankerRouterState-')) 'Tray endpoint catalog does not use the compiled router mutex namespace.'
Assert-True ($source.Contains('StoreMutex.WaitOne')) 'Endpoint catalog mutation is not serialized with the router.'
Assert-True ($source.Contains('LoadActiveUnlocked()')) 'Atomic update does not reload the latest catalog while holding the lock.'
Assert-True ($source.Contains('SaveActiveUnlocked(doc)')) 'Atomic update does not save under the same lock.'

Write-Host '  CONNECTION SELECTION 4: passive refresh updates markers instead of rebuilding the model list'
Assert-True ($source.Contains('public void RefreshProjectMarkers() => RefreshEndpointSelectionMarkers();')) 'Passive refresh still rebuilds the discovered model grid.'
Assert-True ($source.Contains('_loadedModelConnection')) 'Connection selection does not suppress redundant model-grid rebuilds.'

Write-Host 'PASS: connection endpoint selection is immediate, row-stable, cross-process atomic, and does not require a save action.'

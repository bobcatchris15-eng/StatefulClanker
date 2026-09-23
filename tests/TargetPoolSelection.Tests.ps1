$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$dll=Join-Path $repo 'src\StatefulClanker.Tray\bin\Debug\net8.0-windows\StatefulClanker.dll'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "TARGET POOL SELECTION TEST FAILED: $Message"}}
if(-not(Test-Path -LiteralPath $dll)){throw "Build the tray before running this test: $dll"}
$assembly=[Reflection.Assembly]::LoadFrom($dll)
$store=$assembly.GetType('StatefulClanker.Tray.TargetPoolStore',$true)
$documentType=$assembly.GetType('StatefulClanker.Tray.TargetPoolDocument',$true)
$entryType=$assembly.GetType('StatefulClanker.Tray.TargetPoolEntry',$true)
$apply=$store.GetMethod('ApplySelection',[Reflection.BindingFlags]'Public,Static')
$removeConnection=$store.GetMethod('RemoveConnection',[Reflection.BindingFlags]'Public,Static')
Assert-True ($null-ne$apply) 'TargetPoolStore does not expose immediate selection persistence.'
Assert-True ($null-ne$removeConnection) 'TargetPoolStore does not prune removed connections.'

$pool=[Activator]::CreateInstance($documentType)
$entry=[Activator]::CreateInstance($entryType)
$entry.id='demo::model-a';$entry.connection='demo';$entry.model='model-a';$entry.enabled=$true

Write-Host '  SELECTION 1: selecting a discovered model adds it to the active pool'
[void]$apply.Invoke($null,@($pool,$entry,$true))
Assert-True ($pool.entries.ContainsKey('demo::model-a')) 'Selected endpoint was not added to the active pool.'
Assert-True ([bool]$pool.entries['demo::model-a'].enabled) 'Selected endpoint was not enabled.'

Write-Host '  SELECTION 2: deselecting a discovered model records manual selection'
[void]$apply.Invoke($null,@($pool,$entry,$false))
Assert-True (-not$pool.entries.ContainsKey('demo::model-a')) 'Deselected endpoint remained in the active pool.'
Assert-True ($pool.manualConnections.Contains('demo')) 'Connection was not switched to manual selection.'

Write-Host '  SELECTION 3: deselecting an auto-managed model keeps a suppression marker'
$managed=[Activator]::CreateInstance($entryType)
$managed.id='demo::auto-free';$managed.connection='demo';$managed.model='auto-free';$managed.managedBy='free-capacity'
[void]$apply.Invoke($null,@($pool,$managed,$true))
[void]$apply.Invoke($null,@($pool,$managed,$false))
Assert-True ($pool.entries.ContainsKey('demo::auto-free')) 'Auto-managed endpoint lost its suppression marker.'
Assert-True (-not[bool]$pool.entries['demo::auto-free'].enabled) 'Deselected auto-managed endpoint remained enabled.'
Assert-True ([string]$pool.entries['demo::auto-free'].userOverride -eq 'disabled') 'Deselected auto-managed endpoint lacks a user override.'
[void]$apply.Invoke($null,@($pool,$managed,$true))
Assert-True ([bool]$pool.entries['demo::auto-free'].enabled) 'Re-selected auto-managed endpoint remained disabled.'

Write-Host '  SELECTION 4: removing a connection prunes every endpoint it contributed and its manual mode'
$entry.id='demo::model-b';$entry.model='model-b';[void]$apply.Invoke($null,@($pool,$entry,$true))
$other=[Activator]::CreateInstance($entryType);$other.id='other::model-c';$other.connection='other';$other.model='model-c';$other.enabled=$true
[void]$apply.Invoke($null,@($pool,$other,$true))
[int]$removed=$removeConnection.Invoke($null,@($pool,'demo'))
Assert-True ($removed -eq 2) 'Connection removal did not report the selected endpoints it pruned.'
Assert-True (-not$pool.entries.ContainsKey('demo::model-b')) 'Removed connection endpoint remained active.'
Assert-True ($pool.entries.ContainsKey('other::model-c')) 'Connection removal removed an unrelated endpoint.'
Assert-True (-not$pool.manualConnections.Contains('demo')) 'Removed connection retained manual selection mode.'
Write-Host 'PASS: endpoint selection mutates the active machine catalog immediately.'

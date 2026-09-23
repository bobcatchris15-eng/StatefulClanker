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

Write-Host '  SELECTION 2: deselecting a discovered model removes it from the active pool'
[void]$apply.Invoke($null,@($pool,$entry,$false))
Assert-True (-not$pool.entries.ContainsKey('demo::model-a')) 'Deselected endpoint remained in the active pool.'

Write-Host '  SELECTION 3: removing a connection prunes every endpoint it contributed'
$entry.id='demo::model-b';$entry.model='model-b';[void]$apply.Invoke($null,@($pool,$entry,$true))
$other=[Activator]::CreateInstance($entryType);$other.id='other::model-c';$other.connection='other';$other.model='model-c';$other.enabled=$true
[void]$apply.Invoke($null,@($pool,$other,$true))
[int]$removed=$removeConnection.Invoke($null,@($pool,'demo'))
Assert-True ($removed -eq 1) 'Connection removal did not report the selected endpoint it pruned.'
Assert-True (-not$pool.entries.ContainsKey('demo::model-b')) 'Removed connection endpoint remained active.'
Assert-True ($pool.entries.ContainsKey('other::model-c')) 'Connection removal removed an unrelated endpoint.'
Write-Host 'PASS: endpoint selection mutates the active machine catalog immediately.'

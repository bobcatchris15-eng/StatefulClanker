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
Assert-True ($null-ne$apply) 'TargetPoolStore does not expose immediate selection persistence.'

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
Write-Host 'PASS: endpoint selection mutates the active machine catalog immediately.'

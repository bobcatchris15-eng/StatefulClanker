$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$dll=Join-Path $repo 'src\StatefulClanker.Tray\bin\Debug\net8.0-windows\StatefulClanker.dll'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "TARGET POOL CHANGE TEST FAILED: $Message"}}
if(-not(Test-Path -LiteralPath $dll)){throw "Build the tray before running this test: $dll"}

$assembly=[Reflection.Assembly]::LoadFrom($dll)
$type=$assembly.GetType('StatefulClanker.Tray.TargetPoolChangeDispatcher',$true)
$dispatcher=[Activator]::CreateInstance($type)
$received=0
$handler=[EventHandler]{ param($sender,$args) $script:received++ }

Write-Host '  CHANGE 1: a machine catalog write publishes one UI refresh notification'
$type.GetEvent('Changed').AddEventHandler($dispatcher,$handler)
$type.GetMethod('Publish').Invoke($dispatcher,@())
Assert-True ($received -eq 1) 'The left target pool cannot be notified after a catalog change.'

Write-Host 'PASS: catalog changes can refresh dependent target views immediately.'

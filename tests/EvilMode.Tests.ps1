$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "EVIL MODE TEST FAILED: $Message"}}
function Assert-Trips([scriptblock]$Action,[string]$ExpectedTrigger,[string]$Message){
    $threw=$false
    try{& $Action}catch{$threw=$true}
    Assert-True $threw "$Message (operation was not blocked)"
    Assert-True (Test-SCEvilLatched) "$Message (evil latch was not set)"
    $record=Read-SCJson (Get-SCEvilPath)
    Assert-True ([string]$record.trigger-eq$ExpectedTrigger) "$Message (expected trigger $ExpectedTrigger, got $($record.trigger))"
    Clear-SCEvilTrip 'test reset'
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-evil-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try{
    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    Set-SCRoots $temp $temp
    $state=Join-Path $temp '.statefulclanker'
    New-Item -ItemType Directory -Force -Path $state|Out-Null
    [IO.File]::WriteAllText((Join-Path $state 'state.json'),'{}',(New-Object Text.UTF8Encoding($false)))
    function Invoke-SCProvider { throw 'CLI provider path not expected in evil-mode test.' }
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')

    $task=[pscustomobject]@{id='evil-test';role='worker'}
    [IO.File]::WriteAllText((Join-Path $temp 'inside.txt'),'safe',(New-Object Text.UTF8Encoding($false)))

    $inside=Resolve-SCWorkerToolPath '.\inside.txt' $task 'read_file'
    Assert-True ($inside.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'In-project file was rejected.'
    Assert-True (-not(Test-SCEvilLatched)) 'Normal in-project access tripped evil mode.'

    Assert-Trips { Resolve-SCWorkerToolPath '..\outside.txt' $task 'read_file'|Out-Null } 'worker.path_escape' 'Relative path escape did not trip.'
    Assert-Trips { Resolve-SCWorkerToolPath (Join-Path ([IO.Path]::GetTempPath()) 'definitely-outside-sc.txt') $task 'read_file' -AllowMissing|Out-Null } 'worker.path_escape' 'Absolute path escape did not trip.'

    $control=Resolve-SCWorkerPath '.statefulclanker\config.json' -AllowMissing
    Assert-Trips { Assert-SCWorkerMutablePath $control $task 'write_file' } 'worker.control_state_tamper' 'Direct control-state mutation did not trip.'

    Assert-SCWorkerCommandSafe 'Get-Content .\inside.txt' $task
    Assert-True (-not(Test-SCEvilLatched)) 'Safe in-project run_command tripped evil mode.'
    Assert-SCWorkerCommandSafe '"C:\Program Files\dotnet\dotnet.exe" --info' $task
    Assert-True (-not(Test-SCEvilLatched)) 'Absolute executable path was mistaken for project escape.'

    $outsideFile=Join-Path ([IO.Path]::GetTempPath()) ('sc-outside-'+[Guid]::NewGuid().ToString('N')+'.txt')
    Assert-Trips { Assert-SCWorkerCommandSafe ("Get-Content -LiteralPath '"+$outsideFile+"'") $task } 'worker.command_path_escape' 'run_command absolute path escape did not trip.'
    Assert-Trips { Assert-SCWorkerCommandSafe 'Get-Content $env:TEMP\secret.txt' $task } 'worker.command_path_escape' 'run_command environment path escape did not trip.'
    Assert-Trips { Assert-SCWorkerCommandSafe 'Remove-Item .statefulclanker\EVIL -Force' $task } 'worker.control_state_tamper' 'Control-state deletion did not trip.'
    Assert-Trips { Assert-SCWorkerCommandSafe 'Stop-Process -Name StatefulClanker.Tray' $task } 'worker.oversight_termination' 'Oversight termination did not trip.'

    Set-SCEvilTrip 'test.manual' 'manual latch for dispatch guard test' @{taskId=$task.id}|Out-Null
    $blocked=$false
    try{Assert-SCNotEvil}catch{$blocked=$true}
    Assert-True $blocked 'Latched evil state did not block later work.'
    Clear-SCEvilTrip 'test complete'
    Assert-True (-not(Test-SCEvilLatched)) 'Explicit clear did not release evil latch.'

    Write-Host 'PASS: evil mode latches on concrete worker boundary/oversight violations and ignores normal in-project work.'
}finally{
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "EVIL MODE TEST FAILED: $Message"}}
function Assert-Rejected([scriptblock]$Action,[string]$ExpectedError,[string]$Message){
    $caught=$null
    try{& $Action}catch{$caught=$_}
    Assert-True ($null-ne$caught) "$Message (operation was not blocked)"
    Assert-True ($caught.Exception.Message-like"*$ExpectedError*") "$Message (expected error containing '$ExpectedError', got '$($caught.Exception.Message)')"
}

$evilSymbols=@('Get-SCEvilPath','Test-SCEvilLatched','Set-SCEvilTrip','Clear-SCEvilTrip','Assert-SCNotEvil')
$runtimeFiles=@(
    (Join-Path $repo 'lib\StatefulClanker.Core.ps1'),
    (Join-Path $repo 'lib\StatefulClanker.Execution.ps1'),
    (Join-Path $repo 'lib\StatefulClanker.Autofill.ps1')
)
foreach($file in $runtimeFiles){
    $source=[IO.File]::ReadAllText($file)
    foreach($symbol in $evilSymbols){
        Assert-True ($source-notmatch([regex]::Escape($symbol))) "Legacy evil-mode symbol '$symbol' remains in $file."
    }
}
$cliSource=[IO.File]::ReadAllText((Join-Path $repo 'StatefulClanker.ps1'))
Assert-True ($cliSource-notmatch"'evil'") 'Legacy evil CLI route remains in StatefulClanker.ps1.'

$traySource=[IO.File]::ReadAllText((Join-Path $repo 'src\StatefulClanker.Tray\Program.cs'))
foreach($symbol in @('IsEvil','SetEvil','EvilMode','clanker.evil','clanker.evil.cleared')){
    Assert-True ($traySource-notmatch([regex]::Escape($symbol))) "Legacy evil-mode tray symbol '$symbol' remains in Program.cs."
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

    Assert-Rejected { Resolve-SCWorkerToolPath '..\outside.txt' $task 'read_file'|Out-Null } 'Path escapes worker root' 'Relative path escape was not rejected locally.'

    $control=Resolve-SCWorkerPath '.statefulclanker\config.json' -AllowMissing
    Assert-Rejected { Assert-SCWorkerMutablePath $control $task 'write_file' } 'Worker mutation of control state is forbidden' 'Control-state mutation was not rejected locally.'

    Assert-SCWorkerCommandSafe 'cmd.exe /c dir /s /b' $task
    Assert-Rejected { Assert-SCWorkerCommandSafe 'cmd.exe /outside' $task } 'run_command path escapes worker root' 'Rooted slash path was not rejected locally.'
    Assert-SCWorkerCommandSafe 'Get-Content .\inside.txt' $task
    Assert-True (-not(Test-Path -LiteralPath (Join-Path $state 'EVIL'))) 'Rejected operations created an EVIL latch file.'

    Write-Host 'PASS: worker violations are rejected locally without latching later worker operations.'
}finally{
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

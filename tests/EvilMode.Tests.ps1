$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$regressions=[Collections.Generic.List[string]]::new()
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
    . (Join-Path $repo 'lib\StatefulClanker.WorkerPolicy.ps1')
    # Keep machine policy reads within this fixture, retaining real authorization.
    function Get-SCWorkerPolicyMachinePath { return Join-Path $temp 'worker-capabilities.json' }
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

    # Each case must reject its own operation, without poisoning the next read.
    $outside=Join-Path (Split-Path -Parent $temp) 'outside.txt'
    $cases=@(
        @('Get-Content /s','path escapes'),
        @('Write-Output x > /b','redirection escapes'),
        @('cmd.exe /c dir /s > /b','redirection escapes'),
        @('cmd.exe /c Get-Content /s','path escapes'),
        @('cmd.exe /b','path escapes'),
        @('cmd.exe /c dir /outside','path escapes'),
        @("Get-Content '$outside'",'path escapes'),
        @('Get-Content $env:TEMP\outside.txt','path escapes'),
        @('Set-Content .statefulclanker\config.json broken','may not mutate'),
        @('Write-Output broken > .git\config','may not mutate'),
        @('Stop-Process -Name StatefulClanker','may not terminate'),
        @('taskkill.exe /IM StatefulClanker.exe /F','may not terminate')
    )
    foreach($case in $cases){
        try{Assert-Rejected { Assert-SCWorkerCommandSafe $case[0] $task } $case[1] "Command was not rejected locally: $($case[0])"}catch{$regressions.Add($_.Exception.Message)}
        Assert-SCWorkerCommandSafe 'Get-Content .\inside.txt' $task
        Assert-True (-not(Test-Path -LiteralPath (Join-Path $state 'EVIL'))) 'A command rejection created a persistent latch.'
    }
    Assert-Rejected { Resolve-SCWorkerToolPath $outside $task 'read_file'|Out-Null } 'Path escapes worker root' 'Absolute tool path escape was not rejected locally.'
    $absoluteCmd=Join-Path $env:SystemRoot 'System32\cmd.exe'
    Assert-SCWorkerCommandSafe "& '$absoluteCmd' /c dir /s /b" $task

    # Historic state is an inert fixture: successful and rejected operations may
    # neither interpret it nor overwrite it. Exercise real worker tools as well.
    $sentinel=Join-Path $state 'EVIL'
    $historic="historic sentinel content`r`nDo not rewrite."
    [IO.File]::WriteAllText($sentinel,$historic)
    $sentinelBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($sentinel))
    $registry=Get-SCIntrinsicWorkerToolRecords $task 'run'
    Assert-Rejected { Assert-SCWorkerCommandSafe 'Get-Content ..\outside.txt' $task } 'path escapes' 'Historic sentinel affected the local path error.'
    $written=Invoke-SCWorkerTool 'write_file' ([pscustomobject]@{path='after.txt';content='still working'}) $task 'run' $registry
    Assert-True ($written-eq'written') 'Valid write failed with a historic sentinel present.'
    $read=Invoke-SCWorkerTool 'read_file' ([pscustomobject]@{path='after.txt'}) $task 'run' $registry
    Assert-True ($read-like'*still working*') 'Valid read failed with a historic sentinel present.'
    $result=Invoke-SCWorkerTool 'run_command' ([pscustomobject]@{command='Write-Output still-working'}) $task 'run' $registry|ConvertFrom-Json
    Assert-True ($result.exitCode-eq0-and$result.stdout.Trim()-eq'still-working') 'Valid command failed with a historic sentinel present.'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($sentinel))-ceq$sentinelBytes) 'Historic sentinel bytes changed.'

    # Load the actual built tray and exercise its event reader without creating
    # a MainForm (which would start the MCP host and touch user settings).
    & dotnet build (Join-Path $repo 'src\StatefulClanker.Tray\StatefulClanker.Tray.csproj') --no-restore --verbosity quiet
    Assert-True ($LASTEXITCODE-eq0) 'Tray build failed before event regression test.'
    Add-Type -AssemblyName System.Windows.Forms
    $assembly=[Reflection.Assembly]::LoadFrom((Join-Path $repo 'src\StatefulClanker.Tray\bin\Debug\net8.0-windows\StatefulClanker.dll'))
    $form=$assembly.GetType('StatefulClanker.Tray.MainForm')
    $reader=$form.GetMethod('ReadNewEvents',[Reflection.BindingFlags]'Static,NonPublic')
    try{
        Assert-True ($null-ne$reader) 'Tray failure/hold event reader is missing.'
        $eventTypes=@('run.failed','critic.error','validator.error','project.hold.set','project.review.failed','state.proposal_rejected','task.plan_repair_required','autofill.stalled')
        $events=Join-Path $state 'events.jsonl'
        $lines=@('{invalid-json')
        for($i=0;$i-lt$eventTypes.Count;$i++){
            $lines+=(@{ts=('2026-09-21T12:00:{0:00}Z'-f($i+1));type=$eventTypes[$i];message='needs attention'}|ConvertTo-Json -Compress)
        }
        $lines+='{"ts":"2026-09-21T12:00:09Z","type":"clanker.evil"}'
        $lines+='{"ts":"2026-09-21T12:00:10Z","type":"clanker.evil.cleared"}'
        $lines+='{"ts":"2026-09-21T12:00:11Z","type":"run.completed"}'
        [IO.File]::WriteAllLines($events,$lines)
        $arguments=[object[]]@([string]$events,'2026-09-21T12:00:00Z')
        $notices=$reader.Invoke($null,$arguments)
        Assert-True ($notices.Count-eq8) 'Tray lost ordinary escalation events or escalated historic/routine events.'
        for($i=0;$i-lt8;$i++){
            Assert-True ($notices[$i].Item2-eq$eventTypes[$i]-and$notices[$i].Item3-eq'needs attention') 'Tray event type or message was not preserved.'
        }
        Assert-True ($arguments[1]-eq'2026-09-21T12:00:11Z') 'Tray cursor did not advance past ignored events.'
        Assert-True ($reader.Invoke($null,$arguments).Count-eq0) 'Tray replayed events already consumed.'
    }catch{$regressions.Add($_.Exception.Message)}
    Assert-True ($regressions.Count-eq0) ($regressions-join"`n")

    Write-Host 'PASS: worker violations are rejected locally without latching later worker operations.'
}finally{
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

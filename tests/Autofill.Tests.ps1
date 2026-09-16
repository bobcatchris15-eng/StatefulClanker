<# Autofill supervisor: keeps the configured worker complement full from the ready queue. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot;$harness=Join-Path $repo 'StatefulClanker.ps1';$slow=Join-Path $PSScriptRoot 'SlowWritingProvider.cmd';$mock=Join-Path $PSScriptRoot 'MockProvider.cmd'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "AUTOFILL TEST FAILED: $Message"}}
$pwshPath=(Get-Process -Id $PID).Path
if(-not(Get-Command git -ErrorAction SilentlyContinue)){Write-Host '  AUTOFILL: SKIPPED - git not found.';return}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-autofill-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $temp|Out-Null
$proc=$null
try {
    Push-Location $temp
    & git init -q .;& git config user.email 'test@statefulclanker.local';& git config user.name 'StatefulClanker Test'
    'seed'|Set-Content seed.txt -Encoding UTF8;'.statefulclanker/'|Set-Content .gitignore -Encoding UTF8
    & $pwshPath -NoProfile -File $harness init|Out-Null
    $cfgPath=Join-Path $temp '.statefulclanker\config.json';$cfg=Get-Content -Raw $cfgPath|ConvertFrom-Json
    $cfg.defaultProvider='slow';$cfg.criticProvider='ro';$cfg.validatorProvider='ro';$cfg.maxConcurrent=2;$cfg.autofillEnabled=$true;$cfg.autofillIntervalSeconds=1;$cfg.projectReviewEveryTasks=0
    $cfg.providers|Add-Member -NotePropertyName slow -NotePropertyValue ([pscustomobject]@{command='cmd.exe';args=@('/d','/c',$slow,'{taskId}','out-{taskId}.txt');mode='inline'}) -Force
    $cfg.providers|Add-Member -NotePropertyName ro -NotePropertyValue ([pscustomobject]@{command='cmd.exe';args=@('/d','/c',$mock,'{promptFile}');mode='prompt-file'}) -Force
    $cfg|ConvertTo-Json -Depth 12|Set-Content $cfgPath -Encoding UTF8
    1..4|ForEach-Object{& $pwshPath -NoProfile -File $harness task add -TaskId "a$_" -Title "Autofill $_" -Instruction 'Do bounded work.' -Accept 'passes' -Retrieval 'seed.txt'|Out-Null}
    & git add -A;& git commit -q -m seed
    Write-Host '  AUTOFILL 1: resident supervisor fills two slots and replenishes them without a conversational kick'
    $log=Join-Path $temp '.statefulclanker\autofill-test.log';$argLine="-NoProfile -NonInteractive -File `"$harness`" autofill run -IntervalSeconds 1"
    $proc=Start-Process -FilePath $pwshPath -ArgumentList $argLine -WorkingDirectory $temp -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden -PassThru
    $deadline=(Get-Date).AddSeconds(35);$maxBusy=0;$complete=0
    do {
        Start-Sleep -Milliseconds 250
        $tasks=@(Get-ChildItem (Join-Path $temp '.statefulclanker\tasks') -Filter *.json|ForEach-Object{Get-Content -Raw $_.FullName|ConvertFrom-Json})
        $busy=@($tasks|Where-Object{@('running','reviewing','validating')-contains[string]$_.status}).Count;if($busy-gt$maxBusy){$maxBusy=$busy}
        $complete=@($tasks|Where-Object{$_.status-eq'complete'}).Count
    } while($complete-lt4-and(Get-Date)-lt$deadline)
    Assert-True ($complete-eq4) "Expected all four tasks to finish without another dispatch call; got $complete. STDOUT: $(if(Test-Path $log){Get-Content -Raw $log}) STDERR: $(if(Test-Path "$log.err"){Get-Content -Raw "$log.err"})"
    $mergeDeadline=(Get-Date).AddSeconds(12)
    do {
        $allMerged=$true;foreach($i in 1..4){if(-not(Test-Path (Join-Path $temp "out-a$i.txt"))){$allMerged=$false;break}}
        if(-not$allMerged){Start-Sleep -Milliseconds 200}
    } while(-not$allMerged-and(Get-Date)-lt$mergeDeadline)
    Assert-True $allMerged "All tasks validated but the supervisor did not finish merging every worktree. STDOUT: $(if(Test-Path $log){Get-Content -Raw $log}) STDERR: $(if(Test-Path "$log.err"){Get-Content -Raw "$log.err"})"
    Assert-True ($maxBusy-le2) "Autofill exceeded maxConcurrent=2 (observed $maxBusy)."
    Assert-True ($maxBusy-ge2) "Autofill never filled the allowed complement of two workers (observed $maxBusy)."
    foreach($i in 1..4){Assert-True (Test-Path (Join-Path $temp "out-a$i.txt")) "Merged output for a$i is missing."}
    $statusPath=Join-Path $temp '.statefulclanker\autofill\supervisor.json';$idle=$false;$idleDeadline=(Get-Date).AddSeconds(6)
    do{Start-Sleep -Milliseconds 200;if(Test-Path $statusPath){try{$st=Get-Content -Raw $statusPath|ConvertFrom-Json;$idle=([string]$st.state-eq'idle'-and[int]$st.ownedActive-eq0-and[int]$st.readyCount-eq0)}catch{}}}while(-not$idle-and(Get-Date)-lt$idleDeadline)
    Assert-True $idle 'Autofill did not settle to idle after the ready queue was exhausted.'
    $events=@(Get-Content (Join-Path $temp '.statefulclanker\events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json});Assert-True (@($events|Where-Object{$_.type-eq'autofill.dispatched'}).Count-ge4) 'Expected at least four autofill.dispatched events.'
    Write-Host '  AUTOFILL 2: human-gated work remains queued and undispatched'
    & $pwshPath -NoProfile -File $harness task add -TaskId gate -Title 'Human gate' -Instruction 'Do not dispatch automatically.' -Accept 'human approval' -Retrieval 'seed.txt' -HumanGate|Out-Null
    Start-Sleep -Seconds 3;$g=Get-Content -Raw (Join-Path $temp '.statefulclanker\tasks\gate.json')|ConvertFrom-Json
    Assert-True ([bool]$g.humanGate) 'Human-gated test task lost its gate.';Assert-True (@('running','reviewing','validating','complete')-notcontains[string]$g.status) "Human-gated task was dispatched (status $($g.status)).";Assert-True (-not(Test-Path (Join-Path $temp 'out-gate.txt'))) 'Human-gated task produced worker output.'
    Write-Host '  AUTOFILL 3: manual dispatch is rejected while autofill owns scheduling'
    $manual=$null;$oldPref=$ErrorActionPreference;try{$ErrorActionPreference='Continue';$manual=& $pwshPath -NoProfile -File $harness run 2>&1|Out-String}finally{$ErrorActionPreference=$oldPref};Assert-True ($manual-match'autofill supervisor') "Manual dispatch was not rejected clearly. Got: $manual"
    & $pwshPath -NoProfile -File $harness autofill stop|Out-Null
    if(-not$proc.WaitForExit(10000)){throw 'Autofill supervisor did not drain/stop within 10 seconds.'}
    Write-Host 'PASS: autofill maintains the ready worker complement, respects maxConcurrent, and owns dispatch while resident.'
} finally {
    if($proc-and-not$proc.HasExited){try{& $pwshPath -NoProfile -File $harness autofill stop|Out-Null}catch{};try{$proc.Kill()}catch{}}
    if($proc){$proc.Dispose()};Pop-Location -ErrorAction SilentlyContinue;Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue
}

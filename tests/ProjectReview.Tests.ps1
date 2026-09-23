<# Project review tests: one semantic reviewer, deterministic validation as the
   only hard gate, and advisory semantic findings. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$harness=Join-Path $repo 'StatefulClanker.ps1'
$passProvider=Join-Path $PSScriptRoot 'MockProvider.cmd'
$failProvider=Join-Path $PSScriptRoot 'FailingProvider.cmd'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "PROJECT REVIEW TEST FAILED: $Message"}}
$pwshPath=(Get-Process -Id $PID).Path
if([string]::IsNullOrWhiteSpace($pwshPath)){$pwshPath=(Get-Command pwsh).Source}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-review-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
Push-Location $temp
try{
    'seed'|Set-Content -LiteralPath 'seed.txt' -Encoding UTF8
    & $pwshPath -NoProfile -File $harness init|Out-Null

    $cfgPath=Join-Path $temp '.statefulclanker\config.json'
    $cfg=Get-Content -Raw -LiteralPath $cfgPath|ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName projectReviewEveryTasks -NotePropertyValue 2 -Force
    $cfg | Add-Member -NotePropertyName projectReviewerEnabled -NotePropertyValue $true -Force
    $cfg | Add-Member -NotePropertyName projectValidateCommand -NotePropertyValue 'echo PROJECT VALID && exit 0' -Force
    $cfg.providers|Add-Member -NotePropertyName mock -NotePropertyValue ([pscustomobject]@{
        command='cmd.exe';args=@('/d','/c',$passProvider,'{promptFile}');mode='prompt-file'
    }) -Force
    $cfg.providers|Add-Member -NotePropertyName failreview -NotePropertyValue ([pscustomobject]@{
        command='cmd.exe';args=@('/d','/c',$failProvider,'{promptFile}');mode='prompt-file'
    }) -Force
    $cfg|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $cfgPath -Encoding UTF8

    foreach($n in 1..2){
        & $pwshPath -NoProfile -File $harness task add -TaskId "r$n" -Title "Task $n" -Instruction 'Return a successful bounded result.' -Accept 'mock passes' -Retrieval 'seed.txt'|Out-Null
    }

    Write-Host '  REVIEW 1: interval waits for the configured task count'
    $out1=& $pwshPath -NoProfile -File $harness run -TaskId r1 -Provider mock 2>&1|Out-String
    Assert-True ($out1-notmatch'Project review') "Review fired before interval. $out1"

    Write-Host '  REVIEW 2: one reviewer runs at the interval with deterministic evidence'
    $out2=& $pwshPath -NoProfile -File $harness run -TaskId r2 -Provider mock 2>&1|Out-String
    Assert-True ($out2-match'Project review') "Review did not fire at interval. $out2"
    $reviewDir=Join-Path $temp '.statefulclanker\reviews'
    $latest=Get-ChildItem $reviewDir -Filter '*.json'|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
    $record=Get-Content -Raw $latest.FullName|ConvertFrom-Json
    Assert-True (@($record.stages).Count-eq1) 'Project review should make exactly one semantic reviewer call.'
    Assert-True ([string]$record.stages[0].stage-eq'reviewer') 'Project review stage should be reviewer.'
    Assert-True ([int]$record.projectValidate.exitCode-eq0) 'Passing deterministic project validation was not recorded.'
    Assert-True (-not[bool]$record.hardFailure) 'Passing deterministic validation incorrectly hard-failed the project.'
    $hold=& $pwshPath -NoProfile -File $harness hold status 2>&1|Out-String
    Assert-True ($hold-match'Not held') 'Passing review unexpectedly held dispatch.'

    Write-Host '  REVIEW 3: semantic FAIL is advisory and does not freeze dispatch'
    $out3=& $pwshPath -NoProfile -File $harness review run -Provider failreview 2>&1|Out-String
    Assert-True ($out3-match'advisory') "Semantic reviewer failure was not reported as advisory. $out3"
    $hold=& $pwshPath -NoProfile -File $harness hold status 2>&1|Out-String
    Assert-True ($hold-match'Not held') 'Semantic findings alone froze dispatch.'
    $latest=Get-ChildItem $reviewDir -Filter '*.json'|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
    $record=Get-Content -Raw $latest.FullName|ConvertFrom-Json
    Assert-True ([bool]$record.advisoryFindings) 'Semantic findings were not recorded.'
    Assert-True (-not[bool]$record.hardFailure) 'Semantic-only findings were mislabeled as a hard failure.'

    Write-Host '  REVIEW 4: deterministic project failure is the hard gate'
    $cfg=Get-Content -Raw $cfgPath|ConvertFrom-Json
    $cfg.projectValidateCommand='echo TESTS FAILED: deterministic evidence && exit 1'
    $cfg|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $cfgPath -Encoding UTF8
    $out4=& $pwshPath -NoProfile -File $harness review run -Provider mock 2>&1|Out-String
    Assert-True ($out4-match'HARD FAILED') "Deterministic failure did not hard-fail review. $out4"
    $hold=& $pwshPath -NoProfile -File $harness hold status 2>&1|Out-String
    Assert-True ($hold-match'HELD') 'Deterministic project validation failure did not hold dispatch.'

    Write-Host '  REVIEW 5: held dispatch refuses ordinary work until repaired/cleared'
    & $pwshPath -NoProfile -File $harness task add -TaskId r3 -Title 'Task 3' -Instruction 'Return a successful bounded result.' -Accept 'mock passes' -Retrieval 'seed.txt'|Out-Null
    $old=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';$blocked=& $pwshPath -NoProfile -File $harness run -TaskId r3 -Provider mock 2>&1|Out-String}finally{$ErrorActionPreference=$old}
    Assert-True ($blocked-match'on hold') "Held dispatch was not refused. $blocked"

    Write-Host '  REVIEW 6: repair + hold clear restores dispatch; interval 0 disables periodic review'
    & $pwshPath -NoProfile -File $harness hold clear|Out-Null
    $cfg=Get-Content -Raw $cfgPath|ConvertFrom-Json
    $cfg.projectValidateCommand='echo PROJECT VALID && exit 0'
    $cfg.projectReviewEveryTasks=0
    $cfg|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $cfgPath -Encoding UTF8
    $out5=& $pwshPath -NoProfile -File $harness run -TaskId r3 -Provider mock 2>&1|Out-String
    Assert-True ($out5-notmatch'Project review') "Interval 0 did not disable periodic review. $out5"

    $events=@(Get-Content (Join-Path $temp '.statefulclanker\events.jsonl')|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json})
    Assert-True (@($events|Where-Object{$_.type-eq'project.review.findings'}).Count-ge1) 'Advisory reviewer findings event missing.'
    Assert-True (@($events|Where-Object{$_.type-eq'project.review.failed'}).Count-ge1) 'Deterministic hard-failure event missing.'
    Assert-True (@($events|Where-Object{$_.type-eq'project.hold.cleared'}).Count-ge1) 'Hold clear event missing.'
    Write-Host 'PASS: project review uses one semantic reviewer, advisory findings, and deterministic hard gating.'
}
finally{
    Pop-Location
    Set-Location $repo
    Remove-Item -Recurse -Force -LiteralPath $temp -ErrorAction SilentlyContinue
}

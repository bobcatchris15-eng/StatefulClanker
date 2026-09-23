$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$harness = Join-Path $repo 'StatefulClanker.ps1'
$mockPs = Join-Path $PSScriptRoot 'MockProvider.ps1'
$mockCmd = Join-Path $PSScriptRoot 'MockProvider.cmd'
$mcp = Join-Path $repo 'mcp\StatefulClanker.Mcp.ps1'

Write-Host 'STEP 1: parse every PowerShell file in the repo'
foreach($script in @(Get-ChildItem -LiteralPath $repo -Recurse -Filter '*.ps1' -File |
        Where-Object { -not $_.FullName.Contains('.statefulclanker') } |
        Select-Object -ExpandProperty FullName)){
    $tokens=$null;$errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script,[ref]$tokens,[ref]$errors)
    if($errors.Count -gt 0){throw "Parse failure in $script : $($errors | Out-String)"}
}

Write-Host 'STEP 1b: bareword-concatenation guard'
foreach($script in @(Get-ChildItem -LiteralPath $repo -Recurse -Filter '*.ps1' -File |
        Where-Object { -not $_.FullName.Contains('.statefulclanker') } )){
    $n=0
    foreach($line in (Get-Content -LiteralPath $script.FullName)){
        $n++
        if($line.TrimStart().StartsWith('#')){continue}
        if($line -match '(^|[;{}])\s*(return|throw|exit|break|continue)[''"]'){
            throw "Bareword concatenation in $($script.FullName) line ${n}: $line"
        }
    }
}

Write-Host 'STEP 1c: verdict parser contract'
. (Join-Path $repo 'lib\StatefulClanker.Execution.ps1')
if((Get-SCVerdict "VERDICT: PASS" 0) -ne 'PASS'){throw 'Get-SCVerdict failed to parse PASS.'}
if((Get-SCVerdict "VERDICT: FAIL" 0) -ne 'FAIL'){throw 'Get-SCVerdict failed to parse FAIL.'}
if((Get-SCVerdict "VERDICT: PASS" 1) -ne 'ERROR'){throw 'Get-SCVerdict must return ERROR on nonzero exit.'}
if((Get-SCVerdict "chatty preamble" 0) -ne 'FAIL'){throw 'Get-SCVerdict must fail closed on malformed output.'}
if((Get-SCVerdict "I reviewed the diff and the tests run.`n`nVERDICT: PASS" 0) -ne 'PASS'){throw 'Get-SCVerdict must accept a verdict after a preamble.'}
if((Get-SCVerdict "Findings:`n- all criteria met`n**VERDICT: PASS**" 0) -ne 'PASS'){throw 'Get-SCVerdict must tolerate markdown decoration.'}
if((Get-SCVerdict "Analysis.`n  VERDICT: PASS.  " 0) -ne 'PASS'){throw 'Get-SCVerdict must tolerate indentation and trailing punctuation.'}
if((Get-SCVerdict "VERDICT: FAIL`nOn reflection VERDICT: PASS" 0) -ne 'FAIL'){throw 'A later PASS must not override an earlier FAIL.'}
if((Get-SCVerdict "Do not emit VERDICT: PASS unless tests ran." 0) -ne 'FAIL'){throw 'A prose mention of a verdict is not a vote.'}
if((Get-SCVerdict "The worker said VERDICT: PASS but is wrong.`nVERDICT: FAIL" 0) -ne 'FAIL'){throw 'Prose PASS must not outrank a real FAIL.'}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-smoke-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
Push-Location $temp
try {
    Write-Host 'STEP 2: initialize project'
    'evidence for retrieval' | Set-Content -LiteralPath '.\evidence.txt' -Encoding UTF8
    & $harness init
    $cfgPath = Join-Path $temp '.statefulclanker\config.json'
    $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    $cfg.providers | Add-Member -NotePropertyName mock -NotePropertyValue ([pscustomobject]@{
        command = 'cmd.exe'
        args = @('/d','/c',$mockCmd)
        mode = 'prompt-file'
    }) -Force
    $cfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cfgPath -Encoding UTF8

    Write-Host 'STEP 3: create goal and task'
    & $harness goal -Message 'Exercise worker-validation and telemetry.'
    & $harness task add -TaskId smoke-task -Title 'Smoke task' -Instruction 'Return a successful bounded result.' -Accept 'Mock validator passes' -Retrieval 'evidence.txt'

    Write-Host 'STEP 4: execute worker/validator pipeline in bounded job'
    $job = Start-Job -ArgumentList $harness,$temp -ScriptBlock {
        param($HarnessPath,$ProjectPath)
        Set-Location $ProjectPath
        & $HarnessPath run -TaskId smoke-task -Provider mock
    }
    $finished = Wait-Job -Job $job -Timeout 15
    if($null -eq $finished){
        $stateDir=Join-Path $temp '.statefulclanker'
        $activeDir=Join-Path $stateDir 'telemetry\active'
        $completedDir=Join-Path $stateDir 'telemetry\runs'
        $promptDir=Join-Path $stateDir 'prompts'
        $active=@();$completed=@();$prompts=@();$events='';$jobOutput=''
        if(Test-Path $activeDir){$active=@(Get-ChildItem -LiteralPath $activeDir -Filter '*.json' -File | ForEach-Object { Get-Content -Raw $_.FullName })}
        if(Test-Path $completedDir){$completed=@(Get-ChildItem -LiteralPath $completedDir -Filter '*.json' -File | ForEach-Object { Get-Content -Raw $_.FullName })}
        if(Test-Path $promptDir){$prompts=@(Get-ChildItem -LiteralPath $promptDir -File | Select-Object -ExpandProperty Name)}
        $eventsPath=Join-Path $stateDir 'events.jsonl';if(Test-Path $eventsPath){$events=(Get-Content -LiteralPath $eventsPath|Where-Object{$_}) -join ' | '}
        try{$jobOutput=(Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue 2>&1|Out-String)}catch{$jobOutput="<receive failed: $($_.Exception.Message)>"}
        $taskSnapshot=Get-Content -Raw -LiteralPath (Join-Path $stateDir 'tasks\smoke-task.json')
        throw "Pipeline exceeded 15 seconds. Task=$taskSnapshot ActiveTelemetry=$($active -join ' | ') CompletedTelemetry=$($completed -join ' | ') Prompts=$($prompts -join ',') Events=$events JobOutput=$jobOutput"
    }
    Receive-Job -Job $job | Write-Host
    Remove-Job -Job $job -Force
    Write-Host 'STEP 5: pipeline returned'

    $task = Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\tasks\smoke-task.json') | ConvertFrom-Json
    if ($task.status -ne 'complete') { throw "Expected complete, got $($task.status)" }
    if (-not $task.latestRunId) { throw 'Missing worker receipt id.' }
    if (-not $task.latestValidationId) { throw 'Missing validator receipt id.' }

    Write-Host 'STEP 6: validate telemetry records'
    $telemetry = @(Get-ChildItem -LiteralPath (Join-Path $temp '.statefulclanker\telemetry\runs') -Filter '*.json' -File | ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json })
    if ($telemetry.Count -ne 2) { throw "Expected 2 telemetry records (worker + validator), got $($telemetry.Count)" }
    if (@($telemetry | Where-Object { $_.lifecycle -ne 'completed' }).Count -ne 0) { throw 'Expected completed telemetry records.' }
    if (@($telemetry | Where-Object { $_.stage -eq 'critic' }).Count -ne 0) { throw 'Ordinary task unexpectedly ran a critic.' }
    if (@($telemetry | Where-Object { $_.stage -eq 'validator' -and $_.verdict -eq 'PASS' }).Count -ne 1) { throw 'Missing passing validator telemetry.' }
    if (@(Get-ChildItem -LiteralPath (Join-Path $temp '.statefulclanker\telemetry\active') -Filter '*.json' -File).Count -ne 0) { throw 'Active telemetry should be empty after completion.' }

    Write-Host 'STEP 6b: every .jsonl line is a single JSON object'
    foreach ($jsonl in @('events.jsonl', 'telemetry\events.jsonl', 'telemetry\context-faults.jsonl')) {
        $jsonlPath = Join-Path $temp ".statefulclanker\$jsonl"
        if (-not (Test-Path -LiteralPath $jsonlPath)) { continue }
        $n = 0
        foreach ($line in @(Get-Content -LiteralPath $jsonlPath | Where-Object { $_ })) {
            $n++
            try { $line | ConvertFrom-Json | Out-Null }
            catch { throw "$jsonl line ${n} is not a standalone JSON object: $line" }
        }
    }

    Write-Host 'STEP 7: exercise telemetry CLI'
    $history = (& $harness telemetry history | Out-String)
    if ($history -notmatch 'smoke-task') { throw 'Telemetry CLI did not show smoke task.' }

    Write-Host 'PASS: worker -> validator -> complete + durable telemetry'
}
finally {
    Write-Host 'STEP 8: cleanup'
    Pop-Location
}

Write-Host 'STEP 8b: prompt delivery'
& (Join-Path $PSScriptRoot 'Prompt.Tests.ps1')
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "Prompt tests failed (exit $LASTEXITCODE)." }

Write-Host 'STEP 9: MCP control plane'
& (Join-Path $PSScriptRoot 'Mcp.Tests.ps1')
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "MCP tests failed (exit $LASTEXITCODE)." }

Write-Host 'STEP 10: parallel execution'
& (Join-Path $PSScriptRoot 'Concurrency.Tests.ps1')
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "Concurrency tests failed (exit $LASTEXITCODE)." }

Write-Host 'STEP 11: periodic project review'
& (Join-Path $PSScriptRoot 'ProjectReview.Tests.ps1')
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "Project review tests failed (exit $LASTEXITCODE)." }

Write-Host 'STEP 12: integrations catalogue'
& (Join-Path $PSScriptRoot 'Integrations.Tests.ps1')
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "Integration tests failed (exit $LASTEXITCODE)." }

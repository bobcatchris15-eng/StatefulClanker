$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$harness = Join-Path $repo 'StatefulClanker.ps1'
$mockPs = Join-Path $PSScriptRoot 'MockProvider.ps1'
$mockCmd = Join-Path $PSScriptRoot 'MockProvider.cmd'
$mcp = Join-Path $repo 'mcp\StatefulClanker.Mcp.ps1'
$cockpit = Join-Path $repo 'desktop\StatefulClanker.Cockpit.ps1'

Write-Host 'STEP 1: parse PowerShell entrypoints'
foreach($script in @($harness,$mockPs,$mcp,$cockpit)){
    $tokens=$null;$errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script,[ref]$tokens,[ref]$errors)
    if($errors.Count -gt 0){throw "Parse failure in $script : $($errors | Out-String)"}
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-smoke-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
Push-Location $temp
try {
    Write-Host 'STEP 2: initialize project'
    'evidence for retrieval' | Set-Content -LiteralPath '.\evidence.txt' -Encoding UTF8
    & $harness init
    $cfgPath = Join-Path $temp '.statefulclanker\config.json'
    $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    $cfg.defaultProvider = 'mock'
    $cfg.criticProvider = 'mock'
    $cfg.validatorProvider = 'mock'
    $cfg.providers | Add-Member -NotePropertyName mock -NotePropertyValue ([pscustomobject]@{
        command = 'cmd.exe'
        args = @('/d','/c',$mockCmd)
        mode = 'prompt-file'
    }) -Force
    $cfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cfgPath -Encoding UTF8

    Write-Host 'STEP 3: create goal and task'
    & $harness goal -Message 'Exercise worker-review-validation and telemetry.'
    & $harness task add -TaskId smoke-task -Title 'Smoke task' -Instruction 'Return a successful bounded result.' -Accept 'Mock validator passes' -Retrieval 'evidence.txt'

    Write-Host 'STEP 4: execute worker/review pipeline in bounded job'
    $job = Start-Job -ArgumentList $harness,$temp -ScriptBlock {
        param($HarnessPath,$ProjectPath)
        Set-Location $ProjectPath
        & $HarnessPath run -TaskId smoke-task
    }
    $finished = Wait-Job -Job $job -Timeout 15
    if($null -eq $finished){
        $activeDir=Join-Path $temp '.statefulclanker\telemetry\active'
        $active=@()
        if(Test-Path $activeDir){$active=@(Get-ChildItem -LiteralPath $activeDir -Filter '*.json' -File | ForEach-Object { Get-Content -Raw $_.FullName })}
        $taskSnapshot=Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\tasks\smoke-task.json')
        throw "Pipeline exceeded 15 seconds. Task=$taskSnapshot ActiveTelemetry=$($active -join ' | ')"
    }
    Receive-Job -Job $job | Write-Host
    Remove-Job -Job $job -Force
    Write-Host 'STEP 5: pipeline returned'

    $task = Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\tasks\smoke-task.json') | ConvertFrom-Json
    if ($task.status -ne 'complete') { throw "Expected complete, got $($task.status)" }
    if (-not $task.latestRunId) { throw 'Missing worker receipt id.' }
    if (-not $task.latestCritiqueId) { throw 'Missing critic receipt id.' }
    if (-not $task.latestValidationId) { throw 'Missing validator receipt id.' }

    Write-Host 'STEP 6: validate telemetry records'
    $telemetry = @(Get-ChildItem -LiteralPath (Join-Path $temp '.statefulclanker\telemetry\runs') -Filter '*.json' -File | ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json })
    if ($telemetry.Count -ne 3) { throw "Expected 3 telemetry records, got $($telemetry.Count)" }
    if (@($telemetry | Where-Object { $_.lifecycle -ne 'completed' }).Count -ne 0) { throw 'Expected completed telemetry records.' }
    if (@($telemetry | Where-Object { $_.stage -eq 'critic' -and $_.verdict -eq 'PASS' }).Count -ne 1) { throw 'Missing passing critic telemetry.' }
    if (@($telemetry | Where-Object { $_.stage -eq 'validator' -and $_.verdict -eq 'PASS' }).Count -ne 1) { throw 'Missing passing validator telemetry.' }
    if (@(Get-ChildItem -LiteralPath (Join-Path $temp '.statefulclanker\telemetry\active') -Filter '*.json' -File).Count -ne 0) { throw 'Active telemetry should be empty after completion.' }

    Write-Host 'STEP 7: exercise telemetry CLI'
    $history = (& $harness telemetry history | Out-String)
    if ($history -notmatch 'smoke-task') { throw 'Telemetry CLI did not show smoke task.' }

    Write-Host 'PASS: worker -> critic -> validator -> complete + durable telemetry'
}
finally {
    Write-Host 'STEP 8: cleanup'
    Pop-Location
}

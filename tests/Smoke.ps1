$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$harness = Join-Path $repo 'StatefulClanker.ps1'
$mock = Join-Path $PSScriptRoot 'MockProvider.ps1'
$shell = (Get-Process -Id $PID).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-smoke-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
Push-Location $temp
try {
    'evidence for retrieval' | Set-Content -LiteralPath '.\evidence.txt' -Encoding UTF8
    & $harness init
    $cfgPath = Join-Path $temp '.statefulclanker\config.json'
    $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    $cfg.defaultProvider = 'mock'
    $cfg.criticProvider = 'mock'
    $cfg.validatorProvider = 'mock'
    $cfg.providers | Add-Member -NotePropertyName mock -NotePropertyValue ([pscustomobject]@{
        command = $shell
        args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$mock,'-PromptFile','{promptFile}')
        mode = 'prompt-file'
    }) -Force
    $cfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cfgPath -Encoding UTF8

    & $harness goal -Message 'Exercise the complete worker-review-validation state machine.'
    & $harness task add -TaskId smoke-task -Title 'Smoke task' -Instruction 'Return a successful bounded result.' -Accept 'Mock validator passes' -Retrieval 'evidence.txt'
    & $harness run -TaskId smoke-task

    $task = Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\tasks\smoke-task.json') | ConvertFrom-Json
    if ($task.status -ne 'complete') { throw "Expected complete, got $($task.status)" }
    if (-not $task.latestRunId) { throw 'Missing worker receipt id.' }
    if (-not $task.latestCritiqueId) { throw 'Missing critic receipt id.' }
    if (-not $task.latestValidationId) { throw 'Missing validator receipt id.' }
    Write-Host 'PASS: worker -> critic -> validator -> complete'
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

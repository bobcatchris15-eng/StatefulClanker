<# Periodic project-review tests: interval trigger, evidence, and the failure path
   (hold, remediation task, refusal of further dispatch, release).

   The per-task validator judges one task against one compiled context.
   This layer is the only thing that looks at the project as a whole, and it is the
   only thing that can stop the queue, so the failure path matters more than the
   happy path. #>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$harness = Join-Path $repo 'StatefulClanker.ps1'
$passProvider = Join-Path $PSScriptRoot 'MockProvider.cmd'
$failProvider = Join-Path $PSScriptRoot 'FailingProvider.cmd'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "PROJECT REVIEW TEST FAILED: $Message" }
}
function Get-PwshPath {
    $self = (Get-Process -Id $PID).Path
    if (-not [string]::IsNullOrWhiteSpace($self)) { return $self }
    return (Get-Command pwsh).Source
}
$pwshPath = Get-PwshPath

function Set-Reviewer([string]$Project, [string]$Cmd) {
    $cfgPath = Join-Path $Project '.statefulclanker\config.json'
    $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    $cfg.providers | Add-Member -NotePropertyName rev -NotePropertyValue ([pscustomobject]@{
            command = 'cmd.exe'; args = @('/d', '/c', $Cmd, '{promptFile}'); mode = 'prompt-file'
        }) -Force
    $cfg.criticProvider = 'rev'; $cfg.validatorProvider = 'rev'
    $cfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cfgPath -Encoding UTF8
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('sc-review-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
Push-Location $temp
try {
    'seed' | Set-Content -LiteralPath 'seed.txt' -Encoding UTF8
    & $pwshPath -NoProfile -File $harness init | Out-Null

    $cfgPath = Join-Path $temp '.statefulclanker\config.json'
    $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    $cfg.defaultProvider = 'mock'; $cfg.criticProvider = 'mock'; $cfg.validatorProvider = 'mock'
    $cfg | Add-Member -NotePropertyName projectReviewEveryTasks -NotePropertyValue 2 -Force
    # A command that fails, so the reviewer has real evidence rather than a guess.
    $cfg | Add-Member -NotePropertyName projectValidateCommand -NotePropertyValue 'echo TESTS FAILED: 3 assertions && exit 1' -Force
    $cfg.providers | Add-Member -NotePropertyName mock -NotePropertyValue ([pscustomobject]@{
            command = 'cmd.exe'; args = @('/d', '/c', $passProvider, '{promptFile}'); mode = 'prompt-file'
        }) -Force
    $cfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cfgPath -Encoding UTF8

    foreach ($n in 1..2) {
        & $pwshPath -NoProfile -File $harness task add -TaskId "r$n" -Title "Task $n" `
            -Instruction 'Return a successful bounded result.' -Accept 'mock passes' -Retrieval 'seed.txt' | Out-Null
    }

    Write-Host '  REVIEW 1: does not fire before the interval'
    $out1 = & $pwshPath -NoProfile -File $harness run -TaskId r1 2>&1 | Out-String
    Assert-True ($out1 -notmatch 'Project review') "Review fired after 1 task with interval 2. Output:`n$out1"

    Write-Host '  REVIEW 2: fires on the interval and runs the validate command'
    $out2 = & $pwshPath -NoProfile -File $harness run -TaskId r2 2>&1 | Out-String
    Assert-True ($out2 -match 'Project review') "Review did not fire on the interval. Output:`n$out2"
    Assert-True ($out2 -match 'projectValidateCommand: exit 1') "The validate command was not run. Output:`n$out2"

    Write-Host '  REVIEW 3: the failing command reaches the reviewer as evidence'
    $reviewDir = Join-Path $temp '.statefulclanker\reviews'
    $latest = Get-ChildItem -LiteralPath $reviewDir -Filter '*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $record = Get-Content -Raw -LiteralPath $latest.FullName | ConvertFrom-Json
    Assert-True ([bool]$record.projectValidate.configured) 'The review did not record the validate command.'
    Assert-True ($record.projectValidate.exitCode -eq 1) "Expected exit 1, got $($record.projectValidate.exitCode)."
    Assert-True ($record.packet.projectValidate.output -match 'TESTS FAILED') 'The command output did not reach the reviewer packet.'
    Assert-True (@($record.packet.recentlyCompleted).Count -ge 2) 'Completed tasks were not carried into the packet.'
    Assert-True (@($record.stages).Count -eq 2) 'Expected both a project critic and a project validator stage.'

    Write-Host '  REVIEW 4: the counter resets, so it does not re-fire immediately'
    $state = Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\state.json') | ConvertFrom-Json
    Assert-True ([int]$state.tasksSinceProjectReview -eq 0) "Counter should reset after a review, got $($state.tasksSinceProjectReview)."

    Write-Host '  REVIEW 5: a FAIL halts dispatch and queues a human-gated remediation task'
    Set-Reviewer $temp $failProvider
    $out3 = & $pwshPath -NoProfile -File $harness review run 2>&1 | Out-String
    Assert-True ($out3 -match 'FAILED') "The failing reviewer should fail the review. Output:`n$out3"
    Assert-True ($out3 -match 'remediation task') "A remediation task should be queued. Output:`n$out3"

    $tasks = @(Get-ChildItem -LiteralPath (Join-Path $temp '.statefulclanker\tasks') -Filter '*.json' |
        ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json })
    $remediation = @($tasks | Where-Object { $_.id -like 'remediate-*' })
    Assert-True ($remediation.Count -eq 1) "Expected exactly one remediation task, got $($remediation.Count)."
    # It must not run itself: the harness generated it, so a human reads it first.
    Assert-True ([bool]$remediation[0].humanGate) 'The remediation task MUST be human-gated.'
    Assert-True ($remediation[0].instruction -match 'REVIEW FINDINGS') 'The remediation task should carry the findings.'

    Write-Host '  REVIEW 6: held dispatch is refused with an actionable message'
    $held = & $pwshPath -NoProfile -File $harness hold status 2>&1 | Out-String
    Assert-True ($held -match 'HELD') "hold status should report the hold. Got:`n$held"
    & $pwshPath -NoProfile -File $harness task add -TaskId r3 -Title 'Task 3' `
        -Instruction 'Return a successful bounded result.' -Accept 'mock passes' -Retrieval 'seed.txt' | Out-Null
    $oldPref=$ErrorActionPreference; try{$ErrorActionPreference='Continue'; $blocked = & $pwshPath -NoProfile -File $harness run -TaskId r3 2>&1 | Out-String}finally{$ErrorActionPreference=$oldPref}
    Assert-True ($blocked -match 'on hold') "Dispatch must be refused while held. Got:`n$blocked"
    Assert-True ($blocked -match 'hold clear') 'The refusal should say how to release it.'

    Write-Host '  REVIEW 7: clearing the hold is recorded and restores dispatch'
    & $pwshPath -NoProfile -File $harness hold clear | Out-Null
    $after = & $pwshPath -NoProfile -File $harness hold status 2>&1 | Out-String
    Assert-True ($after -match 'Not held') "hold clear should release. Got:`n$after"
    $events = @(Get-Content -LiteralPath (Join-Path $temp '.statefulclanker\events.jsonl') |
        Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($events | Where-Object { $_.type -eq 'project.review.failed' }).Count -ge 1) 'The failed review was not recorded as an event.'
    Assert-True (@($events | Where-Object { $_.type -eq 'project.hold.cleared' }).Count -ge 1) 'Clearing the hold was not recorded.'

    Write-Host '  REVIEW 8: interval 0 disables the periodic review'
    $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    $cfg.projectReviewEveryTasks = 0
    $cfg.criticProvider = 'mock'; $cfg.validatorProvider = 'mock'
    $cfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    $out4 = & $pwshPath -NoProfile -File $harness run -TaskId r3 2>&1 | Out-String
    Assert-True ($out4 -notmatch 'Project review') "Interval 0 must disable the review. Output:`n$out4"

    Write-Host 'PASS: project review (interval, evidence, hold, remediation, release, disable)'
} finally {
    Pop-Location
    Set-Location $repo
    Remove-Item -Recurse -Force -LiteralPath $temp -ErrorAction SilentlyContinue
}

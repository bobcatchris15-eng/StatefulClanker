<# Parallel execution tests: worktree isolation, shared-state safety, merging, and
   what happens when two workers touch the same file.

   Uses tests/WritingProvider.cmd so the commit and merge paths are actually
   exercised; a provider that changes nothing cannot prove a merge works. #>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$harness = Join-Path $repo 'StatefulClanker.ps1'
$writer = Join-Path $PSScriptRoot 'WritingProvider.cmd'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "CONCURRENCY TEST FAILED: $Message" }
}
function Get-PwshPath {
    $self = (Get-Process -Id $PID).Path
    if (-not [string]::IsNullOrWhiteSpace($self)) { return $self }
    return (Get-Command pwsh).Source
}
$pwshPath = Get-PwshPath

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host '  CONC: SKIPPED - git is not on PATH (worktree isolation needs it).'
    return
}

function New-TestProject([string]$Path, [string]$TargetFile, [int]$TaskCount, [int]$MaxConcurrent = 3) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Push-Location $Path
    try {
        & git init -q .
        & git config user.email 'test@statefulclanker.local'
        & git config user.name 'StatefulClanker Test'
        'seed' | Set-Content -LiteralPath 'seed.txt' -Encoding UTF8
        'line' | Set-Content -LiteralPath 'shared.txt' -Encoding UTF8
        '.statefulclanker/' | Set-Content -LiteralPath '.gitignore' -Encoding UTF8

        & $pwshPath -NoProfile -File $harness init | Out-Null
        $cfgPath = Join-Path $Path '.statefulclanker\config.json'
        $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
        $cfg.defaultProvider = 'w'; $cfg.criticProvider = 'ro'; $cfg.validatorProvider = 'ro'
        $cfg | Add-Member -NotePropertyName maxConcurrent -NotePropertyValue $MaxConcurrent -Force
        $cfg.providers | Add-Member -NotePropertyName w -NotePropertyValue ([pscustomobject]@{
                command = 'cmd.exe'; args = @('/d', '/c', $writer, '{taskId}', $TargetFile); mode = 'inline'
            }) -Force
        $cfg.providers | Add-Member -NotePropertyName ro -NotePropertyValue ([pscustomobject]@{
                command = 'cmd.exe'; args = @('/d', '/c', (Join-Path $PSScriptRoot 'MockProvider.cmd'), '{promptFile}'); mode = 'prompt-file'
            }) -Force
        $cfg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cfgPath -Encoding UTF8

        for ($i = 1; $i -le $TaskCount; $i++) {
            & $pwshPath -NoProfile -File $harness task add -TaskId "t$i" -Title "Task $i" `
                -Instruction 'Do the bounded work.' -Accept 'provider passes' -Retrieval 'seed.txt' | Out-Null
        }
        & git add -A
        & git commit -q -m 'seed'
    } finally { Pop-Location }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('sc-conc-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    Write-Host '  CONC 1: three cycles run concurrently and all reach complete'
    $p1 = Join-Path $root 'clean'
    New-TestProject $p1 'out-{taskId}.txt' 3
    Push-Location $p1
    try {
        $out = & $pwshPath -NoProfile -File $harness run -Parallel 3 2>&1 | Out-String
        Assert-True ($out -match 'Dispatching 3') "Expected 3 dispatched. Output:`n$out"

        $tasks = @(Get-ChildItem -LiteralPath (Join-Path $p1 '.statefulclanker\tasks') -Filter '*.json' |
            ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json })
        Assert-True ($tasks.Count -eq 3) "Expected 3 tasks, got $($tasks.Count)."
        Assert-True (@($tasks | Where-Object { $_.status -eq 'complete' }).Count -eq 3) `
            "All 3 should be complete, got: $(($tasks | ForEach-Object { "$($_.id)=$($_.status)" }) -join ', '). Scheduler output:`n$out"

        foreach ($t in $tasks) {
            Assert-True ([bool]$t.latestRunId) "$($t.id) has no worker receipt."
            Assert-True ([bool]$t.latestProposalId) "$($t.id) has no proposal."
        }
        $state = Get-Content -Raw -LiteralPath (Join-Path $p1 '.statefulclanker\state.json') | ConvertFrom-Json
        Assert-True ($null -ne $state -and [bool]$state.projectId) 'state.json was corrupted by concurrent writes.'

        Write-Host '  CONC 2: non-conflicting work merges into the main tree'
        Assert-True ($out -match 'MERGED\s+t1') "t1 should have merged. Output:`n$out"
        foreach ($i in 1..3) {
            Assert-True (Test-Path -LiteralPath (Join-Path $p1 "out-t$i.txt")) "out-t$i.txt did not reach the main tree."
        }
        $status = & git status --porcelain | Out-String
        Assert-True ([string]::IsNullOrWhiteSpace($status)) "Main tree should be clean after merging. Got:`n$status"

        Write-Host '  CONC 3: worktrees are cleaned up'
        $wt = Join-Path $p1 '.statefulclanker\worktrees'
        $left = if (Test-Path -LiteralPath $wt) { @(Get-ChildItem -LiteralPath $wt -Directory) } else { @() }
        Assert-True ($left.Count -eq 0) "Worktrees left behind: $(($left | ForEach-Object { $_.Name }) -join ', ')"
    } finally { Pop-Location }

    Write-Host '  CONC 4: colliding writes - one merges, the other is held, tree stays clean'
    $p2 = Join-Path $root 'conflict'
    New-TestProject $p2 'shared.txt' 2 2
    Push-Location $p2
    try {
        $out = & $pwshPath -NoProfile -File $harness run -Parallel 2 2>&1 | Out-String
        Assert-True ($out -match 'MERGED') "One task should have merged. Output:`n$out"
        Assert-True ($out -match 'merge conflict') "The second should report a merge conflict. Output:`n$out"

        $shared = Get-Content -Raw -LiteralPath (Join-Path $p2 'shared.txt')
        Assert-True ($shared -notmatch '<<<<<<<') 'Conflict markers were left in the main tree.'
        $status = & git status --porcelain | Out-String
        Assert-True ([string]::IsNullOrWhiteSpace($status)) "Main tree must be clean after an aborted merge. Got:`n$status"

        $branches = (& git branch) -join ' '
        Assert-True ($branches -match 'sc/task/t2' -or $branches -match 'sc/task/t1') 'The conflicting work should be preserved on its branch.'

        $tasks = @(Get-ChildItem -LiteralPath (Join-Path $p2 '.statefulclanker\tasks') -Filter '*.json' |
            ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json })
        $held = @($tasks | Where-Object { $_.status -eq 'needs_rework' })
        Assert-True ($held.Count -eq 1) "Exactly one task should be needs_rework, got $($held.Count)."
        Assert-True ($held[0].blockReason -match 'onflict') 'The held task should say why it was held.'
    } finally { Pop-Location }

    Write-Host '  CONC 5: refuses to run parallel where it would be unsafe'
    $p3 = Join-Path $root 'notgit'
    New-Item -ItemType Directory -Force -Path $p3 | Out-Null
    Push-Location $p3
    try {
        & $pwshPath -NoProfile -File $harness init | Out-Null
        $out = & $pwshPath -NoProfile -File $harness run -Parallel 2 2>&1 | Out-String
        Assert-True ($out -match 'git repository') "A non-git project must be refused with a clear reason. Got:`n$out"
    } finally { Pop-Location }

    Push-Location $p1
    try {
        'uncommitted' | Set-Content -LiteralPath (Join-Path $p1 'dirty.txt') -Encoding UTF8
        & $pwshPath -NoProfile -File $harness task add -TaskId 'extra' -Title 'Extra' `
            -Instruction 'Do work.' -Accept 'passes' -Retrieval 'seed.txt' | Out-Null
        $out = & $pwshPath -NoProfile -File $harness run -Parallel 2 2>&1 | Out-String
        Assert-True ($out -match 'uncommitted changes') "A dirty tree must be refused. Got:`n$out"
    } finally { Pop-Location }

    Write-Host 'PASS: concurrency (parallel dispatch, shared state, merge, conflict hold, safety refusals)'
} finally {
    Set-Location $repo
    foreach ($proj in @('clean', 'conflict')) {
        $p = Join-Path $root $proj
        if (Test-Path -LiteralPath $p) { & git -C $p worktree prune 2>$null | Out-Null }
    }
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}

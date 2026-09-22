<# Scheduler recovery regressions: route cooldown recovery, orphan cleanup, and operator diagnostics. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$harness=Join-Path $repo 'StatefulClanker.ps1'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "SCHEDULER RECOVERY TEST FAILED: $Message"}}
$pwshPath=(Get-Process -Id $PID).Path
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-scheduler-recovery-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try {
    Push-Location $temp
    & git init -q .; & git config user.email 'test@statefulclanker.local'; & git config user.name 'StatefulClanker Test'
    'seed'|Set-Content seed.txt -Encoding UTF8; '.statefulclanker/'|Set-Content .gitignore -Encoding UTF8
    & $pwshPath -NoProfile -File $harness init|Out-Null
    & $pwshPath -NoProfile -File $harness task add -TaskId route-expired -Title 'Route expired' -Instruction 'Work.' -Accept 'passes'|Out-Null
    & $pwshPath -NoProfile -File $harness task add -TaskId human-blocked -Title 'Human block' -Instruction 'Wait.' -Accept 'approval' -HumanGate|Out-Null
    & git add -A; & git commit -q -m seed

    Write-Host '  SCHED 1: expired routing-only blocks become dispatchable again'
    $routePath=Join-Path $temp '.statefulclanker\tasks\route-expired.json'
    $route=Get-Content -Raw $routePath|ConvertFrom-Json;$route.status='blocked';$route.blockReason='All healthy endpoints are cooling down.';$route|Add-Member routingNotBefore ([datetimeoffset]::UtcNow.AddSeconds(-5).ToString('o')) -Force;$route|ConvertTo-Json -Depth 20|Set-Content $routePath -Encoding UTF8
    & $pwshPath -NoProfile -File $harness task list|Out-Null
    $route=Get-Content -Raw $routePath|ConvertFrom-Json
    Assert-True ($route.status-eq'ready') 'An expired routing-only block did not return to ready.'
    Assert-True (-not $route.routingNotBefore) 'Expired routing cooldown was not cleared.'

    Write-Host '  SCHED 2: human gates remain blocked when routing cooldown expires'
    $humanPath=Join-Path $temp '.statefulclanker\tasks\human-blocked.json'
    $human=Get-Content -Raw $humanPath|ConvertFrom-Json;$human.status='blocked';$human.blockReason='Waiting for human approval.';$human|Add-Member routingNotBefore ([datetimeoffset]::UtcNow.AddSeconds(-5).ToString('o')) -Force;$human|ConvertTo-Json -Depth 20|Set-Content $humanPath -Encoding UTF8
    & $pwshPath -NoProfile -File $harness task list|Out-Null
    $human=Get-Content -Raw $humanPath|ConvertFrom-Json
    Assert-True ($human.status-eq'blocked') 'A human-gated task was incorrectly released by routing recovery.'

    Write-Host '  SCHED 3: supervisor reports deferred, dependency, and terminal queues distinctly'
    $route.status='ready';$route.blockReason=$null;$route.routingNotBefore=[datetimeoffset]::UtcNow.AddMinutes(2).ToString('o');$route|ConvertTo-Json -Depth 20|Set-Content $routePath -Encoding UTF8
    $supervisorLog=Join-Path $temp '.statefulclanker\scheduler-recovery-supervisor.log'
    $supervisor=Start-Process -FilePath $pwshPath -ArgumentList "-NoProfile -NonInteractive -File `"$harness`" autofill run -IntervalSeconds 1" -WorkingDirectory $temp -RedirectStandardOutput $supervisorLog -RedirectStandardError "$supervisorLog.err" -WindowStyle Hidden -PassThru
    $statusPath=Join-Path $temp '.statefulclanker\autofill\supervisor.json';$deadline=(Get-Date).AddSeconds(8);$status=$null
    do { Start-Sleep -Milliseconds 200;try{if(Test-Path $statusPath){$status=Get-Content -Raw $statusPath|ConvertFrom-Json}}catch{} } while(($null-eq$status-or[string]$status.state-ne'blocked')-and(Get-Date)-lt$deadline)
    Assert-True ([string]$status.state-eq'blocked') 'Supervisor did not surface terminal-stalled work while a route cooldown is pending.'
    Assert-True ([string]$status.blockReason-match'routing-deferred') 'Supervisor did not identify routing-deferred work.'
    Assert-True ([string]$status.blockReason-match'terminal-stalled') 'Supervisor did not distinguish terminal-stalled work.'
    & $pwshPath -NoProfile -File $harness autofill stop|Out-Null;if(-not$supervisor.WaitForExit(10000)){$supervisor.Kill()};$supervisor.Dispose()

    Write-Host '  SCHED 4: orphan recovery closes its matching worker session'
    $route.status='running';$route|Add-Member activeWorkerSessionId 'orphan-session' -Force;$route|Add-Member latestWorkerSessionId 'orphan-session' -Force;$route.updatedAt=[datetimeoffset]::UtcNow.AddMinutes(-2).ToString('o');$route|ConvertTo-Json -Depth 20|Set-Content $routePath -Encoding UTF8
    $session=[ordered]@{id='orphan-session';taskId='route-expired';status='active';updatedAt=[datetimeoffset]::UtcNow.ToString('o')}
    $session|ConvertTo-Json -Depth 20|Set-Content (Join-Path $temp '.statefulclanker\worker-sessions\orphan-session.json') -Encoding UTF8
    & $pwshPath -NoProfile -File $harness task list|Out-Null
    $route=Get-Content -Raw $routePath|ConvertFrom-Json;$session=Get-Content -Raw (Join-Path $temp '.statefulclanker\worker-sessions\orphan-session.json')|ConvertFrom-Json
    Assert-True ($route.status-eq'needs_rework') 'Orphaned running task was not recovered.'
    Assert-True (-not $route.activeWorkerSessionId) 'Orphan recovery left activeWorkerSessionId pinned.'
    Assert-True ($session.status-eq'orphaned') 'Orphan recovery did not close the worker session.'

    Write-Host '  SCHED 5: dirty-worktree diagnostics bound paths and give recovery advice'
    1..7|ForEach-Object { "x$_"|Set-Content ("dirty$_.txt") -Encoding UTF8 }
    $old=$ErrorActionPreference;try{$ErrorActionPreference='Continue';$output=& $pwshPath -NoProfile -File $harness run -Parallel 1 2>&1|Out-String}finally{$ErrorActionPreference=$old}
    Assert-True ($output-match'dirty1\.txt') "Dirty-worktree diagnostic omitted a path. Output: $output"
    Assert-True ($output-match'\(\+2 more\)') "Dirty-worktree diagnostic was not bounded. Output: $output"
    Assert-True ($output-match'commit, stash, or revert') "Dirty-worktree diagnostic omitted recovery advice. Output: $output"
    Write-Host 'PASS: scheduler recovery releases only expired routing blocks, closes orphan sessions, and reports actionable dirty-tree diagnostics.'
} finally { Pop-Location -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }

$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "RETRIEVAL HEALTH TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-retrieval-'+[guid]::NewGuid().ToString('N'))
$stateRoot=Join-Path $temp 'main'
$stateDir=Join-Path $stateRoot '.statefulclanker'
$workRoot=Join-Path $stateDir 'worktrees\task-1'
New-Item -ItemType Directory -Force -Path (Join-Path $workRoot 'src')|Out-Null
try{
    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Signals.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Context.ps1')
    New-Item -ItemType Directory -Force -Path $stateDir|Out-Null
    Write-SCJson (Join-Path $stateDir 'state.json') ([ordered]@{schemaVersion=4;projectId='test'})
    Write-SCJson (Join-Path $stateDir 'config.json') ([ordered]@{workingSetBudgetChars=24000;maxFileChars=8000})
    'legitimate worktree file'|Set-Content -LiteralPath (Join-Path $workRoot 'src\allowed.txt') -Encoding UTF8
    'control state'|Set-Content -LiteralPath (Join-Path $stateDir 'secret.txt') -Encoding UTF8
    Set-SCRoots $workRoot $stateRoot

    $allowed=Join-Path $workRoot 'src\allowed.txt'
    $secret=Join-Path $stateDir 'secret.txt'
    $task=[pscustomobject]@{id='t-1';title='retrieve';instruction='read';acceptance=@();dependsOn=@();relations=@();retrieval=@($allowed,$secret);evidence=@();sources=@();provider=$null;role='worker';humanGate=$false}
    Write-SCJson (Get-SCPath 'tasks/t-1.json') $task
    $packet=Get-SCRetrievalPacket $task
    Assert-True (@($packet.items).Count-eq1) 'legitimate worktree file was not the only included item'
    Assert-True ([string]$packet.items[0].path-eq'src\allowed.txt') 'worktree file was not projected relative to work root'
    Assert-True ([int]$packet.health.excludedByBoundaryCount-eq1) 'control-state exclusion was not counted'
    Assert-True (-not[bool]$packet.health.allUsefulRetrievalCollapsed) 'mixed retrieval incorrectly reported collapse'

    $task2=[pscustomobject]@{id='t-2';title='blocked';instruction='read';acceptance=@();dependsOn=@();relations=@();retrieval=@($secret);evidence=@();sources=@();provider=$null;role='worker';humanGate=$false}
    Write-SCJson (Get-SCPath 'tasks/t-2.json') $task2
    $packet2=Get-SCRetrievalPacket $task2
    Assert-True ([bool]$packet2.health.allUsefulRetrievalCollapsed) 'fully excluded retrieval did not report collapse'
    $signals=@(Get-SCSignalsForAudience task 't-2' 'current_attempt')
    Assert-True (@($signals|Where-Object{$_.kind-eq'retrieval_anomaly'}).Count-eq1) 'retrieval anomaly was not addressed to the task'
    Write-Host 'PASS: worktree retrieval is allowed inside state-root worktrees while control state stays excluded.'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}

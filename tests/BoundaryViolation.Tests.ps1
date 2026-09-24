$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "BOUNDARY VIOLATION TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-boundary-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $temp|Out-Null
$oldLocal=$env:LOCALAPPDATA;$env:LOCALAPPDATA=Join-Path $temp 'local';New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA|Out-Null
try {
    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1');$script:StatefulClankerHome=$repo;Set-SCRoots $temp $temp
    $script:capturedEvents=@()
    function Add-SCEvent { param($Type,$Message,$Data) $script:capturedEvents+=,[pscustomobject]@{type=$Type;message=$Message;data=$Data} }
    function Test-SCGitAvailable { return $false }
    Initialize-SC | Out-Null

    . (Join-Path $repo 'lib\StatefulClanker.WorkerPolicy.ps1')
    function Invoke-SCProvider { throw 'CLI provider path not expected.' }
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')

    function New-TestTask([string]$Id) {
        $task=New-SCTaskObject $Id 'Boundary test task' 'instruction' @('a') @() @() @() @() $null 'worker' $false
        Save-SCTask $task
        return Get-SCTask $Id
    }

    # --- Detection: read escape (Resolve-SCWorkerToolPath) emits worker.boundary_violation, still blocks ---
    $script:capturedEvents=@()
    $task1=New-TestTask 't-read'
    $threw=$false
    try{ [void](Resolve-SCWorkerToolPath 'C:\Windows\win.ini' $task1 'read_file' -Stage 'worker' -WorkerSessionId 'sess-1') } catch { $threw=$true }
    Assert-True $threw 'Path escape must still throw and block access.'
    $violation=@($script:capturedEvents|Where-Object{$_.type-eq'worker.boundary_violation'})
    Assert-True ($violation.Count-eq1) 'Expected exactly one worker.boundary_violation event.'
    Assert-True ($violation[0].data.taskId-eq't-read') 'Violation event missing taskId.'
    Assert-True ($violation[0].data.sessionId-eq'sess-1') 'Violation event missing sessionId.'
    Assert-True ($violation[0].data.tool-eq'read_file') 'Violation event missing tool name.'
    Assert-True ($violation[0].data.kind-eq'read') 'Read escape must be tagged kind=read.'
    Assert-True (($violation[0].data.attempted)-match'win\.ini') 'Violation event missing attempted path.'
    Assert-True ((Get-SCTask 't-read').status-eq'pending') 'Single violation below threshold must not change task status.'

    # --- Detection: control-state mutation (Assert-SCWorkerMutablePath) ---
    $script:capturedEvents=@()
    $task2=New-TestTask 't-control'
    $ctrlPath=Join-Path (Get-SCRoot) '.statefulclanker\config.json'
    $threw=$false
    try{ Assert-SCWorkerMutablePath $ctrlPath $task2 'write_file' 'worker' 'sess-2' } catch { $threw=$true }
    Assert-True $threw 'Control-state mutation must still throw and block.'
    $violation=@($script:capturedEvents|Where-Object{$_.type-eq'worker.boundary_violation'})
    Assert-True ($violation.Count-eq1) 'Expected exactly one control-state violation event.'
    Assert-True ($violation[0].data.kind-eq'control-state') 'Control-state mutation must be tagged kind=control-state.'

    # --- Detection: run_command escape (Assert-SCWorkerCommandSafe) ---
    $script:capturedEvents=@()
    $task3=New-TestTask 't-command'
    $threw=$false
    try{ Assert-SCWorkerCommandSafe 'Get-Content C:\Windows\win.ini' $task3 'worker' 'sess-3' } catch { $threw=$true }
    Assert-True $threw 'run_command escape must still throw and block.'
    $violation=@($script:capturedEvents|Where-Object{$_.type-eq'worker.boundary_violation'})
    Assert-True ($violation.Count-eq1) 'Expected exactly one run_command violation event.'
    Assert-True ($violation[0].data.kind-eq'command') 'run_command escape must be tagged kind=command.'

    # --- Escalation at default threshold (3) ---
    $script:capturedEvents=@()
    $task4=New-TestTask 't-escalate'
    for($i=1;$i-le2;$i++){
        try{ [void](Resolve-SCWorkerToolPath 'C:\Windows\win.ini' $task4 'read_file' -Stage 'worker' -WorkerSessionId 'sess-4') } catch {}
    }
    Assert-True ((Get-SCTask 't-escalate').status-eq'pending') 'Task must remain pending below the violation threshold.'
    $escalated=$false
    try{ [void](Resolve-SCWorkerToolPath 'C:\Windows\win.ini' $task4 'read_file' -Stage 'worker' -WorkerSessionId 'sess-4') } catch { if($_.Exception.Message-match'BOUNDARY_ESCALATED'){$escalated=$true} }
    Assert-True $escalated 'Third violation must escalate (BOUNDARY_ESCALATED).'
    $escEvent=@($script:capturedEvents|Where-Object{$_.type-eq'worker.boundary_escalated'})
    Assert-True ($escEvent.Count-eq1) 'Expected exactly one worker.boundary_escalated event.'
    $reworked=Get-SCTask 't-escalate'
    Assert-True ($reworked.status-eq'needs_rework') 'Escalated task must be marked needs_rework.'
    Assert-True (-not[string]::IsNullOrWhiteSpace($reworked.blockReason)) 'Escalated task must have a blockReason naming the boundary violations.'
    Assert-True ($reworked.blockReason-match'(?i)boundary') 'blockReason must name boundary violations.'

    # --- Config override honoured (workerBoundaryViolationLimit=1) ---
    $cfgPath=Get-SCPath 'config.json'
    $cfg=Get-Content -Raw -LiteralPath $cfgPath|ConvertFrom-Json
    Add-Member -InputObject $cfg -MemberType NoteProperty -Name 'workerBoundaryViolationLimit' -Value 1 -Force
    $cfg|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $cfgPath -Encoding UTF8
    Assert-True ((Get-SCWorkerBoundaryViolationLimit)-eq1) 'Config override for workerBoundaryViolationLimit was not honoured.'

    $script:capturedEvents=@()
    $task5=New-TestTask 't-override'
    $escalated=$false
    try{ [void](Resolve-SCWorkerToolPath 'C:\Windows\win.ini' $task5 'read_file' -Stage 'worker' -WorkerSessionId 'sess-5') } catch { if($_.Exception.Message-match'BOUNDARY_ESCALATED'){$escalated=$true} }
    Assert-True $escalated 'With limit=1 the first violation must escalate immediately.'
    Assert-True ((Get-SCTask 't-override').status-eq'needs_rework') 'Task must be needs_rework after single-violation escalation under override.'

    Write-Host 'PASS: boundary violations are logged, still blocked, and escalate at threshold (config-overridable).'
} finally {$env:LOCALAPPDATA=$oldLocal;Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}

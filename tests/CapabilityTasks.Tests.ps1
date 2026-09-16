$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot;$harness=Join-Path $repo 'StatefulClanker.ps1'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "CAPABILITY TASK TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-cap-task-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $temp|Out-Null
try {
    Push-Location $temp;& $harness init|Out-Null
    $plan=@'
SCPLAN 1
plan capability-authoring
summary Verify capability profile and task-local narrowing persist.
task t-cap
size small
title bounded research edit
instruction Inspect intent and make one bounded change.
capability-profile research-readonly
tool-allow builtin.read_file
tool-allow intent.*
tool-deny builtin.run_command
accept task policy is persisted
end
'@
    $planPath=Join-Path $temp 'cap.scplan';$plan|Set-Content -LiteralPath $planPath -Encoding UTF8;& $harness plan import -Path $planPath|Out-Null
    $task=Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\tasks\t-cap.json')|ConvertFrom-Json
    Assert-True ([string]$task.capabilityProfile-eq'research-readonly') 'SCPLAN capability-profile was not persisted.'
    Assert-True (@($task.toolPolicy.allow)-contains'builtin.read_file') 'SCPLAN tool-allow was not persisted.'
    Assert-True (@($task.toolPolicy.deny)-contains'builtin.run_command') 'SCPLAN tool-deny was not persisted.'

    & $harness task add -TaskId t-cli -Title 'CLI capability task' -Instruction 'Exercise CLI task authoring.' -CapabilityProfile coding -ToolAllow 'builtin.read_file' -ToolDeny 'mcp.*'|Out-Null
    $cliTask=Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\tasks\t-cli.json')|ConvertFrom-Json
    Assert-True ([string]$cliTask.capabilityProfile-eq'coding') 'CLI capability profile was not persisted.'
    Assert-True (@($cliTask.toolPolicy.deny)-contains'mcp.*') 'CLI task-local deny was not persisted.'

    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1');. (Join-Path $repo 'lib\StatefulClanker.Context.ps1');. (Join-Path $repo 'lib\StatefulClanker.Plan.ps1');. (Join-Path $repo 'lib\StatefulClanker.CapabilityTasks.ps1');Set-SCRoots $temp $temp
    $before=Get-SCTaskDefinitionHash $task;$task.toolPolicy.deny=@('builtin.run_command','mcp.*');$after=Get-SCTaskDefinitionHash $task
    Assert-True ($before-ne$after) 'Changing task-local capability policy must change the task definition hash.'
    Write-Host 'PASS: SCPLAN/CLI capability profiles and task-local narrowing are first-class task semantics.'
} finally {if((Get-Location).Path-eq$temp){Pop-Location};Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}

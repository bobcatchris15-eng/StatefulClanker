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
output-kind research
title bounded research edit
instruction Inspect intent and make one bounded change.
capability-profile research-readonly
tool-allow builtin.read_file
tool-allow intent.*
tool-deny builtin.run_command
accept task policy is persisted
check pwsh -NoProfile -Command "exit 0"
judge documentation wording preserves the intended operator meaning
end
'@
    $planPath=Join-Path $temp 'cap.scplan';$plan|Set-Content -LiteralPath $planPath -Encoding UTF8;& $harness plan import -Path $planPath|Out-Null
    $task=Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\tasks\t-cap.json')|ConvertFrom-Json
    Assert-True ([string]$task.capabilityProfile-eq'research-readonly') 'SCPLAN capability-profile was not persisted.'
    Assert-True (@($task.toolPolicy.allow)-contains'builtin.read_file') 'SCPLAN tool-allow was not persisted.'
    Assert-True (@($task.toolPolicy.deny)-contains'builtin.run_command') 'SCPLAN tool-deny was not persisted.'
    Assert-True ([string]$task.outputKind-eq'research') 'SCPLAN output-kind was not persisted.'
    Assert-True (@($task.checks).Count-eq1 -and [string]$task.checks[0]-match'pwsh') "SCPLAN mechanical check was not persisted: $($task.checks|ConvertTo-Json -Compress)."
    Assert-True (@($task.semanticAcceptance).Count-eq1 -and [string]$task.semanticAcceptance[0]-match'documentation wording') 'SCPLAN semantic judge criterion was not persisted.'

    Write-Host '  CAPABILITY TASK: empty acceptance execution lists persist as arrays, not null'
    $plan2=@'
SCPLAN 1
plan empty-acceptance-lists
task t-empty
title no explicit validation execution fields
instruction Persist an ordinary task with no check or judge lines.
accept task persists
end
'@
    $plan2Path=Join-Path $temp 'empty.scplan';$plan2|Set-Content -LiteralPath $plan2Path -Encoding UTF8;& $harness plan import -Path $plan2Path|Out-Null
    $emptyTask=Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\tasks\t-empty.json')|ConvertFrom-Json
    Assert-True ($null-ne$emptyTask.checks) 'Imported task checks collapsed to JSON null.'
    Assert-True ($null-ne$emptyTask.semanticAcceptance) 'Imported task semanticAcceptance collapsed to JSON null.'
    Assert-True (@($emptyTask.checks).Count-eq0) 'Imported task checks should be an empty array.'
    Assert-True (@($emptyTask.semanticAcceptance).Count-eq0) 'Imported task semanticAcceptance should be an empty array.'

    & $harness task add -TaskId t-cli -Title 'CLI capability task' -Instruction 'Exercise CLI task authoring.' -OutputKind diagnosis -CapabilityProfile coding -ToolAllow 'builtin.read_file' -ToolDeny 'mcp.*' -Check 'cmd /d /c exit 0' -Judge 'semantic criterion'|Out-Null
    $cliTask=Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\tasks\t-cli.json')|ConvertFrom-Json
    Assert-True ([string]$cliTask.capabilityProfile-eq'coding') 'CLI capability profile was not persisted.'
    Assert-True (@($cliTask.toolPolicy.deny)-contains'mcp.*') 'CLI task-local deny was not persisted.'
    Assert-True ([string]$cliTask.outputKind-eq'diagnosis') 'CLI OutputKind was not persisted.'
    Assert-True (@($cliTask.checks).Count-eq1) 'CLI mechanical check was not persisted.'
    Assert-True (@($cliTask.semanticAcceptance).Count-eq1) 'CLI semantic judge criterion was not persisted.'

    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1');. (Join-Path $repo 'lib\StatefulClanker.Context.ps1');. (Join-Path $repo 'lib\StatefulClanker.Plan.ps1');. (Join-Path $repo 'lib\StatefulClanker.CapabilityTasks.ps1');Set-SCRoots $temp $temp
    $before=Get-SCTaskDefinitionHash $task;$task.toolPolicy.deny=@('builtin.run_command','mcp.*');$after=Get-SCTaskDefinitionHash $task
    Assert-True ($before-ne$after) 'Changing task-local capability policy must change the task definition hash.'
    $beforeKind=$after;$task.outputKind='change';$afterKind=Get-SCTaskDefinitionHash $task
    Assert-True ($beforeKind-ne$afterKind) 'Changing output-kind must change the task definition hash.'
    $beforeAcceptance=$afterKind;$task.checks=@('cmd /c exit 0','cmd /c exit 1');$afterAcceptance=Get-SCTaskDefinitionHash $task
    Assert-True ($beforeAcceptance-ne$afterAcceptance) 'Changing mechanical acceptance checks must change the task definition hash.'
    Write-Host 'PASS: SCPLAN/CLI capability profiles and task-local narrowing are first-class task semantics.'
} finally {if((Get-Location).Path-eq$temp){Pop-Location};Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}

$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$harness=Join-Path $repo 'StatefulClanker.ps1'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-plan-startup-'+[guid]::NewGuid().ToString('N'))
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "PLAN STARTUP TEST FAILED: $Message"}}
New-Item -ItemType Directory -Path $temp|Out-Null
try {
    Push-Location $temp
    & $harness init|Out-Null
    $planPath=Join-Path $temp 'plan.json'
    $plan=@{name='Startup test';tasks=@(@{id='startup-one';title='One';instruction='Do one.';acceptance=@('done')},@{id='startup-two';title='Two';instruction='Do two.';acceptance=@('done')})}
    $plan|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $planPath
    & $harness task add -TaskId startup-two -Title Existing -Instruction 'Already exists.'|Out-Null
    $before=@(Get-ChildItem '.statefulclanker/plans' -Filter '*.json').Count
    $failed=$false
    try{& $harness plan import -Path $planPath|Out-Null}catch{$failed=$true}
    Assert-True $failed 'Duplicate task ID did not reject the import.'
    Assert-True (@(Get-ChildItem '.statefulclanker/plans' -Filter '*.json').Count -eq $before) 'Rejected import left an orphan plan.'
    Assert-True (-not(Test-Path '.statefulclanker/tasks/startup-one.json')) 'Rejected import partially wrote a task.'
    $state=Get-Content '.statefulclanker/state.json' -Raw|ConvertFrom-Json
    Assert-True (-not$state.activePlanId) 'Rejected import changed the active plan.'
    $plan.tasks[1].id='startup-three';$plan|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $planPath
    & $harness plan import -Path $planPath|Out-Null
    $state=Get-Content '.statefulclanker/state.json' -Raw|ConvertFrom-Json
    Assert-True ([bool]$state.activePlanId) 'Valid plan did not become active.'
    Assert-True (-not[bool]$state.planApproved) 'New plan bypassed required approval.'
    $dispatchError=''
    try{& $harness run -TaskId startup-one|Out-Null}catch{$dispatchError=$_.Exception.Message}
    Assert-True ($dispatchError -match 'requires human approval') 'Unapproved task passed the dispatch gate.'
    $task=Get-Content '.statefulclanker/tasks/startup-one.json' -Raw|ConvertFrom-Json
    Assert-True ($task.status -eq 'ready') 'Unapproved dispatch mutated task state.'
    & $harness plan approve|Out-Null
    $state=Get-Content '.statefulclanker/state.json' -Raw|ConvertFrom-Json
    Assert-True ([bool]$state.planApproved) 'Plan approval did not persist.'
    Write-Host 'PASS: duplicate import is all-or-nothing and a valid plan requires approval.'
} finally {
    Pop-Location -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

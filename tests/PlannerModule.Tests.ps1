$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$project=Join-Path $repo 'src\StatefulClanker.Planner\StatefulClanker.Planner.csproj'
$dotnet=(Get-Command dotnet -ErrorAction SilentlyContinue)
if(-not$dotnet){throw 'dotnet SDK is required for PlannerModule.Tests.ps1'}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-planner-module-'+[Guid]::NewGuid().ToString('N'))
$stateRoot=Join-Path $temp '.statefulclanker'
New-Item -ItemType Directory -Force -Path (Join-Path $stateRoot 'tasks')|Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stateRoot 'intent')|Out-Null

@{
    schemaVersion=4
    revision=7
    intentRevision=3
    activePlanId='plan-old'
}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $stateRoot 'state.json') -Encoding UTF8

@{
    schemaVersion=2
    revision=3
    objective='exercise planning module'
    requirements=@()
    constraints=@()
    invariants=@()
    nonGoals=@()
    decisions=@()
    preferences=@()
    openQuestions=@()
    successDefinition='planner state transitions work'
}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $stateRoot 'intent\contract.json') -Encoding UTF8

@{
    id='busy-task'
    status='running'
    title='Busy'
}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $stateRoot 'tasks\busy-task.json') -Encoding UTF8

function Invoke-Planner([string[]]$Args){
    $raw=& $dotnet.Source run --project $project -- @Args 2>&1|Out-String
    if($LASTEXITCODE-ne0){throw "Planner command failed: $raw"}
    $result=$raw|ConvertFrom-Json
    if(-not$result.ok){throw "Planner returned failure: $($result.error)"}
    return $result.data
}

try {
    Push-Location $temp
    try {
        $begin=Invoke-Planner @('begin','--project',$temp,'--reason','test replan','--execution-token-estimate','1000')
        if($begin.phase-ne'quiescing'){throw "Expected quiescing, got $($begin.phase)"}
        if($begin.budget.planningToExecutionRatio-ne1){throw 'Expected parity planning budget.'}
        if(-not(Test-Path (Join-Path $stateRoot 'planning\active.json'))){throw 'Missing planning barrier.'}
        if(-not(Test-Path (Join-Path $stateRoot 'autofill\pause.request'))){throw 'Planner did not pause Autofill.'}

        $blocked=Invoke-Planner @('settle','--project',$temp)
        if($blocked.settled){throw 'Settle succeeded while a task was running.'}
        if(@($blocked.busyTaskIds)-notcontains'busy-task'){throw 'Busy task was not reported.'}

        $task=Get-Content -Raw -LiteralPath (Join-Path $stateRoot 'tasks\busy-task.json')|ConvertFrom-Json
        $task.status='ready'
        $task|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $stateRoot 'tasks\busy-task.json') -Encoding UTF8

        $settled=Invoke-Planner @('settle','--project',$temp)
        if(-not$settled.settled-or$settled.phase-ne'planning'){throw 'Planner did not settle into planning.'}
        if(-not(Test-Path (Join-Path $stateRoot 'planning\sessions'))){throw 'Missing planner session directory.'}

        $question=Invoke-Planner @(
            'ask','--project',$temp,
            '--text','Which behavior?',
            '--why','Changes architecture',
            '--impact','high',
            '--owner','human',
            '--blocking','true')
        if($question.status-ne'open'){throw 'Question was not persisted open.'}

        $answer=Invoke-Planner @('answer','--project',$temp,'--question',$question.id,'--text','Behavior A')
        if($answer.status-ne'answered'){throw 'Question answer was not persisted.'}

        'SCPLAN 1
plan test
task t-1
title Do thing
instruction Do the accepted thing.
accept thing exists
end'|Set-Content -LiteralPath (Join-Path $temp 'candidate.scplan') -Encoding UTF8

        $candidate=Invoke-Planner @(
            'candidate','--project',$temp,
            '--plan',(Join-Path $temp 'candidate.scplan'),
            '--summary','test candidate')
        if(-not$candidate.planSha256){throw 'Candidate hash missing.'}

        $handoff=Invoke-Planner @('accept','--project',$temp,'--candidate',$candidate.id)
        if($handoff.status-ne'accepted'){throw 'Candidate did not become accepted handoff.'}

        $state=Get-Content -Raw -LiteralPath (Join-Path $stateRoot 'state.json')|ConvertFrom-Json
        $state.activePlanId='plan-applied'
        $state|Add-Member -NotePropertyName lastPlanningHandoffId -NotePropertyValue ([string]$handoff.id) -Force
        $state|Add-Member -NotePropertyName lastPlanningTransactionId -NotePropertyValue 'replan-test' -Force
        $state|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $stateRoot 'state.json') -Encoding UTF8

        $released=Invoke-Planner @(
            'release','--project',$temp,
            '--handoff',$handoff.id,
            '--applied-plan-id','plan-applied')
        if($released.status-ne'applied'){throw 'Handoff was not marked applied.'}
        if(Test-Path (Join-Path $stateRoot 'planning\active.json')){throw 'Planning barrier survived successful release.'}
        if(Test-Path (Join-Path $stateRoot 'autofill\pause.request')){throw 'Planner-owned Autofill pause survived release.'}
        if(-not(Test-Path (Join-Path $stateRoot 'autofill\trigger.request'))){throw 'Planner did not wake Autofill after release.'}

        Write-Host 'PASS: Planner module phase, question, candidate, and handoff flow.'
    }
    finally { Pop-Location }
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

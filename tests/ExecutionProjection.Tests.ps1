$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "EXECUTION PROJECTION TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-projection-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try{
    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Signals.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Manifests.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.ExecutionProjection.ps1')
    Set-SCRoots $temp $temp
    New-Item -ItemType Directory -Force -Path (Join-Path $temp '.statefulclanker')|Out-Null
    Write-SCJson (Get-SCPath 'state.json') ([ordered]@{schemaVersion=4;projectId='projection-test';revision=0;directionRevision=0})
    function Add-SCEvent { param($Type,$Message,$Data) }

    $up=[pscustomobject][ordered]@{id='up';title='upstream';instruction='change';status='complete';stateRevision=0;controlRevision=0;acceptance=@();dependsOn=@();relations=@();retrieval=@();evidence=@();provider=$null;role='worker';humanGate=$false;latestCompletionManifestId='completion-up'}
    $down=[pscustomobject][ordered]@{id='down';title='downstream';instruction='consume';status='ready';stateRevision=0;controlRevision=0;attemptCount=2;acceptance=@();dependsOn=@('up');relations=@();retrieval=@();evidence=@();provider=$null;role='worker';humanGate=$false}
    Write-SCJson (Get-SCPath 'tasks/up.json') $up
    Write-SCJson (Get-SCPath 'tasks/down.json') $down
    Write-SCJson (Get-SCPath 'completion-manifests/completion-up.json') ([ordered]@{schemaVersion=1;id='completion-up';taskId='up';changedFiles=@('src/a.cs');artifacts=@('artifact.txt');conclusions=@([ordered]@{authority='advisory';summary='upstream fact'});validation=[ordered]@{id='v-up';verdict='PASS'};warningsForSuccessor=@();evidenceRefs=@('validation:v-up')})

    Publish-SCExecutionSignal -Kind validator_rejection -Task $down -Component validator -Scope task -Authority corrective -Qualifier next_attempt -Payload @{reasonCode='ACCEPTANCE_FAILED';summary='repair this';evidenceRefs=@('validation:v-down')}|Out-Null
    Publish-SCExecutionSignal -Kind worker_run_failed -Task $down -Component worker -Scope attempt -Authority observed -Qualifier next_attempt -Payload @{runId='run-down';exitCode=1;evidenceRefs=@('run:run-down')}|Out-Null

    $a=Get-SCExecutionProjection $down
    Start-Sleep -Milliseconds 20
    $b=Get-SCExecutionProjection $down
    Assert-True ([string]$a.hash-eq[string]$b.hash) 'semantic projection hash changed only because id/time changed'
    Assert-True (@($a.correctiveFeedback).Count-eq1) 'corrective feedback was not reduced'
    Assert-True ([string]$a.correctiveFeedback[0].reasonCode-eq'ACCEPTANCE_FAILED') 'corrective reason code was lost'
    Assert-True (@($a.dependencyKnowledge).Count-eq1) 'dependency knowledge missing'
    Assert-True ([string]$a.dependencyKnowledge[0].manifestId-eq'completion-up') 'completion manifest was not selected'
    Assert-True (@($a.dependencyKnowledge[0].changedFiles)-contains'src/a.cs') 'dependency changed files were lost'
    Assert-True (-not[bool]$a.dependencyKnowledge[0].compatibilitySynthesized) 'manifest-backed dependency marked as compatibility fallback'
    Write-SCExecutionProjection $a|Out-Null
    Assert-True (Test-Path -LiteralPath (Get-SCPath ("projections/execution/{0}.json"-f$a.id))) 'projection was not persisted'
    Write-Host 'PASS: execution signals reduce deterministically with manifest-backed dependency knowledge.'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}

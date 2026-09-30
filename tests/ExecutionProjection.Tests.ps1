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
    Write-SCJson (Get-SCPath 'config.json') ([ordered]@{dependencyResultBudgetChars=8000})
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
    Start-Sleep -Milliseconds 10
    Publish-SCExecutionSignal -Kind validation_error -Task $down -Component validator -Scope task -Authority observed -SourceExtra @{validationId='v-error'} -Payload @{verdict='ERROR';summary='reviewer unavailable'}|Out-Null
    $errorProjection=Get-SCExecutionProjection $down
    Assert-True ($errorProjection.acceptanceFeedback.kind-eq'validation_error'-and-not$errorProjection.continuation.requiresCorrection) 'reviewer ERROR was treated as substantive candidate rejection'
    Start-Sleep -Milliseconds 10
    Publish-SCExecutionSignal -Kind validator_rejection -Task $down -Component validator -Scope task -Authority corrective -Payload @{reasonCode='CURRENT_REJECTION'}|Out-Null
    $down.controlRevision=1
    $retried=Get-SCExecutionProjection $down
    Assert-True (@($retried.correctiveFeedback).Count-eq0-and$null-eq$retried.acceptanceFeedback) 'manual retry carried active correction/error from old task control revision'
    $down.controlRevision=0
    Start-Sleep -Milliseconds 10
    Publish-SCExecutionSignal -Kind validation_passed -Task $down -Component validator -Scope task -Authority observed -Payload @{verdict='PASS'}|Out-Null
    Assert-True (-not(Get-SCExecutionProjection $down).continuation.requiresCorrection) 'PASS did not retire earlier correction'
    $manifest=Get-SCCompletionManifest 'completion-up'
    Set-SCProperty $manifest 'taskDefinitionHash' (Get-SCTaskDefinitionHash $up)
    Set-SCProperty $manifest 'taskControlRevision' 0
    Write-SCJson (Get-SCPath 'completion-manifests/completion-up.json') $manifest
    $up.controlRevision=1;Save-SCTask $up
    $stale=Get-SCExecutionProjection $down
    Assert-True ($stale.dependencyKnowledge[0].manifestStatus-eq'stale'-and$null-eq$stale.dependencyKnowledge[0].manifestId) 'retried upstream task kept old completed manifest as current'
    Set-SCProperty $up 'latestRunId' 'legacy-run';Set-SCProperty $up 'latestValidationId' 'legacy-validation';Save-SCTask $up
    Write-SCJson (Get-SCPath 'runs/legacy-run.json') @{stdout=('x'*500);exitCode=1;contextRequests=@('required context');candidateClaim=@{summary='legacy claim'}}
    Write-SCJson (Get-SCPath 'validations/legacy-validation.json') @{verdict='ERROR';validationKind='infrastructure';acceptanceEvidence=@('receipt');rejectionReasons=@()}
    Write-SCJson (Get-SCPath 'config.json') @{dependencyResultBudgetChars=12}
    $legacy=Get-SCExecutionProjection $down
    Assert-True ($legacy.dependencyKnowledge[0].legacyResult.Length-le12-and$legacy.dependencyKnowledge[0].legacyResultTruncated) 'minimum per-dependency floor exceeded configured budget'
    Assert-True ($legacy.dependencyKnowledge[0].validation.verdict-eq'ERROR'-and$legacy.dependencyKnowledge[0].exitCode-eq1) 'legacy handoff lost validation/error evidence'
    Write-SCJson (Get-SCPath 'config.json') @{dependencyResultBudgetChars=0}
    $zero=Get-SCExecutionProjection $down
    Assert-True ($zero.dependencyKnowledge[0].legacyResult.Length-eq0-and$zero.dependencyKnowledge[0].exitCode-eq1) 'zero text budget either leaked narrative or lost structured evidence'
    Write-Host 'PASS: execution signals reduce deterministically with manifest-backed dependency knowledge.'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}

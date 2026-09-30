$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "COMPLETION MANIFEST TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-manifest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try{
    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Signals.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Manifests.ps1')
    Set-SCRoots $temp $temp
    New-Item -ItemType Directory -Force -Path (Join-Path $temp '.statefulclanker')|Out-Null
    Write-SCJson (Get-SCPath 'state.json') ([ordered]@{schemaVersion=4;projectId='manifest-test';revision=0;directionRevision=0})
    function Add-SCEvent { param($Type,$Message,$Data) }

    $task=[pscustomobject][ordered]@{
        id='t-1';title='manifest task';instruction='change file';status='complete';stateRevision=0;controlRevision=0
        acceptance=@('artifact exists');dependsOn=@();relations=@();retrieval=@();evidence=@();provider=$null;role='worker';humanGate=$false
        outputKind='change';latestRunId='run-1';latestValidationId='val-1';latestProposalId='proposal-1';targetArtifacts=@('artifact.txt')
    }
    Write-SCJson (Get-SCPath 'tasks/t-1.json') $task
    Write-SCJson (Get-SCPath 'runs/run-1.json') ([ordered]@{id='run-1';compilationId='compile-1';candidateClaim=[ordered]@{summary='Implemented the manifest path';expectedArtifacts=@('artifact.txt');verification=@('unit test');warningsForSuccessor=@('UI not exercised');uncertainties=@('unknown concurrency limit');negativeFindings=@('old parser defect ruled out: Plan.ps1')}})
    Write-SCJson (Get-SCPath 'compilations/compile-1.json') @{id='compile-1';runtimeIdentity=@{sourceCommit='source-tip';libraryFingerprint='fingerprint'}}
    Write-SCJson (Get-SCPath 'validations/val-1.json') ([ordered]@{id='val-1';verdict='PASS';validationKind='deterministic'})
    $proposal=[pscustomobject][ordered]@{
        id='proposal-1';taskId='t-1';status='committed'
        evidence=[ordered]@{
            runId='run-1';validationId='val-1';validationVerdict='PASS'
            candidatePreflight=[ordered]@{changedFiles=@('src/a.cs','artifact.txt')}
            candidateClaim=[ordered]@{summary='Implemented the manifest path';expectedArtifacts=@('artifact.txt');verification=@('unit test');warningsForSuccessor=@('UI not exercised');uncertainties=@('unknown concurrency limit');negativeFindings=@('old parser defect ruled out: Plan.ps1')}
        }
    }
    Write-SCJson (Get-SCPath 'proposals/proposal-1.json') $proposal

    $manifest=Write-SCTaskCompletionManifest $task $proposal 'validated'
    Assert-True ($null-ne$manifest) 'manifest was not written'
    Assert-True (@($manifest.changedFiles)-contains'src/a.cs') 'deterministic changed files were lost'
    Assert-True (@($manifest.artifacts)-contains'artifact.txt') 'artifact list was lost'
    Assert-True ([string]$manifest.validation.verdict-eq'PASS') 'validator verdict was lost'
    Assert-True ([string]$manifest.conclusions[0].authority-eq'advisory') 'worker conclusion was not marked advisory'
    Assert-True ($manifest.warningsForSuccessor-contains'UI not exercised') 'successor warning was lost'
    Assert-True ($manifest.uncertainties-contains'unknown concurrency limit') 'uncertainty was lost'
    Assert-True ($manifest.negativeFindings-contains'old parser defect ruled out: Plan.ps1') 'negative evidence was lost'
    Assert-True ($manifest.sourceIdentity.sourceCommit-eq'source-tip'-and$manifest.claimAuthority-eq'advisory') 'source identity or claim authority was lost'
    $saved=Get-SCTask 't-1'
    Assert-True (-not[string]::IsNullOrWhiteSpace([string]$saved.latestCompletionManifestId)) 'task did not reference latest completion manifest'
    Assert-True ($null-ne(Get-SCCompletionManifest $saved.latestCompletionManifestId)) 'manifest could not be reloaded'
    $signals=@(Get-SCSignalsForAudience dependency 't-1' 'downstream')
    Assert-True (@($signals|Where-Object{$_.kind-eq'task_completion'}).Count-eq1) 'completion signal was not addressed downstream'
    Write-Host 'PASS: completion manifest preserves deterministic handoff data and advisory provenance.'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}

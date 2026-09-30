# Deterministic reduction of addressed execution signals into bounded task state.

function Get-SCExecutionProjection {
    param([Parameter(Mandatory=$true)]$Task,[int]$SignalLimit=500)
    $signals=@()
    foreach($signal in @(Get-SCSignalsForAudience task ([string]$Task.id) $null execution $SignalLimit)){
        $fresh=Test-SCSignalFreshness $signal $Task
        if([bool]$fresh.fresh){$signals+=$signal}
    }
    $signals=@($signals|Sort-Object {([datetimeoffset]$_.createdAt)})

    $corrective=@()
    $passed=@($signals|Where-Object{$_.kind-eq'validation_passed'}|Select-Object -Last 1)
    $latestAcceptance=@($signals|Where-Object{$_.kind-in@('validation_passed','validator_rejection','validation_error')}|Select-Object -Last 1)
    foreach($signal in @($signals|Where-Object{[string]$_.authority-eq'corrective'})){
        if($passed.Count-and([datetimeoffset]$signal.createdAt)-le([datetimeoffset]$passed[0].createdAt)){continue}
        if($signal.kind-eq'validator_rejection'-and$latestAcceptance.Count-and$signal.id-ne$latestAcceptance[0].id){continue}
        $payload=Get-SCSignalValue $signal 'payload'
        $source=Get-SCSignalValue $signal 'source'
        $corrective+=,[ordered]@{
            signalId=[string]$signal.id
            kind=[string]$signal.kind
            createdAt=[string]$signal.createdAt
            reasonCode=Get-SCSignalValue $payload 'reasonCode'
            summary=Get-SCSignalValue $payload 'summary'
            requests=@(Get-SCSignalValue $payload 'requests')
            evidenceRefs=@(Get-SCSignalValue $payload 'evidenceRefs')
            runId=Get-SCSignalValue $source 'runId'
            validationId=Get-SCSignalValue $source 'validationId'
            compilationId=Get-SCSignalValue $source 'compilationId'
        }
    }
    if($corrective.Count-gt6){$corrective=@($corrective|Select-Object -Last 6)}

    $attemptSignals=@($signals|Where-Object{[string]$_.kind-in@('worker_run_completed','worker_run_failed','candidate_empty','context_requested')}|Select-Object -Last 8)
    $prior=@($attemptSignals|ForEach-Object{
        $payload=Get-SCSignalValue $_ 'payload'
        [ordered]@{
            signalId=[string]$_.id;kind=[string]$_.kind;createdAt=[string]$_.createdAt
            runId=Get-SCSignalValue $payload 'runId';exitCode=Get-SCSignalValue $payload 'exitCode'
            reason=Get-SCSignalValue $payload 'reason';changedFiles=@(Get-SCSignalValue $payload 'changedFiles')
            evidenceRefs=@(Get-SCSignalValue $payload 'evidenceRefs')
        }
    })

    $retrievalSignal=@($signals|Where-Object{[string]$_.kind-eq'retrieval_anomaly'}|Select-Object -Last 1)
    $retrievalHealth=if($retrievalSignal.Count-gt0){Get-SCSignalValue (Get-SCSignalValue $retrievalSignal[0] 'payload') 'health'}else{$null}

    $dependencyKnowledge=@()
    $depIds=@($Task.dependsOn|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)})
    $cfg=Get-SCConfig
    $legacyBudget=if($cfg.PSObject.Properties['dependencyResultBudgetChars']){[int]$cfg.dependencyResultBudgetChars}else{8000}
    $legacyShare=if($depIds.Count-gt0){[Math]::Max(0,[Math]::Floor($legacyBudget/$depIds.Count))}else{0}
    foreach($depId in $depIds){
        try{$dep=Get-SCTask ([string]$depId)}catch{$dep=$null}
        if($null-eq$dep){
            $dependencyKnowledge+=,[ordered]@{id=[string]$depId;status='missing';definitionHash=$null;manifestId=$null;compatibilitySynthesized=$true}
            continue
        }
        $latestRunId=if($dep.PSObject.Properties['latestRunId']){[string]$dep.latestRunId}else{$null}
        $latestValidationId=if($dep.PSObject.Properties['latestValidationId']){[string]$dep.latestValidationId}else{$null}
        $manifest=Get-SCLatestCompletionManifest $dep
        $manifestStatus=if($manifest){'current'}else{'missing'}
        if($manifest-and(($manifest.PSObject.Properties['taskDefinitionHash']-and[string]$manifest.taskDefinitionHash-ne(Get-SCTaskDefinitionHash $dep))-or($manifest.PSObject.Properties['taskControlRevision']-and[int]$manifest.taskControlRevision-ne(Get-SCTaskControlRevision $dep)))){$manifestStatus='stale';$manifest=$null}
        if($manifest){
            $dependencyKnowledge+=,[ordered]@{
                id=[string]$dep.id
                title=[string]$dep.title
                status=[string]$dep.status
                definitionHash=Get-SCTaskDefinitionHash $dep
                latestRunId=$latestRunId
                latestValidationId=$latestValidationId
                manifestId=[string]$manifest.id
                manifestStatus=$manifestStatus
                changedFiles=@($manifest.changedFiles)
                artifacts=@($manifest.artifacts)
                conclusions=@($manifest.conclusions)
                validation=$manifest.validation
                warningsForSuccessor=@($manifest.warningsForSuccessor)
                uncertainties=@(Get-SCManifestField $manifest 'uncertainties')
                negativeFindings=@(Get-SCManifestField $manifest 'negativeFindings')
                sourceIdentity=Get-SCManifestField $manifest 'sourceIdentity'
                evidenceRefs=@($manifest.evidenceRefs)
                compatibilitySynthesized=$false
            }
        }else{
            $legacyResult=$null;$legacyTruncated=$false
            $receipt=$null;$legacyValidation=$null
            if($latestValidationId){$legacyValidation=Read-SCJson (Get-SCPath ("validations/{0}.json"-f$latestValidationId))}
            if($latestRunId){
                try{
                    $receipt=Read-SCJson (Get-SCPath ("runs/{0}.json"-f$latestRunId))
                    if($receipt){
                        $text=[string]$receipt.stdout
                        $take=[Math]::Min($text.Length,$legacyShare)
                        $legacyResult=if($take-gt0){$text.Substring(0,$take)}else{''}
                        $legacyTruncated=($text.Length-gt$take)
                    }
                }catch{}
            }
            $dependencyKnowledge+=,[ordered]@{
                id=[string]$dep.id
                title=[string]$dep.title
                status=[string]$dep.status
                definitionHash=Get-SCTaskDefinitionHash $dep
                latestRunId=$latestRunId
                latestValidationId=$latestValidationId
                manifestId=$null
                manifestStatus=$manifestStatus
                changedFiles=@()
                artifacts=@()
                conclusions=@()
                validation=[ordered]@{id=$latestValidationId;verdict=Get-SCManifestField $legacyValidation 'verdict';kind=Get-SCManifestField $legacyValidation 'validationKind';rejectionReasons=@(Get-SCManifestField $legacyValidation 'rejectionReasons');acceptanceEvidence=@(Get-SCManifestField $legacyValidation 'acceptanceEvidence')}
                warningsForSuccessor=@()
                evidenceRefs=@()
                compatibilitySynthesized=$true
                legacyResult=$legacyResult
                legacyResultTruncated=$legacyTruncated
                exitCode=Get-SCManifestField $receipt 'exitCode'
                candidateClaim=Get-SCManifestField $receipt 'candidateClaim'
                contextRequests=@(Get-SCManifestField $receipt 'contextRequests')
            }
        }
    }

    $lastRun=@($signals|Where-Object{[string]$_.kind-in@('worker_run_completed','worker_run_failed')}|Select-Object -Last 1)
    $lastValidation=@($signals|Where-Object{[string]$_.kind-in@('validation_passed','validator_rejection','validation_error')}|Select-Object -Last 1)
    $latestCorrection=if($corrective.Count-gt0){$corrective[-1]}else{$null}
    $acceptanceFeedback=if($lastValidation.Count){[ordered]@{kind=[string]$lastValidation[0].kind;authority=[string]$lastValidation[0].authority;createdAt=[string]$lastValidation[0].createdAt;validationId=Get-SCSignalValue $lastValidation[0].source 'validationId';payload=$lastValidation[0].payload}}else{$null}
    $preservedCandidates=@()
    if($Task.PSObject.Properties['latestPreservedCandidateId']-and$Task.latestPreservedCandidateId){
        $preserved=Read-SCJson (Get-SCPath ("preserved-candidates/{0}.json"-f$Task.latestPreservedCandidateId))
        if($preserved){$preservedCandidates+=,$preserved}
    }
    $continuationEvidence=@()
    foreach($item in @($corrective|Select-Object -Last 3)){
        $continuationEvidence+=@($item.evidenceRefs)
    }
    foreach($item in @($prior|Select-Object -Last 4)){
        $continuationEvidence+=@($item.evidenceRefs)
    }
    $continuationEvidence=@($continuationEvidence|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}|Select-Object -Unique)
    $latestRunPayload=if($lastRun.Count){Get-SCSignalValue $lastRun[0] 'payload'}else{$null}
    $latestValidationSource=if($lastValidation.Count){Get-SCSignalValue $lastValidation[0] 'source'}else{$null}
    $continuation=[ordered]@{
        latestCorrection=$latestCorrection
        latestRunRef=if($latestRunPayload-and(Get-SCSignalValue $latestRunPayload 'runId')){"run:"+[string](Get-SCSignalValue $latestRunPayload 'runId')}else{$null}
        latestValidationRef=if($latestValidationSource-and(Get-SCSignalValue $latestValidationSource 'validationId')){"validation:"+[string](Get-SCSignalValue $latestValidationSource 'validationId')}else{$null}
        recentAttemptSignalIds=@($attemptSignals|Select-Object -Last 4|ForEach-Object{[string]$_.id})
        evidenceRefs=$continuationEvidence
        requiresCorrection=($null-ne$latestCorrection)
    }
    $semantic=[ordered]@{
        taskId=[string]$Task.id
        taskDefinitionHash=Get-SCTaskDefinitionHash $Task
        executionDiagnostics=[ordered]@{
            attemptCount=if($Task.PSObject.Properties['attemptCount']){[int]$Task.attemptCount}else{0}
            signalCount=@($signals).Count
            workerRunSignalCount=@($signals|Where-Object{[string]$_.kind-in@('worker_run_completed','worker_run_failed')}).Count
            lastRunKind=if($lastRun.Count){[string]$lastRun[0].kind}else{$null}
            lastRunAt=if($lastRun.Count){[string]$lastRun[0].createdAt}else{$null}
            latestValidationKind=if($lastValidation.Count){[string]$lastValidation[0].kind}else{$null}
            latestValidationAt=if($lastValidation.Count){[string]$lastValidation[0].createdAt}else{$null}
        }
        correctiveFeedback=@($corrective)
        acceptanceFeedback=$acceptanceFeedback
        preservedCandidates=@($preservedCandidates)
        priorAttemptKnowledge=@($prior)
        continuation=$continuation
        dependencyKnowledge=@($dependencyKnowledge)
        retrievalHealth=$retrievalHealth
    }
    $hash=Get-SCHashString (ConvertTo-SCJson $semantic 24)
    $projection=[ordered]@{schemaVersion=1;id=New-SCId 'execproj';generatedAt=[datetimeoffset]::UtcNow.ToString('o');hash=$hash}
    foreach($entry in $semantic.GetEnumerator()){$projection[$entry.Key]=$entry.Value}
    return [pscustomobject]$projection
}

function Write-SCExecutionProjection($Projection) {
    if($null-eq$Projection){return $null}
    Write-SCJson (Get-SCPath ("projections/execution/{0}.json"-f$Projection.id)) $Projection
    if($Projection.PSObject.Properties['taskId'] -and -not[string]::IsNullOrWhiteSpace([string]$Projection.taskId)){
        Write-SCJson (Get-SCPath ("projections/execution/latest/{0}.json"-f$Projection.taskId)) $Projection
    }
    return $Projection
}

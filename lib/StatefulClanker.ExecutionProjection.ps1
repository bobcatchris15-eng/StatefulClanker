# Deterministic reduction of addressed execution signals into bounded task state.

function Get-SCExecutionProjection {
    param([Parameter(Mandatory=$true)]$Task,[int]$SignalLimit=500)
    $signals=@()
    foreach($signal in @(Get-SCSignalsForAudience task ([string]$Task.id) $null execution $SignalLimit)){
        $fresh=Test-SCSignalFreshness $signal $Task
        if([bool]$fresh.fresh){$signals+=$signal}
    }
    $signals=@($signals|Sort-Object {[datetimeoffset]::Parse([string]$_.createdAt)})

    $corrective=@()
    foreach($signal in @($signals|Where-Object{[string]$_.authority-eq'corrective'})){
        $payload=Get-SCSignalValue $signal 'payload'
        $corrective+=,[ordered]@{
            signalId=[string]$signal.id
            kind=[string]$signal.kind
            createdAt=[string]$signal.createdAt
            reasonCode=Get-SCSignalValue $payload 'reasonCode'
            summary=Get-SCSignalValue $payload 'summary'
            requests=@(Get-SCSignalValue $payload 'requests')
            evidenceRefs=@(Get-SCSignalValue $payload 'evidenceRefs')
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
    foreach($depId in @($Task.dependsOn)){
        if([string]::IsNullOrWhiteSpace([string]$depId)){continue}
        try{$dep=Get-SCTask ([string]$depId)}catch{$dep=$null}
        if($null-eq$dep){
            $dependencyKnowledge+=,[ordered]@{id=[string]$depId;status='missing';manifest=$null}
            continue
        }
        $manifest=Get-SCLatestCompletionManifest $dep
        if($manifest){
            $dependencyKnowledge+=,[ordered]@{
                id=[string]$dep.id
                status=[string]$dep.status
                definitionHash=Get-SCTaskDefinitionHash $dep
                manifestId=[string]$manifest.id
                changedFiles=@($manifest.changedFiles)
                artifacts=@($manifest.artifacts)
                conclusions=@($manifest.conclusions)
                validation=$manifest.validation
                warningsForSuccessor=@($manifest.warningsForSuccessor)
                evidenceRefs=@($manifest.evidenceRefs)
                compatibilitySynthesized=$false
            }
        }else{
            $dependencyKnowledge+=,[ordered]@{
                id=[string]$dep.id
                status=[string]$dep.status
                definitionHash=Get-SCTaskDefinitionHash $dep
                manifestId=$null
                changedFiles=@()
                artifacts=@()
                conclusions=@()
                validation=[ordered]@{id=if($dep.PSObject.Properties['latestValidationId']){$dep.latestValidationId}else{$null};verdict=$null}
                warningsForSuccessor=@()
                evidenceRefs=@()
                compatibilitySynthesized=$true
                latestRunId=if($dep.PSObject.Properties['latestRunId']){$dep.latestRunId}else{$null}
            }
        }
    }

    $lastRun=@($signals|Where-Object{[string]$_.kind-in@('worker_run_completed','worker_run_failed')}|Select-Object -Last 1)
    $lastValidation=@($signals|Where-Object{[string]$_.kind-in@('validation_passed','validator_rejection','validation_error')}|Select-Object -Last 1)
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
        priorAttemptKnowledge=@($prior)
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
    return $Projection
}

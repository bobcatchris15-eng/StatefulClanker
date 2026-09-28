# Structured completion manifests: durable downstream handoff, not worker prose.

function Get-SCCompletionManifest([string]$Id) {
    if([string]::IsNullOrWhiteSpace($Id)){return $null}
    try{return Read-SCJson (Get-SCPath ("completion-manifests/{0}.json"-f$Id))}catch{return $null}
}

function Get-SCLatestCompletionManifest($Task) {
    if($null-eq$Task-or-not$Task.PSObject.Properties['latestCompletionManifestId']-or-not$Task.latestCompletionManifestId){return $null}
    return Get-SCCompletionManifest ([string]$Task.latestCompletionManifestId)
}

function Get-SCManifestField($Object,[string]$Name) {
    if($null-eq$Object){return $null}
    if($Object-is[System.Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]};return $null}
    $p=$Object.PSObject.Properties[$Name];if($p){return $p.Value};return $null
}

function Write-SCTaskCompletionManifest {
    param(
        [Parameter(Mandatory=$true)]$Task,
        $Proposal=$null,
        [string]$CompletionAuthority='validated',
        [string]$Reason=$null
    )
    try{
        if([string]$Task.status-ne'complete'){throw "Task $($Task.id) is not complete."}
        if($null-eq$Proposal-and$Task.PSObject.Properties['latestProposalId']-and$Task.latestProposalId){
            $Proposal=Read-SCJson (Get-SCPath ("proposals/{0}.json"-f$Task.latestProposalId))
        }

        $proposalId=if($Proposal){[string](Get-SCManifestField $Proposal 'id')}else{$null}
        $proposalEvidence=if($Proposal){Get-SCManifestField $Proposal 'evidence'}else{$null}
        $runId=if($proposalEvidence){[string](Get-SCManifestField $proposalEvidence 'runId')}elseif($Task.PSObject.Properties['latestRunId']){[string]$Task.latestRunId}else{$null}
        $run=if($runId){Read-SCJson (Get-SCPath ("runs/{0}.json"-f$runId))}else{$null}

        $validationId=if($proposalEvidence-and(Get-SCManifestField $proposalEvidence 'validationId')){[string](Get-SCManifestField $proposalEvidence 'validationId')}elseif($Task.PSObject.Properties['latestValidationId']){[string]$Task.latestValidationId}else{$null}
        $validation=if($validationId){Read-SCJson (Get-SCPath ("validations/{0}.json"-f$validationId))}else{$null}

        $preflight=if($proposalEvidence){Get-SCManifestField $proposalEvidence 'candidatePreflight'}else{$null}
        if($null-eq$preflight-and$run){$preflight=Get-SCManifestField $run 'candidatePreflight'}
        $claim=if($proposalEvidence){Get-SCManifestField $proposalEvidence 'candidateClaim'}else{$null}
        if($null-eq$claim-and$run){$claim=Get-SCManifestField $run 'candidateClaim'}

        $changedFiles=@()
        if($preflight){
            $raw=Get-SCManifestField $preflight 'changedFiles'
            if($raw){$changedFiles=@($raw|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}|ForEach-Object{[string]$_}|Select-Object -Unique)}
        }

        $artifacts=@()
        if($claim){
            $expected=Get-SCManifestField $claim 'expectedArtifacts'
            if($expected){$artifacts+=@($expected)}
        }
        if($Task.PSObject.Properties['targetArtifacts']-and$Task.targetArtifacts){$artifacts+=@($Task.targetArtifacts)}
        $artifacts=@($artifacts|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}|ForEach-Object{[string]$_}|Select-Object -Unique)

        $summary=if($claim){[string](Get-SCManifestField $claim 'summary')}else{''}
        $conclusions=@()
        if(-not[string]::IsNullOrWhiteSpace($summary)){$conclusions+=,[ordered]@{authority='advisory';summary=$summary;source='worker-candidate-claim'}}
        $workerVerification=if($claim){@(Get-SCManifestField $claim 'verification')}else{@()}

        $refs=@()
        if($runId){$refs+="run:$runId"}
        if($proposalId){$refs+="proposal:$proposalId"}
        if($validationId){$refs+="validation:$validationId"}

        $manifest=[pscustomobject][ordered]@{
            schemaVersion=1
            id=New-SCId 'completion'
            taskId=[string]$Task.id
            title=[string]$Task.title
            result='completed'
            completedAt=[datetimeoffset]::UtcNow.ToString('o')
            completionAuthority=$CompletionAuthority
            reason=$Reason
            taskDefinitionHash=Get-SCTaskDefinitionHash $Task
            taskControlRevision=Get-SCTaskControlRevision $Task
            proposalId=$proposalId
            runId=$runId
            validation=[ordered]@{
                id=$validationId
                verdict=if($validation){Get-SCManifestField $validation 'verdict'}elseif($proposalEvidence){Get-SCManifestField $proposalEvidence 'validationVerdict'}else{$null}
                kind=if($validation){Get-SCManifestField $validation 'validationKind'}else{$null}
            }
            changedFiles=@($changedFiles)
            artifacts=@($artifacts)
            conclusions=@($conclusions)
            invariantsDiscovered=@()
            warningsForSuccessor=@()
            workerVerification=@($workerVerification)
            mechanicalAcceptance=if($proposalEvidence){Get-SCManifestField $proposalEvidence 'mechanicalAcceptance'}else{$null}
            evidenceRefs=@($refs)
        }

        Write-SCJson (Get-SCPath ("completion-manifests/{0}.json"-f$manifest.id)) $manifest
        Set-SCProperty $Task 'latestCompletionManifestId' ([string]$manifest.id)
        Save-SCTask $Task

        try{
            $signal=New-SCSignalEnvelope -Domain execution -Kind task_completion -Source @{component='completion-finalizer';taskId=[string]$Task.id;manifestId=[string]$manifest.id} -Subject @{type='task';id=[string]$Task.id} -Audience @(@{type='task';id=[string]$Task.id;qualifier='completed'},@{type='dependency';id=[string]$Task.id;qualifier='downstream'}) -Authority observed -Scope task -Freshness @{taskDefinitionHash=$manifest.taskDefinitionHash} -Payload @{manifestId=[string]$manifest.id;changedFiles=@($changedFiles);artifacts=@($artifacts);evidenceRefs=@("completion:$($manifest.id)")}
            Write-SCSignal $signal|Out-Null
        }catch{try{Add-SCEvent 'signal.shadow_write_failed' $_.Exception.Message @{taskId=$Task.id;kind='task_completion'}}catch{}}

        Add-SCEvent 'task.completion_manifest' "Wrote completion manifest $($manifest.id) for $($Task.id)." @{taskId=$Task.id;manifestId=$manifest.id;completionAuthority=$CompletionAuthority;changedFiles=@($changedFiles)}
        return $manifest
    }catch{
        try{Add-SCEvent 'task.completion_manifest_failed' $_.Exception.Message @{taskId=if($Task){$Task.id}else{$null}}}catch{}
        return $null
    }
}

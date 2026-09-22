# Compiled router dispatch bridge. The C# service owns leases/health/cursor;
# PowerShell continues to own provider invocation and worker transcript semantics.

function Invoke-SCProviderViaCompiledRouter($Task,[string]$Prompt,[string]$Stage,[string]$ParentAgentId=$null,$Compilation=$null,[string]$WorkerSessionId=$null,[string]$ContinuationMessage=$null) {
    $history=@()
    $routeSnapshot=Get-SCRouteSnapshotReceipt
    Set-SCProperty $routeSnapshot 'router' 'compiled'
    $preferred=$null
    if($Stage-eq'run' -and $WorkerSessionId){
        $pin=Get-SCWorkerSessionRoutePin $WorkerSessionId
        if($pin){$preferred=[string]$pin.endpoint}
    }

    $cfg=Get-SCConfig;$max=6
    if($cfg.PSObject.Properties['routing'] -and $cfg.routing -and $cfg.routing.PSObject.Properties['maxRouteAttempts']){
        try{$max=[Math]::Min(32,[Math]::Max(1,[int]$cfg.routing.maxRouteAttempts))}catch{}
    }

    $last=$null
    for($attempt=1;$attempt-le$max;$attempt++){
        $acquireArgs=@('acquire')
        if($WorkerSessionId){$acquireArgs+=@('--session',$WorkerSessionId)}
        if($preferred){$acquireArgs+=@('--preferred',$preferred)}
        $acquire=Invoke-SCCompiledRouterCommand $acquireArgs

        if(-not[bool]$acquire.ok){
            $now=[datetimeoffset]::UtcNow
            $retry=$now.AddSeconds(2)
            if($acquire.data -and $acquire.data.PSObject.Properties['nextRetryAt'] -and $acquire.data.nextRetryAt){
                $parsed=[datetimeoffset]::MinValue
                if([datetimeoffset]::TryParse([string]$acquire.data.nextRetryAt,[ref]$parsed)){$retry=$parsed}
            }elseif($acquire.data -and $acquire.data.PSObject.Properties['retryAfterSeconds']){
                try{$retry=$now.AddSeconds([double]$acquire.data.retryAfterSeconds)}catch{}
            }
            return [pscustomobject][ordered]@{
                schemaVersion=4;id=New-SCId $Stage;agentId=New-SCId 'agent';taskId=$Task.id;stage=$Stage
                provider=$preferred;endpoint=$preferred;workerSessionId=$WorkerSessionId;workerSessionResumable=([bool]$WorkerSessionId)
                compilationId=if($Compilation){$Compilation.id}else{$null};inputFingerprint=if($Compilation){$Compilation.inputFingerprint}else{$null}
                command='compiled-router';args=@();promptPath=$null;startedAt=$now.ToString('o');endedAt=$now.ToString('o');durationSeconds=0
                exitCode=-3;stdout='';stderr=[string]$acquire.error;routeDeferred=$true;retryAfter=$retry.ToString('o')
                routeAttempts=$history.Count;routeHistory=@($history);routeSnapshot=$routeSnapshot;compiledRouter=$true
            }
        }

        $leaseToken=[string]$acquire.data.lease
        $endpoint=[string]$acquire.data.endpoint
        $record=@(Get-SCTargetPoolRecords|Where-Object{[string]$_.name-eq$endpoint}|Select-Object -First 1)
        $released=$false
        if($record.Count-eq0){
            try{[void](Invoke-SCCompiledRouterCommand @('failure','--lease',$leaseToken,'--class','configuration','--message',"Endpoint $endpoint disappeared from the catalog after lease acquisition."));$released=$true}catch{}
            $history+=,[ordered]@{endpoint=$endpoint;outcome='failed';failureClass='configuration';healthScope='connection'}
            $preferred=$null
            continue
        }
        $record=$record[0]

        try{
            $type=if($record.config.PSObject.Properties['type']){[string]$record.config.type}else{'api'}
            try{
                if($type-eq'api'){$receipt=Invoke-SCDirectApiProvider $Task $Prompt $Stage $record $ParentAgentId $Compilation $WorkerSessionId $ContinuationMessage}
                else{$receipt=& $script:SCInvokeProviderCliBase $Task $Prompt $Stage ([string]$record.name) $ParentAgentId $Compilation}
            }catch{
                $now=(Get-Date).ToUniversalTime().ToString('o')
                $receipt=[pscustomobject][ordered]@{
                    schemaVersion=4;id=New-SCId $Stage;agentId=New-SCId 'agent';taskId=$Task.id;stage=$Stage
                    provider=$endpoint;endpoint=$endpoint;compilationId=if($Compilation){$Compilation.id}else{$null}
                    inputFingerprint=if($Compilation){$Compilation.inputFingerprint}else{$null};command='compiled-router'
                    args=@();promptPath=$null;startedAt=$now;endedAt=$now;durationSeconds=0;exitCode=-1;stdout='';stderr=($_|Out-String)
                }
            }
            if(-not$receipt.PSObject.Properties['workerSessionId']){
                Set-SCProperty $receipt 'workerSessionId' $WorkerSessionId
                Set-SCProperty $receipt 'workerSessionResumable' $false
            }
            $last=$receipt
            $text=(([string]$receipt.stderr)+[Environment]::NewLine+([string]$receipt.stdout)).Trim()

            if([int]$receipt.exitCode-eq0){
                [void](Invoke-SCCompiledRouterCommand @('success','--lease',$leaseToken));$released=$true
                if($WorkerSessionId){
                    Set-SCWorkerSessionRoutePin $WorkerSessionId $endpoint ([string]$record.config.connection) ([string]$record.config.model)
                }
                $history+=,[ordered]@{endpoint=$endpoint;connection=[string]$record.config.connection;model=[string]$record.config.model;outcome='success';failureClass=$null;healthScope=$null}
                Set-SCProperty $receipt 'routeAttempts' $history.Count
                Set-SCProperty $receipt 'routeHistory' @($history)
                Set-SCProperty $receipt 'routeSnapshot' $routeSnapshot
                Set-SCProperty $receipt 'compiledRouter' $true
                if($history.Count-gt1){Add-SCEvent 'routing.failover_succeeded' "Compiled router failover succeeded on $endpoint." @{taskId=$Task.id;stage=$Stage;attempts=$history.Count;history=@($history)}}
                return $receipt
            }

            $class=Get-SCRouteFailureClass ([int]$receipt.exitCode) $text
            $failure=Invoke-SCCompiledRouterCommand @('failure','--lease',$leaseToken,'--class',$class,'--message',$text)
            $released=$true
            $scope=if($failure.data -and $failure.data.PSObject.Properties['scope']){[string]$failure.data.scope}else{'request'}
            $key=if($failure.data -and $failure.data.PSObject.Properties['key']){[string]$failure.data.key}else{$null}
            $history+=,[ordered]@{endpoint=$endpoint;connection=[string]$record.config.connection;model=[string]$record.config.model;outcome='failed';failureClass=$class;healthScope=$scope;healthKey=$key}
            Set-SCProperty $receipt 'routeAttempts' $history.Count
            Set-SCProperty $receipt 'routeHistory' @($history)
            Set-SCProperty $receipt 'compiledRouter' $true

            if(-not(Test-SCRouteFailureTransient $class) -and $class-ne'auth'){
                Add-SCEvent 'routing.failover_stopped' "Compiled router stopped replay after non-transient failure: $class" @{taskId=$Task.id;stage=$Stage;endpoint=$endpoint;failureClass=$class}
                return $receipt
            }
            Add-SCEvent 'routing.failover' "Compiled router retired $endpoint for $class; acquiring another endpoint." @{taskId=$Task.id;stage=$Stage;endpoint=$endpoint;failureClass=$class;attempt=$history.Count}
            $preferred=$null
        }finally{
            if(-not$released -and $leaseToken){try{[void](Invoke-SCCompiledRouterCommand @('release','--lease',$leaseToken))}catch{}}
        }
    }

    if($last){
        Set-SCProperty $last 'routeAttempts' $history.Count
        Set-SCProperty $last 'routeHistory' @($history)
        Set-SCProperty $last 'routeExhausted' $true
        Set-SCProperty $last 'routeSnapshot' $routeSnapshot
        Set-SCProperty $last 'compiledRouter' $true
        return $last
    }
    throw 'Compiled routing produced no endpoint receipt.'
}

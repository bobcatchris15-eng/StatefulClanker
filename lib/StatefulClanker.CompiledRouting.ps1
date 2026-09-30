# Compiled router dispatch bridge. The C# service owns endpoint selection,
# leases, health, cooldowns, probing, and the round-robin cursor. PowerShell owns
# provider invocation and durable worker transcript semantics only.

function Get-SCProjectRoutingAllowlist {
    $cfg=Get-SCConfig
    if(-not($cfg.PSObject.Properties['routing'] -and $cfg.routing)){return @()}
    if(-not $cfg.routing.PSObject.Properties['endpoints']){return @()}
    $raw=$cfg.routing.endpoints
    if(-not $raw){return @()}
    return @($raw|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}|ForEach-Object{[string]$_})
}

function Invoke-SCProviderViaCompiledRouter($Task,[string]$Prompt,[string]$Stage,[string]$ParentAgentId=$null,$Compilation=$null,[string]$WorkerSessionId=$null,[string]$ContinuationMessage=$null,[string]$EndpointOverride=$null,[string]$ConnectionOverride=$null) {
    $allowlist=@(Get-SCProjectRoutingAllowlist)
    $routeSnapshot=Get-SCRouteSnapshotReceipt
    Set-SCProperty $routeSnapshot 'router' 'compiled'

    $preferred=$EndpointOverride
    if(-not$preferred -and -not$ConnectionOverride -and $Stage-eq'run' -and $WorkerSessionId){
        $pin=Get-SCWorkerSessionRoutePin $WorkerSessionId
        if($pin){$preferred=[string]$pin.endpoint}
    }

    $cfg=Get-SCConfig
    $maxRouteAttempts=6
    $maxRouteWaitSeconds=20
    if($cfg.PSObject.Properties['routing'] -and $cfg.routing){
        if($cfg.routing.PSObject.Properties['maxRouteAttempts']){
            try{$maxRouteAttempts=[Math]::Min(32,[Math]::Max(1,[int]$cfg.routing.maxRouteAttempts))}catch{}
        }
        if($cfg.routing.PSObject.Properties['maxRouteWaitSeconds']){
            try{$maxRouteWaitSeconds=[Math]::Min(300,[Math]::Max(0,[int]$cfg.routing.maxRouteWaitSeconds))}catch{}
        }
    }

    $negotiateArgs=@('negotiate')
    if($preferred){$negotiateArgs+=@('--preferred',$preferred)}
    if($ConnectionOverride){$negotiateArgs+=@('--connection',$ConnectionOverride)}
    if($EndpointOverride){$negotiateArgs+=@('--strict-preferred','true')}
    if($allowlist.Count-gt0){$negotiateArgs+=@('--endpoints',($allowlist-join','))}
    $negotiated=Invoke-SCCompiledRouterCommand $negotiateArgs

    if(-not[bool]$negotiated.ok){
        $now=[datetimeoffset]::UtcNow
        $retry=$now.AddSeconds(2)
        if($negotiated.data -and $negotiated.data.PSObject.Properties['nextRetryAt'] -and $negotiated.data.nextRetryAt){
            $parsed=[datetimeoffset]::MinValue
            if([datetimeoffset]::TryParse([string]$negotiated.data.nextRetryAt,[ref]$parsed)){$retry=$parsed}
        }
        return [pscustomobject][ordered]@{
            schemaVersion=4;id=New-SCId $Stage;agentId=New-SCId 'agent';taskId=$Task.id;stage=$Stage
            provider='router';endpoint=$EndpointOverride;connection=$ConnectionOverride;workerSessionId=$WorkerSessionId;workerSessionResumable=([bool]$WorkerSessionId)
            compilationId=if($Compilation){$Compilation.id}else{$null};inputFingerprint=if($Compilation){$Compilation.inputFingerprint}else{$null}
            command='compiled-router';args=@();promptPath=$null;startedAt=$now.ToString('o');endedAt=$now.ToString('o');durationSeconds=0
            exitCode=-3;stdout='';stderr=[string]$negotiated.error;routeDeferred=$true;retryAfter=$retry.ToString('o')
            routeAttempts=0;routeHistory=@();routeSnapshot=$routeSnapshot;compiledRouter=$true
        }
    }

    $toolMode=if($negotiated.data -and $negotiated.data.PSObject.Properties['toolMode']){[string]$negotiated.data.toolMode}else{'text'}
    if($Stage-eq'run' -and $WorkerSessionId){
        $session=Get-SCWorkerSession $WorkerSessionId
        # A durable transcript fixes its wire protocol. The gateway enforces
        # native compatibility and defers if only text routes remain available.
        if($session -and $session.PSObject.Properties['toolMode']){$toolMode=[string]$session.toolMode}
    }
    $routerConfig=[ordered]@{
        type='api'
        routerManaged=$true
        toolMode=$toolMode
        preferred=$preferred
        connection=$ConnectionOverride
        strictPreferred=[bool]$EndpointOverride
        allowedEndpoints=@($allowlist)
        sessionId=$WorkerSessionId
        maxRouteAttempts=$maxRouteAttempts
        maxRouteWaitSeconds=$maxRouteWaitSeconds
        model='router'
    }
    $record=[pscustomobject][ordered]@{name='router:auto';config=[pscustomobject]$routerConfig}

    try{
        $receipt=Invoke-SCDirectApiProvider $Task $Prompt $Stage $record $ParentAgentId $Compilation $WorkerSessionId $ContinuationMessage
    }catch{
        $now=(Get-Date).ToUniversalTime().ToString('o')
        $receipt=[pscustomobject][ordered]@{
            schemaVersion=4;id=New-SCId $Stage;agentId=New-SCId 'agent';taskId=$Task.id;stage=$Stage
            provider='router';endpoint=$EndpointOverride;connection=$ConnectionOverride;compilationId=if($Compilation){$Compilation.id}else{$null}
            inputFingerprint=if($Compilation){$Compilation.inputFingerprint}else{$null};command='compiled-router'
            args=@();promptPath=$null;startedAt=$now;endedAt=$now;durationSeconds=0;exitCode=-1;stdout='';stderr=($_|Out-String)
            routeAttempts=0;routeHistory=@();compiledRouter=$true
        }
    }

    if(-not$receipt.PSObject.Properties['workerSessionId']){
        Set-SCProperty $receipt 'workerSessionId' $WorkerSessionId
        Set-SCProperty $receipt 'workerSessionResumable' $false
    }
    Set-SCProperty $receipt 'routeSnapshot' $routeSnapshot
    Set-SCProperty $receipt 'compiledRouter' $true
    Set-SCProperty $receipt 'negotiatedToolMode' $toolMode

    if([int]$receipt.exitCode-eq0){
        if($WorkerSessionId -and $receipt.PSObject.Properties['endpoint'] -and $receipt.endpoint -and [string]$receipt.endpoint-ne'router:auto'){
            Set-SCWorkerSessionRoutePin $WorkerSessionId ([string]$receipt.endpoint) ([string]$receipt.connection) ([string]$receipt.model)
        }
        if($receipt.PSObject.Properties['routeAttempts'] -and [int]$receipt.routeAttempts-gt1){
            Add-SCEvent 'routing.failover_succeeded' "ClankerRouter completed inference after transparent failover." @{taskId=$Task.id;stage=$Stage;attempts=[int]$receipt.routeAttempts;history=@($receipt.routeHistory)}
        }
        return $receipt
    }

    if($receipt.PSObject.Properties['routeDeferred'] -and [bool]$receipt.routeDeferred){
        Add-SCEvent 'routing.deferred' "ClankerRouter has no usable route yet; inference is deferred until routing recovers." @{taskId=$Task.id;stage=$Stage;retryAfter=$receipt.retryAfter;attempts=$receipt.routeAttempts}
    }elseif($receipt.PSObject.Properties['routeExhausted'] -and [bool]$receipt.routeExhausted){
        Add-SCEvent 'routing.exhausted' "ClankerRouter exhausted its transparent failover budget." @{taskId=$Task.id;stage=$Stage;attempts=$receipt.routeAttempts;history=@($receipt.routeHistory)}
    }
    return $receipt
}


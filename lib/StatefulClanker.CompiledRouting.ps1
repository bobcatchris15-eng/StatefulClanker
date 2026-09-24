# Compiled router dispatch bridge. The C# service owns endpoint selection,
# leases, health, cooldowns, probing, and the round-robin cursor. PowerShell owns
# provider invocation and durable worker transcript semantics only.

function Get-SCCompiledRouterRoot {
    if($env:SC_ROUTER_ROOT){return [IO.Path]::GetFullPath([string]$env:SC_ROUTER_ROOT)}
    return Join-Path $env:LOCALAPPDATA 'StatefulClanker'
}
function Get-SCMachineEndpointCatalogPath { return Join-Path (Get-SCCompiledRouterRoot) 'endpoints.json' }
function Get-SCMachineEndpointRecord([string]$Endpoint) {
    $catalogId=if($Endpoint.StartsWith('pool:',[StringComparison]::OrdinalIgnoreCase)){$Endpoint.Substring(5)}else{$Endpoint}
    $path=Get-SCMachineEndpointCatalogPath
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    try{$catalog=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json}catch{return $null}
    if(-not$catalog.PSObject.Properties['entries'] -or -not$catalog.entries){return $null}
    $prop=$catalog.entries.PSObject.Properties[$catalogId]
    if($null-eq$prop){return $null}
    $entry=$prop.Value
    return [pscustomobject][ordered]@{
        name=('pool:'+$catalogId)
        config=[pscustomobject][ordered]@{
            type='api'
            connection=[string]$entry.connection
            model=[string]$entry.model
            toolMode=if($entry.PSObject.Properties['toolMode'] -and $entry.toolMode){[string]$entry.toolMode}else{'native'}
            supportsTools=if($entry.PSObject.Properties['supportsTools']){$entry.supportsTools}else{$null}
            contextLength=if($entry.PSObject.Properties['contextLength']){$entry.contextLength}else{$null}
        }
    }
}

function Ensure-SCManagedHarnessRoutes {
    if($env:SC_DISABLE_MANAGED_OPENCODE -eq '1'){return}
    if(-not$env:SC_OPENCODE_EXE -and -not(Get-Command opencode -ErrorAction SilentlyContinue)){return}
    try{
        [void](Invoke-SCCompiledRouterCommand @('ensure-harness','--adapter','opencode','--working-directory',(Get-SCRoot)))
    }catch{
        try{Add-SCEvent 'routing.harness_discovery_failed' "Managed OpenCode capacity was unavailable; continuing with ordinary endpoints." @{adapter='opencode';error=$_.Exception.Message}}catch{}
    }
}

function Invoke-SCProviderViaCompiledRouter($Task,[string]$Prompt,[string]$Stage,[string]$ParentAgentId=$null,$Compilation=$null,[string]$WorkerSessionId=$null,[string]$ContinuationMessage=$null,[string]$EndpointOverride=$null,[string]$ConnectionOverride=$null) {
    if(-not$EndpointOverride -and -not$ConnectionOverride){Ensure-SCManagedHarnessRoutes}
    $history=@()
    $routeSnapshot=Get-SCRouteSnapshotReceipt
    Set-SCProperty $routeSnapshot 'router' 'compiled'
    $preferred=$EndpointOverride
    if(-not$preferred -and -not$ConnectionOverride -and $Stage-eq'run' -and $WorkerSessionId){
        $pin=Get-SCWorkerSessionRoutePin $WorkerSessionId
        if($pin){$preferred=[string]$pin.endpoint}
    }

    $cfg=Get-SCConfig;$max=6
    if($cfg.PSObject.Properties['routing'] -and $cfg.routing -and $cfg.routing.PSObject.Properties['maxRouteAttempts']){
        try{$max=[Math]::Min(32,[Math]::Max(1,[int]$cfg.routing.maxRouteAttempts))}catch{}
    }

    $last=$null
    for($attempt=1;$attempt-le$max;$attempt++){
        $acquireArgs=@('acquire','--owner-pid',[string]$PID,'--working-directory',(Get-SCRoot))
        if($WorkerSessionId){$acquireArgs+=@('--session',$WorkerSessionId)}
        if($preferred){$acquireArgs+=@('--preferred',$preferred)}
        if($ConnectionOverride){$acquireArgs+=@('--connection',$ConnectionOverride)}
        if($EndpointOverride){$acquireArgs+=@('--strict-preferred','true')}
        $acquire=Invoke-SCCompiledRouterCommand $acquireArgs

        if(-not[bool]$acquire.ok){
            $now=[datetimeoffset]::UtcNow
            $retry=$now.AddSeconds(2)
            $diagnostic=$null
            if($acquire.data){
                try{$diagnostic=$acquire.data|ConvertTo-Json -Depth 12 -Compress}catch{$diagnostic=[string]$acquire.data}
                Set-SCProperty $routeSnapshot 'acquireDiagnostic' $acquire.data
            }
            if($acquire.data -and $acquire.data.PSObject.Properties['nextRetryAt'] -and $acquire.data.nextRetryAt){
                $parsed=[datetimeoffset]::MinValue
                if([datetimeoffset]::TryParse([string]$acquire.data.nextRetryAt,[ref]$parsed)){$retry=$parsed}
            }elseif($acquire.data -and $acquire.data.PSObject.Properties['retryAfterSeconds']){
                try{$retry=$now.AddSeconds([double]$acquire.data.retryAfterSeconds)}catch{}
            }
            return [pscustomobject][ordered]@{
                schemaVersion=4;id=New-SCId $Stage;agentId=New-SCId 'agent';taskId=$Task.id;stage=$Stage
                provider=if($preferred){$preferred}else{$ConnectionOverride};endpoint=$preferred;connection=$ConnectionOverride;workerSessionId=$WorkerSessionId;workerSessionResumable=([bool]$WorkerSessionId)
                compilationId=if($Compilation){$Compilation.id}else{$null};inputFingerprint=if($Compilation){$Compilation.inputFingerprint}else{$null}
                command='compiled-router';args=@();promptPath=$null;startedAt=$now.ToString('o');endedAt=$now.ToString('o');durationSeconds=0
                exitCode=-3;stdout='';stderr=(([string]$acquire.error)+$(if($diagnostic){[Environment]::NewLine+'Router diagnostic: '+$diagnostic}else{''}));routeDeferred=$true;retryAfter=$retry.ToString('o')
                routeAttempts=$history.Count;routeHistory=@($history);routeSnapshot=$routeSnapshot;compiledRouter=$true
            }
        }

        $leaseToken=[string]$acquire.data.lease
        $endpoint=[string]$acquire.data.endpoint
        $record=Get-SCMachineEndpointRecord $endpoint
        $released=$false
        if($null-eq$record){
            try{[void](Invoke-SCCompiledRouterCommand @('failure','--lease',$leaseToken,'--class','configuration','--message',"Endpoint $endpoint disappeared from the catalog after lease acquisition."));$released=$true}catch{}
            $history+=,[ordered]@{endpoint=$endpoint;outcome='failed';failureClass='configuration';healthScope='connection'}
            if($EndpointOverride){throw "Explicit endpoint '$EndpointOverride' disappeared from the endpoint catalog after lease acquisition."}
            $preferred=$null
            continue
        }

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

            $failure=Invoke-SCCompiledRouterCommand @('failure','--lease',$leaseToken,'--message',$text)
            $released=$true
            $class=if($failure.data -and $failure.data.PSObject.Properties['failureClass']){[string]$failure.data.failureClass}else{'request_error'}
            $scope=if($failure.data -and $failure.data.PSObject.Properties['scope']){[string]$failure.data.scope}else{'request'}
            $key=if($failure.data -and $failure.data.PSObject.Properties['key']){[string]$failure.data.key}else{$null}
            $canFailover=if($failure.data -and $failure.data.PSObject.Properties['failoverAllowed']){[bool]$failure.data.failoverAllowed}else{$false}
            $history+=,[ordered]@{endpoint=$endpoint;connection=[string]$record.config.connection;model=[string]$record.config.model;outcome='failed';failureClass=$class;healthScope=$scope;healthKey=$key}
            Set-SCProperty $receipt 'routeAttempts' $history.Count
            Set-SCProperty $receipt 'routeHistory' @($history)
            Set-SCProperty $receipt 'compiledRouter' $true

            if($EndpointOverride){
                Add-SCEvent 'routing.endpoint_override_failed' "Explicit endpoint override $EndpointOverride failed ($class); not failing over to another endpoint." @{taskId=$Task.id;stage=$Stage;endpoint=$endpoint;failureClass=$class}
                return $receipt
            }
            if(-not$canFailover){
                Add-SCEvent 'routing.failover_stopped' "Compiled router stopped replay after non-failover failure: $class" @{taskId=$Task.id;stage=$Stage;endpoint=$endpoint;failureClass=$class}
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

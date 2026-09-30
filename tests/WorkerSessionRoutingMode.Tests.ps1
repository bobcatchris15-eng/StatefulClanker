<# A resumed transcript retains its protocol when pool negotiation changes. #>
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Value,[string]$Message){if(-not$Value){throw "SESSION ROUTING MODE TEST FAILED: $Message"}}
$router=Join-Path $repo 'src/StatefulClanker.Router/bin/Debug/net8.0-windows/StatefulClanker.Router.exe'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-session-mode-'+[guid]::NewGuid().ToString('N'))
$oldRoot=$env:SC_ROUTER_ROOT
$daemon=$null
New-Item -ItemType Directory -Path $temp|Out-Null
Push-Location $temp
try{
    $env:SC_ROUTER_ROOT=Join-Path $temp 'router'
    New-Item -ItemType Directory -Path $env:SC_ROUTER_ROOT|Out-Null
    @{
        schemaVersion=2;entries=@{
            'native::model'=@{id='native::model';connection='native';model='model';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='native'}
            'text::model'=@{id='text::model';connection='text';model='model';enabled=$true;workhorse=$true;supportsTools=$false;toolMode='text'}
        }
    }|ConvertTo-Json -Depth 20|Set-Content (Join-Path $env:SC_ROUTER_ROOT 'endpoints.json')
    @{schemaVersion=2;connections=@{
        native=@{name='native';protocol='openai-chat';baseUrl='http://127.0.0.1:65531/v1';authKind='none';headers=@{}}
        text=@{name='text';protocol='openai-chat';baseUrl='http://127.0.0.1:65532/v1';authKind='none';headers=@{}}
    }}|ConvertTo-Json -Depth 20|Set-Content (Join-Path $env:SC_ROUTER_ROOT 'connections.json')
    $daemon=Start-Process $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden
    $ready=$false
    foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{if((& $router ping|ConvertFrom-Json).ok){$ready=$true;break}}catch{}}
    Assert-True $ready 'Isolated router did not start.'
    . (Join-Path $repo 'lib/StatefulClanker.Core.ps1')
    Set-SCRoots $temp $temp
    . (Join-Path $repo 'lib/StatefulClanker.WorkerRuntime.ps1')
    . (Join-Path $repo 'lib/StatefulClanker.CompiledRouting.ps1')
    New-Item -ItemType Directory -Path (Join-Path $temp '.statefulclanker')|Out-Null
    Write-SCJson (Get-SCPath 'state.json') ([ordered]@{schemaVersion=4;revision=0;directionRevision=0;projectId='session-mode';projectRoot=$temp;goal='';activePlanId=$null;planApproved=$true;createdAt=[datetimeoffset]::UtcNow.ToString('o');updatedAt=[datetimeoffset]::UtcNow.ToString('o')})
    ''|Set-Content (Get-SCPath 'events.jsonl')
    function Get-SCConfig {return [pscustomobject]@{routing=[pscustomobject]@{endpoints=@($script:allowed);maxRouteWaitSeconds=0}}}
    function Get-SCRouteSnapshotReceipt {return [pscustomobject]@{}}
    function Invoke-SCCompiledRouterCommand([string[]]$Arguments){return (& $router @Arguments|ConvertFrom-Json)}
    $task=[pscustomobject]@{id='mode-task'}
    $compilation=[pscustomobject]@{id='mode-compilation';inputFingerprint='same-context'}
    $continuation='continue existing work'
    function Invoke-SCDirectApiProvider($Task,[string]$Prompt,[string]$Stage,$ProviderRecord,[string]$ParentAgentId,$Compilation,[string]$WorkerSessionId,[string]$ContinuationMessage){
        $session=Sync-SCWorkerSessionContext $WorkerSessionId $Task $Compilation $Prompt $ProviderRecord.config.toolMode @() $ContinuationMessage
        if($script:expectDeferred){
            # Exercise the actual inference gateway: no transport is reached
            # when a native transcript has only text endpoints available.
            $request=Join-Path $temp 'request.json'
            @{messages=@($session.messages);tools=@();toolMode=$ProviderRecord.config.toolMode;maxRouteWaitSeconds=0;maxRouteAttempts=1}|ConvertTo-Json -Depth 30|Set-Content $request
            $result=Invoke-SCCompiledRouterCommand @('infer','--request-file',$request,'--endpoints',$script:allowed,'--session',$WorkerSessionId)
            Assert-True ($result.ok -and $result.data.routeDeferred -and $result.data.routeAttempts-eq0) 'Incompatible session reached transport instead of deferring.'
            return [pscustomobject]@{exitCode=-3;stdout='';stderr=$result.data.diagnosis.summary;routeDeferred=$true;retryAfter=$result.data.nextRetryAt;routeAttempts=0;workerSessionId=$WorkerSessionId;workerSessionResumable=$true}
        }
        $route=Invoke-SCCompiledRouterCommand @('acquire','--endpoints',$script:allowed,'--require-tools','false','--session',$WorkerSessionId,'--owner-pid',[string]$PID)
        Assert-True $route.ok 'Native endpoint was unavailable to text protocol session.'
        try{return [pscustomobject]@{exitCode=0;stdout='resumed';stderr='';endpoint=$route.data.endpoint;connection=$route.data.connection;model=$route.data.model;workerSessionId=$WorkerSessionId;workerSessionResumable=$true;routeAttempts=1;routeHistory=@()}}
        finally{[void](Invoke-SCCompiledRouterCommand @('release','--lease',$route.data.lease))}
    }
    foreach($case in @(@{mode='native';allowed='text::model';deferred=$true},@{mode='text';allowed='native::model';deferred=$false})){
        $script:allowed=$case.allowed;$script:expectDeferred=$case.deferred
        $id='session-'+$case.mode
        $priorMessages=@([pscustomobject]@{role='assistant';content='existing reasoning'})
        if($case.mode-eq'native'){
            $priorMessages+=,[pscustomobject]@{role='assistant';content=$null;tool_calls=@([pscustomobject]@{id='prior-call';type='function';function=[pscustomobject]@{name='read_file';arguments='{"path":"existing.txt"}'}})}
            $priorMessages+=,[pscustomobject]@{role='tool';tool_call_id='prior-call';content='existing file contents'}
        }
        Save-SCWorkerSession ([pscustomobject]@{id=$id;taskId=$task.id;status='active';toolMode=$case.mode;workRoot=$temp;compilationId=$compilation.id;inputFingerprint=$compilation.inputFingerprint;pinnedEndpoint=$null;pinnedConnection=$null;pinnedModel=$null;messages=$priorMessages;appliedContinuations=@()})
        $priorJson=(Get-SCWorkerSession $id).messages|ConvertTo-Json -Depth 30 -Compress
        $receipt=Invoke-SCProviderViaCompiledRouter $task 'original prompt' 'run' $null $compilation $id $continuation
        Assert-True ($receipt.exitCode-eq $(if($case.deferred){-3}else{0})) "Session $($case.mode) failed: $($receipt.stderr)"
        Assert-True ($receipt.negotiatedToolMode-eq$case.mode) 'Bridge replaced persisted transcript mode with current pool preference.'
        Assert-True ($receipt.workerSessionId-eq$id -and $receipt.workerSessionResumable) 'Receipt lost resumable session identity.'
        $persisted=Get-SCWorkerSession $id
        Assert-True ($persisted.toolMode-eq$case.mode -and $persisted.workRoot-eq$temp) 'Session mode or worktree changed.'
        Assert-True (@($persisted.messages|Where-Object{$_.content-eq'existing reasoning'}).Count-eq1) 'Existing transcript was converted or discarded.'
        $retainedJson=@($persisted.messages|Select-Object -First $priorMessages.Count)|ConvertTo-Json -Depth 30 -Compress
        Assert-True ($retainedJson-ceq$priorJson) 'Prior native tool calls or tool results were converted.'
        Assert-True (@($persisted.messages|Where-Object{$_.content-eq$continuation}).Count-eq1) 'Continuation was lost or duplicated.'
        Write-Host "PASS: $($case.mode) session retains transcript protocol with pool $($case.allowed)."
    }
}finally{
    if($daemon -and -not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force}
    $env:SC_ROUTER_ROOT=$oldRoot
    Pop-Location
    Remove-Item -LiteralPath $temp -Recurse -Force
}

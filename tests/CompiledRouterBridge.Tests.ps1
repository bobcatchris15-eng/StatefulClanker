<# Verifies that PowerShell is a thin endpoint-agnostic client of ClankerRouter. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "COMPILED ROUTER BRIDGE TEST FAILED: $Message"}}

. (Join-Path $repo 'lib\StatefulClanker.CompiledRouting.ps1')
$realAllowlistFunction=${function:Get-SCProjectRoutingAllowlist}

function Get-SCConfig { return [pscustomobject]@{routing=[pscustomobject]@{maxRouteAttempts=6;maxRouteWaitSeconds=20}} }
function Get-SCProjectRoutingAllowlist { return @('a::m1','b::m2') }
function Get-SCRouteSnapshotReceipt { return [pscustomobject]@{selectedAt=[datetimeoffset]::UtcNow.ToString('o')} }
function Get-SCWorkerSessionRoutePin([string]$SessionId) { return [pscustomobject]@{endpoint='pool:a::m1';connection='a';model='m1'} }
function Get-SCWorkerSession([string]$SessionId) { return $null }
$script:lastPin=$null
function Set-SCWorkerSessionRoutePin([string]$SessionId,[string]$Endpoint,[string]$Connection,[string]$Model) {
    $script:lastPin=[pscustomobject]@{endpoint=$Endpoint;connection=$Connection;model=$Model}
}
$script:events=@()
function Add-SCEvent { param($Type,$Message,$Data);$script:events+=,[pscustomobject]@{type=$Type;data=$Data} }
function Set-SCProperty($Object,[string]$Name,$Value) {
    if($Object.PSObject.Properties[$Name]){$Object.$Name=$Value}else{$Object|Add-Member -NotePropertyName $Name -NotePropertyValue $Value}
}
function New-SCId([string]$Prefix){return "$Prefix-test"}

$script:routerCalls=@()
function Invoke-SCCompiledRouterCommand([string[]]$Arguments) {
    $script:routerCalls+=,@($Arguments)
    Assert-True ($Arguments[0]-eq'negotiate') 'PowerShell bridge called acquire/infer routing commands directly instead of negotiation.'
    return [pscustomobject]@{ok=$true;data=[pscustomobject]@{toolMode='native';healthyCandidates=2;nativeCandidates=2;currentlyAvailable=$true}}
}

$script:providerCalls=0
$script:seenRecord=$null
function Invoke-SCDirectApiProvider($Task,[string]$Prompt,[string]$Stage,$ProviderRecord,[string]$ParentAgentId,$Compilation,[string]$WorkerSessionId,[string]$ContinuationMessage) {
    $script:providerCalls++
    $script:seenRecord=$ProviderRecord
    return [pscustomobject][ordered]@{
        id='r1';taskId=$Task.id;stage=$Stage;provider='router:auto'
        endpoint='pool:b::m2';connection='b';model='m2'
        exitCode=0;stdout='ok';stderr=''
        routeAttempts=2
        routeHistory=@(
            [pscustomobject]@{attempt=1;endpoint='pool:a::m1';connection='a';model='m1';outcome='failed';failureClass='rate_limited';scope='endpoint'},
            [pscustomobject]@{attempt=2;endpoint='pool:b::m2';connection='b';model='m2';outcome='success'}
        )
    }
}

Write-Host '  BRIDGE 1: PowerShell negotiates capability class but never acquires an endpoint'
$task=[pscustomobject]@{id='bridge-task'}
$receipt=Invoke-SCProviderViaCompiledRouter $task 'do work' 'run' $null $null 'ws-bridge' $null
Assert-True ([int]$receipt.exitCode-eq0) 'Router-managed provider receipt did not succeed.'
Assert-True ([bool]$receipt.compiledRouter) 'Receipt did not identify compiled routing.'
Assert-True ($script:routerCalls.Count-eq1) 'Bridge made more than one direct router control call.'
Assert-True ($script:providerCalls-eq1) 'PowerShell retried the provider instead of letting ClankerRouter fail over internally.'
Assert-True ([bool]$script:seenRecord.config.routerManaged) 'Provider record was not marked router-managed.'
Assert-True ([string]$script:seenRecord.config.toolMode-eq'native') 'Negotiated tool mode was not passed to worker runtime.'
Assert-True ([string]$script:seenRecord.config.preferred-eq'pool:a::m1') 'Soft session affinity hint was lost.'
Assert-True (-not[bool]$script:seenRecord.config.strictPreferred) 'Session affinity was incorrectly made a hard endpoint pin.'
Assert-True (@($script:seenRecord.config.allowedEndpoints).Count-eq2) 'Project endpoint allowlist was not passed through.'

Write-Host '  BRIDGE 2: router-internal failover remains telemetry, not PowerShell control flow'
Assert-True (@($receipt.routeHistory).Count-eq2) 'Router route history was not preserved on the receipt.'
Assert-True ([string]$script:lastPin.endpoint-eq'pool:b::m2') 'Final successful endpoint was not retained as soft session affinity.'
Assert-True (@($script:events|Where-Object{$_.type-eq'routing.failover_succeeded'}).Count-eq1) 'Transparent failover success was not surfaced as telemetry.'
Write-Host 'PASS: PowerShell delegates endpoint selection and failover to ClankerRouter.'

Write-Host '  BRIDGE 3: real project allowlists retain negotiation and worker argument shape under StrictMode'
# Restore production parsing after the earlier bridge tests' fixed allowlist double.
${function:Get-SCProjectRoutingAllowlist}=$realAllowlistFunction
function Get-SCConfig { return $script:allowlistConfig }
Set-StrictMode -Version 2.0
$allowlistCases=@(
    @{name='missing routing';config=[pscustomobject]@{};expected=@()},
    @{name='missing endpoints';config=[pscustomobject]@{routing=[pscustomobject]@{}};expected=@()},
    @{name='empty endpoints';config=[pscustomobject]@{routing=[pscustomobject]@{endpoints=@()}};expected=@()},
    @{name='singleton';config=[pscustomobject]@{routing=[pscustomobject]@{endpoints=@('a::m1')}};expected=@('a::m1')},
    @{name='multiple';config=[pscustomobject]@{routing=[pscustomobject]@{endpoints=@('a::m1','b::m2')}};expected=@('a::m1','b::m2')}
)
$allowlistFailures=@()
foreach($case in $allowlistCases){
    $script:allowlistConfig=$case.config
    $script:routerCalls=@()
    $script:providerCalls=0
    $script:seenRecord=$null
    try{
        $caseReceipt=Invoke-SCProviderViaCompiledRouter $task 'do work' 'run' $null $null 'ws-bridge' $null
        Assert-True ($caseReceipt.exitCode-eq0) "$($case.name): dispatch failed."
        Assert-True ($script:routerCalls.Count-eq1 -and $script:providerCalls-eq1) "$($case.name): expected one negotiation and provider invocation."
        $expectedArgs=@('negotiate','--preferred','pool:a::m1')
        if($case.expected.Count-gt0){$expectedArgs+=@('--endpoints',($case.expected-join','))}
        Assert-True (($script:routerCalls[0]-join '|')-ceq($expectedArgs-join '|')) "$($case.name): negotiation changed endpoint arguments."
        $actual=$script:seenRecord.config.allowedEndpoints
        Assert-True ($actual -is [array]) "$($case.name): allowedEndpoints must be an actual array."
        Assert-True ($actual.Count-eq$case.expected.Count) "$($case.name): allowedEndpoints count changed."
        Assert-True (($actual-join '|')-ceq($case.expected-join '|')) "$($case.name): allowedEndpoints values changed."
        Write-Host "    PASS: $($case.name)"
    }catch{
        $allowlistFailures+=,"$($case.name): $($_.Exception.Message)"
        Write-Host "    FAIL: $($allowlistFailures[-1])"
    }
}
Assert-True ($allowlistFailures.Count-eq0) ($allowlistFailures-join '; ')
Write-Host 'PASS: real allowlists dispatch with exact negotiation arguments and worker arrays.'

Write-Host '  BRIDGE 4: resumed durable session migrates excluded affinity through actual router acquisition'
$router=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-router-bridge-'+[guid]::NewGuid().ToString('N'))
$oldRoot=$env:SC_ROUTER_ROOT
$daemon=$null
New-Item -ItemType Directory -Force -Path $temp|Out-Null
Push-Location $temp
try{
    $env:SC_ROUTER_ROOT=Join-Path $temp 'router'
    New-Item -ItemType Directory -Force -Path $env:SC_ROUTER_ROOT|Out-Null
    @{
        schemaVersion=2;entries=@{
            'a::m1'=@{id='a::m1';connection='a';model='m1';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='native'}
            'b::m2'=@{id='b::m2';connection='b';model='m2';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='native'}
        }
    }|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $env:SC_ROUTER_ROOT 'endpoints.json') -Encoding UTF8
    @{
        schemaVersion=2;connections=@{
            a=@{name='a';presetId='custom';protocol='openai-chat';baseUrl='http://127.0.0.1:65531/v1';authKind='none';headers=@{}}
            b=@{name='b';presetId='custom';protocol='openai-chat';baseUrl='http://127.0.0.1:65532/v1';authKind='none';headers=@{}}
        }
    }|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $env:SC_ROUTER_ROOT 'connections.json') -Encoding UTF8
    $daemon=Start-Process -FilePath $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden
    $ready=$false
    foreach($i in 1..30){
        Start-Sleep -Milliseconds 100
        try{$ping=& $router ping|ConvertFrom-Json;if($ping.ok){$ready=$true;break}}catch{}
    }
    Assert-True $ready 'Isolated bridge router did not become ready.'

    # Use real durable session/context/pin functions. Only the provider transport
    # seam is replaced; negotiation and endpoint acquisition use the actual daemon.
    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    Set-SCRoots $temp $temp
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')
    New-Item -ItemType Directory -Force -Path (Join-Path $temp '.statefulclanker')|Out-Null
    Write-SCJson (Get-SCPath 'state.json') ([ordered]@{
        schemaVersion=4;revision=0;directionRevision=0;projectId='router-bridge-test';projectRoot=$temp
        goal='';activePlanId=$null;planApproved=$true
        createdAt=[datetimeoffset]::UtcNow.ToString('o');updatedAt=[datetimeoffset]::UtcNow.ToString('o')
    })
    ''|Set-Content -LiteralPath (Get-SCPath 'events.jsonl') -Encoding UTF8
    function Get-SCConfig { return [pscustomobject]@{routing=[pscustomobject]@{endpoints=@('b::m2')}} }
    function Get-SCMachineEndpointCatalogPath { return Join-Path $env:SC_ROUTER_ROOT 'endpoints.json' }
    function Invoke-SCCompiledRouterCommand([string[]]$Arguments) { return (& $router @Arguments|ConvertFrom-Json) }
    $resumeId='ws-bridge-resume'
    $resumeTask=[pscustomobject]@{id='bridge-resume-task';latestWorkerSessionId=$resumeId}
    $compilation=[pscustomobject]@{id='compiled-resume';inputFingerprint='existing-context'}
    $continuation='CONTINUATION: preserve existing work and finish validation'
    Save-SCWorkerSession ([pscustomobject]@{
        id=$resumeId;taskId=$resumeTask.id;status='validator-error';toolMode='native';workRoot=$temp
        compilationId=$compilation.id;inputFingerprint=$compilation.inputFingerprint
        pinnedEndpoint='pool:a::m1';pinnedConnection='a';pinnedModel='m1'
        messages=@([pscustomobject]@{role='user';content='original task'},[pscustomobject]@{role='assistant';content='existing work and reasoning'})
        appliedContinuations=@()
    })
    Assert-True ((Get-SCReusableWorkerSessionId $resumeTask)-eq$resumeId) 'Existing session could not be resumed.'
    function Invoke-SCDirectApiProvider($Task,[string]$Prompt,[string]$Stage,$ProviderRecord,[string]$ParentAgentId,$Compilation,[string]$WorkerSessionId,[string]$ContinuationMessage) {
        Assert-True ($WorkerSessionId-eq$resumeId -and $ProviderRecord.config.sessionId-eq$resumeId) 'Bridge changed resumed worker session identity.'
        Assert-True ($ContinuationMessage-ceq$continuation) 'Bridge lost continuation argument.'
        Assert-True ($ProviderRecord.config.preferred-eq'pool:a::m1' -and -not$ProviderRecord.config.strictPreferred) 'Stale session pin was dropped or made strict.'
        $session=Sync-SCWorkerSessionContext $WorkerSessionId $Task $Compilation $Prompt $ProviderRecord.config.toolMode @() $ContinuationMessage
        Assert-True (@($session.messages|Where-Object{$_.content-eq'existing work and reasoning'}).Count-eq1) 'Resume discarded the prior transcript.'
        Assert-True (@($session.messages|Where-Object{$_.content-ceq$ContinuationMessage}).Count-eq1) 'Continuation was not appended exactly once.'
        $acquire=Invoke-SCCompiledRouterCommand @('acquire','--preferred',$ProviderRecord.config.preferred,'--strict-preferred',([string]$ProviderRecord.config.strictPreferred).ToLowerInvariant(),'--endpoints',($ProviderRecord.config.allowedEndpoints-join','),'--require-tools',([string]($ProviderRecord.config.toolMode-eq'native')).ToLowerInvariant(),'--session',$WorkerSessionId,'--owner-pid',[string]$PID)
        Assert-True ([bool]$acquire.ok) "Allowed acquisition failed: $($acquire|ConvertTo-Json -Depth 10 -Compress)"
        try{
            Assert-True ($acquire.data.endpoint-eq'pool:b::m2' -and -not$acquire.data.preferredHonored) 'Acquisition escaped allowlist or honored excluded affinity.'
            $snapshot=Invoke-SCCompiledRouterCommand @('snapshot')
            Assert-True (@($snapshot.data.leases|Where-Object{$_.sessionId-eq$WorkerSessionId -and $_.route-eq'pool:b::m2'}).Count-eq1) 'Allowed lease lost resumed session identity.'
            Assert-True ((Get-SCWorkerSessionRoutePin $WorkerSessionId).endpoint-eq'pool:a::m1') 'Pin changed before successful provider completion.'
            return [pscustomobject]@{exitCode=0;stdout='continued';stderr='';endpoint=$acquire.data.endpoint;connection=$acquire.data.connection;model=$acquire.data.model;workerSessionId=$WorkerSessionId;workerSessionResumable=$true;routeAttempts=1;routeHistory=@()}
        }finally{[void](Invoke-SCCompiledRouterCommand @('release','--lease',$acquire.data.lease))}
    }
    $resumedReceipt=Invoke-SCProviderViaCompiledRouter $resumeTask 'original task' 'run' $null $compilation $resumeId $continuation
    Assert-True ($resumedReceipt.exitCode-eq0) "Resumed bridge dispatch failed: $($resumedReceipt.stderr)"
    Assert-True ($resumedReceipt.workerSessionId-eq$resumeId) 'Successful receipt changed worker session identity.'
    $persisted=Get-SCWorkerSession $resumeId
    Assert-True ($persisted.id-eq$resumeId -and $persisted.workRoot-eq$temp) 'Migration changed session identity or work root.'
    Assert-True (@($persisted.messages|Where-Object{$_.content-eq'existing work and reasoning'}).Count-eq1) 'Migration discarded prior transcript.'
    Assert-True (@($persisted.messages|Where-Object{$_.content-ceq$continuation}).Count-eq1) 'Migration discarded or duplicated continuation.'
    Assert-True ($persisted.pinnedEndpoint-eq'pool:b::m2' -and $persisted.pinnedConnection-eq'b' -and $persisted.pinnedModel-eq'm2') 'Successful bridge completion did not persist the selected allowed route.'
    Write-Host 'PASS: same durable session resumes, acquires allowed endpoint, preserves transcript and continuation, and updates affinity on successful completion.'
}finally{
    if($daemon -and -not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    $env:SC_ROUTER_ROOT=$oldRoot
    Pop-Location
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

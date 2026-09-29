<# Verifies that PowerShell is a thin endpoint-agnostic client of ClankerRouter. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "COMPILED ROUTER BRIDGE TEST FAILED: $Message"}}

. (Join-Path $repo 'lib\StatefulClanker.CompiledRouting.ps1')

function Get-SCConfig { return [pscustomobject]@{routing=[pscustomobject]@{maxRouteAttempts=6;maxRouteWaitSeconds=20}} }
function Get-SCProjectRoutingAllowlist { return @('a::m1','b::m2') }
function Get-SCRouteSnapshotReceipt { return [pscustomobject]@{selectedAt=[datetimeoffset]::UtcNow.ToString('o')} }
function Get-SCWorkerSessionRoutePin([string]$SessionId) { return [pscustomobject]@{endpoint='pool:a::m1';connection='a';model='m1'} }
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

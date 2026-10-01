$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ROUTING AVAILABILITY TEST FAILED: $Message"}}

$engine=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Router\RouterEngine.cs')
$reducer=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Router\RoutingHealthReducer.cs')
$policy=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Router\FailurePolicy.cs')
$gateway=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Router\Inference\InferenceGateway.cs')
$bridge=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.CompiledRouting.ps1')

Write-Host '  ROUTING AVAILABILITY 1: acquire heals expired cooldown state before filtering'
$dll=if($env:SC_TEST_ROUTER_DLL){$env:SC_TEST_ROUTER_DLL}else{Join-Path $repo 'src/StatefulClanker.Router/bin/Debug/net8.0-windows/StatefulClanker.Router.dll'}
[void][Reflection.Assembly]::LoadFrom($dll)
$tempRoot=[IO.Path]::GetTempPath()
$fixture=Join-Path $tempRoot ('sc-availability-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $fixture|Out-Null
    @{schemaVersion=3;entries=@{'mock::one'=@{id='mock::one';connection='mock';model='one';enabled=$true;workhorse=$true;free=$true}}}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $fixture 'endpoints.json')
    @{schemaVersion=2;connections=@{mock=@{name='mock';presetId='custom';protocol='openai-chat';baseUrl='http://127.0.0.1:1/v1';authKind='none';headers=@{}}}}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $fixture 'connections.json')
    $store=[StatefulClanker.Router.RouterStore]::new($fixture)
    $runtime=[StatefulClanker.Router.RouterEngine]::new($store)
    $healthReducer=[StatefulClanker.Router.RoutingHealthReducer]::new($store,[StatefulClanker.Router.SignalStore]::new($fixture))
    [void]$healthReducer.RegisterFailure('pool:mock::one','endpoint','timeout','timeout',$null)
    $health=$store.LoadHealth();$entry=$health.endpoints['pool:mock::one']
    $entry.retryAfter=[datetimeoffset]::UtcNow.AddMinutes(-1).ToString('O');$entry.lastSuccess='2020-01-01T00:00:00Z';$store.SaveHealth($health)
    $acquired=$runtime.Acquire($null,$null,$false,'availability-test',$false,$PID)
    Assert-True $acquired.ok 'Acquire did not make an expired endpoint eligible.'
    $entry=$store.LoadHealth().endpoints['pool:mock::one']
    Assert-True ($entry.state -eq 'healthy') 'Expired endpoint remains blocked.'
    Assert-True ($entry.lastSuccess -eq '2020-01-01T00:00:00Z') 'Cooldown expiry fabricated a successful provider observation.'
    [void]$runtime.Release([string]$acquired.data.lease)
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture)
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath($tempRoot),[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup path.'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}

Write-Host '  ROUTING AVAILABILITY 2: tool capability is negotiated independently of endpoint identity'
Assert-True ($engine.Contains('requiredToolMode')) 'Acquire cannot enforce negotiated tool-mode compatibility.'
Assert-True ($engine.Contains('public RouterResponse Negotiate(')) 'Router has no endpoint-free capability negotiation surface.'
Assert-True ($bridge.Contains("@('negotiate')")) 'PowerShell bridge does not negotiate capability class before inference.'
Assert-True (-not $bridge.Contains("@('acquire'")) 'PowerShell bridge still owns endpoint acquisition.'

Write-Host '  ROUTING AVAILABILITY 3: transient provider failures stay granular'
Assert-True ([StatefulClanker.Router.FailurePolicy]::ScopeFor('billing_exhausted') -eq 'connection') 'Credential/account-wide scope mapping changed unexpectedly.'
foreach($failure in @('protocol_error','timeout','server_error','provider_tool_output_invalid')){
    Assert-True ([StatefulClanker.Router.FailurePolicy]::ScopeFor($failure) -eq 'endpoint') 'Provider failures must remain endpoint-local.'
}
Assert-True ($gateway.Contains('requestExcluded.Add(route.RouteName)')) 'Request-scoped incompatibility cannot move to another endpoint without poisoning health.'

Write-Host '  ROUTING AVAILABILITY 4: inference owns wait/failover and returns one scheduler result'
Assert-True ($gateway.Contains('while(routeAttempt<maxAttempts)')) 'Inference does not own a bounded internal route-attempt loop.'
Assert-True ($gateway.Contains('await Task.Delay(delay,token)')) 'Router cannot wait through a temporary no-route window.'
Assert-True ($gateway.Contains('routeAttempt++;')) 'Actual inference attempts are not accounted separately from route polling.'
Assert-True ($gateway.Contains('last.routeExhausted=true')) 'Attempted pool exhaustion is not collapsed into one terminal router result.'
Assert-True ($gateway.Contains('routeDeferred=true')) 'Never-dispatched route unavailability is not distinguished from exhaustion.'

Write-Host 'PASS: endpoint availability self-heals, routing stays inside ClankerRouter, and callers receive one reduced availability result.'

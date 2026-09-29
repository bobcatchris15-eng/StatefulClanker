$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ROUTING AVAILABILITY TEST FAILED: $Message"}}

$engine=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Router\RouterEngine.cs')
$reducer=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Router\RoutingHealthReducer.cs')
$policy=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Router\FailurePolicy.cs')
$gateway=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Router\Inference\InferenceGateway.cs')
$bridge=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.CompiledRouting.ps1')

Write-Host '  ROUTING AVAILABILITY 1: acquire heals expired cooldown state before filtering'
Assert-True ($engine.Contains('NormalizeExpiredCooldowns();')) 'Acquire/snapshot does not normalize expired cooldowns synchronously.'
Assert-True ($reducer.Contains('if(!DateTimeOffset.TryParse(raw,out var due) || due>now) continue;')) 'Health reducer does not respect active retry windows.'
Assert-True ($reducer.Contains('MarkHealthy(kv.Key,"cooldown-expired")')) 'Expired cooldown does not reduce back to healthy.'

Write-Host '  ROUTING AVAILABILITY 2: tool capability is negotiated independently of endpoint identity'
Assert-True ($engine.Contains('requiredToolMode')) 'Acquire cannot enforce negotiated tool-mode compatibility.'
Assert-True ($engine.Contains('public RouterResponse Negotiate(')) 'Router has no endpoint-free capability negotiation surface.'
Assert-True ($bridge.Contains("@('negotiate')")) 'PowerShell bridge does not negotiate capability class before inference.'
Assert-True (-not $bridge.Contains("@('acquire'")) 'PowerShell bridge still owns endpoint acquisition.'

Write-Host '  ROUTING AVAILABILITY 3: transient provider failures stay granular'
Assert-True ($policy.Contains('"billing_exhausted" => "connection"')) 'Credential/account-wide scope mapping changed unexpectedly.'
Assert-True ($policy.Contains('"protocol_error" or "timeout" or "server_error" => "endpoint"')) 'Timeout/5xx failures are still connection-wide.'
Assert-True ($gateway.Contains('requestExcluded.Add(route.RouteName)')) 'Request-scoped incompatibility cannot move to another endpoint without poisoning health.'

Write-Host '  ROUTING AVAILABILITY 4: inference owns wait/failover and returns one scheduler result'
Assert-True ($gateway.Contains('while(routeAttempt<maxAttempts)')) 'Inference does not own a bounded internal route-attempt loop.'
Assert-True ($gateway.Contains('await Task.Delay(delay,token)')) 'Router cannot wait through a temporary no-route window.'
Assert-True ($gateway.Contains('routeAttempt++;')) 'Actual inference attempts are not accounted separately from route polling.'
Assert-True ($gateway.Contains('last.routeExhausted=true')) 'Attempted pool exhaustion is not collapsed into one terminal router result.'
Assert-True ($gateway.Contains('routeDeferred=true')) 'Never-dispatched route unavailability is not distinguished from exhaustion.'

Write-Host 'PASS: endpoint availability self-heals, routing stays inside ClankerRouter, and callers receive one reduced availability result.'

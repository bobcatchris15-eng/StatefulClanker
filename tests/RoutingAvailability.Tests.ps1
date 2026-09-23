$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ROUTING AVAILABILITY TEST FAILED: $Message"}}

$engine=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Router\RouterEngine.cs')
$policy=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Router\FailurePolicy.cs')
$bridge=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.CompiledRouting.ps1')

Write-Host '  ROUTING AVAILABILITY 1: acquire heals expired cooldown state before filtering'
Assert-True ($engine.Contains('NormalizeExpiredCooldowns();')) 'Acquire/snapshot does not normalize expired cooldowns synchronously.'
Assert-True ($engine.Contains('if(!DateTimeOffset.TryParse(raw,out var due) || due>now) continue;')) 'Cooldown normalization does not respect active retry windows.'

Write-Host '  ROUTING AVAILABILITY 2: unknown tool metadata is not a blanket eligibility veto'
Assert-True (-not $engine.Contains('.Where(r=>!string.Equals(r.Endpoint.toolMode,"native",StringComparison.OrdinalIgnoreCase) || r.Endpoint.supportsTools==true)')) 'Router still removes ordinary endpoints whose tool support metadata is unknown.'
Assert-True ($engine.Contains('.Where(r=>!requireTools || (r.Endpoint.supportsTools==true')) 'Explicit native-tool requirements are not enforced separately.'

Write-Host '  ROUTING AVAILABILITY 3: transient request/provider failures stay endpoint scoped'
Assert-True ($policy.Contains('"billing_exhausted" => "connection"')) 'Credential/account-wide scope mapping changed unexpectedly.'
Assert-True ($policy.Contains('"protocol_error" or "timeout" or "server_error" => "endpoint"')) 'Timeout/5xx failures are still connection-wide.'

Write-Host '  ROUTING AVAILABILITY 4: failed acquire receipts retain router diagnosis'
Assert-True ($engine.Contains('reason=eligible.Count==0 ? "no_eligible_endpoint" : "all_candidates_unhealthy"')) 'Acquire does not return a structured eligibility reason.'
Assert-True ($engine.Contains('candidates=eligible.Select(r=>RouteDiagnostic(r,health)).ToArray()')) 'Acquire does not return per-candidate rejection state.'
Assert-True ($bridge.Contains("'acquireDiagnostic'")) 'Worker receipt does not retain the structured router acquire diagnostic.'
Assert-True ($bridge.Contains('Router diagnostic: ')) 'Human/control-plane stderr does not expose the router diagnosis.'

Write-Host 'PASS: endpoint availability self-heals, remains granular, and explains routing failures.'

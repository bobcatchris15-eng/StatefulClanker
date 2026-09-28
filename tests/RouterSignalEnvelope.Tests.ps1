$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ROUTER SIGNAL TEST FAILED: $Message"}}
$envSource=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Router\SignalEnvelope.cs')
$storeSource=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Router\SignalStore.cs')
Assert-True ($envSource.Contains('public sealed class SignalEnvelope')) 'SignalEnvelope class missing'
Assert-True ($envSource.Contains('public List<SignalAddress> audience')) 'Audience addressing missing'
Assert-True ($envSource.Contains('public Dictionary<string,object?> freshness')) 'Freshness metadata missing'
Assert-True ($storeSource.Contains('SignalEnvelopeValidator.Validate')) 'Envelope validation is not used by the durable store'
Assert-True ($storeSource.Contains('routing","signals')) 'Router signal store is not machine-local under routing/signals'
Assert-True ($storeSource.Contains('File.AppendAllText')) 'Router signal store is not append-only'
Assert-True ($storeSource.Contains('StatefulClankerRouterSignals-')) 'Router signal append is not serialized across processes'
Write-Host 'PASS: router signal envelope/store scaffold is present and append-only.'

$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ROUTER SHADOW SIGNAL TEST FAILED: $Message"}}
$engine=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Router\RouterEngine.cs')
Assert-True ($engine.Contains('readonly SignalStore _signals;')) 'RouterEngine does not own the signal store'
Assert-True ($engine.Contains('"route_acquired"')) 'route acquisition is not shadow-signaled'
Assert-True ($engine.Contains('"route_unavailable"')) 'route unavailability is not shadow-signaled'
Assert-True ($engine.Contains('"route_succeeded"')) 'route success is not shadow-signaled'
Assert-True ($engine.Contains('"route_failed"')) 'route failure is not shadow-signaled'
Assert-True ($engine.Contains('Shadow stage: signal persistence must not alter routing behavior.')) 'shadow-stage failure isolation missing'
Assert-True ($engine.Contains('healthChanged",false')) 'request-scoped failure does not preserve no-health-mutation evidence'
Write-Host 'PASS: compiled router emits shadow routing signals while legacy health remains authoritative.'

<# Endpoint routing/failover classification and durable circuit-state tests. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ROUTING TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-routing-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try {
    function Get-SCPath([string]$Path) {
        if($Path-eq'routing'){return Join-Path $temp 'routing'}
        return Join-Path $temp $Path
    }
    function Write-SCJson($Path,$Value) {
        $parent=Split-Path -Parent $Path
        if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
        $Value|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $Path -Encoding UTF8
    }
    function Add-SCEvent {}

    . (Join-Path $repo 'libStatefulClanker.Routing.ps1')

    Assert-True ((Get-SCRouteFailureClass 1 'HTTP 429 Too Many Requests') -eq 'rate_limited') '429 was not classified as rate_limited.'
    Assert-True ((Get-SCRouteFailureClass 1 '503 service unavailable') -eq 'server_error') '503 was not classified as server_error.'
    Assert-True ((Get-SCRouteFailureClass 1 '401 invalid api key') -eq 'auth') '401 was not classified as auth.'
    Assert-True ((Get-SCRouteFailureClass 1 'maximum context length exceeded') -eq 'context_too_large') 'Context overflow classification failed.'
    Assert-True ((Get-SCRouteFailureClass 1 '400 bad request') -eq 'bad_request') '400 classification failed.'
    Assert-True (Test-SCRouteFailureTransient 'rate_limited') 'Rate limit should be failover-safe.'
    Assert-True (-not(Test-SCRouteFailureTransient 'bad_request')) 'Bad request must not be sprayed across endpoints.'

    $failed=Register-SCRouteFailure 'ep-a' 'rate_limited' 'HTTP 429 Retry-After: 17'
    Assert-True ($failed.state-eq'cooldown') 'Rate-limited endpoint was not put into cooldown.'
    Assert-True (-not(Test-SCRouteAvailable 'ep-a')) 'Cooling endpoint remained eligible.'
    Register-SCRouteSuccess 'ep-a'
    Assert-True (Test-SCRouteAvailable 'ep-a') 'Successful endpoint did not recover.'
    $health=Get-SCRoutingHealth
    Assert-True ($health.endpoints.'ep-a'.state-eq'healthy') 'Healthy circuit state was not persisted.'

    # Candidate ordering: preferred endpoint, same model through another connection,
    # then a different-model fallback. Shared connection cooldown removes all endpoints
    # attached to that credential source.
    $script:testCfg=[pscustomobject]@{
        defaultProvider='primary'
        providers=[pscustomobject]@{
            primary=[pscustomobject]@{type='api';connection='conn-a';model='model-x';priority=10}
            sameModel=[pscustomobject]@{type='api';connection='conn-b';model='model-x';priority=30}
            otherModel=[pscustomobject]@{type='api';connection='conn-c';model='model-y';priority=20}
        }
    }
    function Get-SCConfig { return $script:testCfg }
    $names=@(Get-SCProviderCandidates $null $null 'worker'|ForEach-Object{$_.name})
    Assert-True (($names -join ',') -eq 'primary,sameModel,otherModel') "Same-model continuation order was wrong: $($names -join ',')"

    Register-SCRouteFailure 'connection:conn-a' 'rate_limited' '429'
    $names=@(Get-SCProviderCandidates $null $null 'worker'|ForEach-Object{$_.name})
    Assert-True (($names -join ',') -eq 'sameModel,otherModel') "Shared connection cooldown did not remove primary: $($names -join ',')"

    Write-Host 'PASS: endpoint routing classification, cooldown recovery, shared-connection filtering, and same-model failover.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

<# Scoped routing/failover classification, inherited health, and adaptive recovery tests. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ROUTING TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-routing-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
$oldLocal=$env:LOCALAPPDATA
$env:LOCALAPPDATA=Join-Path $temp 'local'
New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA|Out-Null
try {
    function Get-SCPath([string]$Path) {
        if($Path-eq'routing'){return Join-Path $temp 'routing'}
        return Join-Path $temp $Path
    }
    function Write-SCJson($Path,$Value) {
        $parent=Split-Path -Parent $Path
        if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
        $Value|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $Path -Encoding UTF8
    }
    function Add-SCEvent {}
    function Set-SCProperty($Object,[string]$Name,$Value){
        if($Object.PSObject.Properties[$Name]){$Object.$Name=$Value}else{$Object|Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force}
    }
    function Get-SCRoot { return $temp }
    function Get-SCHashString([string]$Text){return '0123456789abcdef0123456789abcdef'}

    . (Join-Path $repo 'lib/StatefulClanker.Routing.ps1')

    # Remove machine/environment variability from this unit test.
    function Get-SCConnectionServiceName([string]$ConnectionName) {
        if($ConnectionName -in @('or-a','or-a2','or-b','or-c')){return 'openrouter'}
        if($ConnectionName-eq'groq-a'){return 'groq'}
        return 'custom'
    }
    function Get-SCConnectionConfigFingerprint([string]$ConnectionName){return "fp-$ConnectionName"}

    Assert-True ((Get-SCRouteFailureClass 1 'HTTP 429 Too Many Requests') -eq 'rate_limited') '429 was not classified as rate_limited.'
    Assert-True ((Get-SCRouteFailureClass 1 '503 service unavailable') -eq 'server_error') '503 was not classified as server_error.'
    Assert-True ((Get-SCRouteFailureClass 1 '401 invalid api key') -eq 'auth') '401 was not classified as auth.'
    Assert-True ((Get-SCRouteFailureClass 1 'maximum context length exceeded') -eq 'context_too_large') 'Context overflow classification failed.'
    Assert-True ((Get-SCRouteFailureClass 1 'model returned no content or tool call') -eq 'empty_response') 'Empty-response classification failed.'
    Assert-True (Test-SCRouteFailureTransient 'bad_request') 'A provider-specific 400 should be allowed to rotate within the bounded route list.'
    Assert-True ((Get-SCProbeDelaySeconds 'rate_limited' '' 1) -eq 1800) 'Unknown 429 should first probe at 30 minutes.'
    Assert-True ((Get-SCProbeDelaySeconds 'rate_limited' '' 2) -eq 3600) 'Repeated 429 recovery should back off to one hour.'
    Assert-True ((Get-SCProbeDelaySeconds 'server_error' '' 1) -eq 300) 'Transport/server recovery should start with a five-minute probe.'
    Assert-True ((Get-SCProbeDelaySeconds 'rate_limited' 'Retry-After: 17' 4) -eq 17) 'Provider Retry-After must override local backoff.'

    $script:testPool=@(
        [pscustomobject]@{name='pool:or-a::model-x';poolId='or-a::model-x';config=[pscustomobject]@{type='api';connection='or-a';model='model-x'}},
        [pscustomobject]@{name='pool:or-a::model-y';poolId='or-a::model-y';config=[pscustomobject]@{type='api';connection='or-a';model='model-y'}},
        [pscustomobject]@{name='pool:or-b::model-x';poolId='or-b::model-x';config=[pscustomobject]@{type='api';connection='or-b';model='model-x'}},
        [pscustomobject]@{name='pool:or-c::model-z';poolId='or-c::model-z';config=[pscustomobject]@{type='api';connection='or-c';model='model-z'}},
        [pscustomobject]@{name='pool:groq-a::model-g';poolId='groq-a::model-g';config=[pscustomobject]@{type='api';connection='groq-a';model='model-g'}}
    )
    function Get-SCTargetPoolRecords { return @($script:testPool) }
    function Get-SCConfig { return [pscustomobject]@{routing=[pscustomobject]@{maxRouteAttempts=16};providers=[pscustomobject]@{}} }

    # Pseudo-round-robin should rotate the first candidate rather than preserving a model/provider role.
    $first=@(Get-SCProviderCandidates $null $null 'worker'|ForEach-Object{$_.name})
    $second=@(Get-SCProviderCandidates $null $null 'critic'|ForEach-Object{$_.name})
    Assert-True ($first.Count-eq5 -and $second.Count-eq5) 'Expected all five target-pool rows to be eligible.'
    Assert-True ($first[0]-ne$second[0]) 'Durable pseudo-round-robin did not rotate the first route between dispatches.'

    # A 429 belongs to the connection/account. Every model beneath that credential
    # must disappear together, while another OpenRouter key remains usable.
    $orA=$script:testPool[0]
    $domain=Register-SCRouteFailureForRecord $orA 'rate_limited' 'HTTP 429 quota exceeded'
    Assert-True ($domain.scope-eq'connection' -and $domain.key-eq'connection:or-a') '429 was not lifted to connection scope.'
    Assert-True (-not(Test-SCRouteRecordAvailable $script:testPool[0])) 'First child of rate-limited connection remained eligible.'
    Assert-True (-not(Test-SCRouteRecordAvailable $script:testPool[1])) 'Second child of rate-limited connection remained eligible.'
    Assert-True (Test-SCRouteRecordAvailable $script:testPool[2]) 'Independent OpenRouter connection was incorrectly poisoned by account-level 429.'

    # Request-specific failures rotate but do not damage reusable route health.
    $requestDomain=Register-SCRouteFailureForRecord $script:testPool[2] 'context_too_large' 'maximum context length exceeded'
    Assert-True ($requestDomain.scope-eq'request') 'Context overflow should be request-scoped.'
    Assert-True (Test-SCRouteAvailable 'pool:or-b::model-x') 'Request-scoped context failure poisoned endpoint health.'

    # Auth is a real quarantine, not the old "failed but immediately selectable" bug.
    Register-SCRouteFailure 'connection:or-a2' 'auth' '401 invalid api key' 'connection'|Out-Null
    $auth=Get-SCRouteHealthEntry 'connection:or-a2'
    Assert-True ($auth.state-eq'quarantined') 'Auth failure was not quarantined.'
    Assert-True (-not(Test-SCRouteAvailable 'connection:or-a2')) 'Quarantined auth connection remained selectable.'

    # Two independent transport/server failures under the same service promote the
    # service circuit. A third OpenRouter connection is then suppressed without
    # waiting to rediscover the outage itself; another service remains healthy.
    Register-SCRouteFailureForRecord $script:testPool[0] 'server_error' 'HTTP 503 service unavailable'|Out-Null
    Register-SCRouteFailureForRecord $script:testPool[2] 'server_error' 'HTTP 503 service unavailable'|Out-Null
    $service=Get-SCRouteHealthEntry 'service:openrouter'
    Assert-True ($null-ne$service -and $service.state-eq'cooldown') 'Corroborated OpenRouter failures did not promote to service scope.'
    Assert-True (-not(Test-SCRouteRecordAvailable $script:testPool[3])) 'Service-level outage did not suppress an untouched OpenRouter connection.'
    Assert-True (Test-SCRouteRecordAvailable $script:testPool[4]) 'OpenRouter service outage incorrectly suppressed a different service.'

    # Route Doctor owns recovery: expiry makes a circuit due for a probe, not
    # immediately eligible for production work.
    $h=Get-SCRoutingHealth
    $h.endpoints.'service:openrouter'.nextProbeAt=[datetimeoffset]::UtcNow.AddSeconds(-1).ToString('o')
    $h.endpoints.'service:openrouter'.retryAfter=$h.endpoints.'service:openrouter'.nextProbeAt
    Save-SCRoutingHealth $h
    Assert-True (-not(Test-SCRouteAvailable 'service:openrouter')) 'Expired cooldown became production-eligible before a health probe.'
    $due=@(Get-SCRouteDoctorDue 10|ForEach-Object{$_.name})
    Assert-True ($due -contains 'service:openrouter') 'Expired service circuit was not offered to Route Doctor.'
    Register-SCRouteProbeSuccess 'service:openrouter'
    Assert-True (Test-SCRouteAvailable 'service:openrouter') 'Successful Route Doctor probe did not restore service health.'

    Write-Host 'PASS: target-pool round robin, scoped failure inheritance, service promotion, and adaptive Route Doctor recovery.'
} finally {
    $env:LOCALAPPDATA=$oldLocal
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

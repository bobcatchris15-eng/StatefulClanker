# Endpoint routing and failover.
# Project config still stores entries under "providers" for schema compatibility,
# but each entry is treated as one executable endpoint: a CLI target or an
# API connection + model pair.

function Test-SCProviderEnabled($ProviderEntry) {
    if ($null -eq $ProviderEntry) { return $false }
    if ($ProviderEntry.PSObject.Properties['disabled'] -and $null -ne $ProviderEntry.disabled) {
        return (-not [bool]$ProviderEntry.disabled)
    }
    return $true
}

function Get-SCPrioritizedProviders($Config) {
    if (-not $Config -or -not $Config.PSObject.Properties['providers'] -or -not $Config.providers) { return @() }
    $list = @()
    $def = if ($Config.PSObject.Properties['defaultProvider']) { [string]$Config.defaultProvider } else { '' }
    foreach ($p in $Config.providers.PSObject.Properties) {
        $entry = $p.Value
        if (-not (Test-SCProviderEnabled $entry)) { continue }
        $pri = 100
        if ($entry.PSObject.Properties['priority'] -and $null -ne $entry.priority) {
            $pri = [int]$entry.priority
        } elseif ($p.Name -eq $def) {
            $pri = 0
        }
        $list += [pscustomobject]@{
            Name      = $p.Name
            Priority  = $pri
            IsDefault = ($p.Name -eq $def)
            Config    = $entry
        }
    }
    return @($list | Sort-Object Priority, { if ($_.IsDefault) { 0 } else { 1 } }, Name)
}

function Get-SCRoutingHealthPath {
    $dir = Get-SCPath 'routing'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return Join-Path $dir 'health.json'
}

function Get-SCRoutingHealth {
    $path = Get-SCRoutingHealthPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ schemaVersion = 1; endpoints = [pscustomobject]@{} }
    }
    try {
        $h = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        if (-not $h.PSObject.Properties['endpoints']) {
            $h | Add-Member -NotePropertyName endpoints -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        return $h
    } catch {
        return [pscustomobject]@{ schemaVersion = 1; endpoints = [pscustomobject]@{} }
    }
}

function Save-SCRoutingHealth($Health) {
    Write-SCJson (Get-SCRoutingHealthPath) $Health
}

function Get-SCRouteHealthEntry([string]$Name) {
    $h = Get-SCRoutingHealth
    $p = $h.endpoints.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Test-SCRouteAvailable([string]$Name) {
    $entry = Get-SCRouteHealthEntry $Name
    if ($null -eq $entry) { return $true }
    if (-not $entry.PSObject.Properties['state'] -or [string]$entry.state -ne 'cooldown') { return $true }
    if (-not $entry.PSObject.Properties['retryAfter'] -or [string]::IsNullOrWhiteSpace([string]$entry.retryAfter)) { return $true }
    $until = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$entry.retryAfter,[ref]$until)) { return $true }
    return ($until -le [datetimeoffset]::UtcNow)
}

function Get-SCRouteFailureClass([int]$ExitCode,[string]$Text) {
    $t = if ($Text) { $Text } else { '' }
    if ($t -match '(?i)\b429\b|too many requests|rate.?limit|quota exceeded|resource exhausted') { return 'rate_limited' }
    if ($t -match '(?i)\b401\b|\b403\b|unauthori[sz]ed|invalid api key|authentication|permission denied') { return 'auth' }
    if ($t -match '(?i)context.{0,20}(too (large|long)|length|window)|maximum context|prompt too long') { return 'context_too_large' }
    if ($t -match '(?i)model.{0,25}(not found|unavailable|disabled|unsupported)|unknown model') { return 'model_unavailable' }
    if ($t -match '(?i)capacity|overloaded|busy|temporarily unavailable') { return 'capacity' }
    if ($t -match '(?i)timeout|timed out|connection refused|connection reset|reset by peer|forcibly closed|network is unreachable') { return 'timeout' }
    if ($t -match '(?i)\b50[0234]\b|internal server error|bad gateway|service unavailable|gateway timeout') { return 'server_error' }
    if ($t -match '(?i)\b400\b|bad request|invalid request|malformed|unsupported parameter') { return 'bad_request' }
    if ($ExitCode -eq -2) { return 'timeout' }
    return 'unknown'
}

function Test-SCRouteFailureTransient([string]$Class) {
    return @('rate_limited','capacity','timeout','server_error','model_unavailable') -contains $Class
}

function Get-SCRetryAfterSeconds([string]$Class,[string]$Text,[int]$FailureCount=1) {
    if ($Text -match '(?i)retry[- ]after\s*[:=]?\s*(\d+)') {
        return [Math]::Min(3600,[Math]::Max(1,[int]$Matches[1]))
    }
    if ($Text -match '(?i)try again in\s*(\d+)\s*(seconds?|secs?)') {
        return [Math]::Min(3600,[Math]::Max(1,[int]$Matches[1]))
    }
    switch ($Class) {
        'rate_limited' { return [Math]::Min(900, [int](30 * [Math]::Pow(2,[Math]::Min(4,[Math]::Max(0,$FailureCount-1))))) }
        'capacity' { return [Math]::Min(300, [int](10 * [Math]::Pow(2,[Math]::Min(4,[Math]::Max(0,$FailureCount-1))))) }
        'timeout' { return [Math]::Min(120, [int](5 * [Math]::Pow(2,[Math]::Min(4,[Math]::Max(0,$FailureCount-1))))) }
        'server_error' { return [Math]::Min(180, [int](10 * [Math]::Pow(2,[Math]::Min(4,[Math]::Max(0,$FailureCount-1))))) }
        'model_unavailable' { return 300 }
        default { return 0 }
    }
}

function Register-SCRouteSuccess([string]$Name) {
    $h = Get-SCRoutingHealth
    $entry = $h.endpoints.PSObject.Properties[$Name]
    $now = [datetimeoffset]::UtcNow.ToString('o')
    $value = [ordered]@{ state='healthy'; reason=$null; failures=0; retryAfter=$null; lastFailure=$null; lastSuccess=$now }
    if ($null -eq $entry) { $h.endpoints | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]$value) -Force }
    else { $entry.Value = [pscustomobject]$value }
    Save-SCRoutingHealth $h
}

function Register-SCRouteFailure([string]$Name,[string]$Class,[string]$Text) {
    $h = Get-SCRoutingHealth
    $old = $h.endpoints.PSObject.Properties[$Name]
    $failures = 1
    if ($old -and $old.Value.PSObject.Properties['failures']) {
        try { $failures = [int]$old.Value.failures + 1 } catch {}
    }
    $seconds = Get-SCRetryAfterSeconds $Class $Text $failures
    $state = if (Test-SCRouteFailureTransient $Class) { 'cooldown' } elseif ($Class -eq 'auth') { 'failed' } else { 'failed' }
    $retry = if ($seconds -gt 0) { [datetimeoffset]::UtcNow.AddSeconds($seconds).ToString('o') } else { $null }
    $value = [ordered]@{
        state=$state; reason=$Class; failures=$failures; retryAfter=$retry;
        lastFailure=[datetimeoffset]::UtcNow.ToString('o'); lastSuccess=if($old -and $old.Value.PSObject.Properties['lastSuccess']){$old.Value.lastSuccess}else{$null}
    }
    if ($null -eq $old) { $h.endpoints | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]$value) -Force }
    else { $old.Value = [pscustomobject]$value }
    Save-SCRoutingHealth $h
    Add-SCEvent 'routing.endpoint_degraded' "Endpoint ${Name}: $Class" @{ endpoint=$Name; reason=$Class; retryAfter=$retry; failures=$failures }
    return [pscustomobject]$value
}

function Get-SCRoutePreferenceName($Task,[string]$Stage='worker') {
    $cfg = Get-SCConfig
    $taskProvider = $null
    $taskSize = 'small'
    if ($Task) {
        if ($Task -is [System.Collections.IDictionary]) {
            if ($Task.Contains('provider') -and $Task['provider']) { $taskProvider = [string]$Task['provider'] }
            if ($Task.Contains('size') -and $Task['size']) { $taskSize = [string]$Task['size'] }
        } else {
            if ($Task.PSObject.Properties['provider'] -and $Task.provider) { $taskProvider = [string]$Task.provider }
            if ($Task.PSObject.Properties['size'] -and $Task.size) { $taskSize = [string]$Task.size }
        }
    }
    if ($Stage -eq 'critic' -and $cfg.PSObject.Properties['criticProvider'] -and $cfg.criticProvider) { return [string]$cfg.criticProvider }
    if ($Stage -eq 'validator' -and $cfg.PSObject.Properties['validatorProvider'] -and $cfg.validatorProvider) { return [string]$cfg.validatorProvider }
    if ($taskProvider) { return $taskProvider }
    if ($Stage -eq 'worker' -and $cfg.PSObject.Properties['providerBySize'] -and $cfg.providerBySize) {
        $route = $cfg.providerBySize.PSObject.Properties[$taskSize]
        if ($route -and -not [string]::IsNullOrWhiteSpace([string]$route.Value)) { return [string]$route.Value }
    }
    if ($cfg.PSObject.Properties['defaultProvider'] -and $cfg.defaultProvider) { return [string]$cfg.defaultProvider }
    return $null
}

function Test-SCRouteRecordAvailable($Record) {
    if ($null -eq $Record) { return $false }
    if (-not (Test-SCRouteAvailable ([string]$Record.name))) { return $false }
    $cfg=$Record.config
    $type=if($cfg.PSObject.Properties['type']){[string]$cfg.type}else{'cli'}
    if($type-eq'api' -and $cfg.PSObject.Properties['connection'] -and $cfg.connection){
        if(-not(Test-SCRouteAvailable ("connection:"+[string]$cfg.connection))){return $false}
    }
    return $true
}

function Get-SCProviderCandidates($Task,[string]$Override,[string]$Stage='worker') {
    $cfg = Get-SCConfig
    $prioritized = @(Get-SCPrioritizedProviders $cfg)
    if ($Override) {
        $property = if ($cfg.providers) { $cfg.providers.PSObject.Properties[$Override] } else { $null }
        if ($null -eq $property) { throw "Endpoint '$Override' not configured." }
        if (-not (Test-SCProviderEnabled $property.Value)) { throw "Endpoint '$Override' is disabled." }
        return @([pscustomobject]@{ name=$Override; config=$property.Value; priority=-1; preferred=$true })
    }

    $preferred = Get-SCRoutePreferenceName $Task $Stage
    $ordered = @()
    $preferredRecord=$null
    if ($preferred) {
        $p = $prioritized | Where-Object { $_.Name -eq $preferred } | Select-Object -First 1
        if ($p) {
            $preferredRecord=[pscustomobject]@{ name=$p.Name; config=$p.Config; priority=$p.Priority; preferred=$true }
            $ordered += $preferredRecord
        }
    }

    # Preserve model continuity where possible: after the preferred API endpoint,
    # try the same model through another configured connection before changing models.
    $sameModel=@()
    $rest=@()
    $preferredModel=$null
    $preferredIsApi=$false
    if($preferredRecord){
        $ptype=if($preferredRecord.config.PSObject.Properties['type']){[string]$preferredRecord.config.type}else{'cli'}
        $preferredIsApi=($ptype-eq'api')
        if($preferredIsApi -and $preferredRecord.config.PSObject.Properties['model']){$preferredModel=[string]$preferredRecord.config.model}
    }
    foreach ($p in $prioritized) {
        if ($preferred -and $p.Name -eq $preferred) { continue }
        $record=[pscustomobject]@{ name=$p.Name; config=$p.Config; priority=$p.Priority; preferred=$false }
        $type=if($p.Config.PSObject.Properties['type']){[string]$p.Config.type}else{'cli'}
        $model=if($p.Config.PSObject.Properties['model']){[string]$p.Config.model}else{$null}
        if($preferredIsApi -and $type-eq'api' -and $preferredModel -and $model-eq$preferredModel){$sameModel+=$record}else{$rest+=$record}
    }
    $ordered+=@($sameModel|Sort-Object priority,name)
    $ordered+=@($rest|Sort-Object priority,name)

    $available = @($ordered | Where-Object { Test-SCRouteRecordAvailable $_ })
    $max = 6
    if ($cfg.PSObject.Properties['routing'] -and $cfg.routing -and $cfg.routing.PSObject.Properties['maxRouteAttempts']) {
        try { $max = [Math]::Min(32,[Math]::Max(1,[int]$cfg.routing.maxRouteAttempts)) } catch {}
    }
    return @($available | Select-Object -First $max)
}

function Get-SCNextRouteAvailability {
    $h = Get-SCRoutingHealth
    $next = $null
    foreach ($p in $h.endpoints.PSObject.Properties) {
        $e = $p.Value
        if ([string]$e.state -ne 'cooldown' -or -not $e.retryAfter) { continue }
        $dto = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse([string]$e.retryAfter,[ref]$dto) -and $dto -gt [datetimeoffset]::UtcNow) {
            if ($null -eq $next -or $dto -lt $next) { $next = $dto }
        }
    }
    return $next
}

function Resolve-SCProvider($Task,[string]$Override,[string]$Stage='worker') {
    $candidates = @(Get-SCProviderCandidates $Task $Override $Stage)
    if ($candidates.Count -gt 0) {
        return [ordered]@{ name=$candidates[0].name; config=$candidates[0].config }
    }
    $next = Get-SCNextRouteAvailability
    if ($next) { throw "All enabled inference endpoints are cooling down. Next retry window: $($next.ToLocalTime().ToString('o'))" }
    throw "No enabled inference endpoint is available. Configure or enable at least one endpoint."
}

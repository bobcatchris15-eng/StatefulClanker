# Optional machine/project routing hints layered over ordinary provider CLI config.
# The conversational planner assigns task.size semantically; the runtime only maps
# that declared class to a configured CLI provider when a mapping exists.

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

function Resolve-SCProvider($Task,[string]$Override,[string]$Stage='worker') {
    $cfg = Get-SCConfig
    $prioritized = @(Get-SCPrioritizedProviders $cfg)

    if ($Override) {
        $property = if ($cfg.providers) { $cfg.providers.PSObject.Properties[$Override] } else { $null }
        if ($null -eq $property) { throw "Provider '$Override' not configured." }
        if (-not (Test-SCProviderEnabled $property.Value)) {
            throw "Provider '$Override' is currently disabled in .statefulclanker/config.json."
        }
        return [ordered]@{ name = $Override; config = $property.Value }
    }

    $candidate = $null
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

    if ($Stage -eq 'critic' -and $cfg.PSObject.Properties['criticProvider'] -and $cfg.criticProvider) {
        $candidate = [string]$cfg.criticProvider
    } elseif ($Stage -eq 'validator' -and $cfg.PSObject.Properties['validatorProvider'] -and $cfg.validatorProvider) {
        $candidate = [string]$cfg.validatorProvider
    } elseif ($taskProvider) {
        $candidate = $taskProvider
    } elseif ($Stage -eq 'worker' -and $cfg.PSObject.Properties['providerBySize'] -and $cfg.providerBySize) {
        $route = $cfg.providerBySize.PSObject.Properties[$taskSize]
        if ($route -and -not [string]::IsNullOrWhiteSpace([string]$route.Value)) { $candidate = [string]$route.Value }
    }

    if ($candidate) {
        $prop = if ($cfg.providers) { $cfg.providers.PSObject.Properties[$candidate] } else { $null }
        if ($prop -and (Test-SCProviderEnabled $prop.Value)) {
            return [ordered]@{ name = $candidate; config = $prop.Value }
        }
    }

    if ($prioritized.Count -gt 0) {
        $top = $prioritized[0]
        return [ordered]@{ name = $top.Name; config = $top.Config }
    }

    if ($candidate) {
        throw "Provider '$candidate' is configured but disabled, and no other enabled providers are available."
    }
    throw "No enabled provider available. Configure or enable at least one provider in .statefulclanker/config.json."
}

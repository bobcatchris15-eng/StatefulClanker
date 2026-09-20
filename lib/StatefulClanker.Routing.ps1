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

function Get-SCTargetPoolPath {
    $dir=Get-SCPath 'routing'
    if(-not(Test-Path -LiteralPath $dir)){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    return Join-Path $dir 'target-pool.json'
}

function Get-SCTargetPool {
    $path=Get-SCTargetPoolPath
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return [pscustomobject]@{schemaVersion=1;entries=[pscustomobject]@{}}}
    try{
        $pool=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json
        if(-not$pool.PSObject.Properties['entries']){$pool|Add-Member -NotePropertyName entries -NotePropertyValue ([pscustomobject]@{}) -Force}
        return $pool
    }catch{
        Add-SCEvent 'routing.target_pool_invalid' 'Target pool JSON could not be parsed; falling back to legacy configured providers.' @{path=$path;error=$_.Exception.Message}
        return [pscustomobject]@{schemaVersion=1;entries=[pscustomobject]@{}}
    }
}

function Get-SCTargetPoolRecords {
    $pool=Get-SCTargetPool
    $records=@()
    foreach($p in $pool.entries.PSObject.Properties){
        $e=$p.Value
        if($e.PSObject.Properties['enabled'] -and $null-ne$e.enabled -and -not[bool]$e.enabled){continue}
        if(-not$e.PSObject.Properties['connection'] -or [string]::IsNullOrWhiteSpace([string]$e.connection)){continue}
        if(-not$e.PSObject.Properties['model'] -or [string]::IsNullOrWhiteSpace([string]$e.model)){continue}
        $toolMode=if($e.PSObject.Properties['toolMode'] -and $e.toolMode){[string]$e.toolMode}else{'native'}
        $cfg=[pscustomobject]@{
            type='api'
            connection=[string]$e.connection
            model=[string]$e.model
            toolMode=$toolMode
            disabled=$false
        }
        $records += [pscustomobject]@{
            name=('pool:'+[string]$p.Name)
            poolId=[string]$p.Name
            config=$cfg
            priority=100
            preferred=$false
            targetPool=$true
        }
    }
    return @($records|Sort-Object name)
}

function Get-SCRoundRobinStatePath {
    $dir=Get-SCPath 'routing'
    if(-not(Test-Path -LiteralPath $dir)){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    return Join-Path $dir 'round-robin.json'
}

function Get-SCRoundRobinOrdered($Records) {
    $items=@($Records|Sort-Object name)
    if($items.Count-le 1){return $items}
    $mutexName='Local\StatefulClankerRoute-'+(Get-SCHashString (Get-SCRoot)).Substring(0,16)
    $mutex=New-Object System.Threading.Mutex($false,$mutexName)
    $locked=$false
    try{
        $locked=$mutex.WaitOne(5000)
        $path=Get-SCRoundRobinStatePath
        $state=$null
        if(Test-Path -LiteralPath $path -PathType Leaf){try{$state=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json}catch{}}
        $cursor=0
        if($state-and$state.PSObject.Properties['cursor']){try{$cursor=[int]$state.cursor}catch{}}
        $start=(($cursor % $items.Count)+$items.Count)%$items.Count
        $ordered=@()
        for($i=0;$i-lt$items.Count;$i++){$ordered+=,$items[($start+$i)%$items.Count]}
        Write-SCJson $path ([ordered]@{schemaVersion=1;cursor=(($start+1)%$items.Count);lastDispatch=[datetimeoffset]::UtcNow.ToString('o');lastFirst=[string]$ordered[0].name})
        return @($ordered)
    }finally{
        if($locked){try{$mutex.ReleaseMutex()}catch{}}
        $mutex.Dispose()
    }
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
        return [pscustomobject]@{ schemaVersion = 2; endpoints = [pscustomobject]@{} }
    }
    try {
        $h = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        if (-not $h.PSObject.Properties['endpoints']) {
            $h | Add-Member -NotePropertyName endpoints -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        if (-not $h.PSObject.Properties['schemaVersion']) {
            $h | Add-Member -NotePropertyName schemaVersion -NotePropertyValue 2 -Force
        } else { $h.schemaVersion = 2 }
        return $h
    } catch {
        return [pscustomobject]@{ schemaVersion = 2; endpoints = [pscustomobject]@{} }
    }
}

function Save-SCRoutingHealth($Health) {
    $Health.schemaVersion = 2
    Write-SCJson (Get-SCRoutingHealthPath) $Health
}

function Get-SCRouteHealthEntry([string]$Name) {
    $h = Get-SCRoutingHealth
    $p = $h.endpoints.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Get-SCRoutingMachineConnections {
    $path=Join-Path (Join-Path $env:LOCALAPPDATA 'StatefulClanker') 'connections.json'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return [pscustomobject]@{connections=[pscustomobject]@{}}}
    try{
        $cfg=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json
        if(-not$cfg.PSObject.Properties['connections']){$cfg|Add-Member -NotePropertyName connections -NotePropertyValue ([pscustomobject]@{}) -Force}
        return $cfg
    }catch{return [pscustomobject]@{connections=[pscustomobject]@{}}}
}

function Get-SCRoutingConnection([string]$Name) {
    $cfg=Get-SCRoutingMachineConnections
    $p=$cfg.connections.PSObject.Properties[$Name]
    if($p){return $p.Value}
    return $null
}

function Get-SCConnectionServiceName([string]$ConnectionName) {
    $c=Get-SCRoutingConnection $ConnectionName
    if($null-eq$c){return $null}
    if($c.PSObject.Properties['presetId'] -and -not[string]::IsNullOrWhiteSpace([string]$c.presetId) -and [string]$c.presetId-ne'custom'){
        return ([string]$c.presetId).ToLowerInvariant()
    }
    if($c.PSObject.Properties['baseUrl'] -and $c.baseUrl){
        try{return ([uri][string]$c.baseUrl).Host.ToLowerInvariant()}catch{}
    }
    return $null
}

function Get-SCConnectionConfigFingerprint([string]$ConnectionName) {
    $c=Get-SCRoutingConnection $ConnectionName
    if($null-eq$c){return $null}
    $parts=[ordered]@{}
    foreach($name in @('presetId','protocol','baseUrl','accountId','apiKeyEnv','apiKeyProtected')){
        if($c.PSObject.Properties[$name]){$parts[$name]=$c.$name}
    }
    if($c.PSObject.Properties['headers']){$parts['headers']=$c.headers}
    return Get-SCHashString ($parts|ConvertTo-Json -Depth 12 -Compress)
}

function Get-SCExplicitRetryAfterSeconds([string]$Text) {
    if([string]::IsNullOrWhiteSpace($Text)){return $null}
    if($Text-match'(?i)retry[- ]after\s*[:=]?\s*(\d+)'){return [Math]::Max(1,[int]$Matches[1])}
    if($Text-match'(?i)(?:try again|reset(?:s)?|available again)\s*(?:in|after)?\s*(\d+)\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?)'){
        $n=[int]$Matches[1];$u=$Matches[2].ToLowerInvariant()
        if($u.StartsWith('hour') -or $u.StartsWith('hr')){return $n*3600}
        if($u.StartsWith('min')){return $n*60}
        return $n
    }
    if($Text-match'(?i)retry[- ]after\s*[:=]\s*([A-Za-z]{3},\s*\d{1,2}\s+[A-Za-z]{3}\s+\d{4}\s+\d{2}:\d{2}:\d{2}\s+GMT)'){
        $dto=[datetimeoffset]::MinValue
        if([datetimeoffset]::TryParse($Matches[1],[ref]$dto)){return [Math]::Max(1,[int][Math]::Ceiling(($dto-[datetimeoffset]::UtcNow).TotalSeconds))}
    }
    return $null
}

function Get-SCProbeDelaySeconds([string]$Class,[string]$Text,[int]$ProbeNumber=1) {
    $explicit=Get-SCExplicitRetryAfterSeconds $Text
    if($null-ne$explicit){return [Math]::Min(86400,[Math]::Max(1,[int]$explicit))}
    $n=[Math]::Max(1,$ProbeNumber)
    $series=switch($Class){
        'rate_limited' { @(1800,3600,7200,14400,21600) }
        'auth' { @(21600,43200,43200) }
        'model_unavailable' { @(1800,3600,7200,14400) }
        'capacity' { @(300,900,1800,3600,7200) }
        'timeout' { @(300,900,1800,3600,7200) }
        'server_error' { @(300,900,1800,3600,7200) }
        'malformed_response' { @(900,1800,3600,7200) }
        'empty_response' { @(900,1800,3600,7200) }
        'protocol_error' { @(1800,3600,7200) }
        default { @(1800,3600,7200) }
    }
    $idx=[Math]::Min($series.Count-1,$n-1)
    return [int]$series[$idx]
}

function Test-SCRouteAvailable([string]$Name) {
    $entry=Get-SCRouteHealthEntry $Name
    if($null-eq$entry){return $true}
    $state=if($entry.PSObject.Properties['state']){[string]$entry.state}else{'healthy'}
    return ($state-eq'healthy')
}

function Reset-SCConnectionHealthIfConfigChanged([string]$ConnectionName) {
    $key="connection:$ConnectionName"
    $entry=Get-SCRouteHealthEntry $key
    if($null-eq$entry -or -not$entry.PSObject.Properties['configFingerprint'] -or -not$entry.configFingerprint){return}
    $current=Get-SCConnectionConfigFingerprint $ConnectionName
    if($current -and [string]$current-ne[string]$entry.configFingerprint){
        Register-SCRouteSuccess $key 'connection'|Out-Null
        Add-SCEvent 'routing.connection_reconfigured' "Connection $ConnectionName changed; clearing its routing quarantine." @{connection=$ConnectionName}
    }
}

function Get-SCRouteFailureClass([int]$ExitCode,[string]$Text) {
    $t=if($Text){$Text}else{''}
    if($t-match'(?i)\b429\b|too many requests|rate.?limit|quota exceeded|resource exhausted'){return 'rate_limited'}
    if($t-match'(?i)\b401\b|\b403\b|unauthori[sz]ed|invalid api key|authentication|permission denied'){return 'auth'}
    if($t-match'(?i)context.{0,20}(too (large|long)|length|window)|maximum context|prompt too long'){return 'context_too_large'}
    if($t-match'(?i)model.{0,25}(not found|unavailable|disabled|unsupported)|unknown model'){return 'model_unavailable'}
    if($t-match'(?i)invalid json|malformed json|text-tool model returned invalid json|could not parse.*json'){return 'malformed_response'}
    if($t-match'(?i)returned no choices|returned no content|no content or tool call|empty response'){return 'empty_response'}
    if($t-match'(?i)protocol|unsupported response shape|unexpected response shape'){return 'protocol_error'}
    if($t-match'(?i)capacity|overloaded|busy|temporarily unavailable'){return 'capacity'}
    if($t-match'(?i)timeout|timed out|connection refused|connection reset|reset by peer|forcibly closed|network is unreachable|name or service not known|no such host'){return 'timeout'}
    if($t-match'(?i)\b50[0234]\b|internal server error|bad gateway|service unavailable|gateway timeout'){return 'server_error'}
    if($t-match'(?i)\b400\b|bad request|invalid request|unsupported parameter'){return 'bad_request'}
    if($ExitCode-eq-2){return 'timeout'}
    return 'unknown'
}

function Test-SCRouteFailureTransient([string]$Class) {
    return @('rate_limited','capacity','timeout','server_error','model_unavailable','malformed_response','empty_response','protocol_error','context_too_large','bad_request')-contains$Class
}

function Register-SCRouteSuccess([string]$Name,[string]$Scope=$null) {
    $h=Get-SCRoutingHealth;$entry=$h.endpoints.PSObject.Properties[$Name];$now=[datetimeoffset]::UtcNow.ToString('o')
    if(-not$Scope){$Scope=if($Name.StartsWith('connection:')){'connection'}elseif($Name.StartsWith('service:')){'service'}else{'endpoint'}}
    $fingerprint=$null
    if($Scope-eq'connection' -and $Name.StartsWith('connection:')){$fingerprint=Get-SCConnectionConfigFingerprint $Name.Substring('connection:'.Length)}
    $value=[ordered]@{state='healthy';scope=$Scope;reason=$null;failures=0;probeFailures=0;retryAfter=$null;nextProbeAt=$null;lastFailure=$null;lastProbe=$null;lastSuccess=$now;configFingerprint=$fingerprint}
    if($null-eq$entry){$h.endpoints|Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]$value) -Force}else{$entry.Value=[pscustomobject]$value}
    Save-SCRoutingHealth $h
    return [pscustomobject]$value
}

function Register-SCRouteFailure([string]$Name,[string]$Class,[string]$Text,[string]$Scope=$null) {
    $h=Get-SCRoutingHealth;$old=$h.endpoints.PSObject.Properties[$Name]
    if(-not$Scope){$Scope=if($Name.StartsWith('connection:')){'connection'}elseif($Name.StartsWith('service:')){'service'}else{'endpoint'}}
    $failures=1;$probeFailures=0
    if($old){if($old.Value.PSObject.Properties['failures']){try{$failures=[int]$old.Value.failures+1}catch{}};if($old.Value.PSObject.Properties['probeFailures']){try{$probeFailures=[int]$old.Value.probeFailures}catch{}}}
    $seconds=Get-SCProbeDelaySeconds $Class $Text ($probeFailures+1);$now=[datetimeoffset]::UtcNow;$retry=$now.AddSeconds($seconds).ToString('o')
    $state=if($Class-eq'auth'){'quarantined'}else{'cooldown'};$fingerprint=$null
    if($Scope-eq'connection' -and $Name.StartsWith('connection:')){$fingerprint=Get-SCConnectionConfigFingerprint $Name.Substring('connection:'.Length)}
    $value=[ordered]@{state=$state;scope=$Scope;reason=$Class;failures=$failures;probeFailures=$probeFailures;retryAfter=$retry;nextProbeAt=$retry;lastFailure=$now.ToString('o');lastProbe=if($old-and$old.Value.PSObject.Properties['lastProbe']){$old.Value.lastProbe}else{$null};lastSuccess=if($old-and$old.Value.PSObject.Properties['lastSuccess']){$old.Value.lastSuccess}else{$null};configFingerprint=$fingerprint}
    if($null-eq$old){$h.endpoints|Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]$value) -Force}else{$old.Value=[pscustomobject]$value}
    Save-SCRoutingHealth $h
    Add-SCEvent 'routing.scope_degraded' ("Routing {0} {1}: {2}"-f$Scope,$Name,$Class) @{scope=$Scope;name=$Name;reason=$Class;nextProbeAt=$retry;failures=$failures}
    return [pscustomobject]$value
}

function Register-SCRouteProbeFailure([string]$Name,[string]$Class,[string]$Text) {
    $h=Get-SCRoutingHealth;$old=$h.endpoints.PSObject.Properties[$Name]
    if($null-eq$old){return Register-SCRouteFailure $Name $Class $Text}
    $scope=if($old.Value.PSObject.Properties['scope']){[string]$old.Value.scope}elseif($Name.StartsWith('connection:')){'connection'}elseif($Name.StartsWith('service:')){'service'}else{'endpoint'}
    $probeFailures=1;if($old.Value.PSObject.Properties['probeFailures']){try{$probeFailures=[int]$old.Value.probeFailures+1}catch{}}
    $seconds=Get-SCProbeDelaySeconds $Class $Text ($probeFailures+1);$now=[datetimeoffset]::UtcNow;$next=$now.AddSeconds($seconds).ToString('o')
    $old.Value.state=if($Class-eq'auth'){'quarantined'}else{'cooldown'}
    Set-SCProperty $old.Value 'scope' $scope;Set-SCProperty $old.Value 'reason' $Class;Set-SCProperty $old.Value 'probeFailures' $probeFailures;Set-SCProperty $old.Value 'lastProbe' $now.ToString('o');Set-SCProperty $old.Value 'lastFailure' $now.ToString('o');Set-SCProperty $old.Value 'nextProbeAt' $next;Set-SCProperty $old.Value 'retryAfter' $next
    if($scope-eq'connection' -and $Name.StartsWith('connection:')){Set-SCProperty $old.Value 'configFingerprint' (Get-SCConnectionConfigFingerprint $Name.Substring('connection:'.Length))}
    Save-SCRoutingHealth $h
    Add-SCEvent 'routing.probe_failed' "Route Doctor probe failed for $Name ($Class); next check at $next." @{scope=$scope;name=$Name;reason=$Class;probeFailures=$probeFailures;nextProbeAt=$next}
    return $old.Value
}

function Register-SCRouteProbeSuccess([string]$Name) {
    $old=Get-SCRouteHealthEntry $Name
    $scope=if($old-and$old.PSObject.Properties['scope']){[string]$old.scope}elseif($Name.StartsWith('connection:')){'connection'}elseif($Name.StartsWith('service:')){'service'}else{'endpoint'}
    Register-SCRouteSuccess $Name $scope|Out-Null
    Add-SCEvent 'routing.probe_recovered' "Route Doctor recovered $Name." @{scope=$scope;name=$Name}
}

function Get-SCFailureHealthScope($Record,[string]$Class) {
    $cfg=$Record.config;$type=if($cfg.PSObject.Properties['type']){[string]$cfg.type}else{'cli'}
    if($type-ne'api'){return [ordered]@{scope='endpoint';key=[string]$Record.name;connection=$null;service=$null}}
    $connection=if($cfg.PSObject.Properties['connection']){[string]$cfg.connection}else{$null};$service=if($connection){Get-SCConnectionServiceName $connection}else{$null}
    if(@('rate_limited','auth','timeout','server_error')-contains$Class -and $connection){return [ordered]@{scope='connection';key="connection:$connection";connection=$connection;service=$service}}
    if(@('capacity','model_unavailable','malformed_response','empty_response','protocol_error')-contains$Class){return [ordered]@{scope='endpoint';key=[string]$Record.name;connection=$connection;service=$service}}
    return [ordered]@{scope='request';key=$null;connection=$connection;service=$service}
}

function Test-SCServiceFailureCorroboration([string]$Service,[string]$ExcludeConnection=$null) {
    if([string]::IsNullOrWhiteSpace($Service)){return $false}
    $h=Get-SCRoutingHealth;$cutoff=[datetimeoffset]::UtcNow.AddMinutes(-10);$connections=@()
    foreach($p in $h.endpoints.PSObject.Properties){
        if(-not$p.Name.StartsWith('connection:')){continue};$conn=$p.Name.Substring('connection:'.Length);if($ExcludeConnection-and$conn-eq$ExcludeConnection){continue};$v=$p.Value
        if(-not(@('timeout','server_error')-contains[string]$v.reason)){continue};$when=[datetimeoffset]::MinValue
        if(-not$v.PSObject.Properties['lastFailure'] -or -not[datetimeoffset]::TryParse([string]$v.lastFailure,[ref]$when) -or $when-lt$cutoff){continue}
        if((Get-SCConnectionServiceName $conn)-eq$Service){$connections+=,$conn}
    }
    return (@($connections|Select-Object -Unique).Count-ge1)
}

function Register-SCRouteFailureForRecord($Record,[string]$Class,[string]$Text) {
    $domain=Get-SCFailureHealthScope $Record $Class
    if($domain.scope-eq'request'){return $domain}
    Register-SCRouteFailure ([string]$domain.key) $Class $Text ([string]$domain.scope)|Out-Null
    if($domain.scope-eq'connection' -and @('timeout','server_error')-contains$Class -and $domain.service -and (Test-SCServiceFailureCorroboration ([string]$domain.service) ([string]$domain.connection))){
        $serviceKey="service:$($domain.service)";Register-SCRouteFailure $serviceKey $Class $Text 'service'|Out-Null
        Add-SCEvent 'routing.service_degraded' "Independent connections indicate service $($domain.service) is unavailable." @{service=$domain.service;failureClass=$Class}
    }
    return $domain
}

function Get-SCRouteDoctorDue([int]$Limit=2) {
    $h=Get-SCRoutingHealth;$now=[datetimeoffset]::UtcNow;$rows=@()
    foreach($p in $h.endpoints.PSObject.Properties){
        $v=$p.Value;$state=if($v.PSObject.Properties['state']){[string]$v.state}else{'healthy'};if($state-eq'healthy'){continue};$at=$null
        if($state-eq'probing'){
            $last=[datetimeoffset]::MinValue
            if($v.PSObject.Properties['lastProbe'] -and [datetimeoffset]::TryParse([string]$v.lastProbe,[ref]$last) -and $last-gt$now.AddMinutes(-10)){continue}
            $at=$now
        }else{
            foreach($field in @('nextProbeAt','retryAfter')){if($v.PSObject.Properties[$field] -and $v.$field){$dto=[datetimeoffset]::MinValue;if([datetimeoffset]::TryParse([string]$v.$field,[ref]$dto)){$at=$dto;break}}}
        }
        if($null-eq$at -or $at-le$now){$rows+=,[pscustomobject]@{name=[string]$p.Name;scope=if($v.PSObject.Properties['scope']){[string]$v.scope}else{'endpoint'};reason=if($v.PSObject.Properties['reason']){[string]$v.reason}else{'unknown'};dueAt=$at;entry=$v}}
    }
    return @($rows|Sort-Object @{Expression={if($_.dueAt){$_.dueAt}else{[datetimeoffset]::MinValue}}},name|Select-Object -First ([Math]::Max(1,$Limit)))
}

function Set-SCRouteProbing([string]$Name) {
    $mutexName='Local\StatefulClankerRouteDoctor-'+(Get-SCHashString (Get-SCRoot)).Substring(0,16)
    $mutex=New-Object System.Threading.Mutex($false,$mutexName);$locked=$false
    try{
        $locked=$mutex.WaitOne(5000);if(-not$locked){return $false}
        $h=Get-SCRoutingHealth;$p=$h.endpoints.PSObject.Properties[$Name];if($null-eq$p){return $false}
        $now=[datetimeoffset]::UtcNow;$state=if($p.Value.PSObject.Properties['state']){[string]$p.Value.state}else{'healthy'}
        if($state-eq'healthy'){return $false}
        if($state-eq'probing'){
            $last=[datetimeoffset]::MinValue
            if($p.Value.PSObject.Properties['lastProbe'] -and [datetimeoffset]::TryParse([string]$p.Value.lastProbe,[ref]$last) -and $last-gt$now.AddMinutes(-10)){return $false}
        }else{
            $raw=$null
            if($p.Value.PSObject.Properties['nextProbeAt'] -and $p.Value.nextProbeAt){$raw=[string]$p.Value.nextProbeAt}elseif($p.Value.PSObject.Properties['retryAfter'] -and $p.Value.retryAfter){$raw=[string]$p.Value.retryAfter}
            if($raw){$at=[datetimeoffset]::MinValue;if([datetimeoffset]::TryParse($raw,[ref]$at) -and $at-gt$now){return $false}}
        }
        $p.Value.state='probing';Set-SCProperty $p.Value 'lastProbe' $now.ToString('o');Save-SCRoutingHealth $h;return $true
    }finally{
        if($locked){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()
    }
}

function Resolve-SCRouteProbeRecord([string]$Name) {
    $records=@(Get-SCTargetPoolRecords)
    $cfg=Get-SCConfig
    if($cfg.PSObject.Properties['providers'] -and $cfg.providers){
        foreach($p in $cfg.providers.PSObject.Properties){
            $entry=$p.Value;$type=if($entry.PSObject.Properties['type']){[string]$entry.type}else{'cli'}
            if($type-ne'api' -or -not(Test-SCProviderEnabled $entry)){continue}
            if(@($records|Where-Object{[string]$_.name-eq[string]$p.Name}).Count-eq0){$records+=,[pscustomobject]@{name=[string]$p.Name;poolId=$null;config=$entry;targetPool=$false}}
        }
    }
    if($Name.StartsWith('connection:')){
        $connection=$Name.Substring('connection:'.Length);$usable=@($records|Where-Object{[string]$_.config.connection-eq$connection -and (Test-SCRouteAvailable ([string]$_.name))})
        if($usable.Count-eq0){$usable=@($records|Where-Object{[string]$_.config.connection-eq$connection})};return @($usable|Select-Object -First 1)
    }
    if($Name.StartsWith('service:')){
        $service=$Name.Substring('service:'.Length);$usable=@()
        foreach($r in $records){$conn=[string]$r.config.connection;if((Get-SCConnectionServiceName $conn)-ne$service){continue};$connEntry=Get-SCRouteHealthEntry ("connection:$conn");if($connEntry-and[string]$connEntry.reason-eq'auth'){continue};$usable+=,$r}
        return @($usable|Select-Object -First 1)
    }
    return @($records|Where-Object{[string]$_.name-eq$Name}|Select-Object -First 1)
}

function Get-SCTaskExplicitProvider($Task) {
    if (-not $Task) { return $null }
    if ($Task -is [System.Collections.IDictionary]) {
        if ($Task.Contains('provider') -and $Task['provider']) { return [string]$Task['provider'] }
        return $null
    }
    if ($Task.PSObject.Properties['provider'] -and $Task.provider) { return [string]$Task.provider }
    return $null
}

function Get-SCRoutingSelectionMode($Config) {
    if ($Config -and $Config.PSObject.Properties['routing'] -and $Config.routing -and $Config.routing.PSObject.Properties['selectionMode']) {
        $mode = [string]$Config.routing.selectionMode
        if ($mode -eq 'random') { return 'random' }
    }
    return 'pinned'
}

function Get-SCRoutePreferenceName($Task,[string]$Stage='worker') {
    $cfg = Get-SCConfig
    $taskProvider = Get-SCTaskExplicitProvider $Task
    $taskSize = 'small'
    if ($Task) {
        if ($Task -is [System.Collections.IDictionary]) {
            if ($Task.Contains('size') -and $Task['size']) { $taskSize = [string]$Task['size'] }
        } else {
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
    if($null-eq$Record){return $false}
    if(-not(Test-SCRouteAvailable ([string]$Record.name))){return $false}
    $cfg=$Record.config;$type=if($cfg.PSObject.Properties['type']){[string]$cfg.type}else{'cli'}
    if($type-eq'api' -and $cfg.PSObject.Properties['connection'] -and $cfg.connection){
        $connection=[string]$cfg.connection;Reset-SCConnectionHealthIfConfigChanged $connection
        if(-not(Test-SCRouteAvailable ("connection:"+$connection))){return $false}
        $service=Get-SCConnectionServiceName $connection
        if($service -and -not(Test-SCRouteAvailable ("service:"+$service))){return $false}
    }
    return $true
}

function Get-SCProviderCandidates($Task,[string]$Override,[string]$Stage='worker') {
    $cfg=Get-SCConfig
    $poolRecords=@(Get-SCTargetPoolRecords)

    # Explicit operator/debug override remains strict. It may name a target-pool id,
    # its pool:<id> route name, or a legacy configured provider. Normal task/provider
    # role pins are deliberately ignored.
    if($Override){
        $poolMatch=$poolRecords|Where-Object{[string]$_.name-eq$Override -or [string]$_.poolId-eq$Override}|Select-Object -First 1
        if($poolMatch){
            if(-not(Test-SCRouteRecordAvailable $poolMatch)){throw "Target-pool route '$Override' is currently unavailable."}
            return @($poolMatch)
        }
        $property=if($cfg.providers){$cfg.providers.PSObject.Properties[$Override]}else{$null}
        if($null-eq$property){throw "Route '$Override' is not configured."}
        if(-not(Test-SCProviderEnabled $property.Value)){throw "Route '$Override' is disabled."}
        $record=[pscustomobject]@{name=$Override;config=$property.Value;priority=-1;preferred=$true;targetPool=$false}
        if(-not(Test-SCRouteRecordAvailable $record)){throw "Route '$Override' is currently unavailable."}
        return @($record)
    }

    # Once a target pool exists it is the automatic routing authority. Worker,
    # critic and validator all draw from the same healthy workhorse pool; model
    # identity is telemetry, not a role assignment.
    $records=@()
    if($poolRecords.Count-gt 0){
        $records=@($poolRecords)
    }else{
        # Backward-compatible migration path for projects that have not created a
        # target pool yet. Legacy providers still run, but role/default/size pins
        # and priority ordering no longer affect automatic selection.
        foreach($p in @(Get-SCPrioritizedProviders $cfg)){
            $records += [pscustomobject]@{name=$p.Name;config=$p.Config;priority=100;preferred=$false;targetPool=$false}
        }
    }

    $available=@($records|Where-Object{Test-SCRouteRecordAvailable $_})
    if($available.Count-eq 0){return @()}
    $ordered=@(Get-SCRoundRobinOrdered $available)
    $max=6
    if($cfg.PSObject.Properties['routing'] -and $cfg.routing -and $cfg.routing.PSObject.Properties['maxRouteAttempts']){
        try{$max=[Math]::Min(32,[Math]::Max(1,[int]$cfg.routing.maxRouteAttempts))}catch{}
    }
    return @($ordered|Select-Object -First $max)
}

function Get-SCNextRouteAvailability {
    $h=Get-SCRoutingHealth;$next=$null
    foreach($p in $h.endpoints.PSObject.Properties){
        $e=$p.Value;if([string]$e.state-eq'healthy'){continue};$raw=$null
        if($e.PSObject.Properties['nextProbeAt'] -and $e.nextProbeAt){$raw=[string]$e.nextProbeAt}elseif($e.PSObject.Properties['retryAfter'] -and $e.retryAfter){$raw=[string]$e.retryAfter}
        if(-not$raw){continue};$dto=[datetimeoffset]::MinValue
        if([datetimeoffset]::TryParse($raw,[ref]$dto)){if($null-eq$next -or $dto-lt$next){$next=$dto}}
    }
    return $next
}

function Resolve-SCProvider($Task,[string]$Override,[string]$Stage='worker') {
    $candidates = @(Get-SCProviderCandidates $Task $Override $Stage)
    if ($candidates.Count -gt 0) {
        return [ordered]@{ name=$candidates[0].name; config=$candidates[0].config }
    }
    $next = Get-SCNextRouteAvailability
    if ($next) { throw "All eligible target-pool routes are cooling down. Next retry window: $($next.ToLocalTime().ToString('o'))" }
    throw "No eligible inference route is available. Add/enable models in the project target pool or configure a fallback connection."
}

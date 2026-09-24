<# Compiled router integration: IPC leases, health scopes, cooldown recovery, and config healing. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$router=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "COMPILED ROUTER TEST FAILED: $Message"}}
function Call-Router([string[]]$CallArgs) {
    $raw=& $router @CallArgs
    $code=$LASTEXITCODE
    $obj=$raw | ConvertFrom-Json
    if($code -ne 0 -or -not [bool]$obj.ok){throw ("Router call failed ({0}): {1}" -f ($CallArgs -join ' '),$raw)}
    return $obj
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-router-'+[guid]::NewGuid().ToString('N'))
$oldRoot=$env:SC_ROUTER_ROOT
$daemon=$null
try {
    New-Item -ItemType Directory -Force -Path $temp|Out-Null
    $env:SC_ROUTER_ROOT=$temp

    $endpointDoc=[ordered]@{
        schemaVersion=2
        entries=[ordered]@{
            'free-a::m1'=[ordered]@{id='free-a::m1';connection='free-a';model='m1';displayName='A1';enabled=$true;workhorse=$true;free=$true;supportsTools=$true;toolMode='native'}
            'free-a::m2'=[ordered]@{id='free-a::m2';connection='free-a';model='m2';displayName='A2';enabled=$true;workhorse=$true;free=$true;supportsTools=$true;toolMode='native'}
            'free-b::m3'=[ordered]@{id='free-b::m3';connection='free-b';model='m3';displayName='B3';enabled=$true;workhorse=$true;free=$true;supportsTools=$true;toolMode='native'}
            'free-b::m4'=[ordered]@{id='free-b::m4';connection='free-b';model='m4';displayName='B4 unknown tool metadata';enabled=$true;workhorse=$true;free=$true;toolMode='native'}
            'auto::openrouter/free'=[ordered]@{id='auto::openrouter/free';connection='auto';model='openrouter/free';displayName='OpenRouter Free Auto';enabled=$true;workhorse=$true;free=$true;supportsTools=$true;toolMode='native'}
        }
    }
    $endpointDoc|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'endpoints.json') -Encoding UTF8

    $connectionDoc=[ordered]@{
        schemaVersion=2
        connections=[ordered]@{
            'free-a'=[ordered]@{name='free-a';presetId='custom';protocol='openai-chat';baseUrl='http://127.0.0.1:65531/v1';modelsPath='/models';authKind='none';headers=[ordered]@{}}
            'free-b'=[ordered]@{name='free-b';presetId='custom';protocol='openai-chat';baseUrl='http://127.0.0.1:65532/v1';modelsPath='/models';authKind='none';headers=[ordered]@{}}
            'auto'=[ordered]@{name='auto';presetId='custom';protocol='openai-chat';baseUrl='http://127.0.0.1:65533/v1';modelsPath='/models';authKind='none';headers=[ordered]@{}}
        }
    }
    $connectionDoc|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'connections.json') -Encoding UTF8

    $daemon=Start-Process -FilePath $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden
    $ready=$false
    foreach($i in 1..30){
        Start-Sleep -Milliseconds 100
        try{[void](Call-Router @('ping'));$ready=$true;break}catch{}
    }
    Assert-True $ready 'Router daemon did not become ready.'

    Write-Host '  ROUTER 0: operator may pin a connection pool or one exact endpoint'
    $connPin=Call-Router @('acquire','--connection','free-a','--session','pin-connection','--owner-pid',[string]$PID)
    Assert-True ([string]$connPin.data.connection -eq 'free-a') 'Connection pin escaped to a different provider/account.'
    Assert-True ([bool]$connPin.data.connectionHonored) 'Connection pin was not reported as honored.'
    [void](Call-Router @('release','--lease',[string]$connPin.data.lease))
    $endpointPin=Call-Router @('acquire','--preferred','free-b::m3','--strict-preferred','true','--session','pin-endpoint','--owner-pid',[string]$PID)
    Assert-True ([string]$endpointPin.data.catalogId -eq 'free-b::m3') 'Exact endpoint pin selected a different endpoint.'
    Assert-True ([bool]$endpointPin.data.preferredHonored) 'Exact endpoint pin was not reported as honored.'
    [void](Call-Router @('release','--lease',[string]$endpointPin.data.lease))

    Write-Host '  ROUTER 0B: unknown tool metadata does not silently remove an enabled endpoint'
    $unknownTools=Call-Router @('acquire','--preferred','free-b::m4','--strict-preferred','true','--session','unknown-tools','--owner-pid',[string]$PID)
    Assert-True ([string]$unknownTools.data.catalogId -eq 'free-b::m4') 'Enabled endpoint with unknown tool metadata was silently excluded from ordinary routing.'
    [void](Call-Router @('release','--lease',[string]$unknownTools.data.lease))

    Write-Host '  ROUTER 0C: no-route failures explain the eligibility decision'
    $noneRaw=& $router acquire --connection definitely-missing --session no-route --owner-pid $PID | ConvertFrom-Json
    Assert-True (-not [bool]$noneRaw.ok) 'Missing connection unexpectedly acquired a route.'
    Assert-True ([string]$noneRaw.data.reason -eq 'no_eligible_endpoint') 'No-route result did not identify an eligibility failure.'
    Assert-True ([int]$noneRaw.data.configuredEndpoints -ge 4) 'No-route diagnostic did not report the configured endpoint population.'

    Write-Host '  ROUTER 0D: one timeout cools only the failed endpoint, not sibling models'
    $transient=Call-Router @('acquire','--preferred','free-a::m1','--strict-preferred','true','--session','transient-scope','--owner-pid',[string]$PID)
    [void](Call-Router @('failure','--lease',[string]$transient.data.lease,'--class','timeout','--message','request timed out'))
    $transientSnap=(Call-Router @('snapshot')).data
    $failedTransient=@($transientSnap.routes|Where-Object{[string]$_.endpoint -eq 'pool:free-a::m1'})[0]
    $siblingTransient=@($transientSnap.routes|Where-Object{[string]$_.endpoint -eq 'pool:free-a::m2'})[0]
    Assert-True (-not [bool]$failedTransient.available) 'Timed-out endpoint did not cool down.'
    Assert-True ([bool]$siblingTransient.available) 'One timeout incorrectly removed sibling models on the same connection.'
    [void](Call-Router @('success','--endpoint','pool:free-a::m1'))

    Write-Host '  ROUTER 1: one active lease per exact endpoint and round-robin spreads work'
    $a=Call-Router @('acquire','--connection','free-a','--session','s1','--owner-pid',[string]$PID)
    $b=Call-Router @('acquire','--session','s2','--owner-pid',[string]$PID)
    Assert-True ([string]$a.data.endpoint -ne [string]$b.data.endpoint) 'Second worker received an already-leased endpoint.'
    $c=Call-Router @('acquire','--session','s3','--preferred',[string]$a.data.endpoint,'--owner-pid',[string]$PID)
    Assert-True ([string]$c.data.endpoint -ne [string]$a.data.endpoint) 'Preferred endpoint bypassed an active lease.'
    Assert-True (-not [bool]$c.data.preferredHonored) 'Busy preferred route was reported as honored.'

    Write-Host '  ROUTER 1B: an auto-routing endpoint accepts five leases while a fixed model remains exclusive'
    $autoBefore=(Call-Router @('snapshot')).data
    $existingAuto=[int](@($autoBefore.leases|Where-Object{[string]$_.route -eq 'pool:auto::openrouter/free'}).Count)
    $autoLeases=@()
    foreach($n in 1..(5-$existingAuto)){$autoLeases+=,(Call-Router @('acquire','--preferred','auto::openrouter/free','--strict-preferred','true','--session',("auto-"+$n),'--owner-pid',[string]$PID))}
    $autoAtCapacity=(Call-Router @('snapshot')).data
    Assert-True (@($autoAtCapacity.leases|Where-Object{[string]$_.route -eq 'pool:auto::openrouter/free'}).Count -eq 5) 'Auto-routing endpoint did not reach five concurrent leases.'
    $sixthRaw=& $router acquire --preferred 'auto::openrouter/free' --strict-preferred true --session auto-6 --owner-pid $PID | ConvertFrom-Json
    Assert-True (-not [bool]$sixthRaw.ok) 'Auto-routing endpoint accepted a sixth concurrent lease.'
    foreach($lease in $autoLeases){[void](Call-Router @('release','--lease',[string]$lease.data.lease))}

    Write-Host '  ROUTER 2: a model 429 cools only that endpoint'
    [void](Call-Router @('failure','--lease',[string]$a.data.lease,'--class','rate_limited','--message','HTTP 429 Retry-After: 30'))
    $snap=(Call-Router @('snapshot')).data
    $sameConnection=@($snap.routes|Where-Object { [string]$_.connection -eq 'free-a' })
    Assert-True (@($sameConnection|Where-Object { [string]$_.endpoint -eq [string]$a.data.endpoint -and -not [bool]$_.available }).Count -eq 1) 'Rate-limited endpoint remained eligible.'
    Assert-True (@($sameConnection|Where-Object { [string]$_.endpoint -ne [string]$a.data.endpoint -and [bool]$_.available }).Count -gt 0) 'Model-scoped 429 incorrectly poisoned a sibling endpoint.'
    $otherConnection=@($snap.routes|Where-Object { [string]$_.connection -eq 'free-b' })
    Assert-True (@($otherConnection|Where-Object { [bool]$_.available }).Count -gt 0) 'Model-scoped 429 incorrectly poisoned a different connection.'

    Write-Host '  ROUTER 3: active endpoint cooldown remains excluded from production routing'
    Start-Sleep -Milliseconds 500
    $snap=(Call-Router @('snapshot')).data
    $stillCooling=@($snap.routes|Where-Object { [string]$_.endpoint -eq [string]$a.data.endpoint })
    Assert-True (@($stillCooling|Where-Object { [bool]$_.available }).Count -eq 0) 'Endpoint cooldown was ignored before its Retry-After window elapsed.'

    Write-Host '  ROUTER 4: connection auth quarantine removes every model sharing that credential'
    [void](Call-Router @('failure','--lease',[string]$b.data.lease,'--class','auth','--message','HTTP 401 invalid API key'))
    $snap=(Call-Router @('snapshot')).data
    $same=@($snap.routes|Where-Object { [string]$_.connection -eq [string]$b.data.connection })
    Assert-True ($same.Count -gt 0) 'Expected routes sharing the failed connection.'
    Assert-True (@($same|Where-Object { [bool]$_.available }).Count -eq 0) 'Auth quarantine did not suppress all sibling endpoints.'

    Write-Host '  ROUTER 5: changing connection configuration clears hard quarantine'
    $connections=Get-Content -Raw (Join-Path $temp 'connections.json')|ConvertFrom-Json
    $connections.connections.([string]$b.data.connection)|Add-Member -NotePropertyName accountId -NotePropertyValue 'changed-config' -Force
    $connections|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'connections.json') -Encoding UTF8
    $deadline=(Get-Date).AddSeconds(6)
    do {
        Start-Sleep -Milliseconds 300
        $snap=(Call-Router @('snapshot')).data
        $same=@($snap.routes|Where-Object { [string]$_.connection -eq [string]$b.data.connection })
    } while(@($same|Where-Object { [bool]$_.available }).Count -eq 0 -and (Get-Date) -lt $deadline)
    Assert-True (@($same|Where-Object { [bool]$_.available }).Count -gt 0) 'Configuration change did not release auth quarantine.'

    Write-Host '  ROUTER 6: live worker lease survives router daemon restart'
    $leasedEndpoint=[string]$c.data.endpoint
    Stop-Process -Id $daemon.Id -Force
    $daemon.WaitForExit()
    # Simulate a nominal lease TTL expiring while the worker process is still
    # alive. Process identity must remain authoritative across router restart.
    $leasePath=Join-Path $temp 'routing\leases.json'
    $leaseDoc=Get-Content -Raw -LiteralPath $leasePath|ConvertFrom-Json
    foreach($lp in $leaseDoc.leases.PSObject.Properties){$lp.Value.expiresAt=[datetimeoffset]::UtcNow.AddMinutes(-5).ToString('o')}
    $leaseDoc|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $leasePath -Encoding UTF8
    $daemon=Start-Process -FilePath $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden
    $ready=$false
    foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{[void](Call-Router @('ping'));$ready=$true;break}catch{}}
    Assert-True $ready 'Restarted router daemon did not become ready.'
    $snap=(Call-Router @('snapshot')).data
    $persisted=@($snap.routes|Where-Object { [string]$_.endpoint -eq $leasedEndpoint })[0]
    Assert-True ([bool]$persisted.leased) 'Live worker lease disappeared across router restart / nominal TTL expiry.'
    Assert-True ([int]$snap.activeLeases -ge 1) 'Restarted router did not restore durable leases.'
    [void](Call-Router @('release','--lease',[string]$c.data.lease))

    Write-Host '  ROUTER 7: dead worker PID causes monitor to reclaim its endpoint'
    $owner=Start-Process -FilePath $PSHOME\pwsh.exe -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 30' -PassThru -WindowStyle Hidden
    $deadLease=Call-Router @('acquire','--session','dead-owner','--owner-pid',[string]$owner.Id)
    Stop-Process -Id $owner.Id -Force
    $owner.WaitForExit()
    $deadline=(Get-Date).AddSeconds(6)
    do {
        Start-Sleep -Milliseconds 300
        $snap=(Call-Router @('snapshot')).data
    } while([int]$snap.activeLeases -gt 0 -and (Get-Date) -lt $deadline)
    Assert-True ([int]$snap.activeLeases -eq 0) 'Dead worker process left a durable endpoint lease behind.'

    Write-Host '  ROUTER 8: legacy endpoint without weight loads as weight 1'
    $legacySnap=(Call-Router @('snapshot')).data
    $legacyRoute=@($legacySnap.routes|Where-Object{[string]$_.endpoint -eq 'pool:free-a::m1'})[0]
    Assert-True ([int]$legacyRoute.weight -eq 1) 'Endpoint stored without a weight field did not default to weight 1.'

    Write-Host '  ROUTER 9: smooth weighted round robin distributes 3:1'
    [void](Call-Router @('success','--endpoint','pool:free-a::m1'))
    [void](Call-Router @('success','--endpoint','pool:free-a::m2'))
    $wEndpointDoc=Get-Content -Raw -LiteralPath (Join-Path $temp 'endpoints.json')|ConvertFrom-Json
    $wEndpointDoc.entries.'free-a::m1'|Add-Member -NotePropertyName weight -NotePropertyValue 3 -Force
    $wEndpointDoc.entries.'free-a::m2'|Add-Member -NotePropertyName weight -NotePropertyValue 1 -Force
    foreach($k in @('free-b::m3','free-b::m4','auto::openrouter/free')){$wEndpointDoc.entries.$k.enabled=$false}
    $wEndpointDoc|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'endpoints.json') -Encoding UTF8
    Start-Sleep -Milliseconds 300
    $counts=@{}
    for($i=0;$i -lt 40;$i++){
        $r=Call-Router @('acquire','--session',("w-$i"),'--owner-pid',[string]$PID)
        $ep=[string]$r.data.endpoint
        $counts[$ep]=([int]($counts[$ep])) + 1
        [void](Call-Router @('release','--lease',[string]$r.data.lease))
    }
    $m1Count=[int]$counts['pool:free-a::m1']
    $m2Count=[int]$counts['pool:free-a::m2']
    Assert-True ($m1Count -gt 0 -and $m2Count -gt 0) 'Weighted round robin starved one of the two weighted endpoints.'
    $ratio=$m1Count / [double]$m2Count
    Assert-True ($ratio -gt 2.0 -and $ratio -lt 4.0) "Weighted round robin did not approximate a 3:1 split (got $m1Count`:$m2Count)."

    Write-Host '  ROUTER 10: weight 0 endpoint is excluded from rotation'
    $wEndpointDoc.entries.'free-a::m2'|Add-Member -NotePropertyName weight -NotePropertyValue 0 -Force
    $wEndpointDoc|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'endpoints.json') -Encoding UTF8
    Start-Sleep -Milliseconds 300
    $sawZeroWeight=$false
    for($i=0;$i -lt 15;$i++){
        $r=Call-Router @('acquire','--session',("wz-$i"),'--owner-pid',[string]$PID)
        if([string]$r.data.endpoint -eq 'pool:free-a::m2'){$sawZeroWeight=$true}
        [void](Call-Router @('release','--lease',[string]$r.data.lease))
    }
    Assert-True (-not $sawZeroWeight) 'Weight-0 endpoint was still chosen by round robin.'
    $explicitZero=Call-Router @('acquire','--preferred','free-a::m2','--strict-preferred','true','--session','wz-explicit','--owner-pid',[string]$PID)
    Assert-True ([string]$explicitZero.data.catalogId -eq 'free-a::m2') 'Weight-0 endpoint could not be selected when explicitly preferred.'
    [void](Call-Router @('release','--lease',[string]$explicitZero.data.lease))
    foreach($k in @('free-b::m3','free-b::m4','auto::openrouter/free')){$wEndpointDoc.entries.$k.enabled=$true}
    $wEndpointDoc.entries.'free-a::m1'|Add-Member -NotePropertyName weight -NotePropertyValue 1 -Force
    $wEndpointDoc.entries.'free-a::m2'|Add-Member -NotePropertyName weight -NotePropertyValue 1 -Force
    $wEndpointDoc|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'endpoints.json') -Encoding UTF8
    Start-Sleep -Milliseconds 300

    Write-Host '  ROUTER 11: project endpoint allowlist filters candidates and rejects an outside preferred pin'
    $allowed=Call-Router @('acquire','--endpoints','free-a::m1,free-a::m2','--session','allow-1','--owner-pid',[string]$PID)
    Assert-True (@('pool:free-a::m1','pool:free-a::m2') -contains [string]$allowed.data.endpoint) 'Allowlisted acquire returned an endpoint outside the allowlist.'
    Assert-True ([bool]$allowed.data.allowlistApplied) 'Allowlisted acquire did not report allowlistApplied.'
    [void](Call-Router @('release','--lease',[string]$allowed.data.lease))
    $outsidePreferredRaw=& $router acquire --endpoints 'free-a::m1,free-a::m2' --preferred 'free-b::m3' --session allow-2 --owner-pid $PID | ConvertFrom-Json
    Assert-True (-not [bool]$outsidePreferredRaw.ok) 'Preferred endpoint outside the allowlist was unexpectedly honored.'
    Assert-True ([string]$outsidePreferredRaw.data.reason -eq 'preferred_not_allowed') 'Preferred-outside-allowlist failure did not report the expected reason.'

    Write-Host '  ROUTER 12: an allowlist that matches nothing fails explicitly, never falls back to the global pool'
    $noneAllowedRaw=& $router acquire --endpoints 'does-not-exist' --session allow-3 --owner-pid $PID | ConvertFrom-Json
    Assert-True (-not [bool]$noneAllowedRaw.ok) 'Allowlist matching no endpoint unexpectedly acquired from the global pool.'
    Assert-True ([string]$noneAllowedRaw.data.reason -eq 'no_allowed_endpoints') 'Empty-allowlist failure did not report the expected reason.'

    Write-Host 'PASS: compiled router owns durable worker leases, supports connection/exact-endpoint pins, scopes failures correctly, recovers cooldowns, notices connection changes, weights rotation, and honors project allowlists.'
}
finally {
    if($daemon -and -not $daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    $env:SC_ROUTER_ROOT=$oldRoot
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

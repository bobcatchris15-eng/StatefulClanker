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
        }
    }
    $endpointDoc|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'endpoints.json') -Encoding UTF8

    $connectionDoc=[ordered]@{
        schemaVersion=2
        connections=[ordered]@{
            'free-a'=[ordered]@{name='free-a';presetId='custom';protocol='openai-chat';baseUrl='http://127.0.0.1:65531/v1';modelsPath='/models';authKind='none';headers=[ordered]@{}}
            'free-b'=[ordered]@{name='free-b';presetId='custom';protocol='openai-chat';baseUrl='http://127.0.0.1:65532/v1';modelsPath='/models';authKind='none';headers=[ordered]@{}}
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

    Write-Host '  ROUTER 1: one active lease per exact endpoint and round-robin spreads work'
    $a=Call-Router @('acquire','--session','s1','--owner-pid',[string]$PID)
    $b=Call-Router @('acquire','--session','s2','--owner-pid',[string]$PID)
    Assert-True ([string]$a.data.endpoint -ne [string]$b.data.endpoint) 'Second worker received an already-leased endpoint.'
    $c=Call-Router @('acquire','--session','s3','--preferred',[string]$a.data.endpoint,'--owner-pid',[string]$PID)
    Assert-True ([string]$c.data.endpoint -ne [string]$a.data.endpoint) 'Preferred endpoint bypassed an active lease.'
    Assert-True (-not [bool]$c.data.preferredHonored) 'Busy preferred route was reported as honored.'

    Write-Host '  ROUTER 2: endpoint 429 cools only that exact provider/model'
    [void](Call-Router @('failure','--lease',[string]$a.data.lease,'--class','rate_limited','--message','HTTP 429 Retry-After: 1'))
    $snap=(Call-Router @('snapshot')).data
    $failed=@($snap.routes|Where-Object { [string]$_.endpoint -eq [string]$a.data.endpoint })[0]
    Assert-True (-not [bool]$failed.available) 'Rate-limited endpoint remained available during cooldown.'
    $sibling=@($snap.routes|Where-Object { [string]$_.connection -eq 'free-a' -and [string]$_.endpoint -ne [string]$a.data.endpoint })[0]
    Assert-True ([bool]$sibling.available) 'Endpoint 429 incorrectly poisoned a sibling model under the same credential.'

    Write-Host '  ROUTER 3: cooldown monitor automatically re-admits endpoint when its window expires'
    Start-Sleep -Seconds 3
    $snap=(Call-Router @('snapshot')).data
    $failed=@($snap.routes|Where-Object { [string]$_.endpoint -eq [string]$a.data.endpoint })[0]
    Assert-True ([bool]$failed.available) 'Expired endpoint cooldown was not automatically recovered.'

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
    $daemon=Start-Process -FilePath $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden
    $ready=$false
    foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{[void](Call-Router @('ping'));$ready=$true;break}catch{}}
    Assert-True $ready 'Restarted router daemon did not become ready.'
    $snap=(Call-Router @('snapshot')).data
    $persisted=@($snap.routes|Where-Object { [string]$_.endpoint -eq $leasedEndpoint })[0]
    Assert-True ([bool]$persisted.leased) 'Live worker lease disappeared across router restart.'
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

    Write-Host 'PASS: compiled router owns durable worker leases, scopes failures correctly, recovers cooldowns, and notices connection changes.'
}
finally {
    if($daemon -and -not $daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    $env:SC_ROUTER_ROOT=$oldRoot
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

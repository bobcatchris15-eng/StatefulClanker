<# Verifies that PowerShell dispatch delegates routing authority to the compiled daemon. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "COMPILED ROUTER BRIDGE TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-router-bridge-'+[guid]::NewGuid().ToString('N'))
$oldLocal=$env:LOCALAPPDATA;$oldRoot=$env:SC_ROUTER_ROOT;$oldExe=$env:STATEFULCLANKER_ROUTER_EXE
$daemon=$null
try {
    $env:LOCALAPPDATA=Join-Path $temp 'local'
    $machine=Join-Path $env:LOCALAPPDATA 'StatefulClanker'
    New-Item -ItemType Directory -Force -Path $machine|Out-Null
    $env:SC_ROUTER_ROOT=$machine
    $router=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'
    $env:STATEFULCLANKER_ROUTER_EXE=$router
    $script:StatefulClankerHome=$repo

    @{
        schemaVersion=2
        entries=[ordered]@{
            'a::m1'=[ordered]@{id='a::m1';connection='a';model='m1';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='native'}
            'b::m2'=[ordered]@{id='b::m2';connection='b';model='m2';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='native'}
        }
    }|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $machine 'endpoints.json') -Encoding UTF8
    @{
        schemaVersion=2
        connections=[ordered]@{
            a=[ordered]@{name='a';baseUrl='http://127.0.0.1:65531/v1';modelsPath='/models';authKind='none';protocol='openai-chat';headers=[ordered]@{}}
            b=[ordered]@{name='b';baseUrl='http://127.0.0.1:65532/v1';modelsPath='/models';authKind='none';protocol='openai-chat';headers=[ordered]@{}}
        }
    }|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $machine 'connections.json') -Encoding UTF8

    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.RouterClient.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.CompiledRouting.ps1')

    function Get-SCConfig { return [pscustomobject]@{routing=[pscustomobject]@{maxRouteAttempts=6}} }
    function Get-SCRouteSnapshotReceipt { return [pscustomobject]@{selectedAt=[datetimeoffset]::UtcNow.ToString('o')} }
    function Get-SCWorkerSessionRoutePin([string]$SessionId) { return $null }
    $script:lastPin=$null
    function Set-SCWorkerSessionRoutePin([string]$SessionId,[string]$Endpoint,[string]$Connection,[string]$Model) {
        $script:lastPin=[pscustomobject]@{endpoint=$Endpoint;connection=$Connection;model=$Model}
    }
    function Add-SCEvent { param($Type,$Message,$Data) }
    $script:providerCalls=@()
    function Invoke-SCDirectApiProvider($Task,[string]$Prompt,[string]$Stage,$ProviderRecord,[string]$ParentAgentId,$Compilation,[string]$WorkerSessionId,[string]$ContinuationMessage) {
        $script:providerCalls+=,[string]$ProviderRecord.name
        if($script:providerCalls.Count-eq1){
            return [pscustomobject]@{id='r1';taskId=$Task.id;stage=$Stage;provider=$ProviderRecord.name;endpoint=$ProviderRecord.name;exitCode=1;stdout='';stderr='HTTP 429 Retry-After: 60'}
        }
        return [pscustomobject]@{id='r2';taskId=$Task.id;stage=$Stage;provider=$ProviderRecord.name;endpoint=$ProviderRecord.name;exitCode=0;stdout='ok';stderr=''}
    }

    $daemon=Start-Process -FilePath $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden
    $ready=$false
    foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{$r=Invoke-SCCompiledRouterCommand @('ping');if($r.ok){$ready=$true;break}}catch{}}
    Assert-True $ready 'Compiled router daemon did not become ready.'

    Write-Host '  BRIDGE 1: provider 429 fails over through compiled lease authority'
    $task=[pscustomobject]@{id='bridge-task'}
    $receipt=Invoke-SCProviderViaCompiledRouter $task 'do work' 'run' $null $null 'ws-bridge' $null
    Assert-True ([int]$receipt.exitCode-eq0) 'Failover did not reach a successful endpoint.'
    Assert-True ([bool]$receipt.compiledRouter) 'Receipt did not identify compiled routing.'
    Assert-True (@($receipt.routeHistory).Count-eq2) 'Expected one failed route and one successful route.'
    Assert-True ($script:providerCalls.Count-eq2 -and $script:providerCalls[0]-ne$script:providerCalls[1]) 'PowerShell retried the same endpoint instead of acquiring another.'
    Assert-True ($script:lastPin.endpoint-eq$script:providerCalls[1]) 'Successful failover did not update the session route preference.'

    Write-Host '  BRIDGE 2: daemon health reflects failure and releases all leases'
    $snap=(Invoke-SCCompiledRouterCommand @('snapshot')).data
    Assert-True ([int]$snap.activeLeases-eq0) 'Successful bridge left a router lease active.'
    $failed=@($snap.routes|Where-Object { [string]$_.endpoint-eq[string]$script:providerCalls[0] })[0]
    Assert-True (-not[bool]$failed.available) '429 endpoint was not left cooling after failover.'

    Write-Host 'PASS: PowerShell inference execution now uses compiled routing leases and health.'
}
finally {
    if($daemon-and-not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    $env:LOCALAPPDATA=$oldLocal;$env:SC_ROUTER_ROOT=$oldRoot;$env:STATEFULCLANKER_ROUTER_EXE=$oldExe
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

<# Free capacity lifecycle: configured connections continuously maintain only confirmed-zero-cost workhorses. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$dll=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.dll'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "FREE CAPACITY TEST FAILED: $Message"}}
if(-not(Test-Path -LiteralPath $dll)){throw "Build router before running test: $dll"}
[void][Reflection.Assembly]::LoadFrom($dll)

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-free-capacity-'+[guid]::NewGuid().ToString('N'))
$serverJob=$null
try {
    New-Item -ItemType Directory -Force -Path $temp|Out-Null

    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start();$port=([Net.IPEndPoint]$listener.LocalEndpoint).Port;$listener.Stop()

    $catalogs=@(
        '{"data":[{"id":"free-a","display_name":"Free A","supports_tools":true,"context_length":32768,"pricing":{"input":"0","output":"0"}},{"id":"free-d","display_name":"Free D","supports_tools":true,"context_length":32768,"pricing":{"input":"0","output":"0"}},{"id":"free-p","display_name":"Free P","supports_tools":true,"context_length":32768,"pricing":{"input":"0","output":"0"}},{"id":"paid-b","display_name":"Paid B","supports_tools":true,"context_length":32768,"pricing":{"input":"0.01","output":"0.02"}},{"id":"unknown-c","display_name":"Unknown C","supports_tools":true,"context_length":32768}]}',
        '{"data":[{"id":"free-a","display_name":"Free A","supports_tools":true,"context_length":32768,"pricing":{"input":"0","output":"0"}},{"id":"free-d","display_name":"Free D","supports_tools":true,"context_length":32768,"pricing":{"input":"0","output":"0"}},{"id":"free-p","display_name":"Free P","supports_tools":true,"context_length":32768,"pricing":{"input":"0","output":"0"}}]}',
        '{"data":[{"id":"free-a","display_name":"Free A","supports_tools":true,"context_length":32768,"pricing":{"input":"0","output":"0"}},{"id":"free-p","display_name":"Free P","supports_tools":true,"context_length":32768,"pricing":{"input":"0.02","output":"0.02"}}]}',
        '{"data":[{"id":"free-a","display_name":"Free A","supports_tools":true,"context_length":32768,"pricing":{"input":"0","output":"0"}},{"id":"free-p","display_name":"Free P","supports_tools":true,"context_length":32768,"pricing":{"input":"0","output":"0"}}]}',
        '{"data":[{"id":"free-a","display_name":"Free A","supports_tools":true,"context_length":32768,"pricing":{"input":"0","output":"0"}},{"id":"free-d","display_name":"Free D","supports_tools":true,"context_length":32768,"pricing":{"input":"0","output":"0"}},{"id":"free-p","display_name":"Free P","supports_tools":true,"context_length":32768,"pricing":{"input":"0","output":"0"}}]}'
    )

    $serverJob=Start-Job -ScriptBlock {
        param($Port,$Catalogs)
        $l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
        $l.Start()
        try {
            foreach($body in $Catalogs){
                $client=$l.AcceptTcpClient()
                try {
                    $stream=$client.GetStream()
                    $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,2048,$true)
                    while($true){$line=$reader.ReadLine();if($null-eq$line-or$line-eq''){break}}
                    $bytes=[Text.Encoding]::UTF8.GetBytes([string]$body)
                    $crlf=[string][char]13+[string][char]10
                    $head=('HTTP/1.1 200 OK'+$crlf+'Content-Type: application/json'+$crlf+'Content-Length: '+$bytes.Length+$crlf+'Connection: close'+$crlf+$crlf)
                    $hb=[Text.Encoding]::ASCII.GetBytes($head)
                    $stream.Write($hb,0,$hb.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
                } finally {$client.Dispose()}
            }
        } finally {$l.Stop()}
    } -ArgumentList $port,$catalogs

    $store=[StatefulClanker.Router.RouterStore]::new($temp)
    $manager=[StatefulClanker.Router.FreeCapacityManager]::new($store)
    $profile=[StatefulClanker.Router.ConnectionProfile]::new()
    $profile.name='configured'
    $profile.presetId='custom'
    $profile.protocol='openai-chat'
    $profile.baseUrl="http://127.0.0.1:$port/v1"
    $profile.modelsPath='/models'
    $profile.discoveryKind='openai'
    $profile.authKind='none'

    Write-Host '  CAPACITY 1: only positively confirmed zero-cost workhorses enter the pool'
    Assert-True ($manager.SyncConnectionAsync('configured',$profile).GetAwaiter().GetResult()) 'Initial catalog sync failed.'
    $pool=$store.LoadEndpoints()
    Assert-True ($pool.entries.ContainsKey('configured::free-a')) 'Confirmed-free model was not added.'
    Assert-True ($pool.entries.ContainsKey('configured::free-d')) 'Second confirmed-free model was not added.'
    Assert-True ($pool.entries.ContainsKey('configured::free-p')) 'Third confirmed-free model was not added.'
    Assert-True (-not$pool.entries.ContainsKey('configured::paid-b')) 'Paid model entered the automatic free pool.'
    Assert-True (-not$pool.entries.ContainsKey('configured::unknown-c')) 'Unknown-cost model entered the automatic free pool.'
    Assert-True ([string]$pool.entries['configured::free-a'].managedBy-eq'free-capacity') 'Auto-added endpoint is not lifecycle-managed.'

    Write-Host '  CAPACITY 2: human disable persists across successful rediscovery'
    $pool.entries['configured::free-a'].enabled=$false
    $pool.entries['configured::free-a'].userOverride='disabled'
    $store.SaveEndpoints($pool)
    Assert-True ($manager.SyncConnectionAsync('configured',$profile).GetAwaiter().GetResult()) 'Second catalog sync failed.'
    $pool=$store.LoadEndpoints()
    Assert-True (-not[bool]$pool.entries['configured::free-a'].enabled) 'Human-disabled auto endpoint was resurrected.'
    Assert-True ([string]$pool.entries['configured::free-a'].userOverride-eq'disabled') 'Human suppression marker was lost.'

    Write-Host '  CAPACITY 3: first catalog miss gets grace while positive price retires immediately'
    Assert-True ($manager.SyncConnectionAsync('configured',$profile).GetAwaiter().GetResult()) 'Third catalog sync failed.'
    $pool=$store.LoadEndpoints()
    Assert-True ([bool]$pool.entries['configured::free-d'].enabled) 'Single catalog miss retired a free endpoint too aggressively.'
    Assert-True ([int]$pool.entries['configured::free-d'].discoveryMisses-eq1) 'First disappearance miss was not recorded.'
    Assert-True (-not[bool]$pool.entries['configured::free-p'].enabled) 'Positive-price model remained enabled.'
    Assert-True ([string]$pool.entries['configured::free-p'].retiredReason-eq'no-longer-zero-cost') 'Price flip retirement reason was wrong.'

    Write-Host '  CAPACITY 4: second miss retires missing model and zero-price recovery re-enables price-flipped model'
    Assert-True ($manager.SyncConnectionAsync('configured',$profile).GetAwaiter().GetResult()) 'Fourth catalog sync failed.'
    $pool=$store.LoadEndpoints()
    Assert-True (-not[bool]$pool.entries['configured::free-d'].enabled) 'Second successful catalog miss did not retire endpoint.'
    Assert-True ([string]$pool.entries['configured::free-d'].retiredReason-eq'catalog-missing') 'Missing endpoint retirement reason was wrong.'
    Assert-True ([bool]$pool.entries['configured::free-p'].enabled) 'Model returning to confirmed-zero-cost did not re-enter pool.'
    Assert-True ($null-eq$pool.entries['configured::free-p'].retiredReason) 'Recovered free model kept stale retirement reason.'

    Write-Host '  CAPACITY 5: reappearing free model returns automatically; suppressed endpoint stays suppressed'
    Assert-True ($manager.SyncConnectionAsync('configured',$profile).GetAwaiter().GetResult()) 'Fifth catalog sync failed.'
    $pool=$store.LoadEndpoints()
    Assert-True ([bool]$pool.entries['configured::free-d'].enabled) 'Reappearing confirmed-free model did not return to rotation.'
    Assert-True ([int]$pool.entries['configured::free-d'].discoveryMisses-eq0) 'Reappearing model did not clear miss counter.'
    Assert-True (-not[bool]$pool.entries['configured::free-a'].enabled) 'Human-suppressed endpoint was resurrected after later rediscovery.'

    Write-Host '  CAPACITY 6: discovery state records free/paid/unknown inventory'
    $discovery=$store.LoadCapacityDiscovery()
    $state=$discovery.connections['configured']
    Assert-True ([int]$state.confirmedFree-eq3) 'Final confirmed-free inventory count was wrong.'
    Assert-True ([int]$state.workhorseFree-eq3) 'Final free workhorse count was wrong.'
    Assert-True ($null-eq$state.lastError) 'Successful discovery retained an error.'

    Write-Host 'PASS: configured connections autonomously maintain a safe zero-cost workhorse pool without overriding operator suppression.'
}
finally {
    if($serverJob){Stop-Job $serverJob -ErrorAction SilentlyContinue;Remove-Job $serverJob -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

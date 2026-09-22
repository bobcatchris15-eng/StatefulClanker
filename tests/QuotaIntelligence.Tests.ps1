<# Provider quota intelligence: exact cooldowns and autonomous connection sampling. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$router=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "QUOTA INTELLIGENCE TEST FAILED: $Message"}}
function Call-Router([string[]]$CallArgs) {
    $raw=& $router @CallArgs
    $code=$LASTEXITCODE
    $obj=$raw|ConvertFrom-Json
    if($code-ne0-or-not[bool]$obj.ok){throw ("Router call failed ({0}): {1}" -f ($CallArgs-join' '),$raw)}
    return $obj
}
function Route([object]$Snapshot,[string]$Endpoint){return @($Snapshot.routes|Where-Object{[string]$_.endpoint-eq$Endpoint})[0]}
function SecondsUntil([string]$Iso){return ([datetimeoffset]::Parse($Iso)-[datetimeoffset]::UtcNow).TotalSeconds}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-quota-'+[guid]::NewGuid().ToString('N'))
$oldRoot=$env:SC_ROUTER_ROOT
$daemon=$null;$serverJob=$null
try {
    New-Item -ItemType Directory -Force -Path $temp|Out-Null
    $env:SC_ROUTER_ROOT=$temp

    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start();$port=([Net.IPEndPoint]$listener.LocalEndpoint).Port;$listener.Stop()
    $serverJob=Start-Job -ScriptBlock {
        param($Port)
        $l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
        $l.Start()
        try {
            foreach($requestNo in 1..5){
                $client=$l.AcceptTcpClient()
                try {
                    $stream=$client.GetStream()
                    $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,1024,$true)
                    while($true){$line=$reader.ReadLine();if($null-eq$line-or$line-eq''){break}}
                    $body='{"data":[]}'
                    $bytes=[Text.Encoding]::UTF8.GetBytes($body)
                    $crlf=[string][char]13+[string][char]10
                    $head=('HTTP/1.1 200 OK'+$crlf+
                        'Content-Type: application/json'+$crlf+
                        'Content-Length: '+$bytes.Length+$crlf+
                        'X-RateLimit-Limit-Requests: 30'+$crlf+
                        'X-RateLimit-Remaining-Requests: 7'+$crlf+
                        'X-RateLimit-Reset-Requests: 45s'+$crlf+
                        'X-RateLimit-Limit-Tokens: 8000'+$crlf+
                        'X-RateLimit-Remaining-Tokens: 6000'+$crlf+
                        'X-RateLimit-Reset-Tokens: 7.66s'+$crlf+
                        'Connection: close'+$crlf+$crlf)
                    $headBytes=[Text.Encoding]::ASCII.GetBytes($head)
                    $stream.Write($headBytes,0,$headBytes.Length)
                    $stream.Write($bytes,0,$bytes.Length)
                    $stream.Flush()
                } finally {$client.Dispose()}
            }
        } finally {$l.Stop()}
    } -ArgumentList $port

    $rootUrl='http://127.0.0.1:'+$port
    @{
      schemaVersion=2
      entries=[ordered]@{
        'groq::m'=[ordered]@{id='groq::m';connection='groq';model='m';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='native'}
        'anth::m'=[ordered]@{id='anth::m';connection='anth';model='m';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='native'}
        'cf::m'=[ordered]@{id='cf::m';connection='cf';model='m';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='native'}
        'gem::m'=[ordered]@{id='gem::m';connection='gem';model='m';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='native'}
        'mock::m'=[ordered]@{id='mock::m';connection='mock';model='m';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='native'}
      }
    }|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'endpoints.json') -Encoding UTF8

    @{
      schemaVersion=2
      connections=[ordered]@{
        groq=[ordered]@{name='groq';presetId='groq';protocol='openai-chat';baseUrl=($rootUrl+'/v1');modelsPath='/models';authKind='none';headers=[ordered]@{}}
        anth=[ordered]@{name='anth';presetId='anthropic';protocol='anthropic-messages';baseUrl=$rootUrl;modelsPath='/v1/models';authKind='none';headers=[ordered]@{}}
        cf=[ordered]@{name='cf';presetId='cloudflare';protocol='openai-chat';baseUrl=($rootUrl+'/v1');modelsPath='/models';authKind='none';headers=[ordered]@{}}
        gem=[ordered]@{name='gem';presetId='gemini';protocol='gemini-native';baseUrl=($rootUrl+'/v1beta');modelsPath='/models';authKind='none';headers=[ordered]@{}}
        mock=[ordered]@{name='mock';presetId='custom';protocol='openai-chat';baseUrl=($rootUrl+'/v1');modelsPath='/models';authKind='none';headers=[ordered]@{}}
      }
    }|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'connections.json') -Encoding UTF8

    $daemon=Start-Process -FilePath $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden
    $ready=$false
    foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{[void](Call-Router @('ping'));$ready=$true;break}catch{}}
    Assert-True $ready 'Router daemon did not become ready.'

    Write-Host '  QUOTA 1: Groq compact reset duration becomes exact endpoint cooldown'
    $lease=Call-Router @('acquire','--preferred','pool:groq::m','--owner-pid',[string]$PID)
    $msg='HTTP 429'+[Environment]::NewLine+'X-RateLimit-Remaining-Requests: 0'+[Environment]::NewLine+'X-RateLimit-Reset-Requests: 2m59.56s'
    [void](Call-Router @('failure','--lease',[string]$lease.data.lease,'--class','rate_limited','--message',$msg))
    $r=Route (Call-Router @('snapshot')).data 'pool:groq::m'
    $secs=SecondsUntil ([string]$r.health.quota.nextAvailableAt)
    Assert-True ($secs-gt150-and$secs-lt190) "Groq reset duration was not preserved ($secs sec)."

    Write-Host '  QUOTA 2: Anthropic RFC3339 reset is preserved'
    $anthReset=[datetimeoffset]::UtcNow.AddMinutes(4).ToString('O')
    $lease=Call-Router @('acquire','--preferred','pool:anth::m','--owner-pid',[string]$PID)
    $msg='HTTP 429'+[Environment]::NewLine+'Anthropic-RateLimit-Requests-Remaining: 0'+[Environment]::NewLine+'Anthropic-RateLimit-Requests-Reset: '+$anthReset
    [void](Call-Router @('failure','--lease',[string]$lease.data.lease,'--class','rate_limited','--message',$msg))
    $r=Route (Call-Router @('snapshot')).data 'pool:anth::m'
    Assert-True ([math]::Abs((SecondsUntil ([string]$r.health.quota.nextAvailableAt))-240)-lt8) 'Anthropic reset timestamp was not used.'

    Write-Host '  QUOTA 3: Cloudflare composite RateLimit t value is parsed intact'
    $lease=Call-Router @('acquire','--preferred','pool:cf::m','--owner-pid',[string]$PID)
    $msg='HTTP 429'+[Environment]::NewLine+'RateLimit: "default";r=0;t=30'
    [void](Call-Router @('failure','--lease',[string]$lease.data.lease,'--class','rate_limited','--message',$msg))
    $r=Route (Call-Router @('snapshot')).data 'pool:cf::m'
    Assert-True ((SecondsUntil ([string]$r.health.quota.nextAvailableAt))-gt20) 'Cloudflare t=30 window was not used.'
    Assert-True ([double]$r.health.quota.remaining-eq0) 'Cloudflare remaining quota was not captured.'

    Write-Host '  QUOTA 4: Gemini RetryInfo body controls retry time'
    $lease=Call-Router @('acquire','--preferred','pool:gem::m','--owner-pid',[string]$PID)
    $gemBody='HTTP 429 Body: {"error":{"code":429,"details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"42s"}]}}'
    [void](Call-Router @('failure','--lease',[string]$lease.data.lease,'--class','rate_limited','--message',$gemBody))
    $r=Route (Call-Router @('snapshot')).data 'pool:gem::m'
    $secs=SecondsUntil ([string]$r.health.quota.nextAvailableAt)
    Assert-True ($secs-gt30-and$secs-lt50) 'Gemini RetryInfo delay was not used.'

    Write-Host '  QUOTA 5: monitor autonomously samples a healthy connection without inference'
    $deadline=(Get-Date).AddSeconds(15);$mock=$null
    do {
        Start-Sleep -Milliseconds 300
        $mock=Route (Call-Router @('snapshot')).data 'pool:mock::m'
    } while(($null-eq$mock.health.quota-or$null-eq$mock.health.quota.remaining)-and(Get-Date)-lt$deadline)
    Assert-True ($null-ne$mock.health.quota) 'Monitor did not record quota metadata from healthy connection probe.'
    Assert-True ([double]$mock.health.quota.remaining-eq7) 'Healthy probe did not capture remaining request quota.'
    Assert-True ([double]$mock.health.quota.limit-eq30) 'Healthy probe did not capture request limit.'
    Assert-True ($null-ne$mock.health.quota.resetAt) 'Healthy probe did not capture reset window.'
    Assert-True ([string]$mock.health.quota.source -like 'probe:*') 'Background quota metadata was not labeled as probe-derived.'

    Write-Host '  QUOTA 5B: simultaneous request/token windows are retained independently'
    $mock=Route (Call-Router @('snapshot')).data 'pool:mock::m'
    $windows=@($mock.health.quota.windows)
    $requestWindow=@($windows|Where-Object { [string]$_.kind -eq 'requests' }|Select-Object -First 1)
    $tokenWindow=@($windows|Where-Object { [string]$_.kind -eq 'tokens' }|Select-Object -First 1)
    Assert-True ($requestWindow.Count-eq1) 'Request quota window was not retained.'
    Assert-True ($tokenWindow.Count-eq1) 'Token quota window was not retained.'
    Assert-True ([double]$requestWindow[0].remaining-eq7) 'Request remaining count was wrong.'
    Assert-True ([double]$tokenWindow[0].remaining-eq6000) 'Token remaining count was wrong.'
    Assert-True ($null-ne$requestWindow[0].resetAt -and $null-ne$tokenWindow[0].resetAt) 'Independent reset times were not retained.'

    Write-Host '  QUOTA 5C: fixed provider reset rules are available without inference'
    $cf=Route (Call-Router @('snapshot')).data 'pool:cf::m'
    $cfWindow=@($cf.health.quota.windows|Where-Object { [string]$_.kind -eq 'free_allocation' }|Select-Object -First 1)
    Assert-True ($cfWindow.Count-eq1) 'Cloudflare daily free-allocation window was not derived.'
    Assert-True ([string]$cfWindow[0].unit-eq'neurons/day') 'Cloudflare quota unit was not preserved.'
    Assert-True ([double]$cfWindow[0].limit-eq10000) 'Cloudflare daily free allocation limit was not recorded.'
    $gem=Route (Call-Router @('snapshot')).data 'pool:gem::m'
    $gemWindow=@($gem.health.quota.windows|Where-Object { [string]$_.kind -eq 'requests_per_day' }|Select-Object -First 1)
    Assert-True ($gemWindow.Count-eq1) 'Gemini daily reset window was not derived without inference.'

    Write-Host '  QUOTA 6: Retry-After outranks a longer generic reset timer'
    $lease=Call-Router @('acquire','--preferred','pool:mock::m','--owner-pid',[string]$PID)
    $msg='HTTP 429'+[Environment]::NewLine+'Retry-After: 3'+[Environment]::NewLine+'X-RateLimit-Remaining-Requests: 0'+[Environment]::NewLine+'X-RateLimit-Reset-Requests: 2m'
    [void](Call-Router @('failure','--lease',[string]$lease.data.lease,'--class','rate_limited','--message',$msg))
    $r=Route (Call-Router @('snapshot')).data 'pool:mock::m'
    $secs=SecondsUntil ([string]$r.health.quota.nextAvailableAt)
    Assert-True ($secs-gt1-and$secs-lt6) "Retry-After did not control the next retry ($secs sec)."
    Assert-True ([string]$r.health.quota.source-eq'retry-after') 'Retry-After was not preserved as the strongest provider evidence.'

    Write-Host 'PASS: provider-reported quota timing drives cooldowns and the monitor learns quota metadata proactively.'
}
finally {
    if($daemon-and-not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    if($serverJob){Stop-Job $serverJob -ErrorAction SilentlyContinue;Remove-Job $serverJob -Force -ErrorAction SilentlyContinue}
    $env:SC_ROUTER_ROOT=$oldRoot
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

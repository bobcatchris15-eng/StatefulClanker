<# Non-inference probing and programmatic quota-window regression tests. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$router=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'
$dll=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.dll'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "NON-INFERENCE PROBE TEST FAILED: $Message"}}
function Call-Router([string[]]$CallArgs) {
    $raw=& $router @CallArgs
    $code=$LASTEXITCODE
    $obj=$raw|ConvertFrom-Json
    if($code-ne0-or-not[bool]$obj.ok){throw ("Router call failed ({0}): {1}" -f ($CallArgs-join' '),$raw)}
    return $obj
}
function Route([object]$Snapshot,[string]$Endpoint){return @($Snapshot.routes|Where-Object{[string]$_.endpoint-eq$Endpoint})[0]}

Write-Host '  PROBE 1: legacy Route Doctor contains no inference probe'
$worker=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')
$start=$worker.IndexOf('function Invoke-SCRouteProbeRecord')
$end=$worker.IndexOf('function Invoke-SCRouteDoctor',$start)
Assert-True ($start-ge0-and$end-gt$start) 'Could not locate Route Doctor probe function.'
$probeBody=$worker.Substring($start,$end-$start)
Assert-True (-not$probeBody.Contains('Invoke-SCApiChat')) 'Legacy Route Doctor still calls inference.'
Assert-True (-not$probeBody.Contains('Reply exactly OK')) 'Legacy Route Doctor still contains sacrificial prompt text.'
Assert-True ($probeBody.Contains('Invoke-WebRequest -Method Get')) 'Legacy Route Doctor is not using GET metadata probing.'

Write-Host '  PROBE 2: deterministic provider windows advance locally'
[void][Reflection.Assembly]::LoadFrom($dll)
$cf=[StatefulClanker.Router.ConnectionProfile]::new();$cf.presetId='cloudflare'
$now=[datetimeoffset]::UtcNow
$cfWindow=[StatefulClanker.Router.ProviderProbePolicy]::ProgrammaticWindow($cf,$now)
Assert-True ($null-ne$cfWindow) 'Cloudflare deterministic window was not produced.'
$cfReset=[datetimeoffset]::Parse($cfWindow.windowResetAt)
Assert-True ($cfReset-gt$now-and$cfReset-le$now.AddDays(1.01)) 'Cloudflare next daily reset is not within the next UTC day.'
Assert-True ([string]$cfWindow.windowSource-eq'policy:cloudflare-free-allocation') 'Cloudflare window source was not documented policy.'

$gem=[StatefulClanker.Router.ConnectionProfile]::new();$gem.presetId='gemini'
$gemWindow=[StatefulClanker.Router.ProviderProbePolicy]::ProgrammaticWindow($gem,$now)
Assert-True ($null-ne$gemWindow) 'Gemini deterministic window was not produced.'
$gemReset=[datetimeoffset]::Parse($gemWindow.windowResetAt)
Assert-True ($gemReset-gt$now-and$gemReset-le$now.AddDays(1.01)) 'Gemini next RPD reset is not within the next Pacific day.'
Assert-True ([string]$gemWindow.windowSource-eq'policy:gemini-rpd') 'Gemini window source was not documented policy.'

Write-Host '  PROBE 3: OpenRouter uses non-inference account metadata'
$or=[StatefulClanker.Router.ConnectionProfile]::new();$or.presetId='openrouter';$or.baseUrl='https://openrouter.ai/api/v1';$or.modelsPath='/models'
$plan=[StatefulClanker.Router.ProviderProbePolicy]::For($or)
Assert-True ([string]$plan.Uri-eq'https://openrouter.ai/api/v1/key') 'OpenRouter probe is not the current-key metadata endpoint.'
Assert-True ([string]$plan.Kind-eq'account-metadata') 'OpenRouter probe kind is not account metadata.'
Assert-True ([string]$plan.AppliesTo-eq'account-budget') 'OpenRouter metadata is not scoped as account budget.'

Write-Host '  PROBE 4: metadata 429 does not cool inference route'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-noinfer-'+[guid]::NewGuid().ToString('N'))
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
            foreach($requestNo in 1..1){
                $client=$l.AcceptTcpClient()
                try {
                    $stream=$client.GetStream()
                    $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,1024,$true)
                    while($true){$line=$reader.ReadLine();if($null-eq$line-or$line-eq''){break}}
                    $body='{"error":{"message":"metadata bucket busy"}}'
                    $bytes=[Text.Encoding]::UTF8.GetBytes($body)
                    $crlf=[string][char]13+[string][char]10
                    $head=('HTTP/1.1 429 Too Many Requests'+$crlf+
                        'Content-Type: application/json'+$crlf+
                        'Content-Length: '+$bytes.Length+$crlf+
                        'Retry-After: 30'+$crlf+
                        'Connection: close'+$crlf+$crlf)
                    $hb=[Text.Encoding]::ASCII.GetBytes($head)
                    $stream.Write($hb,0,$hb.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
                } finally {$client.Dispose()}
            }
        } finally {$l.Stop()}
    } -ArgumentList $port

    @{
      schemaVersion=2
      entries=[ordered]@{
        'mock::m'=[ordered]@{id='mock::m';connection='mock';model='m';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='native'}
      }
    }|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'endpoints.json') -Encoding UTF8
    @{
      schemaVersion=2
      connections=[ordered]@{
        mock=[ordered]@{name='mock';presetId='custom';protocol='openai-chat';baseUrl=('http://127.0.0.1:'+$port+'/v1');modelsPath='/models';authKind='none';headers=[ordered]@{}}
      }
    }|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'connections.json') -Encoding UTF8

    $daemon=Start-Process -FilePath $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden
    $ready=$false
    foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{[void](Call-Router @('ping'));$ready=$true;break}catch{}}
    Assert-True $ready 'Router daemon did not become ready.'

    $deadline=(Get-Date).AddSeconds(8);$route=$null
    do {
        Start-Sleep -Milliseconds 250
        $route=Route (Call-Router @('snapshot')).data 'pool:mock::m'
    } while(($null-eq$route.health.quota)-and(Get-Date)-lt$deadline)

    Assert-True ($null-ne$route.health.quota) 'Metadata 429 was not observed.'
    Assert-True ([string]$route.health.quota.source -like 'probe:metadata:*') 'Metadata 429 was not clearly scoped as metadata.'
    Assert-True ([bool]$route.available) 'Metadata 429 incorrectly disabled the inference endpoint.'
    Assert-True ([string]$route.health.state-eq'healthy') 'Metadata 429 changed inference route health.'
}
finally {
    if($daemon-and-not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    if($serverJob){Stop-Job $serverJob -ErrorAction SilentlyContinue;Remove-Job $serverJob -Force -ErrorAction SilentlyContinue}
    $env:SC_ROUTER_ROOT=$oldRoot
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS: route probing is non-inference, deterministic windows advance locally, and metadata throttling does not poison inference.'

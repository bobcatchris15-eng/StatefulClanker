<# Pool exhaustion must collapse to one scheduler-facing result with retry projection. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$router=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ROUTER EXHAUSTION TEST FAILED: $Message"}}
function Call-Router([string[]]$CallArgs){$raw=& $router @CallArgs;$obj=$raw|ConvertFrom-Json;if($LASTEXITCODE-ne0-or-not[bool]$obj.ok){throw "router call failed: $raw"};return $obj}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-router-exhaust-'+[guid]::NewGuid().ToString('N'))
$oldRoot=$env:SC_ROUTER_ROOT;$port=39000+(Get-Random -Minimum 0 -Maximum 2000);$server=$null;$daemon=$null
try{
    New-Item -ItemType Directory -Force -Path $temp|Out-Null;$env:SC_ROUTER_ROOT=$temp
    [ordered]@{schemaVersion=2;connections=[ordered]@{
        a=[ordered]@{name='a';presetId='mock';protocol='openai-chat';baseUrl="http://127.0.0.1:$port/a/v1";modelsPath='/models';authKind='none';headers=[ordered]@{}}
        b=[ordered]@{name='b';presetId='mock';protocol='openai-chat';baseUrl="http://127.0.0.1:$port/b/v1";modelsPath='/models';authKind='none';headers=[ordered]@{}}
    }}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'connections.json') -Encoding UTF8
    [ordered]@{schemaVersion=3;entries=[ordered]@{
        'a::model'=[ordered]@{id='a::model';connection='a';model='a-model';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='text';weight=100}
        'b::model'=[ordered]@{id='b::model';connection='b';model='b-model';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='text';weight=1}
    }}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'endpoints.json') -Encoding UTF8

    $serverScript=Join-Path $temp 'server.ps1'
    @'
param([int]$Port)
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port);$listener.Start()
try{
 while($true){
  $client=$listener.AcceptTcpClient();$stream=$client.GetStream()
  try{
   $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,4096,$true);$first=$reader.ReadLine();$headers=@{};$length=0
   while($true){$line=$reader.ReadLine();if($null-eq$line-or$line-eq''){break};$i=$line.IndexOf(':');if($i-gt0){$headers[$line.Substring(0,$i).Trim()]=$line.Substring($i+1).Trim()}}
   if($headers.ContainsKey('Content-Length')){$length=[int]$headers['Content-Length']};if($length-gt0){$buf=New-Object char[] $length;[void]$reader.ReadBlock($buf,0,$length)}
   if($first-match'^GET '){$status='200 OK';$body='{"data":[]}'}
   else{$status='429 Too Many Requests';$body='{"error":{"message":"pool temporarily limited"}}'}
   $bytes=[Text.Encoding]::UTF8.GetBytes($body);$crlf=[string][char]13+[char]10
   $head=[Text.Encoding]::ASCII.GetBytes('HTTP/1.1 '+$status+$crlf+'Content-Type: application/json'+$crlf+'Retry-After: 60'+$crlf+'Content-Length: '+$bytes.Length+$crlf+'Connection: close'+$crlf+$crlf)
   $stream.Write($head,0,$head.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
  }finally{$stream.Dispose();$client.Close()}
 }
}finally{$listener.Stop()}
'@|Set-Content -LiteralPath $serverScript -Encoding UTF8
    $server=Start-Process -FilePath $PSHOME\pwsh.exe -ArgumentList '-NoProfile','-File',$serverScript,'-Port',("$port") -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 500;$daemon=Start-Process -FilePath $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden

    $requestFile=Join-Path $temp 'request.json'
    [ordered]@{messages=@([ordered]@{role='user';content='reply'});tools=@();toolMode='text';maxOutputTokens=16;timeoutSeconds=10;maxRouteAttempts=2;maxRouteWaitSeconds=0}|ConvertTo-Json -Depth 20 -Compress|Set-Content -LiteralPath $requestFile -Encoding UTF8
    $ready=$false;foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{if((Call-Router @('ping')).ok){$ready=$true;break}}catch{}};Assert-True $ready 'router daemon did not become ready'

    $result=(Call-Router @('infer','--request-file',$requestFile)).data
    Assert-True (-not[bool]$result.ok) 'exhausted pool unexpectedly succeeded'
    Assert-True ([bool]$result.routeExhausted) 'failed pool was not marked exhausted'
    Assert-True (-not[bool]$result.routeDeferred) 'attempted/exhausted pool was mislabeled as never-dispatched'
    Assert-True ([int]$result.routeAttempts-eq2) "expected two endpoint attempts, got $($result.routeAttempts)"
    Assert-True (@($result.routeHistory).Count-eq2) 'route history did not preserve both failed endpoints'
    Assert-True (@($result.routeHistory|Select-Object -ExpandProperty endpoint -Unique).Count-eq2) 'router retried the same cooled endpoint instead of exhausting the pool'
    Assert-True ([string]$result.diagnosis.class-eq'rate_limited') 'last provider failure diagnosis was not preserved'
    Assert-True (-not[string]::IsNullOrWhiteSpace([string]$result.nextRetryAt)) 'exhausted result did not preserve health retry projection'
    $retry=[datetimeoffset]::Parse([string]$result.nextRetryAt);Assert-True ($retry-gt[datetimeoffset]::UtcNow) 'retry projection is not in the future'
    $snapshot=(Call-Router @('snapshot')).data;Assert-True ([int]$snapshot.activeLeases-eq0) 'exhaustion leaked a lease'
    Write-Host 'PASS: exhausted pool returns one clean failure with route history and projected retry time.'
}finally{
    $env:SC_ROUTER_ROOT=$oldRoot
    if($daemon-and-not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    if($server-and-not$server.HasExited){Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

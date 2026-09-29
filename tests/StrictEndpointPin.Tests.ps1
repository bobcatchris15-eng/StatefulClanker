<# Explicit endpoint pinning is a human override and must never transparently migrate. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$router=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "STRICT ENDPOINT PIN TEST FAILED: $Message"}}
function Call-Router([string[]]$CallArgs){$raw=& $router @CallArgs;$obj=$raw|ConvertFrom-Json;if($LASTEXITCODE-ne0-or-not[bool]$obj.ok){throw "router call failed: $raw"};return $obj}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-strict-pin-'+[guid]::NewGuid().ToString('N'))
$oldRoot=$env:SC_ROUTER_ROOT;$port=37000+(Get-Random -Minimum 0 -Maximum 2000);$server=$null;$daemon=$null
try{
    New-Item -ItemType Directory -Force -Path $temp|Out-Null;$env:SC_ROUTER_ROOT=$temp
    [ordered]@{schemaVersion=2;connections=[ordered]@{
        pinned=[ordered]@{name='pinned';presetId='mock';protocol='openai-chat';baseUrl="http://127.0.0.1:$port/a/v1";modelsPath='/models';authKind='none';headers=[ordered]@{}}
        spare=[ordered]@{name='spare';presetId='mock';protocol='openai-chat';baseUrl="http://127.0.0.1:$port/b/v1";modelsPath='/models';authKind='none';headers=[ordered]@{}}
    }}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'connections.json') -Encoding UTF8
    [ordered]@{schemaVersion=3;entries=[ordered]@{
        'pinned::model'=[ordered]@{id='pinned::model';connection='pinned';model='pinned-model';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='text';weight=1}
        'spare::model'=[ordered]@{id='spare::model';connection='spare';model='spare-model';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='text';weight=100}
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
   elseif($first-match' /a/v1/chat/completions '){$status='429 Too Many Requests';$body='{"error":{"message":"pinned route limited"}}'}
   else{$status='200 OK';$body='{"model":"spare-model","choices":[{"message":{"role":"assistant","content":"SHOULD_NOT_MIGRATE"}}]}'}
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
    [ordered]@{messages=@([ordered]@{role='user';content='reply'});tools=@();toolMode='text';maxOutputTokens=16;timeoutSeconds=10;maxRouteAttempts=4;maxRouteWaitSeconds=0}|ConvertTo-Json -Depth 20 -Compress|Set-Content -LiteralPath $requestFile -Encoding UTF8
    $ready=$false;foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{if((Call-Router @('ping')).ok){$ready=$true;break}}catch{}};Assert-True $ready 'router daemon did not become ready'

    $result=(Call-Router @('infer','--request-file',$requestFile,'--preferred','pool:pinned::model','--strict-preferred','true')).data
    Assert-True (-not[bool]$result.ok) 'strict pinned route unexpectedly returned success'
    Assert-True ([int]$result.routeAttempts-eq1) "strict pin attempted $($result.routeAttempts) routes instead of one"
    Assert-True ([string]$result.endpoint-eq'pool:pinned::model') 'failure did not come from the pinned endpoint'
    Assert-True ([string]$result.diagnosis.class-eq'rate_limited') 'pinned endpoint failure was not preserved'
    Assert-True (-not[bool]$result.routeExhausted) 'strict pin was incorrectly represented as pool exhaustion'
    Assert-True (-not[string]::IsNullOrWhiteSpace([string]$result.nextRetryAt)) 'strict pin did not return projected retry time'
    Write-Host 'PASS: explicit endpoint pin remains pinned; router does not silently migrate human override.'
}finally{
    $env:SC_ROUTER_ROOT=$oldRoot
    if($daemon-and-not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    if($server-and-not$server.HasExited){Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

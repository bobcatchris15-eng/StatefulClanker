<# Request-scoped incompatibility must fail over without poisoning global health. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$router=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "REQUEST-SCOPED FAILOVER TEST FAILED: $Message"}}
function Call-Router([string[]]$CallArgs){$raw=& $router @CallArgs;$obj=$raw|ConvertFrom-Json;if($LASTEXITCODE-ne0-or-not[bool]$obj.ok){throw "router call failed: $raw"};return $obj}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-request-failover-'+[guid]::NewGuid().ToString('N'))
$oldRoot=$env:SC_ROUTER_ROOT
$port=34000+(Get-Random -Minimum 0 -Maximum 3000)
$server=$null;$daemon=$null
try{
    New-Item -ItemType Directory -Force -Path $temp|Out-Null;$env:SC_ROUTER_ROOT=$temp
    [ordered]@{schemaVersion=2;connections=[ordered]@{
        small=[ordered]@{name='small';presetId='mock';protocol='openai-chat';baseUrl="http://127.0.0.1:$port/a/v1";modelsPath='/models';authKind='none';headers=[ordered]@{}}
        large=[ordered]@{name='large';presetId='mock';protocol='openai-chat';baseUrl="http://127.0.0.1:$port/b/v1";modelsPath='/models';authKind='none';headers=[ordered]@{}}
    }}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'connections.json') -Encoding UTF8
    [ordered]@{schemaVersion=3;entries=[ordered]@{
        'small::model'=[ordered]@{id='small::model';connection='small';model='small-model';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='text';weight=100}
        'large::model'=[ordered]@{id='large::model';connection='large';model='large-model';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='text';weight=1}
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
   elseif($first-match' /a/v1/chat/completions '){$status='413 Payload Too Large';$body='{"error":{"message":"maximum context length exceeded; prompt too long"}}'}
   else{$status='200 OK';$body='{"model":"large-model","choices":[{"message":{"role":"assistant","content":"LARGE_OK"}}]}'}
   $bytes=[Text.Encoding]::UTF8.GetBytes($body);$crlf=[string][char]13+[char]10
   $head=[Text.Encoding]::ASCII.GetBytes('HTTP/1.1 '+$status+$crlf+'Content-Type: application/json'+$crlf+'Content-Length: '+$bytes.Length+$crlf+'Connection: close'+$crlf+$crlf)
   $stream.Write($head,0,$head.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
  }finally{$stream.Dispose();$client.Close()}
 }
}finally{$listener.Stop()}
'@|Set-Content -LiteralPath $serverScript -Encoding UTF8
    $server=Start-Process -FilePath $PSHOME\pwsh.exe -ArgumentList '-NoProfile','-File',$serverScript,'-Port',("$port") -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 500;$daemon=Start-Process -FilePath $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden
    $requestFile=Join-Path $temp 'request.json'
    [ordered]@{messages=@([ordered]@{role='user';content='large prompt'});tools=@();toolMode='text';maxOutputTokens=16;timeoutSeconds=10;maxRouteAttempts=4;maxRouteWaitSeconds=0}|ConvertTo-Json -Depth 20 -Compress|Set-Content -LiteralPath $requestFile -Encoding UTF8
    $ready=$false;foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{if((Call-Router @('ping')).ok){$ready=$true;break}}catch{}};Assert-True $ready 'router daemon did not become ready'

    $result=(Call-Router @('infer','--request-file',$requestFile)).data
    Assert-True ([bool]$result.ok) 'request-scoped incompatibility did not fail over'
    Assert-True ([string]$result.assistant.content-eq'LARGE_OK') 'fallback response was wrong'
    Assert-True ([int]$result.routeAttempts-eq2) 'expected exactly two inference attempts'
    Assert-True ([string]$result.routeHistory[0].failureClass-eq'context_too_large') 'first failure was not context_too_large'
    Assert-True ([string]$result.routeHistory[1].outcome-eq'success') 'second endpoint did not succeed'
    $snapshot=(Call-Router @('snapshot')).data
    $small=@($snapshot.routes|Where-Object{$_.connection-eq'small'})[0]
    Assert-True ([bool]$small.available) 'request-scoped context failure poisoned small endpoint globally'
    Write-Host 'PASS: request-scoped incompatibility moved to another endpoint without changing global health.'
}finally{
    $env:SC_ROUTER_ROOT=$oldRoot
    if($daemon-and-not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    if($server-and-not$server.HasExited){Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

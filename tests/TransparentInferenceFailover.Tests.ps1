<# One inference request must transparently survive a failed endpoint. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$router=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "TRANSPARENT FAILOVER TEST FAILED: $Message"}}
function Call-Router([string[]]$Args){
    $raw=& $router @Args
    $obj=$raw|ConvertFrom-Json
    if($LASTEXITCODE-ne0-or-not[bool]$obj.ok){throw "router call failed: $raw"}
    return $obj
}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-transparent-failover-'+[guid]::NewGuid().ToString('N'))
$oldRoot=$env:SC_ROUTER_ROOT
$port=25000+(Get-Random -Minimum 0 -Maximum 5000)
$server=$null;$daemon=$null
try{
    New-Item -ItemType Directory -Force -Path $temp|Out-Null
    $env:SC_ROUTER_ROOT=$temp

    [ordered]@{schemaVersion=2;connections=[ordered]@{
        broken=[ordered]@{name='broken';presetId='mock';protocol='openai-chat';baseUrl="http://127.0.0.1:$port/a/v1";modelsPath='/models';authKind='none';headers=[ordered]@{}}
        good=[ordered]@{name='good';presetId='mock';protocol='openai-chat';baseUrl="http://127.0.0.1:$port/b/v1";modelsPath='/models';authKind='none';headers=[ordered]@{}}
    }}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'connections.json') -Encoding UTF8

    [ordered]@{schemaVersion=3;entries=[ordered]@{
        'broken::model'=[ordered]@{id='broken::model';connection='broken';model='mock-model';displayName='Broken';enabled=$true;workhorse=$true;free=$true;supportsTools=$true;toolMode='text';weight=100}
        'good::model'=[ordered]@{id='good::model';connection='good';model='mock-model';displayName='Good';enabled=$true;workhorse=$true;free=$true;supportsTools=$true;toolMode='text';weight=1}
    }}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'endpoints.json') -Encoding UTF8

    $serverScript=Join-Path $temp 'server.ps1'
    @'
param([int]$Port)
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port);$listener.Start()
try{
  while($true){
    $client=$listener.AcceptTcpClient();$stream=$client.GetStream()
    try{
      $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,4096,$true)
      $first=$reader.ReadLine();$headers=@{};$length=0
      while($true){$line=$reader.ReadLine();if($null-eq$line-or$line-eq''){break};$i=$line.IndexOf(':');if($i-gt0){$headers[$line.Substring(0,$i).Trim()]=$line.Substring($i+1).Trim()}}
      if($headers.ContainsKey('Content-Length')){$length=[int]$headers['Content-Length']}
      if($length-gt0){$buf=New-Object char[] $length;[void]$reader.ReadBlock($buf,0,$length)}
      if($first-match'^GET '){$status='200 OK';$body='{"data":[{"id":"mock-model"}]}'}
      elseif($first-match' /a/v1/chat/completions '){$status='429 Too Many Requests';$body='{"error":{"message":"rate limit"}}'}
      else{$status='200 OK';$body='{"model":"mock-model","usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5},"choices":[{"message":{"role":"assistant","content":"ROUTED_OK"}}]}'}
      $bytes=[Text.Encoding]::UTF8.GetBytes($body);$crlf=[string][char]13+[char]10
      $extra=if($status-like'429*'){'Retry-After: 60'+$crlf}else{''}
      $headText='HTTP/1.1 '+$status+$crlf+'Content-Type: application/json'+$crlf+$extra+'Content-Length: '+$bytes.Length+$crlf+'Connection: close'+$crlf+$crlf
      $head=[Text.Encoding]::ASCII.GetBytes($headText)
      $stream.Write($head,0,$head.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
    }finally{$stream.Dispose();$client.Close()}
  }
}finally{$listener.Stop()}
'@|Set-Content -LiteralPath $serverScript -Encoding UTF8
    $server=Start-Process -FilePath $PSHOME\pwsh.exe -ArgumentList '-NoProfile','-File',$serverScript,'-Port',("$port") -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 500
    $daemon=Start-Process -FilePath $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden

    $requestFile=Join-Path $temp 'request.json'
    [ordered]@{
        messages=@([ordered]@{role='user';content='reply'})
        tools=@()
        toolMode='text'
        maxOutputTokens=32
        timeoutSeconds=10
        maxRouteAttempts=4
        maxRouteWaitSeconds=0
        sessionKey='transparent-test'
    }|ConvertTo-Json -Depth 20 -Compress|Set-Content -LiteralPath $requestFile -Encoding UTF8

    $ready=$false
    foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{if((Call-Router @('ping')).ok){$ready=$true;break}}catch{}}
    Assert-True $ready 'router daemon did not become ready'

    $result=(Call-Router @('infer','--request-file',$requestFile,'--owner-pid',[string]$PID)).data
    if(-not[bool]$result.ok){Write-Host ('FAILOVER_DIAGNOSTIC='+($result|ConvertTo-Json -Depth 20 -Compress))}
    Assert-True ([bool]$result.ok) 'single inference request did not survive endpoint failure'
    Assert-True ([string]$result.assistant.content-eq'ROUTED_OK') 'successful fallback response was not returned'
    Assert-True ([int]$result.routeAttempts-eq2) "expected 2 internal route attempts, got $($result.routeAttempts)"
    Assert-True ([string]$result.routeHistory[0].failureClass-eq'rate_limited') 'first route failure was not classified as rate_limited'
    Assert-True ([string]$result.routeHistory[1].outcome-eq'success') 'second route did not succeed'
    Assert-True ([string]$result.connection-eq'good') 'final result did not come from fallback connection'

    $snapshot=(Call-Router @('snapshot')).data
    $broken=@($snapshot.routes|Where-Object{$_.connection-eq'broken'})[0]
    $good=@($snapshot.routes|Where-Object{$_.connection-eq'good'})[0]
    Assert-True (-not[bool]$broken.available) '429 endpoint was not cooled down'
    Assert-True ([bool]$good.available) 'healthy fallback endpoint was poisoned'
    Assert-True ([int]$snapshot.activeLeases-eq0) 'transparent failover leaked a lease'
    Write-Host 'PASS: one endpoint-agnostic inference request transparently failed over from 429 to a healthy endpoint.'
}finally{
    $env:SC_ROUTER_ROOT=$oldRoot
    if($daemon-and-not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    if($server-and-not$server.HasExited){Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

<# A single inference call waits through a short provider cooldown and resumes internally. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$router=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ROUTER WAIT RECOVERY TEST FAILED: $Message"}}
function Call-Router([string[]]$CallArgs){
    $raw=& $router @CallArgs
    $obj=$raw|ConvertFrom-Json
    if($LASTEXITCODE-ne0-or-not[bool]$obj.ok){throw "router call failed: $raw"}
    return $obj
}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-router-wait-'+[guid]::NewGuid().ToString('N'))
$oldRoot=$env:SC_ROUTER_ROOT
$port=30000+(Get-Random -Minimum 0 -Maximum 4000)
$server=$null;$daemon=$null
try{
    New-Item -ItemType Directory -Force -Path $temp|Out-Null
    $env:SC_ROUTER_ROOT=$temp
    [ordered]@{schemaVersion=2;connections=[ordered]@{
        only=[ordered]@{name='only';presetId='mock';protocol='openai-chat';baseUrl="http://127.0.0.1:$port/v1";modelsPath='/models';authKind='none';headers=[ordered]@{}}
    }}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'connections.json') -Encoding UTF8
    [ordered]@{schemaVersion=3;entries=[ordered]@{
        'only::model'=[ordered]@{id='only::model';connection='only';model='mock-model';displayName='Only';enabled=$true;workhorse=$true;free=$true;supportsTools=$true;toolMode='text';weight=1}
    }}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'endpoints.json') -Encoding UTF8

    $serverScript=Join-Path $temp 'server.ps1'
    @'
param([int]$Port)
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port);$listener.Start();$posts=0
try{
  while($true){
    $client=$listener.AcceptTcpClient();$stream=$client.GetStream()
    try{
      $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,4096,$true)
      $first=$reader.ReadLine();$headers=@{};$length=0
      while($true){$line=$reader.ReadLine();if($null-eq$line-or$line-eq''){break};$i=$line.IndexOf(':');if($i-gt0){$headers[$line.Substring(0,$i).Trim()]=$line.Substring($i+1).Trim()}}
      if($headers.ContainsKey('Content-Length')){$length=[int]$headers['Content-Length']}
      if($length-gt0){$buf=New-Object char[] $length;[void]$reader.ReadBlock($buf,0,$length)}
      if($first-match'^GET '){$status='200 OK';$body='{"data":[{"id":"mock-model"}]}';$extra=''}
      else{
        $posts++
        if($posts-eq1){$status='429 Too Many Requests';$body='{"error":{"message":"brief rate limit"}}';$extra='Retry-After: 1'}
        else{$status='200 OK';$body='{"model":"mock-model","choices":[{"message":{"role":"assistant","content":"RECOVERED"}}]}';$extra=''}
      }
      $bytes=[Text.Encoding]::UTF8.GetBytes($body);$crlf=[string][char]13+[char]10
      $headText='HTTP/1.1 '+$status+$crlf+'Content-Type: application/json'+$crlf
      if($extra){$headText+=$extra+$crlf}
      $headText+='Content-Length: '+$bytes.Length+$crlf+'Connection: close'+$crlf+$crlf
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
        maxOutputTokens=16
        timeoutSeconds=10
        maxRouteAttempts=2
        maxRouteWaitSeconds=3
    }|ConvertTo-Json -Depth 20 -Compress|Set-Content -LiteralPath $requestFile -Encoding UTF8

    $ready=$false
    foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{if((Call-Router @('ping')).ok){$ready=$true;break}}catch{}}
    Assert-True $ready 'router daemon did not become ready'

    $sw=[Diagnostics.Stopwatch]::StartNew()
    $result=(Call-Router @('infer','--request-file',$requestFile,'--owner-pid',[string]$PID)).data
    $sw.Stop()

    Assert-True ([bool]$result.ok) 'inference did not recover after short cooldown'
    Assert-True ([string]$result.assistant.content-eq'RECOVERED') 'recovered response was not returned'
    Assert-True ([int]$result.routeAttempts-eq2) 'router did not record failed then recovered inference attempts'
    Assert-True ($sw.Elapsed.TotalMilliseconds-ge700) 'router did not actually wait through provider cooldown'
    Assert-True ($sw.Elapsed.TotalSeconds-lt3.5) 'router waited beyond the configured bounded recovery window'
    Assert-True ([string]$result.routeHistory[0].failureClass-eq'rate_limited') 'first attempt was not rate-limited'
    Assert-True ([string]$result.routeHistory[1].outcome-eq'success') 'second inference attempt did not recover'

    $snapshot=(Call-Router @('snapshot')).data
    Assert-True ([int]$snapshot.activeLeases-eq0) 'recovery leaked a route lease'
    Assert-True ([bool]$snapshot.routes[0].available) 'success did not heal the only endpoint'
    Write-Host 'PASS: one inference call waited through Retry-After and recovered without exposing routing failure.'
}finally{
    $env:SC_ROUTER_ROOT=$oldRoot
    if($daemon-and-not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    if($server-and-not$server.HasExited){Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

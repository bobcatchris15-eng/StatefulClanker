<# Full-stack proof: worker -> negotiate -> router infer -> transparent failover -> worker result. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$router=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ROUTED WORKER INFERENCE TEST FAILED: $Message"}}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-routed-worker-'+[guid]::NewGuid().ToString('N'))
$project=Join-Path $temp 'project';$local=Join-Path $temp 'local';$machine=Join-Path $local 'StatefulClanker'
$oldLocal=$env:LOCALAPPDATA;$oldRouterRoot=$env:SC_ROUTER_ROOT;$oldRouterExe=$env:STATEFULCLANKER_ROUTER_EXE
$server=$null;$daemon=$null;$port=24000+(Get-Random -Minimum 0 -Maximum 5000)
try{
    New-Item -ItemType Directory -Force -Path $project,$machine|Out-Null
    $env:LOCALAPPDATA=$local;$env:SC_ROUTER_ROOT=$machine;$env:STATEFULCLANKER_ROUTER_EXE=$router

    [ordered]@{schemaVersion=2;connections=[ordered]@{
        broken=[ordered]@{name='broken';presetId='mock';protocol='openai-chat';baseUrl="http://127.0.0.1:$port/a/v1";modelsPath='/models';authKind='none';headers=[ordered]@{}}
        good=[ordered]@{name='good';presetId='mock';protocol='openai-chat';baseUrl="http://127.0.0.1:$port/b/v1";modelsPath='/models';authKind='none';headers=[ordered]@{}}
    }}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $machine 'connections.json') -Encoding UTF8
    [ordered]@{schemaVersion=3;entries=[ordered]@{
        'broken::model'=[ordered]@{id='broken::model';connection='broken';model='broken-model';enabled=$true;workhorse=$true;free=$true;supportsTools=$true;toolMode='text';weight=100}
        'good::model'=[ordered]@{id='good::model';connection='good';model='good-model';enabled=$true;workhorse=$true;free=$true;supportsTools=$true;toolMode='text';weight=1}
    }}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $machine 'endpoints.json') -Encoding UTF8

    $serverScript=Join-Path $temp 'mock-server.ps1'
    @'
param([int]$Port)
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port);$listener.Start();$goodPosts=0
try{
 while($true){
  $client=$listener.AcceptTcpClient();$stream=$client.GetStream()
  try{
   $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,4096,$true)
   $first=$reader.ReadLine();$headers=@{};$length=0
   while($true){$line=$reader.ReadLine();if($null-eq$line-or$line-eq''){break};$i=$line.IndexOf(':');if($i-gt0){$headers[$line.Substring(0,$i).Trim()]=$line.Substring($i+1).Trim()}}
   if($headers.ContainsKey('Content-Length')){$length=[int]$headers['Content-Length']}
   if($length-gt0){$buf=New-Object char[] $length;[void]$reader.ReadBlock($buf,0,$length)}
   if($first-match'^GET '){$status='200 OK';$body='{"data":[]}'}
   elseif($first-match' /a/v1/chat/completions '){$status='429 Too Many Requests';$body='{"error":{"message":"rate limit"}}'}
   else{
    $status='200 OK';$goodPosts++
    $content=if($goodPosts-eq1){'{"tool":"write_file","arguments":{"path":"router-worker.txt","content":"through transparent router"}}'}else{'{"final":"done"}'}
    $body=([ordered]@{model='good-model';usage=[ordered]@{prompt_tokens=10;completion_tokens=4;total_tokens=14};choices=@([ordered]@{message=[ordered]@{role='assistant';content=$content}})}|ConvertTo-Json -Depth 10 -Compress)
   }
   $bytes=[Text.Encoding]::UTF8.GetBytes($body);$crlf=[string][char]13+[char]10
   $extra=if($status-like'429*'){'Retry-After: 60'+$crlf}else{''}
   $head=[Text.Encoding]::ASCII.GetBytes('HTTP/1.1 '+$status+$crlf+'Content-Type: application/json'+$crlf+$extra+'Content-Length: '+$bytes.Length+$crlf+'Connection: close'+$crlf+$crlf)
   $stream.Write($head,0,$head.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
  }finally{$stream.Dispose();$client.Close()}
 }
}finally{$listener.Stop()}
'@|Set-Content -LiteralPath $serverScript -Encoding UTF8
    $server=Start-Process -FilePath $PSHOME\pwsh.exe -ArgumentList '-NoProfile','-File',$serverScript,'-Port',("$port") -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 600
    $daemon=Start-Process -FilePath $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden

    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.RouterClient.ps1')
    function Invoke-SCProvider { throw 'CLI provider should not run in this test.' }
    . (Join-Path $repo 'lib\StatefulClanker.WorkerPolicy.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.Windows.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.CompiledRouting.ps1')

    Set-SCRoots $project $project
    New-Item -ItemType Directory -Force -Path (Join-Path $project '.statefulclanker')|Out-Null
    Write-SCJson (Get-SCPath 'state.json') ([ordered]@{schemaVersion=4;projectId='routed-worker'})
    Write-SCJson (Get-SCPath 'config.json') ([ordered]@{maxSteps=8;routing=[ordered]@{maxRouteAttempts=6;maxRouteWaitSeconds=2}})
    function Invoke-SCLegacyApiChat { throw 'LEGACY_API_PATH_USED' }

    $ready=$false
    foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{$pong=Invoke-SCCompiledRouterCommand @('ping');if($pong.ok){$ready=$true;break}}catch{}}
    Assert-True $ready 'router daemon did not become ready'

    $task=[pscustomobject]@{id='routed-task';title='routed task';role='worker';size='tiny'}
    $receipt=Invoke-SCProviderViaCompiledRouter $task 'write the requested file' 'worker'

    Assert-True ([int]$receipt.exitCode-eq0) "worker did not finish through router: $($receipt.stderr)"
    Assert-True ([string]$receipt.stdout-eq'done') 'worker final response was wrong'
    Assert-True ([string]$receipt.endpoint-eq'pool:good::model') 'receipt did not record actual successful endpoint'
    Assert-True ([string]$receipt.connection-eq'good') 'receipt did not record actual successful connection'
    Assert-True ([int]$receipt.routeAttempts-eq3) "expected 3 total model attempts across two worker turns, got $($receipt.routeAttempts)"
    Assert-True (@($receipt.routeHistory).Count-eq3) 'aggregated route history did not preserve all worker-turn attempts'
    Assert-True (@($receipt.routeHistory|Where-Object{$_.failureClass-eq'rate_limited'}).Count-eq1) 'hidden 429 failover was not retained in telemetry'

    $out=Join-Path $project 'router-worker.txt'
    Assert-True (Test-Path -LiteralPath $out) 'worker tool result was not applied'
    Assert-True ((Get-Content -Raw -LiteralPath $out)-eq'through transparent router') 'worker output content was wrong'

    $snapshot=(Invoke-SCCompiledRouterCommand @('snapshot')).data
    Assert-True ([int]$snapshot.activeLeases-eq0) 'full worker run leaked router leases'
    $broken=@($snapshot.routes|Where-Object{$_.connection-eq'broken'})[0]
    Assert-True (-not[bool]$broken.available) 'failed endpoint was not cooled after hidden failover'

    $signals=(Get-ChildItem -LiteralPath (Join-Path $machine 'routing\signals') -Filter '*.jsonl'|Get-Content)-join [Environment]::NewLine
    Assert-True ($signals-match'"kind":"inference_failed"') 'failed inference signal missing'
    Assert-True ($signals-match'"kind":"inference_succeeded"') 'successful inference signal missing'
    Write-Host 'PASS: full worker path negotiates once and completes across router-internal failover without legacy HTTP.'
}finally{
    $env:LOCALAPPDATA=$oldLocal;$env:SC_ROUTER_ROOT=$oldRouterRoot;$env:STATEFULCLANKER_ROUTER_EXE=$oldRouterExe
    if($daemon-and-not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    if($server-and-not$server.HasExited){Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

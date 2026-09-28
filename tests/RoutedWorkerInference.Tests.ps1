<# Proves normal worker turns traverse ClankerRouter instead of the legacy PowerShell HTTP serializer. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$router=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ROUTED WORKER INFERENCE TEST FAILED: $Message"}}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-routed-worker-'+[guid]::NewGuid().ToString('N'))
$project=Join-Path $temp 'project';$local=Join-Path $temp 'local';$machine=Join-Path $local 'StatefulClanker'
$oldLocal=$env:LOCALAPPDATA;$oldRouterRoot=$env:SC_ROUTER_ROOT;$oldRouterExe=$env:STATEFULCLANKER_ROUTER_EXE
$server=$null;$daemon=$null;$port=24000+(Get-Random -Minimum 0 -Maximum 6000)
try{
    New-Item -ItemType Directory -Force -Path $project,$machine|Out-Null
    $env:LOCALAPPDATA=$local;$env:SC_ROUTER_ROOT=$machine;$env:STATEFULCLANKER_ROUTER_EXE=$router
    [ordered]@{schemaVersion=2;connections=[ordered]@{mock=[ordered]@{name='mock';presetId='ollama';protocol='openai-chat';baseUrl="http://127.0.0.1:$port/v1";modelsPath='/models';authKind='none';headers=[ordered]@{}}}}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $machine 'connections.json') -Encoding UTF8
    [ordered]@{schemaVersion=3;entries=[ordered]@{'mock::mock-model'=[ordered]@{id='mock::mock-model';connection='mock';model='mock-model';displayName='Mock';enabled=$true;workhorse=$true;free=$true;supportsTools=$true;toolMode='text';weight=1}}}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $machine 'endpoints.json') -Encoding UTF8

    $serverScript=Join-Path $temp 'mock-server.ps1'
    @'
param([int]$Port)
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
$listener.Start();$post=0
try{
  while($true){
    $client=$listener.AcceptTcpClient();$stream=$client.GetStream()
    try{
      $header=New-Object Collections.Generic.List[byte];$match=0;$term=@(13,10,13,10)
      while($match-lt4){$b=$stream.ReadByte();if($b-lt0){break};$header.Add([byte]$b);if($b-eq$term[$match]){$match++}elseif($b-eq13){$match=1}else{$match=0}}
      $raw=[Text.Encoding]::ASCII.GetString($header.ToArray());$first=($raw-split [Environment]::NewLine)[0];$len=0
      foreach($line in($raw-split [Environment]::NewLine)){if($line-match'(?i)^Content-Length:\s*(\d+)'){$len=[int]$Matches[1]}}
      if($len-gt0){$buf=New-Object byte[] $len;$read=0;while($read-lt$len){$n=$stream.Read($buf,$read,$len-$read);if($n-le0){break};$read+=$n}}
      if($first-match'^GET\s'){$body='{"data":[{"id":"mock-model"}]}'}
      else{
        $post++
        $content=if($post-eq1){'{"tool":"write_file","arguments":{"path":"router-worker.txt","content":"through router"}}'}else{'{"final":"done"}'}
        $body=([ordered]@{model='mock-model';usage=[ordered]@{prompt_tokens=10;completion_tokens=4;total_tokens=14};choices=@([ordered]@{message=[ordered]@{role='assistant';content=$content}})}|ConvertTo-Json -Depth 10 -Compress)
      }
      $bytes=[Text.Encoding]::UTF8.GetBytes($body);$crlf=[Environment]::NewLine
      $headText='HTTP/1.1 200 OK'+$crlf+'Content-Type: application/json'+$crlf+'Content-Length: '+$bytes.Length+$crlf+'Connection: close'+$crlf+$crlf
      $head=[Text.Encoding]::ASCII.GetBytes($headText)
      $stream.Write($head,0,$head.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
    }finally{$stream.Dispose();$client.Close()}
  }
}finally{$listener.Stop()}
'@|Set-Content -LiteralPath $serverScript -Encoding UTF8
    $serverOut=Join-Path $temp 'mock-server.stdout.txt';$serverErr=Join-Path $temp 'mock-server.stderr.txt'
    $server=Start-Process -FilePath $PSHOME\pwsh.exe -ArgumentList '-NoProfile','-File',$serverScript,'-Port',("$port") -PassThru -WindowStyle Hidden -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
    Start-Sleep -Milliseconds 800
    if($server.HasExited){
        $detail=if(Test-Path $serverErr){Get-Content -Raw $serverErr}else{'no stderr'}
        throw "Mock inference server exited during startup: $detail"
    }
    $daemon=Start-Process -FilePath $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden

    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.RouterClient.ps1')
    function Invoke-SCProvider { throw 'CLI provider should not run in this test.' }
    . (Join-Path $repo 'lib\StatefulClanker.WorkerPolicy.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.Windows.ps1')

    Set-SCRoots $project $project
    New-Item -ItemType Directory -Force -Path (Join-Path $project '.statefulclanker')|Out-Null
    Write-SCJson (Get-SCPath 'state.json') ([ordered]@{schemaVersion=4;projectId='routed-worker'})
    Write-SCJson (Get-SCPath 'config.json') ([ordered]@{maxSteps=8})
    function Invoke-SCLegacyApiChat { throw 'LEGACY_API_PATH_USED' }

    $provider=[pscustomobject]@{name='pool:mock::mock-model';config=[pscustomobject]@{type='api';connection='mock';model='mock-model';toolMode='text'}}
    $connection=Get-SCEffectiveApiConnection $provider
    $task=[pscustomobject]@{id='routed-task';role='worker';size='tiny'}
    $usage=@{fallbackModel='mock-model';apiRequests=0L;usageReports=0L;promptTokens=0L;completionTokens=0L;totalTokens=0L;modelUsage=@{}}

    $ready=$false
    foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{$pong=Invoke-SCCompiledRouterCommand @('ping');if($pong.ok){$ready=$true;break}}catch{}}
    Assert-True $ready 'router daemon did not become ready'
    $result=Invoke-SCDirectWorkerLoop $connection 'write the requested file' $task 'worker' $usage $null $null $provider $null
    Assert-True ($result-eq'done') "worker did not finish through router: $result"
    $out=Join-Path $project 'router-worker.txt'
    Assert-True (Test-Path -LiteralPath $out) 'worker tool result was not applied'
    Assert-True ((Get-Content -Raw -LiteralPath $out)-eq'through router') 'worker output content was wrong'
    Assert-True ($usage.apiRequests-eq2) 'normalized router usage did not flow back to worker accounting'
    $signals=(Get-ChildItem -LiteralPath (Join-Path $machine 'routing\signals') -Filter '*.jsonl'|Get-Content)-join [Environment]::NewLine
    Assert-True (@($signals -split [Environment]::NewLine|Where-Object{$_-match'"kind":"inference_succeeded"'}).Count-ge2) 'production inference signals were not emitted'
    Write-Host 'PASS: normal worker inference traverses ClankerRouter; legacy HTTP serializer was not touched.'
}finally{
    $env:LOCALAPPDATA=$oldLocal;$env:SC_ROUTER_ROOT=$oldRouterRoot;$env:STATEFULCLANKER_ROUTER_EXE=$oldRouterExe
    if($daemon-and-not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    if($server-and-not$server.HasExited){Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

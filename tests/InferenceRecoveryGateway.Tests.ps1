<# One inference request must transparently survive a failed endpoint. #>
param([ValidateSet('embedded','context','output','exhausted','invalid','strict','contextcap','diagnostic','truncated','nocode','timeout')][string]$Case='embedded',[string]$RouterPath)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$router=if($RouterPath){$RouterPath}else{Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'}
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "INFERENCE RECOVERY TEST FAILED: $Message"}}
function Call-Router([string[]]$CallArgs){
    $raw=& $router @CallArgs
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

    if($Case -eq 'contextcap'){$catalog=Get-Content -Raw (Join-Path $temp 'endpoints.json')|ConvertFrom-Json;$catalog.entries.'broken::model'|Add-Member contextLength 4100;$catalog|ConvertTo-Json -Depth 20|Set-Content (Join-Path $temp 'endpoints.json')}
    $serverScript=Join-Path $temp 'server.ps1'
    @'
param([int]$Port,[string]$Case)
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port);$listener.Start()
try{
  while($true){
    $client=$listener.AcceptTcpClient();$stream=$client.GetStream()
    try{
      $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,4096,$true)
      $first=$reader.ReadLine();$headers=@{};$length=0
      while($true){$line=$reader.ReadLine();if($null-eq$line-or$line-eq''){break};$i=$line.IndexOf(':');if($i-gt0){$headers[$line.Substring(0,$i).Trim()]=$line.Substring($i+1).Trim()}}
      if($headers.ContainsKey('Content-Length')){$length=[int]$headers['Content-Length']}
      $requestBody=$null;if($length-gt0){$buf=New-Object char[] $length;[void]$reader.ReadBlock($buf,0,$length);$requestBody=(-join $buf)|ConvertFrom-Json}
      if($first-match'^GET '){$status='200 OK';$body='{"data":[{"id":"mock-model"}]}'}
      elseif($first-match' /a/v1/chat/completions '){if($Case -eq 'timeout'){Start-Sleep -Seconds 8};if($Case -in @('output','exhausted','contextcap','diagnostic','truncated','timeout')){$status='200 OK';if($Case -eq 'exhausted' -or $requestBody.max_tokens -lt 8192){$body='{"usage":{"prompt_tokens":3,"completion_tokens":4096},"choices": [{"finish_reason":"length","message":{"content":null,"reasoning":"private analysis"}}]}';if($Case -eq 'truncated'){$body=@{usage=@{prompt_tokens=3;completion_tokens=4096};choices=@(@{finish_reason='length';message=@{tool_calls=@(@{id='bad';function=@{name='write';arguments='{"path":'}})}})}|ConvertTo-Json -Depth 10 -Compress }}else{$body='{"usage":{"prompt_tokens":3,"completion_tokens":2},"choices": [{"message":{"content":"ROUTED_OK"}}]}'} }elseif($Case -in @('embedded','nocode')){$status='200 OK';$body='{"error":{"message":"JSON error injected into SSE stream","code":502}}';if($Case -eq 'nocode'){$body='{"error":{"message":"bad gateway"}}'}}else{$status='400 Bad Request';$body='{"error":{"message":"maximum context length is 262144 tokens, requested 423601","code":400}}'}}
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
    $server=Start-Process -FilePath $PSHOME\pwsh.exe -ArgumentList '-NoProfile','-File',$serverScript,'-Port',("$port"),'-Case',$Case -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 500
    $daemon=Start-Process -FilePath $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden

    $requestFile=Join-Path $temp 'request.json'
    [ordered]@{
        messages=@([ordered]@{role='user';content='reply'})
        tools=@()
        toolMode='text'
        maxOutputTokens=4096
        timeoutSeconds=10
        maxRouteAttempts=4
        maxRouteWaitSeconds=0
        sessionKey='recovery-test'
    }|ConvertTo-Json -Depth 20 -Compress|Set-Content -LiteralPath $requestFile -Encoding UTF8

    $ready=$false
    foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{if((Call-Router @('ping')).ok){$ready=$true;break}}catch{}}
    Assert-True $ready 'router daemon did not become ready'

    if($Case -eq 'invalid'){
        $q=Get-Content -Raw $requestFile|ConvertFrom-Json
        $q.messages+=@{role='assistant';tool_calls=@(@{id='x';type='function';function=@{name='write';arguments='{"path":'}})}
        $q|ConvertTo-Json -Depth 20|Set-Content $requestFile
    }
    $callArgs=@('infer','--request-file',$requestFile,'--owner-pid',[string]$PID,'--preferred','pool:broken::model')
    if($Case -in @('strict','timeout')){$callArgs+=@('--strict-preferred','true')}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    if($Case -eq 'diagnostic'){$callArgs=@('test-endpoint','--endpoint','pool:broken::model')}
    $result=(Call-Router $callArgs).data
    if($Case -eq 'invalid'){
        Assert-True (-not $result.ok -and $result.diagnosis.reasonCode -eq 'INVALID_TOOL_ARGUMENTS') 'corrupt transcript not rejected locally'
        Assert-True ($null -eq $result.response.httpStatus) 'corrupt transcript reached provider'
        Assert-True (-not [string]::IsNullOrWhiteSpace($result.signalRef)) 'local corruption diagnosis not signalled'
    }elseif($Case -in @('contextcap','diagnostic')){
        Assert-True (-not $result.ok -and $result.diagnosis.reasonCode -eq 'OUTPUT_BUDGET_EXHAUSTED') 'output cap/diagnostic diagnosis wrong'
        if($Case -eq 'contextcap'){Assert-True ($result.inferenceAttempts.Count -eq 2 -and $result.inferenceAttempts[1].maxOutputTokens -eq 4097) 'known context cap ignored'}
    }elseif($Case -eq 'timeout'){
        Assert-True (-not $result.ok -and $result.diagnosis.reasonCode -eq 'TRANSPORT_TIMEOUT') 'shared timeout misdiagnosed'
        Assert-True ($clock.Elapsed.TotalSeconds -lt 18 -and $result.inferenceAttempts.Count -eq 2) 'retry reset timeout budget'
        Assert-True ($result.usage.completionTokens -eq 4096) 'timeout discarded earlier attempt usage'
    }elseif($Case -eq 'strict'){
        Assert-True (-not $result.ok -and $result.connection -eq 'broken' -and $result.routeAttempts -eq 1) 'strict pin switched provider'
        Assert-True ($result.diagnosis.reasonCode -eq 'CONTEXT_CAPACITY_EXCEEDED') 'strict context diagnosis wrong'
    }elseif($Case -eq 'exhausted'){
        Assert-True (-not $result.ok -and $result.diagnosis.reasonCode -eq 'OUTPUT_BUDGET_EXHAUSTED') 'bounded exhaustion diagnosis wrong'
        Assert-True ($result.usage.completionTokens -eq 12288) 'three output attempts usage missing'
        Assert-True ($result.inferenceAttempts.Count -eq 3) 'retry count not bounded to three'
    }else{
        Assert-True ([bool]$result.ok) 'single inference request did not survive endpoint failure'
        Assert-True ($result.assistant.content -eq 'ROUTED_OK') 'successful response not returned'
        if($Case -in @('output','truncated')){
            Assert-True ($result.connection -eq 'broken') 'output retry changed provider'
            Assert-True ($result.usage.completionTokens -eq 4098) 'retry usage lost'
            Assert-True ($result.inferenceAttempts.Count -eq 2) 'expected two HTTP attempts'
            Assert-True ($result.inferenceAttempts[1].maxOutputTokens -eq 8192) 'retry budget did not double'
            Assert-True ((Get-Content -Raw $requestFile|ConvertFrom-Json).maxOutputTokens -eq 4096) 'caller request mutated'
        }else{
            Assert-True ($result.routeAttempts -eq 2 -and $result.connection -eq 'good') 'fallback did not select second route'
            Assert-True ($result.routeHistory[0].failureClass -eq $(if($Case -in @('embedded','nocode')){'server_error'}else{'context_too_large'})) 'failure class wrong'
            $snapshot=(Call-Router @('snapshot')).data
            $broken=@($snapshot.routes|Where-Object connection -eq 'broken')[0]
            Assert-True ([bool]$broken.available -eq ($Case -eq 'context')) 'provider health scope wrong'
        }
    }
    Assert-True ((Call-Router @('snapshot')).data.activeLeases -eq 0) 'lease leaked'
    Write-Host "PASS: inference recovery $Case"}finally{
    $env:SC_ROUTER_ROOT=$oldRoot
    if($daemon-and-not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    if($server-and-not$server.HasExited){Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

<# One inference request must transparently survive a failed endpoint. #>
param([ValidateSet('embedded','context','output','exhausted','invalid','strict','contextcap','diagnostic','truncated','nocode','timeout','permission','malformed','malformed-recovered','malformed-strict','malformed-mixed','malformed-limit')][string]$Case='embedded',[string]$RouterPath)
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
        'good::model'=[ordered]@{id='good::model';connection=$(if($Case -eq 'permission'){'broken'}else{'good'});model='sibling-model';displayName='Good';enabled=$true;workhorse=$true;free=$true;supportsTools=$true;toolMode='text';weight=1}
    }}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'endpoints.json') -Encoding UTF8

    if($Case -eq 'contextcap'){$catalog=Get-Content -Raw (Join-Path $temp 'endpoints.json')|ConvertFrom-Json;$catalog.entries.'broken::model'|Add-Member contextLength 4100;$catalog|ConvertTo-Json -Depth 20|Set-Content (Join-Path $temp 'endpoints.json')}
    $serverScript=Join-Path $temp 'server.ps1'
    @'
param([int]$Port,[string]$Case)
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port);$listener.Start()
$badAttempts=0
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
      elseif($Case -like 'malformed*' -and $first-match' /a/v1/chat/completions '){
        $badAttempts++;$status='200 OK'
        $body=if($Case -eq 'malformed-recovered' -and $badAttempts -gt 1){'{"usage":{"prompt_tokens":3,"completion_tokens":2},"choices":[{"message":{"content":"ROUTED_OK"}}]}'}else{'{"usage":{"prompt_tokens":3,"completion_tokens":4},"choices":[{"finish_reason":"error","message":{"tool_calls":[{"id":"bad","function":{"name":"write_file","arguments":"{\"path\":"}}]}}]}'}
        if($Case -eq 'malformed-mixed' -and $badAttempts -eq 1){$body='{"usage":{"prompt_tokens":3,"completion_tokens":4096},"choices":[{"finish_reason":"length","message":{"content":null,"reasoning":"analysis"}}]}'}
      }
      elseif($Case -eq 'permission' -and $requestBody.model -eq 'mock-model'){$status='403 Forbidden';$body='{"error":{"message":"thinkingmachines/inkling:free is only available on agentic harnesses. Try plugging it into a coding agent or productivity app listed on https://openrouter.ai/apps","code":403,"metadata":{"failed_routing_step":"Gate Free Endpoints by Agentic Harness"}}}'}
      elseif($first-match' /a/v1/chat/completions ' -and $Case -ne 'permission'){if($Case -eq 'timeout'){Start-Sleep -Seconds 8};if($Case -in @('output','exhausted','contextcap','diagnostic','truncated','timeout')){$status='200 OK';if($Case -eq 'exhausted' -or $requestBody.max_tokens -lt 8192){$body='{"usage":{"prompt_tokens":3,"completion_tokens":4096},"choices": [{"finish_reason":"length","message":{"content":null,"reasoning":"private analysis"}}]}';if($Case -eq 'truncated'){$body=@{usage=@{prompt_tokens=3;completion_tokens=4096};choices=@(@{finish_reason='length';message=@{tool_calls=@(@{id='bad';function=@{name='write';arguments='{"path":'}})}})}|ConvertTo-Json -Depth 10 -Compress }}else{$body='{"usage":{"prompt_tokens":3,"completion_tokens":2},"choices": [{"message":{"content":"ROUTED_OK"}}]}'} }elseif($Case -in @('embedded','nocode')){$status='200 OK';$body='{"error":{"message":"JSON error injected into SSE stream","code":502}}';if($Case -eq 'nocode'){$body='{"error":{"message":"bad gateway"}}'}}else{$status='400 Bad Request';$body='{"error":{"message":"maximum context length is 262144 tokens, requested 423601","code":400}}'}}
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

    if($Case -like 'malformed*'){
        $catalog=Get-Content -Raw (Join-Path $temp 'endpoints.json')|ConvertFrom-Json
        foreach($entry in $catalog.entries.PSObject.Properties.Value){$entry.toolMode='native'}
        $catalog|ConvertTo-Json -Depth 20|Set-Content (Join-Path $temp 'endpoints.json')
        $q=Get-Content -Raw $requestFile|ConvertFrom-Json;$q.toolMode='native'
        $q.tools=@(@{type='function';function=@{name='write_file';description='write';parameters=@{type='object';properties=@{path=@{type='string'};content=@{type='string'}};required=@('path','content')}}})
        $q.messages=@(@{role='assistant';tool_calls=@(@{id='prior';type='function';function=@{name='write_file';arguments='{"path":"old","content":"ok"}'}})},@{role='tool';tool_call_id='prior';content='written'},@{role='user';content='write another file'})
        if($Case -eq 'malformed-limit'){$q.maxRouteAttempts=1}
        $q|ConvertTo-Json -Depth 20|Set-Content $requestFile
    }

    $ready=$false
    foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{if((Call-Router @('ping')).ok){$ready=$true;break}}catch{}}
    Assert-True $ready 'router daemon did not become ready'

    if($Case -eq 'invalid'){
        $q=Get-Content -Raw $requestFile|ConvertFrom-Json
        $q.messages+=@{role='assistant';tool_calls=@(@{id='x';type='function';function=@{name='write';arguments='{"path":'}})}
        $q|ConvertTo-Json -Depth 20|Set-Content $requestFile
    }
    $callArgs=@('infer','--request-file',$requestFile,'--owner-pid',[string]$PID,'--preferred','pool:broken::model')
    if($Case -in @('strict','timeout','malformed-strict')){$callArgs+=@('--strict-preferred','true')}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    if($Case -eq 'diagnostic'){$callArgs=@('test-endpoint','--endpoint','pool:broken::model')}
    $result=(Call-Router $callArgs).data
    if($Case -like 'malformed*'){
        Assert-True ($result.inferenceAttempts.Count -eq $(if($Case -eq 'malformed'){3}elseif($Case -eq 'malformed-mixed'){4}else{2})) 'malformed output retry/failover count wrong'
        $firstToolFailure=if($Case -eq 'malformed-mixed'){1}else{0}
        Assert-True ($result.inferenceAttempts[$firstToolFailure].diagnosis.reasonCode -eq 'INVALID_TOOL_ARGUMENTS' -and $result.inferenceAttempts[$firstToolFailure].diagnosis.class -eq 'provider_tool_output_invalid' -and $result.inferenceAttempts[$firstToolFailure].diagnosis.scope -eq 'endpoint') 'provider output conflated with input corruption'
        if($Case -in @('malformed-strict','malformed-limit')){Assert-True (-not $result.ok -and $result.routeAttempts -eq 1) 'strict pin or attempt limit escaped'}
        else{Assert-True ($result.ok -and $result.assistant.content -eq 'ROUTED_OK') 'malformed output failed to recover'}
        if($Case -eq 'malformed-mixed'){
            Assert-True ($result.routeAttempts -eq 2 -and $result.usage.completionTokens -eq 4106) 'mixed recovery lost usage or failed to bound endpoint attempts'
            Assert-True ($result.inferenceAttempts[1].maxOutputTokens -eq 8192 -and $result.inferenceAttempts[2].maxOutputTokens -eq 8192) 'tool retry changed output budget'
        }
        if($Case -eq 'malformed-limit'){Assert-True ($result.routeExhausted) 'route limit not reported exhausted'}
        if($Case -eq 'malformed'){Assert-True ($result.connection -eq 'good' -and $result.routeAttempts -eq 2 -and $result.usage.completionTokens -eq 10) 'malformed failover lost routing or usage'}
        if($Case -eq 'malformed-recovered'){Assert-True ($result.connection -eq 'broken' -and $result.usage.completionTokens -eq 6) 'one retry did not recover same endpoint'}
        $health=Get-Content -Raw (Join-Path $temp 'routing\health.json')|ConvertFrom-Json
        $quality=$health.endpoints.'pool:broken::model'
        Assert-True ($quality.toolOutputFailures -eq $(if($Case -eq 'malformed-recovered'){1}else{2})) 'endpoint quality count missing'
        Assert-True ($quality.consecutiveToolOutputFailures -eq $(if($Case -eq 'malformed-recovered'){0}else{2})) 'quality streak did not recover correctly'
        Assert-True ($quality.state -eq $(if($Case -eq 'malformed-recovered'){'healthy'}else{'cooldown'})) 'quality cooldown state wrong'
        $routeQuality=@((Call-Router @('snapshot')).data.routes|Where-Object catalogId -eq 'broken::model')[0].quality
        Assert-True ($routeQuality.toolOutputFailures -eq $quality.toolOutputFailures -and $routeQuality.consecutiveToolOutputFailures -eq $quality.consecutiveToolOutputFailures) 'snapshot hides endpoint quality history'
        Assert-True ($null -eq $health.endpoints.'connection:broken' -or $health.endpoints.'connection:broken'.state -eq 'healthy') 'quality failure poisoned connection'
    }elseif($Case -eq 'invalid'){
        Assert-True (-not $result.ok -and $result.diagnosis.reasonCode -eq 'CORRUPT_INPUT_TOOL_CALL') 'corrupt transcript not rejected locally'
        Assert-True ($null -eq $result.response.httpStatus) 'corrupt transcript reached provider'
        Assert-True ($result.routeAttempts -eq 0 -and $result.inferenceAttempts.Count -eq 0) 'corrupt input acquired or attempted an endpoint'
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
            Assert-True ($result.routeAttempts -eq 2 -and $result.connection -eq $(if($Case -eq 'permission'){'broken'}else{'good'})) 'fallback did not select second route'
            Assert-True ($result.routeHistory[0].failureClass -eq $(if($Case -eq 'permission'){'permission'}elseif($Case -in @('embedded','nocode')){'server_error'}else{'context_too_large'})) 'failure class wrong'
            $snapshot=(Call-Router @('snapshot')).data
            $broken=@($snapshot.routes|Where-Object catalogId -eq 'broken::model')[0]
            if($Case -eq 'permission'){
                Assert-True ($result.inferenceAttempts[0].diagnosis.scope -eq 'endpoint' -and $result.inferenceAttempts[0].diagnosis.reasonCode -eq 'MODEL_ACCESS_RESTRICTED') 'model permission diagnosis incorrectly claims credential failure'
                $health=Get-Content -Raw (Join-Path $temp 'routing\health.json')|ConvertFrom-Json
                Assert-True ($health.endpoints.'pool:broken::model'.state -eq 'cooldown') 'model permission must have bounded cooldown'
                Assert-True ($null -eq $health.endpoints.'connection:broken' -or $health.endpoints.'connection:broken'.state -eq 'healthy') 'model permission poisoned connection'
                Assert-True ([bool]@($snapshot.routes|Where-Object catalogId -eq 'good::model')[0].available) 'sibling model unavailable'
                $signals=Get-ChildItem -LiteralPath $temp -Recurse -Filter '*.jsonl'|ForEach-Object{Get-Content -LiteralPath $_.FullName|ForEach-Object{$_|ConvertFrom-Json}}
                $failure=@($signals|Where-Object {$_.kind -eq 'health_failure_observed'})
                Assert-True (@($failure|Where-Object {$_.payload.healthKey -eq 'pool:broken::model'}).Count -gt 0) 'failure signal lacks endpoint health key'
            }
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

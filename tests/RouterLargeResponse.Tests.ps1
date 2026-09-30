<# Complete HTTP inference bodies must survive normalization; diagnostics remain bounded. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$router=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "LARGE RESPONSE TEST FAILED: $Message"}}
function Call-Router([string[]]$CallArgs){
    $raw=& $router @CallArgs
    $code=$LASTEXITCODE
    $obj=$raw|ConvertFrom-Json
    if($code -ne 0 -or -not [bool]$obj.ok){throw "router call failed: $raw"}
    return $obj
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-router-large-'+[guid]::NewGuid().ToString('N'))
$oldRoot=$env:SC_ROUTER_ROOT
$server=$null;$daemon=$null
try{
    New-Item -ItemType Directory -Path $temp|Out-Null
    $env:SC_ROUTER_ROOT=$temp
    $responseFile=Join-Path $temp 'response.json'
    $portFile=Join-Path $temp 'port.txt'
    $server=Start-Job -ArgumentList $responseFile,$portFile -ScriptBlock {
        param($ResponseFile,$PortFile)
        $ErrorActionPreference='Stop'
        $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
        $listener.Start()
        [IO.File]::WriteAllText($PortFile,[string]$listener.LocalEndpoint.Port)
        try{
            while($true){
                $client=$listener.AcceptTcpClient();$stream=$client.GetStream()
                try{
                    $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,4096,$true)
                    $first=$reader.ReadLine();$length=0
                    while($true){
                        $line=$reader.ReadLine()
                        if($null -eq $line -or $line -eq ''){break}
                        if($line -match '^Content-Length:\s*(\d+)'){$length=[int]$Matches[1]}
                    }
                    if($length -gt 0){$buf=New-Object char[] $length;[void]$reader.ReadBlock($buf,0,$length)}
                    if($first -match '^GET '){$body='{"data":[{"id":"mock-model"}]}'}
                    elseif($first -match '^POST /v1/chat/completions '){$body=[IO.File]::ReadAllText($ResponseFile)}
                    else{throw "Unexpected fixture request: $first"}
                    $bytes=[Text.Encoding]::UTF8.GetBytes($body)
                    $head=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
                    $stream.Write($head,0,$head.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
                    if($first -match '^GET /stop '){break}
                }finally{$stream.Dispose();$client.Close()}
            }
        }finally{$listener.Stop()}
    }
    foreach($i in 1..50){if(Test-Path -LiteralPath $portFile){break};Start-Sleep -Milliseconds 100}
    Assert-True (Test-Path -LiteralPath $portFile) 'HTTP fixture did not start'
    $port=[IO.File]::ReadAllText($portFile)
    @{schemaVersion=2;connections=@{local=@{name='local';presetId='mock';protocol='openai-chat';baseUrl="http://127.0.0.1:$port/v1";authKind='none';headers=@{}}}}|ConvertTo-Json -Depth 20|Set-Content (Join-Path $temp 'connections.json')
    @{schemaVersion=3;entries=@{'local::model'=@{id='local::model';connection='local';model='mock-model';enabled=$true;workhorse=$true;supportsTools=$true;toolMode='native';weight=1}}}|ConvertTo-Json -Depth 20|Set-Content (Join-Path $temp 'endpoints.json')
    $requestFile=Join-Path $temp 'request.json'
    @{messages=@(@{role='user';content='reply'});tools=@(@{type='function';function=@{name='write';parameters=@{type='object';properties=@{text=@{type='string'}}}}});toolMode='native';timeoutSeconds=10;maxRouteAttempts=1;maxRouteWaitSeconds=0}|ConvertTo-Json -Depth 20|Set-Content $requestFile
    $daemon=Start-Process -FilePath $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden
    $ready=$false
    foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{[void](Call-Router @('ping'));$ready=$true;break}catch{}}
    Assert-True $ready 'router daemon did not become ready'
    $content=('x'*20000)+"`nUnicode: café 🛰 LARGE_CONTENT_END"
    $arguments=@{text=('y'*24000)+' LARGE_ARGUMENT_END'}|ConvertTo-Json -Compress
    $fixtures=@(
        @{name='content';body=(@{model='mock-model';choices=@(@{message=@{role='assistant';content=$content}})}|ConvertTo-Json -Depth 20 -Compress)},
        @{name='arguments';body=(@{model='mock-model';choices=@(@{message=@{role='assistant';content=$null;tool_calls=@(@{id='call_large';type='function';function=@{name='write';arguments=$arguments}})}})}|ConvertTo-Json -Depth 20 -Compress)},
        @{name='malformed';body='{"choices":['+('m'*20000)+'BROKEN_JSON_END'}
    )
    $failures=@()
    foreach($fixture in $fixtures){
        try{
            [IO.File]::WriteAllText($responseFile,$fixture.body)
            $result=(Call-Router @('infer','--request-file',$requestFile,'--owner-pid',[string]$PID)).data
            Assert-True ([int]$result.response.httpStatus -eq 200) "$($fixture.name): did not reach HTTP success parsing"
            Assert-True ($result.response.bodyExcerpt.Length -eq 4096) "$($fixture.name): large response diagnostic excerpt was not bounded to 4096 characters"
            if($fixture.name -eq 'content'){
                Assert-True ([bool]$result.ok) "content: gateway rejected valid large JSON ($($result.diagnosis.class)/$($result.diagnosis.reasonCode))"
                Assert-True ([string]$result.assistant.content -ceq $content) 'content: complete content including trailing marker was not preserved'
            }elseif($fixture.name -eq 'arguments'){
                Assert-True ([bool]$result.ok) "arguments: gateway rejected valid large JSON ($($result.diagnosis.class)/$($result.diagnosis.reasonCode))"
                $actual=[string]$result.assistant.tool_calls[0].function.arguments
                Assert-True ($actual -ceq $arguments) 'arguments: full normalized argument string was not preserved'
                Assert-True ((($actual|ConvertFrom-Json).text) -ceq (('y'*24000)+' LARGE_ARGUMENT_END')) 'arguments: JSON payload or trailing marker was lost'
            }else{
                Assert-True (-not [bool]$result.ok) 'malformed: invalid JSON unexpectedly succeeded'
                Assert-True ($result.diagnosis.class -eq 'malformed_response' -and $result.diagnosis.scope -eq 'request') 'malformed: wrong diagnosis or scope'
                Assert-True (-not $result.healthChanged -and -not $result.diagnosis.providerHealthSuspect -and -not $result.failoverAllowed) 'malformed: failure changed provider health or allowed failover'
                $snapshot=(Call-Router @('snapshot')).data
                Assert-True ([bool]@($snapshot.routes|Where-Object endpoint -eq 'pool:local::model')[0].available) 'malformed: endpoint was quarantined'
                Assert-True ([int]$snapshot.activeLeases -eq 0) 'malformed: lease was not released'
            }
            Write-Host "PASS: $($fixture.name)"
        }catch{$failures+= $_.Exception.Message;Write-Host "FAIL: $($_.Exception.Message)"}
    }
    Assert-True ($failures.Count -eq 0) ($failures -join '; ')
}finally{
    if($daemon -and -not $daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue;$daemon.WaitForExit()}
    if($server){
        if($server.State -eq 'Running' -and (Test-Path -LiteralPath $portFile)){
            $stopClient=[Net.Sockets.TcpClient]::new()
            try{
                $stopClient.Connect([Net.IPAddress]::Loopback,[int][IO.File]::ReadAllText($portFile))
                $stopBytes=[Text.Encoding]::ASCII.GetBytes("GET /stop HTTP/1.1`r`nHost: localhost`r`n`r`n")
                $stopClient.GetStream().Write($stopBytes,0,$stopBytes.Length)
                [void](Wait-Job $server -Timeout 5)
            }finally{$stopClient.Dispose()}
        }
        Remove-Job $server -Force
    }
    $env:SC_ROUTER_ROOT=$oldRoot
    # Only remove the absolute temporary directory created by this test.
    if($temp.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
}

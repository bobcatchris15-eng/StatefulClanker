<# Real endpoint diagnostics through the compiled router production adapter path. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$router=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ENDPOINT DIAGNOSTIC TEST FAILED: $Message"}}
function Call-Router([string[]]$CallArgs) {
    $raw=& $router @CallArgs
    $obj=$raw|ConvertFrom-Json
    if($LASTEXITCODE-ne0-or-not[bool]$obj.ok){throw ("Router call failed ({0}): {1}"-f($CallArgs-join' '),$raw)}
    return $obj
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-endpoint-test-'+[guid]::NewGuid().ToString('N'))
$oldRoot=$env:SC_ROUTER_ROOT
$port=23000+(Get-Random -Minimum 0 -Maximum 8000)
$job=$null;$daemon=$null
try {
    New-Item -ItemType Directory -Force -Path $temp|Out-Null
    $env:SC_ROUTER_ROOT=$temp
    [ordered]@{schemaVersion=2;entries=[ordered]@{'mock::model'=[ordered]@{id='mock::model';connection='mock';model='mock-model';displayName='Mock';enabled=$true;workhorse=$true;free=$true;supportsTools=$true;toolMode='native'}}}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'endpoints.json') -Encoding UTF8
    [ordered]@{schemaVersion=2;connections=[ordered]@{mock=[ordered]@{name='mock';presetId='ollama';protocol='openai-chat';baseUrl="http://127.0.0.1:$port/v1";modelsPath='/models';authKind='none';headers=[ordered]@{}}}}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'connections.json') -Encoding UTF8
    $job=Start-Job -ArgumentList $port -ScriptBlock {
        param($Port)
        $listener=New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback),$Port;$listener.Start()
        $postCount=0
        try {
            while($true){
                $client=$listener.AcceptTcpClient();$stream=$client.GetStream()
                try {
                    $header=New-Object Collections.Generic.List[byte];$match=0;$term=@(13,10,13,10)
                    while($match-lt4){$b=$stream.ReadByte();if($b-lt0){break};$header.Add([byte]$b);if($b-eq$term[$match]){$match++}elseif($b-eq13){$match=1}else{$match=0}}
                    $text=[Text.Encoding]::ASCII.GetString($header.ToArray());$len=0
                    $firstLine=($text-split [Environment]::NewLine)[0]
                    foreach($line in ($text-split [Environment]::NewLine)){if($line-match'(?i)^Content-Length:\s*(\d+)'){$len=[int]$Matches[1]}}
                    if($len-gt0){$buf=New-Object byte[] $len;$read=0;while($read-lt$len){$n=$stream.Read($buf,$read,$len-$read);if($n-le0){break};$read+=$n}}
                    if($firstLine-match'^GET\s+.+/models\s'){
                        $status='200 OK';$body='{"data":[{"id":"mock-model"}]}'
                    }else{
                        $postCount++
                        if($postCount-eq1){$status='200 OK';$body='{"choices":[{"message":{"role":"assistant","content":"CLANKER_OK"}}]}'}
                        else{$status='400 Bad Request';$body='{"error":{"message":"messages field has invalid shape"}}'}
                    }
                    $bytes=[Text.Encoding]::UTF8.GetBytes($body)
                    $crlf=[string][char]13+[char]10
                    $headText='HTTP/1.1 '+$status+$crlf+'Content-Type: application/json'+$crlf+'X-Request-Id: diag-'+[guid]::NewGuid().ToString('N')+$crlf+'Content-Length: '+$bytes.Length+$crlf+'Connection: close'+$crlf+$crlf
                    $head=[Text.Encoding]::ASCII.GetBytes($headText)
                    $stream.Write($head,0,$head.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
                }finally{$stream.Dispose();$client.Close()}
            }
        }finally{$listener.Stop()}
    }
    Start-Sleep -Milliseconds 300
    $daemon=Start-Process -FilePath $router -ArgumentList 'daemon' -PassThru -WindowStyle Hidden
    $ready=$false
    foreach($i in 1..30){Start-Sleep -Milliseconds 100;try{[void](Call-Router @('ping'));$ready=$true;break}catch{}}
    Assert-True $ready 'router daemon did not become ready'
    Write-Host '  ENDPOINT 1: successful diagnostic traverses the adapter and heals route'
    $ok=(Call-Router @('test-endpoint','--endpoint','mock::model')).data
    Assert-True ([bool]$ok.ok) 'valid inference was not reported successful'
    Assert-True ([string]$ok.adapterId-eq'openai-chat') 'wrong adapter selected'
    Assert-True ([string]$ok.request.method-eq'POST') 'diagnostic did not issue POST'
    Assert-True ([string]$ok.request.uri-like'*/v1/chat/completions') 'OpenAI adapter used wrong URI'
    Assert-True (@($ok.request.bodyShape.topLevelKeys)-contains'messages') 'sanitized body shape omitted messages'
    Assert-True ([bool]$ok.request.headersRedacted) 'diagnostic did not mark headers redacted'
    Assert-True ([string]$ok.diagnosis.reasonCode-eq'TEST_INFERENCE_SUCCEEDED') 'success diagnosis was wrong'
    Write-Host '  ENDPOINT 2: provider request rejection points at adapter, not provider health'
    $bad=(Call-Router @('test-endpoint','--endpoint','mock::model')).data
    Assert-True (-not[bool]$bad.ok) 'HTTP 400 was reported successful'
    Assert-True ([int]$bad.response.httpStatus-eq400) 'HTTP status was not preserved'
    Assert-True ([bool]$bad.diagnosis.adapterSuspect) 'request-shape rejection did not flag adapter'
    Assert-True (-not[bool]$bad.diagnosis.providerHealthSuspect) 'HTTP 400 incorrectly blamed provider health'
    Assert-True ([string]$bad.diagnosis.scope-eq'request') 'HTTP 400 was not request scoped'
    Assert-True ([string]$bad.diagnosis.reasonCode-eq'REQUEST_SHAPE_REJECTED') 'HTTP 400 reason code was wrong'
    Assert-True ([string]$bad.adapterSource-like'*OpenAiChatAdapter.cs') 'diagnostic did not expose repair source'
    $snapshot=(Call-Router @('snapshot')).data
    $route=@($snapshot.routes|Where-Object{[string]$_.endpoint-eq'pool:mock::model'})[0]
    Assert-True ([bool]$route.available) 'request-shape failure poisoned route health'
    $signalDir=Join-Path $temp 'routing\signals'
    $signalText=(Get-ChildItem -LiteralPath $signalDir -Filter '*.jsonl'|Get-Content)-join[Environment]::NewLine
    Assert-True ($signalText-match'endpoint_test_succeeded') 'successful endpoint-test signal missing'
    Assert-True ($signalText-match'endpoint_test_failed') 'failed endpoint-test signal missing'
    Assert-True ($signalText-match'"type":"orchestrator"') 'endpoint-test signal was not addressed to orchestrator'
    Write-Host 'PASS: endpoint diagnostics use real inference, return repair evidence, and preserve health scope.'
}finally{
    $env:SC_ROUTER_ROOT=$oldRoot
    if($daemon-and-not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    if($job){Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
<# A provider response taking over 500ms must complete without a diagnostic replay. #>
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
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-endpoint-delay-'+[guid]::NewGuid().ToString('N'))
$oldRoot=$env:SC_ROUTER_ROOT
$port=23000+(Get-Random -Minimum 0 -Maximum 8000)
$job=$null;$daemon=$null
try {
    New-Item -ItemType Directory -Force -Path $temp|Out-Null
    $env:SC_ROUTER_ROOT=$temp
    [ordered]@{schemaVersion=2;entries=[ordered]@{'mock::model'=[ordered]@{id='mock::model';connection='mock';model='mock-model';displayName='Mock';enabled=$true;workhorse=$true;free=$true;supportsTools=$true;toolMode='native'}}}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'endpoints.json') -Encoding UTF8
    [ordered]@{schemaVersion=2;connections=[ordered]@{mock=[ordered]@{name='mock';presetId='ollama';protocol='openai-chat';baseUrl="http://127.0.0.1:$port/v1";modelsPath='/models';authKind='none';headers=[ordered]@{}}}}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp 'connections.json') -Encoding UTF8
    $countFile=Join-Path $temp 'post-count.txt'
    $job=Start-Job -ArgumentList $port,$countFile -ScriptBlock {
        param($Port,$CountFile)
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
                    if($firstLine-match'^GET /stop '){$status='200 OK';$body='{}'}
                    elseif($firstLine-match'^GET\s+.+/models\s'){
                        $status='200 OK';$body='{"data":[{"id":"mock-model"}]}'
                    }else{
                        $postCount++
                        [IO.File]::WriteAllText($CountFile,[string]$postCount)
                        if($postCount -eq 1){Start-Sleep -Milliseconds 900}
                        if($postCount-eq1){$status='200 OK';$body='{"choices":[{"message":{"role":"assistant","content":"CLANKER_OK"}}]}'}
                        else{$status='400 Bad Request';$body='{"error":{"message":"messages field has invalid shape"}}'}
                    }
                    $bytes=[Text.Encoding]::UTF8.GetBytes($body)
                    $crlf=[string][char]13+[char]10
                    $headText='HTTP/1.1 '+$status+$crlf+'Content-Type: application/json'+$crlf+'X-Request-Id: diag-'+[guid]::NewGuid().ToString('N')+$crlf+'Content-Length: '+$bytes.Length+$crlf+'Connection: close'+$crlf+$crlf
                    $head=[Text.Encoding]::ASCII.GetBytes($headText)
                    $stream.Write($head,0,$head.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
                    if($firstLine-match'^GET /stop '){break}
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
    Assert-True ([bool]$ok.ok) 'delayed diagnostic was not reported successful'
    Assert-True ([IO.File]::ReadAllText($countFile) -eq '1') 'delayed diagnostic was replayed'
    Assert-True ([string]$ok.adapterId-eq'openai-chat') 'wrong adapter selected'
    Assert-True ([string]$ok.request.method-eq'POST') 'diagnostic did not issue POST'
    Assert-True ([string]$ok.request.uri-like'*/v1/chat/completions') 'OpenAI adapter used wrong URI'
    Assert-True (@($ok.request.bodyShape.topLevelKeys)-contains'messages') 'sanitized body shape omitted messages'
    Assert-True ([bool]$ok.request.headersRedacted) 'diagnostic did not mark headers redacted'
    Assert-True ([string]$ok.diagnosis.reasonCode-eq'TEST_INFERENCE_SUCCEEDED') 'success diagnosis was wrong'
    Write-Host 'PASS: a delayed HTTP diagnostic succeeds with exactly one provider request.'
}finally{
    $env:SC_ROUTER_ROOT=$oldRoot
    if($daemon-and-not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
    if($job -and $job.State -eq 'Running'){
        $stopClient=[Net.Sockets.TcpClient]::new()
        try {
            $stopClient.Connect('127.0.0.1',$port)
            $stopStream=$stopClient.GetStream()
            $stopBytes=[Text.Encoding]::ASCII.GetBytes("GET /stop HTTP/1.1`r`nHost: localhost`r`nConnection: close`r`n`r`n")
            $stopStream.Write($stopBytes,0,$stopBytes.Length)
            [void](Wait-Job $job -Timeout 5)
        } catch {} finally { $stopClient.Dispose() }
    }
    if($job){Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}



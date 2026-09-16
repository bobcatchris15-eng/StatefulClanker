<# Direct API worker harness tests. Uses a local mock OpenAI-compatible endpoint; no model, key, network, or URL ACL required. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "DIRECT API TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-api-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
$oldLocal=$env:LOCALAPPDATA;$env:LOCALAPPDATA=Join-Path $temp 'local';New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA|Out-Null
$port=22000+(Get-Random -Minimum 0 -Maximum 10000)
$job=Start-Job -ArgumentList $port -ScriptBlock {
    param($Port)
    $listener=New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback),$Port;$listener.Start()
    try {
        $responses=@(
            '{"model":"openrouter/mock-routed","usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120},"choices":[{"message":{"role":"assistant","content":"{\"tool\":\"write_file\",\"arguments\":{\"path\":\"api-worker.txt\",\"content\":\"hello from direct worker\"}}"}}]}',
            '{"model":"openrouter/mock-routed","usage":{"input_tokens":140,"output_tokens":10,"total_tokens":150},"choices":[{"message":{"role":"assistant","content":"{\"final\":\"done\"}"}}]}'
        )
        foreach($json in $responses){
            $client=$listener.AcceptTcpClient();$stream=$client.GetStream()
            try {
                $header=New-Object Collections.Generic.List[byte];$match=0;$term=@(13,10,13,10)
                while($match-lt4){$b=$stream.ReadByte();if($b-lt0){break};$header.Add([byte]$b);if($b-eq$term[$match]){$match++}elseif($b-eq13){$match=1}else{$match=0}}
                $text=[Text.Encoding]::ASCII.GetString($header.ToArray());$len=0
                foreach($line in ($text-split"`r`n")){if($line-match'(?i)^Content-Length:\s*(\d+)'){$len=[int]$Matches[1]}}
                if($len-gt0){$buf=New-Object byte[] $len;$read=0;while($read-lt$len){$n=$stream.Read($buf,$read,$len-$read);if($n-le0){break};$read+=$n}}
                $bytes=[Text.Encoding]::UTF8.GetBytes($json);$head=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n");$stream.Write($head,0,$head.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
            } finally {$stream.Dispose();$client.Close()}
        }
    } finally {$listener.Stop()}
}
try {
    Start-Sleep -Milliseconds 400
    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    Set-SCRoots $temp $temp
    . (Join-Path $repo 'lib\StatefulClanker.WorkerPolicy.ps1')
    function Invoke-SCProvider { throw 'CLI base should not be called in this unit test.' }
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.Windows.ps1')
    $connection=[pscustomobject]@{baseUrl="http://127.0.0.1:$port/v1";model='mock-model';toolMode='text';maxSteps=4;headers=[pscustomobject]@{}}
    $usage=@{fallbackModel='mock-model';apiRequests=0L;usageReports=0L;promptTokens=0L;completionTokens=0L;totalTokens=0L;modelUsage=@{}}
    $result=Invoke-SCDirectWorkerLoop $connection 'write the requested file' ([pscustomobject]@{id='mock';role='worker'}) 'worker' $usage
    Assert-True ($result -eq 'done') "Expected final output 'done', got '$result'."
    Assert-True ($usage.apiRequests -eq 2 -and $usage.usageReports -eq 2) 'Expected two API requests with reported usage.'
    Assert-True ($usage.promptTokens -eq 240 -and $usage.completionTokens -eq 30 -and $usage.totalTokens -eq 270) "Usage totals were wrong: $($usage|ConvertTo-Json -Depth 5 -Compress)"
    Assert-True ($usage.modelUsage.ContainsKey('openrouter/mock-routed') -and $usage.modelUsage['openrouter/mock-routed'].totalTokens -eq 270) 'Actual routed model usage was not accumulated.'
    $path=Join-Path $temp 'api-worker.txt';Assert-True (Test-Path -LiteralPath $path) 'write_file tool did not create the file.'
    Assert-True ((Get-Content -Raw -LiteralPath $path) -eq 'hello from direct worker') 'write_file content was wrong.'
    Write-Host 'PASS: direct API text-tool loop writes through the capability-filtered StatefulClanker harness.'
} finally {
    $env:LOCALAPPDATA=$oldLocal
    if($job){Wait-Job $job -Timeout 3|Out-Null;Remove-Job $job -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

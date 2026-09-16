<# Direct API worker harness tests. Uses a local mock OpenAI-compatible endpoint; no model, key, or network required. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "DIRECT API TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-api-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
$port=22000+(Get-Random -Minimum 0 -Maximum 10000);$prefix="http://127.0.0.1:$port/"
$job=Start-Job -ArgumentList $prefix -ScriptBlock {
    param($Prefix)
    $listener=New-Object Net.HttpListener;$listener.Prefixes.Add($Prefix);$listener.Start()
    try {
        $responses=@(
            '{"choices":[{"message":{"role":"assistant","content":"{\"tool\":\"write_file\",\"arguments\":{\"path\":\"api-worker.txt\",\"content\":\"hello from direct worker\"}}"}}]}',
            '{"choices":[{"message":{"role":"assistant","content":"{\"final\":\"done\"}"}}]}'
        )
        foreach($json in $responses){$ctx=$listener.GetContext();$reader=New-Object IO.StreamReader($ctx.Request.InputStream);[void]$reader.ReadToEnd();$reader.Dispose();$bytes=[Text.Encoding]::UTF8.GetBytes($json);$ctx.Response.StatusCode=200;$ctx.Response.ContentType='application/json';$ctx.Response.ContentLength64=$bytes.Length;$ctx.Response.OutputStream.Write($bytes,0,$bytes.Length);$ctx.Response.Close()}
    } finally {$listener.Stop();$listener.Close()}
}
try {
    Start-Sleep -Milliseconds 400
    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    function Invoke-SCProvider { throw 'CLI base should not be called in this unit test.' }
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.Windows.ps1')
    Set-SCRoots $temp $temp
    $connection=[pscustomobject]@{baseUrl="http://127.0.0.1:$port/v1";model='mock-model';toolMode='text';maxSteps=4;headers=[pscustomobject]@{}}
    $result=Invoke-SCDirectWorkerLoop $connection 'write the requested file'
    Assert-True ($result -eq 'done') "Expected final output 'done', got '$result'."
    $path=Join-Path $temp 'api-worker.txt';Assert-True (Test-Path -LiteralPath $path) 'write_file tool did not create the file.'
    Assert-True ((Get-Content -Raw -LiteralPath $path) -eq 'hello from direct worker') 'write_file content was wrong.'
    Write-Host 'PASS: direct API text-tool loop writes through the minimal StatefulClanker harness.'
} finally {
    if($job){Wait-Job $job -Timeout 3|Out-Null;Remove-Job $job -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

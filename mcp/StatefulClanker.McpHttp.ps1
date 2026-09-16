<# StatefulClanker MCP server, Streamable HTTP transport.

   Intended to be owned by the Windows tray application. It binds loopback only,
   requires a bearer token, and follows the app's machine-local active project when
   a tool call does not explicitly name another project.

   Deliberately built on TcpListener rather than System.Net.HttpListener so a normal
   per-user install does not need elevation or a netsh URL reservation.
#>
param(
    [string]$ProjectPath,
    [int]$Port = 7337,
    [string]$Token,
    [switch]$NoAuth
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'StatefulClanker.McpCore.ps1')
. (Join-Path $PSScriptRoot 'StatefulClanker.McpExtensions.ps1')

if ($ProjectPath -and (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
    Set-McpDefaultProject $ProjectPath
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    $Token = [Guid]::NewGuid().ToString('N')
}

$tokenDir = Join-Path $env:LOCALAPPDATA 'StatefulClanker'
if (-not (Test-Path -LiteralPath $tokenDir)) { New-Item -ItemType Directory -Force -Path $tokenDir | Out-Null }
$tokenPath = Join-Path $tokenDir 'mcp-http.json'

function Write-HttpResponse($Stream, [int]$Status, [string]$Body, [string]$ContentType = 'application/json') {
    $reason = switch ($Status) {
        200 { 'OK' } 202 { 'Accepted' } 400 { 'Bad Request' } 401 { 'Unauthorized' }
        404 { 'Not Found' } 405 { 'Method Not Allowed' } 413 { 'Payload Too Large' }
        default { 'Internal Server Error' }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $head = "HTTP/1.1 $Status $reason`r`n" +
            "Content-Type: $ContentType; charset=utf-8`r`n" +
            "Content-Length: $($bytes.Length)`r`n" +
            "Cache-Control: no-store`r`n" +
            "Connection: close`r`n`r`n"
    $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($headBytes, 0, $headBytes.Length)
    if ($bytes.Length -gt 0) { $Stream.Write($bytes, 0, $bytes.Length) }
    $Stream.Flush()
}

function Read-HttpRequest($Stream) {
    $headerBytes = New-Object Collections.Generic.List[byte]
    $matched = 0
    $terminator = @(13, 10, 13, 10)
    while ($matched -lt 4) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { return $null }
        $headerBytes.Add([byte]$b)
        if ($b -eq $terminator[$matched]) { $matched++ } elseif ($b -eq 13) { $matched = 1 } else { $matched = 0 }
        if ($headerBytes.Count -gt 65536) { return $null }
    }
    $headerText = [Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
    $lines = $headerText -split "`r`n"
    $parts = $lines[0] -split ' '
    if ($parts.Count -lt 2) { return $null }

    $headers = @{}
    foreach ($line in $lines[1..($lines.Count - 1)]) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $idx = $line.IndexOf(':')
        if ($idx -lt 1) { continue }
        $headers[$line.Substring(0, $idx).Trim().ToLowerInvariant()] = $line.Substring($idx + 1).Trim()
    }

    $length = 0
    if ($headers.ContainsKey('content-length')) { [void][int]::TryParse($headers['content-length'], [ref]$length) }
    if ($length -gt 8388608) { return @{ method = $parts[0]; path = $parts[1]; headers = $headers; body = $null; tooLarge = $true } }

    $body = ''
    if ($length -gt 0) {
        $buffer = New-Object byte[] $length
        $read = 0
        while ($read -lt $length) {
            $n = $Stream.Read($buffer, $read, $length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        $body = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    }
    return @{ method = $parts[0]; path = $parts[1]; headers = $headers; body = $body; tooLarge = $false }
}

function Test-McpAuth($Request) {
    if ($NoAuth) { return $true }
    if (-not $Request.headers.ContainsKey('authorization')) { return $false }
    $value = [string]$Request.headers['authorization']
    if (-not $value.StartsWith('Bearer ', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $presented = $value.Substring(7).Trim()
    if ($presented.Length -ne $Token.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $Token.Length; $i++) { $diff = $diff -bor ([int][char]$presented[$i] -bxor [int][char]$Token[$i]) }
    return ($diff -eq 0)
}

$listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, $Port)
$listener.Start()
$actualPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$url = "http://127.0.0.1:$actualPort/mcp"
$activeProject = if($script:McpDefaultProject){$script:McpDefaultProject}else{Get-McpResidentActiveProject}

@{ url = $url; token = $Token; project = $activeProject; pid = $PID; startedAt = (Get-Date).ToUniversalTime().ToString('o') } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tokenPath -Encoding UTF8

Write-Host "StatefulClanker MCP (HTTP) listening on $url"
if ($activeProject) { Write-Host "Active project: $activeProject" } else { Write-Host 'Active project: none (select one in the app or pass project per tool call)' }
if ($NoAuth) { Write-Host 'Auth: DISABLED (-NoAuth). Any local process can drive the selected project.' } else { Write-Host "Token: $Token" }
Write-Host "Details written to $tokenPath"

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $stream = $null
        try {
            $client.ReceiveTimeout = 30000
            $client.SendTimeout = 30000
            $stream = $client.GetStream()
            $request = Read-HttpRequest $stream
            if ($null -eq $request) { continue }
            $path = ([string]$request.path -split '\?')[0]

            if ($request.method -eq 'OPTIONS') { Write-HttpResponse $stream 200 ''; continue }
            if ($path -eq '/health') {
                Write-HttpResponse $stream 200 (@{ ok = $true; server = 'statefulclanker'; version = $script:McpVersion; activeProject = (Get-McpResidentActiveProject) } | ConvertTo-Json -Compress)
                continue
            }
            if ($path -ne '/mcp') { Write-HttpResponse $stream 404 (@{ error = 'Not found. The MCP endpoint is /mcp' } | ConvertTo-Json -Compress); continue }
            if (-not (Test-McpAuth $request)) { Write-HttpResponse $stream 401 (@{ error = 'Missing or invalid bearer token.' } | ConvertTo-Json -Compress); continue }
            if ($request.tooLarge) { Write-HttpResponse $stream 413 (@{ error = 'Request body too large.' } | ConvertTo-Json -Compress); continue }
            if ($request.method -ne 'POST') { Write-HttpResponse $stream 405 (@{ error = 'Use POST for JSON-RPC.' } | ConvertTo-Json -Compress); continue }

            $id = $null
            try {
                $rpc = $request.body | ConvertFrom-Json
                if ($rpc.PSObject.Properties['id']) { $id = $rpc.id }
                $response = Invoke-McpRpc $rpc
                if ($null -eq $response) { Write-HttpResponse $stream 202 '' }
                else { Write-HttpResponse $stream 200 ($response | ConvertTo-Json -Depth 30 -Compress) }
            } catch {
                $err = [ordered]@{ jsonrpc = '2.0'; id = $id; error = [ordered]@{ code = -32700; message = "Parse error: $($_.Exception.Message)" } }
                Write-HttpResponse $stream 400 ($err | ConvertTo-Json -Depth 10 -Compress)
            }
        } catch {
            Write-Warning "Connection error: $($_.Exception.Message)"
        } finally {
            if ($stream) { try { $stream.Dispose() } catch { } }
            try { $client.Close() } catch { }
        }
    }
} finally {
    $listener.Stop()
    Remove-Item -LiteralPath $tokenPath -Force -ErrorAction SilentlyContinue
}

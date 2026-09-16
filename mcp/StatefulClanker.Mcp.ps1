<# StatefulClanker MCP stdio transport.

   When the Windows app is running, this is a thin stdio bridge to its resident
   loopback MCP server. That gives stdio clients and Streamable-HTTP clients one
   orchestration authority and one active-project selection.

   If no resident server is available, it falls back to the in-process transport so
   CLI/headless use remains supported. #>
param([string]$ProjectPath)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'StatefulClanker.McpCore.ps1')
. (Join-Path $PSScriptRoot 'StatefulClanker.McpExtensions.ps1')

if ($ProjectPath -and (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
    Set-McpDefaultProject $ProjectPath
}

function Get-ResidentDetails {
    $detailsPath=Join-Path (Join-Path $env:LOCALAPPDATA 'StatefulClanker') 'mcp-http.json'
    if(-not(Test-Path -LiteralPath $detailsPath -PathType Leaf)){return $null}
    try{$details=Get-Content -Raw -LiteralPath $detailsPath|ConvertFrom-Json}catch{return $null}
    if(-not$details.url-or-not$details.pid){return $null}
    if(-not(Get-Process -Id ([int]$details.pid) -ErrorAction SilentlyContinue)){return $null}
    return $details
}

function Invoke-ResidentRpc($Details,[string]$JsonLine) {
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $client=New-Object Net.Http.HttpClient
    try {
        $request=New-Object Net.Http.HttpRequestMessage ([Net.Http.HttpMethod]::Post),([string]$Details.url)
        $request.Content=New-Object Net.Http.StringContent $JsonLine,[Text.Encoding]::UTF8,'application/json'
        $request.Headers.Accept.ParseAdd('application/json')
        if($Details.token){$request.Headers.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue 'Bearer',([string]$Details.token)}
        $response=$client.SendAsync($request).GetAwaiter().GetResult()
        if([int]$response.StatusCode-eq 202){return $null}
        $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if(-not$response.IsSuccessStatusCode){throw "Resident MCP returned HTTP $([int]$response.StatusCode): $body"}
        return $body
    } finally {$client.Dispose()}
}

while ($null -ne ($line = [Console]::In.ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $id = $null
    try {
        $request = $line | ConvertFrom-Json
        if ($request.PSObject.Properties['id']) { $id = $request.id }
        $resident=Get-ResidentDetails
        if($resident) {
            $body=Invoke-ResidentRpc $resident $line
            if(-not[string]::IsNullOrWhiteSpace([string]$body)){[Console]::Out.WriteLine($body);[Console]::Out.Flush()}
            continue
        }
        $response = Invoke-McpRpc $request
        if ($null -ne $response) {
            [Console]::Out.WriteLine(($response | ConvertTo-Json -Depth 30 -Compress));[Console]::Out.Flush()
        }
    } catch {
        if ($null -ne $id) {
            [Console]::Out.WriteLine(([ordered]@{ jsonrpc = '2.0'; id = $id; error = [ordered]@{ code = -32603; message = $_.Exception.Message } } | ConvertTo-Json -Depth 10 -Compress))
        } else {
            [Console]::Out.WriteLine(([ordered]@{ jsonrpc = '2.0'; id = $null; error = [ordered]@{ code = -32700; message = "Parse error: $($_.Exception.Message)" } } | ConvertTo-Json -Depth 10 -Compress))
        }
        [Console]::Out.Flush()
    }
}

<# StatefulClanker MCP server, stdio transport.

   Register this with any MCP client that launches a local command (Claude Desktop,
   Claude Code, Opencode, Antigravity). For clients that only accept a URL, use
   StatefulClanker.McpHttp.ps1 instead. Both share McpCore.ps1.

   -ProjectPath sets the default project. Every tool also takes an optional
   "project" argument, so one registered server can drive many projects. #>
param([string]$ProjectPath = (Get-Location).Path)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'StatefulClanker.McpCore.ps1')

if ($ProjectPath -and (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
    Set-McpDefaultProject $ProjectPath
}

while ($null -ne ($line = [Console]::In.ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $id = $null
    try {
        $request = $line | ConvertFrom-Json
        # Capture the id before dispatch so a failure can still echo it. Returning
        # id:null leaves a client that correlates by id waiting forever.
        if ($request.PSObject.Properties['id']) { $id = $request.id }
        $response = Invoke-McpRpc $request
        if ($null -ne $response) {
            ($response | ConvertTo-Json -Depth 30 -Compress)
        }
    } catch {
        if ($null -ne $id) {
            ([ordered]@{ jsonrpc = '2.0'; id = $id; error = [ordered]@{ code = -32603; message = $_.Exception.Message } } | ConvertTo-Json -Depth 10 -Compress)
        } else {
            # No id recoverable: the line was not valid JSON-RPC at all.
            ([ordered]@{ jsonrpc = '2.0'; id = $null; error = [ordered]@{ code = -32700; message = "Parse error: $($_.Exception.Message)" } } | ConvertTo-Json -Depth 10 -Compress)
        }
    }
}

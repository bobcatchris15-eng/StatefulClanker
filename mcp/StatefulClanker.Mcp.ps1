<# StatefulClanker MCP stdio transport.
   The stdio bridge follows the resident Windows host when present. Legacy requests
   stay byte-compatible; 2026-07-28 requests are forwarded with their required HTTP
   routing headers so the resident endpoint sees the same protocol era. #>
param([string]$ProjectPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

. (Join-Path $PSScriptRoot 'StatefulClanker.McpCore.ps1')
. (Join-Path $PSScriptRoot 'StatefulClanker.McpExtensions.ps1')
. (Join-Path $PSScriptRoot 'StatefulClanker.BackendInstructions.ps1')
. (Join-Path $PSScriptRoot 'StatefulClanker.McpWorkerPolicy.ps1')
. (Join-Path $PSScriptRoot 'StatefulClanker.McpProtocol.ps1')
. (Join-Path $PSScriptRoot 'StatefulClanker.SubscriptionPump.ps1')
if($ProjectPath-and(Test-Path -LiteralPath $ProjectPath -PathType Container)){Set-McpDefaultProject $ProjectPath}

function Get-ResidentDetails {
    $detailsPath=Join-Path (Join-Path $env:LOCALAPPDATA 'StatefulClanker') 'mcp-http.json';if(-not(Test-Path -LiteralPath $detailsPath -PathType Leaf)){return $null}
    try{$details=Get-Content -Raw -LiteralPath $detailsPath|ConvertFrom-Json}catch{return $null};if(-not$details.url-or-not$details.pid){return $null};if(-not(Get-Process -Id ([int]$details.pid) -ErrorAction SilentlyContinue)){return $null};return $details
}
function Get-ResidentMcpName($Rpc) {
    if(-not$Rpc.PSObject.Properties['params']-or$null-eq$Rpc.params){return $null};$method=[string]$Rpc.method
    if($method-eq'tools/call'-and$Rpc.params.PSObject.Properties['name']){return[string]$Rpc.params.name};if($method-eq'resources/read'-and$Rpc.params.PSObject.Properties['uri']){return[string]$Rpc.params.uri};return $null
}
function Invoke-ResidentRpc($Details,$Rpc,[string]$JsonLine) {
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue;$client=New-Object Net.Http.HttpClient
    try{
        $request=New-Object Net.Http.HttpRequestMessage ([Net.Http.HttpMethod]::Post),([string]$Details.url);$request.Content=New-Object Net.Http.StringContent $JsonLine,[Text.Encoding]::UTF8,'application/json';$request.Headers.Accept.ParseAdd('application/json, text/event-stream')
        if($Details.token){$request.Headers.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue 'Bearer',([string]$Details.token)}
        if(Test-SCModernMcpRequest $Rpc){$request.Headers.TryAddWithoutValidation('MCP-Protocol-Version',$script:SCModernProtocol)|Out-Null;$request.Headers.TryAddWithoutValidation('Mcp-Method',[string]$Rpc.method)|Out-Null;$name=Get-ResidentMcpName $Rpc;if($name){$request.Headers.TryAddWithoutValidation('Mcp-Name',$name)|Out-Null}}
        $response=$client.SendAsync($request).GetAwaiter().GetResult();if([int]$response.StatusCode-eq202){return $null};$body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();if(-not$response.IsSuccessStatusCode){throw "Resident MCP returned HTTP $([int]$response.StatusCode): $body"};return $body
    }finally{$client.Dispose()}
}

try{
    while($null-ne($line=[Console]::In.ReadLine())){
        if([string]::IsNullOrWhiteSpace($line)){continue};$id=$null
        try{
            $request=$line|ConvertFrom-Json;if($request.PSObject.Properties['id']){$id=$request.id}
            if([string]$request.method-eq'subscriptions/listen'){
                if((Get-SCMcpRequestProtocolVersion $request)-ne$script:SCModernProtocol){[Console]::Out.WriteLine(([ordered]@{jsonrpc='2.0';id=$id;error=@{code=-32601;message='subscriptions/listen requires MCP 2026-07-28 request metadata.'}}|ConvertTo-Json -Depth 10 -Compress));[Console]::Out.Flush();continue}
                if(-not(Start-SCStdioControlSubscription $request)){[Console]::Out.WriteLine(([ordered]@{jsonrpc='2.0';id=$id;error=@{code=-32602;message="StatefulClanker supports subscriptions/listen for $script:SCControlEventsResource."}}|ConvertTo-Json -Depth 10 -Compress));[Console]::Out.Flush()};continue
            }
            if([string]$request.method-eq'notifications/cancelled'){$requestId=$null;if($request.PSObject.Properties['params']-and$request.params-and$request.params.PSObject.Properties['requestId']){$requestId=[string]$request.params.requestId};if($requestId){Stop-SCStdioSubscription $requestId};continue}
            $resident=Get-ResidentDetails
            if($resident){$body=Invoke-ResidentRpc $resident $request $line;if(-not[string]::IsNullOrWhiteSpace([string]$body)){[Console]::Out.WriteLine($body);[Console]::Out.Flush()};continue}
            $response=Invoke-McpRpc $request;if($null-ne$response){[Console]::Out.WriteLine(($response|ConvertTo-Json -Depth 30 -Compress));[Console]::Out.Flush()}
        }catch{
            if($null-ne$id){[Console]::Out.WriteLine(([ordered]@{jsonrpc='2.0';id=$id;error=[ordered]@{code=-32603;message=$_.Exception.Message}}|ConvertTo-Json -Depth 10 -Compress))}else{[Console]::Out.WriteLine(([ordered]@{jsonrpc='2.0';id=$null;error=[ordered]@{code=-32700;message="Parse error: $($_.Exception.Message)"}}|ConvertTo-Json -Depth 10 -Compress))};[Console]::Out.Flush()
        }
    }
}finally{Stop-SCAllStdioSubscriptions}

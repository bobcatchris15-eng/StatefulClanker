<# StatefulClanker MCP stdio transport.
   This is the primary local control-plane transport. It executes the MCP
   dispatcher directly in-process; local stdio clients never tunnel through
   the optional resident HTTP transport. #>
param([string]$ProjectPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

. (Join-Path $PSScriptRoot 'StatefulClanker.McpBootstrap.ps1')

if($ProjectPath-and(Test-Path -LiteralPath $ProjectPath -PathType Container)){
    Set-McpDefaultProject $ProjectPath
}

try{
    while($null-ne($line=[Console]::In.ReadLine())){
        if([string]::IsNullOrWhiteSpace($line)){continue}
        $id=$null
        try{
            $request=$line|ConvertFrom-Json
            if($request.PSObject.Properties['id']){$id=$request.id}

            if([string]$request.method-eq'subscriptions/listen'){
                if((Get-SCMcpRequestProtocolVersion $request)-ne$script:SCModernProtocol){
                    [Console]::Out.WriteLine(([ordered]@{jsonrpc='2.0';id=$id;error=@{code=-32601;message='subscriptions/listen requires MCP 2026-07-28 request metadata.'}}|ConvertTo-Json -Depth 10 -Compress))
                    [Console]::Out.Flush()
                    continue
                }
                if(-not(Start-SCStdioControlSubscription $request)){
                    [Console]::Out.WriteLine(([ordered]@{jsonrpc='2.0';id=$id;error=@{code=-32602;message="StatefulClanker supports subscriptions/listen for $script:SCControlEventsResource."}}|ConvertTo-Json -Depth 10 -Compress))
                    [Console]::Out.Flush()
                }
                continue
            }

            if([string]$request.method-eq'notifications/cancelled'){
                $requestId=$null
                if($request.PSObject.Properties['params']-and$request.params-and$request.params.PSObject.Properties['requestId']){
                    $requestId=[string]$request.params.requestId
                }
                if($requestId){Stop-SCStdioSubscription $requestId}
                continue
            }

            $response=Invoke-McpRpc $request
            if($null-ne$response){
                [Console]::Out.WriteLine(($response|ConvertTo-Json -Depth 30 -Compress))
                [Console]::Out.Flush()
            }
        }catch{
            if($null-ne$id){
                [Console]::Out.WriteLine(([ordered]@{jsonrpc='2.0';id=$id;error=[ordered]@{code=-32603;message=$_.Exception.Message}}|ConvertTo-Json -Depth 10 -Compress))
            }else{
                [Console]::Out.WriteLine(([ordered]@{jsonrpc='2.0';id=$null;error=[ordered]@{code=-32700;message="Parse error: $($_.Exception.Message)"}}|ConvertTo-Json -Depth 10 -Compress))
            }
            [Console]::Out.Flush()
        }
    }
}finally{
    Stop-SCAllStdioSubscriptions
}

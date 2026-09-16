# Final protocol compatibility wrapper. Modern 2026-07-28 subscriptions/listen is
# implemented by the transports, but legacy 2025-06-18 resources/subscribe is not.
# Do not advertise the modern capability through the legacy initialize shape.

$script:SCProtocolInvokeMcpRpc = (Get-Item Function:\Invoke-McpRpc).ScriptBlock

function Invoke-McpRpc($Request) {
    $response=& $script:SCProtocolInvokeMcpRpc $Request
    if([string]$Request.method-eq'initialize'-and$response-and$response.result-and$response.result.capabilities) {
        $response.result.capabilities['resources']=@{subscribe=$false;listChanged=$false}
    }
    return $response
}

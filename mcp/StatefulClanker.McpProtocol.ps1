# Protocol-era adapter. The underlying tool/resource surface stays era-neutral.
# Legacy clients (through 2025-11-25) retain initialize/session-era behavior.
# Modern 2026-07-28 requests are stateless, use server/discover and carry an envelope per request.

. (Join-Path $PSScriptRoot 'StatefulClanker.McpTaskCapabilities.ps1')
. (Join-Path $PSScriptRoot 'StatefulClanker.McpCapabilityProfiles.ps1')

$script:SCProtocolInvokeMcpRpc=(Get-Item Function:\Invoke-McpRpc).ScriptBlock
$script:SCModernProtocol='2026-07-28'
$script:SCLegacyProtocol='2025-06-18'
$script:SCServerInfo=[ordered]@{name='statefulclanker';version=$script:McpVersion}

function Get-SCMcpRequestMeta($Request) {
    if($Request-and$Request.PSObject.Properties['params']-and$Request.params-and$Request.params.PSObject.Properties['_meta']){return $Request.params._meta}
    return $null
}
function Get-SCMcpRequestProtocolVersion($Request) {
    $meta=Get-SCMcpRequestMeta $Request;if($null-eq$meta){return $null}
    $p=$meta.PSObject.Properties['io.modelcontextprotocol/protocolVersion'];if($p){return [string]$p.Value};return $null
}
function Test-SCModernMcpRequest($Request) {
    if([string]$Request.method-eq'server/discover'){return $true}
    return (Get-SCMcpRequestProtocolVersion $Request)-eq$script:SCModernProtocol
}
function Add-SCModernServerInfo($Response) {
    if($null-eq$Response-or-not$Response.PSObject.Properties['result']-or$null-eq$Response.result){return $Response}
    $result=$Response.result;$meta=$null
    if($result.PSObject.Properties['_meta']-and$result._meta){$meta=$result._meta}else{$meta=[ordered]@{};if($result-is[System.Collections.IDictionary]){$result['_meta']=$meta}else{$result|Add-Member -NotePropertyName '_meta' -NotePropertyValue $meta -Force}}
    if($meta-is[System.Collections.IDictionary]){$meta['io.modelcontextprotocol/serverInfo']=$script:SCServerInfo}else{$meta|Add-Member -NotePropertyName 'io.modelcontextprotocol/serverInfo' -NotePropertyValue $script:SCServerInfo -Force}
    return $Response
}
function New-SCModernDiscoverResponse($Request) {
    return [ordered]@{jsonrpc='2.0';id=$Request.id;result=[ordered]@{
        resultType='complete';supportedVersions=@($script:SCModernProtocol,$script:SCLegacyProtocol);ttlMs=30000;cacheScope='private';instructions=Get-SCControlPlaneInstructions
        capabilities=[ordered]@{tools=[ordered]@{listChanged=$false};resources=[ordered]@{subscribe=$true;listChanged=$false}}
        _meta=@{'io.modelcontextprotocol/serverInfo'=$script:SCServerInfo}
    }}
}
function New-SCModernProtocolError($Request,[int]$Code,[string]$Message) {
    return [ordered]@{jsonrpc='2.0';id=if($Request.PSObject.Properties['id']){$Request.id}else{$null};error=[ordered]@{code=$Code;message=$Message}}
}

function Invoke-McpRpc($Request) {
    $method=[string]$Request.method;$modern=Test-SCModernMcpRequest $Request
    if($method-eq'server/discover'){return New-SCModernDiscoverResponse $Request}
    if($modern-and$method-eq'initialize'){return New-SCModernProtocolError $Request -32601 'initialize is not part of MCP 2026-07-28; use server/discover or call the desired method directly with a per-request _meta envelope.'}
    $response=& $script:SCProtocolInvokeMcpRpc $Request
    if($modern){return Add-SCModernServerInfo $response}
    if($method-eq'initialize'-and$response-and$response.result-and$response.result.capabilities){
        # This implementation does not expose legacy resources/subscribe or a standalone GET event stream.
        $response.result.capabilities['resources']=@{subscribe=$false;listChanged=$false}
    }
    return $response
}

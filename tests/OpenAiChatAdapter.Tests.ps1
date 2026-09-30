<# Inspect the actual HTTP request body, rather than the normalized DTO. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
Add-Type -Path (Join-Path $repo 'src/StatefulClanker.Router/bin/Debug/net8.0-windows/StatefulClanker.Router.dll')
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "OPENAI ADAPTER TEST FAILED: $Message"}}
$connection=[StatefulClanker.Router.ConnectionProfile]::new()
$connection.baseUrl='https://provider.example/v1'
$connection.authKind='none'
$endpoint=[StatefulClanker.Router.EndpointEntry]::new()
$endpoint.model='test-model'
$request=[StatefulClanker.Router.NormalizedInferenceRequest]::new()
$request.toolMode='native'
foreach($role in @('system','user','assistant')){
    $message=[StatefulClanker.Router.NormalizedInferenceMessage]::new()
    $message.role=$role;$message.content="$role text"
    $request.messages.Add($message)
}
$assistant=[StatefulClanker.Router.NormalizedInferenceMessage]::new()
$assistant.role='assistant'
$assistant.tool_calls=[Collections.Generic.List[StatefulClanker.Router.NormalizedToolCall]]::new()
foreach($id in @('call-1','call-2')){
    $call=[StatefulClanker.Router.NormalizedToolCall]::new()
    $call.id=$id;$call.function.name='read_file';$call.function.arguments='{"path":"README.md"}'
    if($id -eq 'call-2'){$call.thought_signature='signature-value'}
    $assistant.tool_calls.Add($call)
}
$request.messages.Add($assistant)
$result=[StatefulClanker.Router.NormalizedInferenceMessage]::new()
$result.role='tool';$result.tool_call_id='call-1';$result.content='file contents'
$request.messages.Add($result)
$adapter=[StatefulClanker.Router.OpenAiChatAdapter]::new()
$built=$adapter.BuildRequest($connection,$endpoint,$request,$null)
try{
    $body=$built.Message.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json -AsHashtable
    foreach($message in $body.messages[0..2]){
        Assert-True (-not $message.ContainsKey('tool_calls')) 'ordinary message sent tool_calls:null'
        Assert-True (-not $message.ContainsKey('tool_call_id')) 'ordinary message sent tool_call_id:null'
    }
    $toolTurn=$body.messages[3]
    Assert-True ($toolTurn.ContainsKey('content') -and $null -eq $toolTurn.content) 'assistant tool turn lost content:null'
    Assert-True (-not $toolTurn.ContainsKey('tool_call_id')) 'assistant tool turn sent tool_call_id:null'
    Assert-True ($toolTurn.tool_calls.Count -eq 2) 'native tool call array was lost'
    $call=$toolTurn.tool_calls[0]
    Assert-True ($call.id -ceq 'call-1' -and $call.type -ceq 'function') 'native call identity changed'
    Assert-True ($call.function.name -ceq 'read_file' -and $call.function.arguments -ceq '{"path":"README.md"}') 'native function payload changed'
    Assert-True (-not $call.ContainsKey('thought_signature')) 'native call sent thought_signature:null'
    Assert-True ($toolTurn.tool_calls[1].thought_signature -ceq 'signature-value') 'existing thought signature was lost'
    Assert-True ($body.messages[4].tool_call_id -ceq 'call-1' -and $body.messages[4].content -ceq 'file contents') 'tool result pairing or content changed'
    Assert-True (-not $body.messages[4].ContainsKey('tool_calls')) 'tool result sent tool_calls:null'
    Write-Host 'PASS: OpenAI HTTP request omits absent optional fields and preserves native tool transcript.'
}finally{$built.Message.Dispose()}

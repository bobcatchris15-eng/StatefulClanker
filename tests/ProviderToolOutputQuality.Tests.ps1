param([string]$RouterDll)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(-not $RouterDll){$RouterDll=Join-Path $repo 'src/StatefulClanker.Router/bin/Debug/net8.0-windows/StatefulClanker.Router.dll'}
[void][Reflection.Assembly]::LoadFrom($RouterDll)
$adapter=[StatefulClanker.Router.OpenAiChatAdapter]::new();$endpoint=[StatefulClanker.Router.EndpointEntry]::new()
foreach($calls in @('[{"function":{"name":"bad name","arguments":"{}"}}]','[null]','[{}]','{"function":{}}','[{"function":{"name":"write","arguments":"[]"}}]')){
 $body='{"usage":{"prompt_tokens":3,"completion_tokens":4},"choices":[{"message":{"content":"some text","tool_calls":'+$calls+'}}]}'
 $result=$adapter.ParseSuccess($body,$endpoint)
 if($result.Success -or $result.FailureClass -ne 'invalid_tool_arguments'){throw "Malformed call shape/name accepted or misclassified: $calls"}
 if($result.Usage.completionTokens -ne 4){throw 'Malformed response lost usage'}
}
foreach($case in @(
 @('Gemini','{"candidates":[{"content":{"parts":[{"text":"ok","functionCall":{"args":{}}}]}}],"usageMetadata":{"candidatesTokenCount":4}}'),
 @('Gemini','{"candidates":[{"content":{"parts":[{"text":"ok","functionCall":[]}]}}],"usageMetadata":{"candidatesTokenCount":4}}'),
 @('Gemini','{"candidates":[{"content":{"parts":[{"functionCall":{"name":123,"args":{}}}]}}],"usageMetadata":{"candidatesTokenCount":4}}'),
 @('Anthropic','{"content":[{"type":"tool_use","name":123,"input":{}}],"usage":{"output_tokens":4}}'),
 @('Anthropic','{"content":[{"type":"tool_use","name":"write","input":[]}],"usage":{"output_tokens":4}}')
)){
 $native=if($case[0] -eq 'Gemini'){[StatefulClanker.Router.GeminiNativeAdapter]::new()}else{[StatefulClanker.Router.AnthropicMessagesAdapter]::new()}
 $result=$native.ParseSuccess($case[1],$endpoint)
 if($result.Success -or $result.FailureClass -ne 'invalid_tool_arguments' -or $result.Usage.completionTokens -ne 4){throw "Native adapter accepted/misclassified malformed tool output or lost usage: $($case[0])"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('sc-quality-'+[guid]::NewGuid().ToString('N'))
try{
 $store=[StatefulClanker.Router.RouterStore]::new($root)
 $reducer=[StatefulClanker.Router.RoutingHealthReducer]::new($store,[StatefulClanker.Router.SignalStore]::new($root))
 $profile=[StatefulClanker.Router.ConnectionProfile]::new();$profile.name='mock'
 foreach($i in 1..2){[void]$reducer.RegisterFailure('pool:mock::m','endpoint','provider_tool_output_invalid','Malformed tool output',$profile)}
 $failureTime=$store.LoadHealth().endpoints['pool:mock::m'].lastToolOutputFailure
 if(-not [datetimeoffset]::TryParse($failureTime,[ref]([datetimeoffset]::MinValue))){throw 'Quality failure timestamp missing'}
 foreach($case in @(@(1,60),@(2,120),@(3,240),@(4,480),@(5,900),@(10,900))){
   if([StatefulClanker.Router.FailurePolicy]::Delay('provider_tool_output_invalid',$null,$case[0]).TotalSeconds -ne $case[1]){throw 'Quality cooldown sequence/cap wrong'}
 }
 $reducer.MarkHealthy('pool:mock::m','metadata observation')
 $entry=$store.LoadHealth().endpoints['pool:mock::m']
 if($entry.toolOutputFailures -ne 2 -or $entry.consecutiveToolOutputFailures -ne 2){throw 'Metadata observation erased quality history'}
 $reducer.MarkHealthy('pool:mock::m','successful-observation',$true)
 $entry=$store.LoadHealth().endpoints['pool:mock::m']
 if($entry.toolOutputFailures -ne 2 -or $entry.consecutiveToolOutputFailures -ne 0 -or $entry.lastToolOutputFailure -ne $failureTime){throw 'Inference success did not reset only the streak'}
 'PASS: malformed tool shapes/names rejected with usage preserved; quality history survives metadata and success.'
}finally{
 if([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetTempPath())){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}

$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
Add-Type -Path (Join-Path $repo 'src/StatefulClanker.Router/bin/Debug/net8.0-windows/StatefulClanker.Router.dll')
$a=[StatefulClanker.Router.OpenAiChatAdapter]::new();$e=[StatefulClanker.Router.EndpointEntry]::new();$e.model='model'
function Check($condition,$message){if(-not $condition){throw $message}}
$p=$a.ParseSuccess('{"error":{"message":"JSON error injected into SSE stream","code":502,"metadata":{"error_type":"provider_unavailable"}}}',$e)
Check ($p.ProviderStatus -eq 502 -and $p.FailureClass -eq 'server_error') 'embedded provider failure lost'
$p=$a.ParseSuccess('{"choices":[{"finish_reason":"length","message":{"content":"","reasoning":"secret"}}],"usage":{"prompt_tokens":3,"completion_tokens":4096}}',$e)
Check (-not $p.Success -and $null -eq $p.Assistant -and $p.FailureClass -eq 'output_budget_exhausted') 'reasoning-only length not exhaustion'
$p=$a.ParseSuccess('{"choices":[{"finish_reason":"length","message":{"tool_calls":[{"id":"x","function":{"name":"write","arguments":"{\"path\":"}}]}}],"usage":{"completion_tokens":4096}}',$e)
Check (-not $p.Success -and $null -eq $p.Assistant -and $p.Usage.completionTokens -eq 4096) 'truncated tool admitted or usage lost'
foreach($argsJson in @('[]','null','"text"')){
 $body=@{choices=@(@{message=@{tool_calls=@(@{id='x';function=@{name='write';arguments=$argsJson}})}})}|ConvertTo-Json -Depth 10 -Compress
 Check (-not $a.ParseSuccess($body,$e).Success) 'non-object native arguments admitted'
}
Check ([StatefulClanker.Router.FailurePolicy]::Classify('maximum context length is 262144 tokens. requested 423601',400) -eq 'context_too_large') 'context rejected classification'

$p=$a.ParseSuccess('{"error":{"message":"invalid request","code":"400"}}',$e)
Check ($p.ProviderStatus -eq 400 -and $p.FailureClass -eq 'bad_request') 'embedded400 diagnosis wrong'
$p=$a.ParseSuccess('{"choices":[{"finish_reason":"length","message":{"content":"valid partial answer"}}]}',$e)
Check $p.Success 'usable output was retried solely because finish reason is length'
$p=$a.ParseSuccess('{"choices":[{"finish_reason":"length","message":{"tool_calls":[{"id":"x","function":{"name":"read","arguments":"{}"}}]}}]}',$e)
Check $p.Success 'valid native tool output rejected'
$p=$a.ParseSuccess('{"choices":[{"message":{"content":null}}]}',$e)
Check (-not $p.Success -and $null -eq $p.FailureClass) 'generic empty response incorrectly considered output exhaustion'
Check ([StatefulClanker.Router.FailurePolicy]::Classify('Input length266927 exceeds maximum262112 tokens',400) -eq 'context_too_large') 'input length context diagnosis wrong'
Check ([StatefulClanker.Router.FailurePolicy]::Classify('Prompt365914 >256000 maximum context length',400) -eq 'context_too_large') 'prompt context diagnosis wrong'
$p=$a.ParseSuccess('{"error":{"message":"bad gateway"}}',$e)
Check ($p.ProviderError -and $null -eq $p.ProviderStatus -and $p.FailureClass -eq 'server_error') 'provider envelope without numeric status not identified'
$p=$a.ParseSuccess('{"error":{"message":"bad gateway","code":502},"usage":{"prompt_tokens":3,"completion_tokens":4096}}',$e)
Check ($p.Usage.reported -and $p.Usage.completionTokens -eq 4096) 'error envelope reported usage discarded'
$p=$a.ParseSuccess('{"error":{"message":"JSON error injected into SSE stream","metadata":{"error_type":"provider_unavailable"}}}',$e)
Check ($p.FailureClass -eq 'server_error') 'statusless provider_unavailable not classified'


$p=$a.ParseSuccess('{"usage":{"prompt_tokens":3,"completion_tokens":2},"choices":[null]}',$e)
Check (-not $p.Success -and $p.Usage.reported -and $p.Usage.totalTokens -eq 5) 'malformed response discarded reported usage'
Write-Host 'PASS: inference adapter recovery regressions'

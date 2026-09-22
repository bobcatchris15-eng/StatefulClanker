$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "GEMINI ADAPTER TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-gemini-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
$oldKey=$env:SC_GEMINI_TEST_KEY
try {
    $env:SC_GEMINI_TEST_KEY='AQ.test-not-a-real-secret'
    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    Set-SCRoots $temp $temp
    . (Join-Path $repo 'lib\StatefulClanker.WorkerPolicy.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')

    Write-Host '  GEMINI 1: native auth never becomes Bearer'
    $connection=[pscustomobject]@{protocol='gemini-native';authKind='x-goog-api-key';baseUrl='https://generativelanguage.googleapis.com/v1beta';model='gemini-3.8-flash';apiKeyEnv='SC_GEMINI_TEST_KEY';headers=[pscustomobject]@{'x-goog-api-client'='statefulclanker/0.8'}}
    $headers=New-SCApiHeaders $connection
    Assert-True ($headers['x-goog-api-key']-eq$env:SC_GEMINI_TEST_KEY) 'x-goog-api-key was not populated.'
    Assert-True (-not$headers.ContainsKey('Authorization')) 'Gemini native adapter incorrectly sent Authorization Bearer.'
    Assert-True ($headers['x-goog-api-client']-eq'statefulclanker/0.8') 'Gemini client identification header was lost.'
    Assert-True ((Get-SCApiUri $connection)-eq'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent') 'Native Gemini URI was wrong.'

    Write-Host '  GEMINI 2: canonical tool transcript translates to Gemini function calls/results'
    $messages=@(
        [ordered]@{role='system';content='system'},
        [ordered]@{role='user';content='do work'},
        [ordered]@{role='assistant';content='';tool_calls=@([ordered]@{id='call-1';type='function';function=[ordered]@{name='read_file';arguments='{"path":"README.md"}'}})},
        [ordered]@{role='tool';tool_call_id='call-1';content='hello'}
    )
    $translated=ConvertTo-SCGeminiMessages $messages
    Assert-True ($translated.system-eq'system') 'System instruction was not separated.'
    Assert-True ($translated.contents[1].role-eq'model') 'Assistant turn did not become Gemini model role.'
    Assert-True ($translated.contents[1].parts[0].functionCall.name-eq'read_file') 'Function call name was not translated.'
    Assert-True ($translated.contents[2].parts[0].functionResponse.name-eq'read_file') 'Function result was not paired back to its function name.'

    Write-Host '  GEMINI 3: Gemini response normalizes to canonical tool call'
    $response=[pscustomobject]@{candidates=@([pscustomobject]@{content=[pscustomobject]@{parts=@([pscustomobject]@{functionCall=[pscustomobject]@{name='write_file';args=[pscustomobject]@{path='x.txt';content='x'}}})}})}
    $m=Get-SCAssistantMessage $response 'gemini-native'
    Assert-True (@($m.tool_calls).Count-eq1) 'Gemini function call was not normalized.'
    Assert-True ($m.tool_calls[0].function.name-eq'write_file') 'Normalized Gemini tool name was wrong.'
    Write-Host 'PASS: native Gemini auth, URI, transcript translation, and tool-call normalization.'
} finally {
    $env:SC_GEMINI_TEST_KEY=$oldKey
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

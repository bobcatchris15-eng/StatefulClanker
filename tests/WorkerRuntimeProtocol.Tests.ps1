<# Focused protocol-safety regressions. No network or provider credentials required. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "WORKER RUNTIME PROTOCOL TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-runtime-protocol-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try {
    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    Set-SCRoots $temp $temp
    . (Join-Path $repo 'lib\StatefulClanker.WorkerPolicy.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.Windows.ps1')

    Write-Host '  PROTOCOL 1: malformed non-choices replies yield bounded diagnostics'
    $detail=('x'*1000)
    try {
        Get-SCAssistantMessage ([pscustomobject]@{error=[pscustomobject]@{message=$detail}}) 'openai-chat'|Out-Null
        throw 'Expected malformed response to throw.'
    } catch {
        $message=$_.Exception.Message
        Assert-True ($message -match '^Inference endpoint returned no choices\. Diagnostic: ') "Malformed response did not report a stable diagnostic: $message"
        Assert-True ($message -notmatch 'PropertyNotFoundException') "Malformed response leaked a StrictMode property error: $message"
        Assert-True ($message.Length -le 300) "Malformed response diagnostic was not bounded: $($message.Length)"
    }

    Write-Host '  PROTOCOL 2: Cohere-compatible models never receive native tool calls'
    $cohere=[pscustomobject]@{baseUrl='https://openrouter.ai/api/v1';model='cohere/north-mini-code:free';toolMode='native'}
    Assert-True ((Get-SCEffectiveWorkerToolMode $cohere)-eq'text') 'Cohere-compatible OpenRouter model was left in native tool mode.'
    $ordinary=[pscustomobject]@{baseUrl='https://openrouter.ai/api/v1';model='meta-llama/llama-3.3-70b-instruct';toolMode='native'}
    Assert-True ((Get-SCEffectiveWorkerToolMode $ordinary)-eq'native') 'Non-Cohere model was unexpectedly downgraded from native tool mode.'
    $script:capturedRequest=$null
    function Invoke-RestMethod {
        param($Method,$Uri,$Headers,$ContentType,$Body,$TimeoutSec)
        $script:capturedRequest=[Text.Encoding]::UTF8.GetString([byte[]]$Body)|ConvertFrom-Json
        return [pscustomobject]@{choices=@([pscustomobject]@{message=[pscustomobject]@{content='ok'}})}
    }
    $tool=@([ordered]@{type='function';function=[ordered]@{name='read_file';parameters=[ordered]@{type='object'}}})
    Invoke-SCApiChat $cohere @([ordered]@{role='user';content='hi'}) $tool (Get-SCEffectiveWorkerToolMode $cohere)|Out-Null
    Assert-True ($null-eq$script:capturedRequest.PSObject.Properties['tools']) 'Cohere-compatible request still contained native tool definitions.'
    Assert-True ($null-eq$script:capturedRequest.PSObject.Properties['tool_choice']) 'Cohere-compatible request still contained native tool selection.'

    Write-Host '  PROTOCOL 3: Windows wrapper continues to allow Gemini native adapter'
    Assert-True ($script:SCSupportedApiProtocols -contains 'gemini-native') 'Windows runtime rejected the deployed gemini-native adapter.'
    Write-Host 'PASS: malformed replies are safe, Cohere native tool calls are prevented, and Gemini remains enabled.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

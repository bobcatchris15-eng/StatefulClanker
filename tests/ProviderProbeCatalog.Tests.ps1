<# Provider control-plane probe catalog and provider-specific quota metadata. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$dll=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.dll'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "PROVIDER PROBE TEST FAILED: $Message"}}
if(-not(Test-Path -LiteralPath $dll)){throw "Build the router before running this test: $dll"}
[void][Reflection.Assembly]::LoadFrom($dll)

function New-Profile([string]$Id,[string]$Base,[string]$Models='/models'){
    $p=[StatefulClanker.Router.ConnectionProfile]::new()
    $p.name=$Id;$p.presetId=$Id;$p.baseUrl=$Base;$p.modelsPath=$Models;$p.authKind='bearer'
    return $p
}

Write-Host '  PROBE 1: OpenRouter uses its dedicated key metadata endpoint'
$p=New-Profile 'openrouter' 'http://127.0.0.1:9876/api/v1'
$plan=[StatefulClanker.Router.ProviderProbeCatalog]::Resolve($p)
Assert-True ([string]$plan.Strategy-eq'openrouter-key') 'OpenRouter did not select key metadata strategy.'
Assert-True ([string]$plan.Method.Method-eq'GET') 'OpenRouter probe is not GET.'
Assert-True ($plan.Uri.AbsoluteUri-eq'http://127.0.0.1:9876/api/v1/key') "Unexpected OpenRouter probe URI: $($plan.Uri)"
Assert-True $plan.ReadSuccessBody 'OpenRouter quota probe must read the successful JSON body.'

Write-Host '  PROBE 2: Cohere uses its dedicated key-check endpoint without inference'
$p=New-Profile 'cohere' 'http://127.0.0.1:9999/compatibility/v1' 'http://127.0.0.1:9877/v1/models?page_size=1000&endpoint=chat'
$plan=[StatefulClanker.Router.ProviderProbeCatalog]::Resolve($p)
Assert-True ([string]$plan.Strategy-eq'cohere-key-check') 'Cohere did not select key-check strategy.'
Assert-True ([string]$plan.Method.Method-eq'POST') 'Cohere key check must use POST.'
Assert-True ($plan.Uri.AbsoluteUri-eq'http://127.0.0.1:9877/v1/check-api-key') "Unexpected Cohere probe URI: $($plan.Uri)"

Write-Host '  PROBE 2B: Pollinations uses account/key for non-inference budget telemetry'
$p=New-Profile 'pollinations' 'https://gen.pollinations.ai/v1' 'https://gen.pollinations.ai/text/models'
$plan=[StatefulClanker.Router.ProviderProbeCatalog]::Resolve($p)
Assert-True ([string]$plan.Strategy-eq'pollinations-key') 'Pollinations did not select account/key strategy.'
Assert-True ([string]$plan.Method.Method-eq'GET') 'Pollinations account key probe must use GET.'
Assert-True ($plan.Uri.AbsoluteUri-eq'https://gen.pollinations.ai/account/key') "Unexpected Pollinations probe URI: $($plan.Uri)"
Assert-True $plan.ReadSuccessBody 'Pollinations budget probe must read successful JSON body.'

Write-Host '  PROBE 3: quota-capable model probes stay warmer than silent generic probes'
$groq=[StatefulClanker.Router.ProviderProbeCatalog]::Resolve((New-Profile 'groq' 'https://api.groq.com/openai/v1'))
$generic=[StatefulClanker.Router.ProviderProbeCatalog]::Resolve((New-Profile 'custom' 'https://example.invalid/v1'))
Assert-True ([string]$groq.Strategy-eq'groq-models-headers') 'Groq strategy was not provider-specific.'
Assert-True ($groq.UsefulInterval.TotalMinutes-lt$generic.UsefulInterval.TotalMinutes) 'Useful Groq telemetry should be sampled more often than generic metadata.'
Assert-True ($generic.SilentInterval.TotalMinutes-ge45) 'Quota-silent generic provider did not back off.'

Write-Host '  PROBE 4: local and retired services do not receive periodic network probes'
$local=[StatefulClanker.Router.ProviderProbeCatalog]::Resolve((New-Profile 'ollama' 'http://127.0.0.1:11434/v1'))
Assert-True (-not$local.Enabled) 'Local Ollama should not receive periodic quota probes.'
$gh=New-Profile 'github-models' 'https://models.github.ai/inference'
$retired=[StatefulClanker.Router.ProviderProbeCatalog]::Resolve($gh)
Assert-True (-not$retired.Enabled) 'Retired GitHub Models provider was still probe-enabled.'
Assert-True ([StatefulClanker.Router.ProviderProbeCatalog]::IsRetired($gh)) 'GitHub Models was not classified retired.'

Write-Host '  PROBE 5: Cerebras request/day and token/minute headers become distinct windows'
$h=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
$h['x-ratelimit-limit-requests-day']='1000'
$h['x-ratelimit-remaining-requests-day']='998'
$h['x-ratelimit-reset-requests-day']='3600'
$h['x-ratelimit-limit-tokens-minute']='8000'
$h['x-ratelimit-remaining-tokens-minute']='6500'
$h['x-ratelimit-reset-tokens-minute']='12.5'
$q=[StatefulClanker.Router.QuotaIntelligence]::Observe('cerebras',200,$h,'',$true)
$req=@($q.windows|Where-Object { $_.kind-eq'requests_per_day' }|Select-Object -First 1)
$tok=@($q.windows|Where-Object { $_.kind-eq'tokens_per_minute' }|Select-Object -First 1)
Assert-True ($req.Count-eq1 -and $tok.Count-eq1) 'Cerebras windows were not split by cadence.'
Assert-True ([double]$req[0].remaining-eq998) 'Cerebras request/day remaining count was wrong.'
Assert-True ([double]$tok[0].remaining-eq6500) 'Cerebras token/minute remaining count was wrong.'
Assert-True ($null-ne$req[0].resetAt -and $null-ne$tok[0].resetAt) 'Cerebras reset timers were not parsed.'

Write-Host '  PROBE 6: Kilo published free-model limit is retained as rule telemetry'
$empty=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
$k=[StatefulClanker.Router.QuotaIntelligence]::Observe('kilo',200,$empty,'',$true)
$kw=@($k.windows|Where-Object { $_.kind-eq'free_model_requests_per_ip' }|Select-Object -First 1)
Assert-True ($kw.Count-eq1) 'Kilo free-model limit rule was not recorded.'
Assert-True ([double]$kw[0].limit-eq200) 'Kilo free-model request limit was wrong.'
Assert-True ([string]$kw[0].unit-eq'requests/hour') 'Kilo free-model quota unit was wrong.'

Write-Host 'PASS: provider probe catalog selects cheap control-plane probes and normalizes provider-specific quota metadata.'

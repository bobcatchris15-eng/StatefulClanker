<# Provider-specific zero-cost classifier rules. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$dll=Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.dll'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "FREE CAPACITY PROVIDER RULE TEST FAILED: $Message"}}
if(-not(Test-Path -LiteralPath $dll)){throw "Build router before running this test: $dll"}
[void][Reflection.Assembly]::LoadFrom($dll)

$flags=[Reflection.BindingFlags]'NonPublic,Static'
$type=[StatefulClanker.Router.FreeCapacityManager]
$parse=$type.GetMethod('ParseModels',$flags)
$classify=$type.GetMethod('Classify',$flags)
$family=$type.GetMethod('ProviderFamily',$flags)
if(-not$parse-or-not$classify-or-not$family){throw 'Expected private classifier helpers were not found.'}

function Profile([string]$Preset,[string]$Base,[string]$Discovery='openai'){
    $p=[StatefulClanker.Router.ConnectionProfile]::new()
    $p.name=$Preset;$p.presetId=$Preset;$p.baseUrl=$Base;$p.modelsPath='/models';$p.discoveryKind=$Discovery;$p.authKind='none'
    return $p
}
function Parse-One($Profile,[string]$Json){
    $list=$parse.Invoke($null,@($Json,$Profile))
    Assert-True ($list.Count-eq1) 'Expected exactly one parsed model.'
    return $list[0]
}
function Classify-One($Profile,[string]$Json){
    $m=Parse-One $Profile $Json
    return $classify.Invoke($null,@($Profile,$m,[DateTimeOffset]::UtcNow))
}

Write-Host '  RULE 1: Kilo isFree + zero pricing enters automatic pool'
$p=Profile 'kilo' 'https://api.kilo.ai/api/gateway'
$s=Classify-One $p '{"data":[{"id":"kilo-auto/free","name":"Auto Free","isFree":true,"pricing":{"prompt":"0","completion":"0"},"context_length":256000,"supported_parameters":["tools"]}]}'
Assert-True ([string]$s.classification-eq'confirmed_free') 'Kilo isFree model was not confirmed free.'
Assert-True ([bool]$s.workhorse) 'Kilo Auto Free was not recognized as a workhorse.'

Write-Host '  RULE 2: positive Kilo price remains paid even on same gateway'
$s=Classify-One $p '{"data":[{"id":"openai/gpt-paid","name":"Paid","isFree":false,"pricing":{"prompt":"0.5","completion":"1.0"},"context_length":128000,"supported_parameters":["tools"]}]}'
Assert-True ([string]$s.classification-eq'paid') 'Positive-priced Kilo model was not paid.'

Write-Host '  RULE 3: Pollinations rich pollen pricing is consumed generically'
$p=Profile 'pollinations' 'https://gen.pollinations.ai/v1'
$p.modelsPath='https://gen.pollinations.ai/text/models'
$s=Classify-One $p '[{"name":"openai/gpt-x","title":"GPT X","pricing":{"currency":"pollen","promptTextTokens":"0.000001","completionTextTokens":"0.000002"},"tools":true,"context_length":200000}]'
Assert-True ([string]$s.classification-eq'paid') 'Positive Pollinations pollen pricing was not paid.'
$s=Classify-One $p '[{"name":"future/free-model","title":"Future Free","pricing":{"currency":"pollen","promptTextTokens":"0","completionTextTokens":"0"},"tools":true,"context_length":200000}]'
Assert-True ([string]$s.classification-eq'confirmed_free') 'Zero-priced Pollinations model was not auto-discoverable.'
Assert-True ([bool]$s.workhorse) 'Pollinations tool-capable text model was not a workhorse.'

Write-Host '  RULE 4: configured custom OpenCode Zen is inferred from URL and only explicit free IDs enter pool'
$p=Profile 'custom' 'https://opencode.ai/zen/v1'
Assert-True ([string]$family.Invoke($null,@($p))-eq'opencode-zen') 'Custom OpenCode Zen connection family was not detected.'
$s=Classify-One $p '{"data":[{"id":"mimo-v2.5-free","object":"model"}]}'
Assert-True ([string]$s.classification-eq'confirmed_free') 'OpenCode Zen -free route was not confirmed free.'
$s=Classify-One $p '{"data":[{"id":"big-pickle","object":"model"}]}'
Assert-True ([string]$s.classification-eq'unknown') 'Sparse Big Pickle catalog entry was hard-coded as free despite mutable promotion.'

Write-Host '  RULE 5: OpenCode GO subscription is not mistaken for free-tier capacity'
$p=Profile 'custom' 'https://opencode.ai/zen/go/v1'
Assert-True ([string]$family.Invoke($null,@($p))-eq'opencode-go') 'Custom OpenCode GO connection family was not detected.'
$s=Classify-One $p '{"data":[{"id":"deepseek-v4-flash","object":"model"}]}'
Assert-True ([string]$s.classification-eq'unknown') 'OpenCode GO subscription model was incorrectly auto-free.'

Write-Host '  RULE 6: NVIDIA hosted API Catalog is separately labeled trial-free'
$p=Profile 'nvidia' 'https://integrate.api.nvidia.com/v1'
$s=Classify-One $p '{"data":[{"id":"z-ai/glm-5-3","object":"model","owned_by":"z-ai"}]}'
Assert-True ([string]$s.classification-eq'trial_free') 'NVIDIA NIM catalog model was not labeled trial_free.'
Assert-True ([bool]$s.workhorse) 'NVIDIA text model was not a workhorse candidate.'

Write-Host '  RULE 7: free-tier-capable providers remain unknown without model/account proof'
$p=Profile 'gemini' 'https://generativelanguage.googleapis.com/v1beta' 'gemini'
$s=Classify-One $p '{"models":[{"name":"models/gemini-test","displayName":"Gemini Test","supportedGenerationMethods":["generateContent"],"inputTokenLimit":100000}]}'
Assert-True ([string]$s.classification-eq'unknown') 'Gemini catalog was blanket-classified free without account/model proof.'
$p=Profile 'cloudflare' 'https://api.cloudflare.com/client/v4/accounts/example/ai/v1' 'cloudflare'
$s=Classify-One $p '{"result":[{"id":"@cf/nvidia/nemotron-3-120b-a12b","name":"Nemotron"}]}'
Assert-True ([string]$s.classification-eq'unknown') 'Cloudflare model was blanket-classified free without account-plan proof.'

Write-Host '  RULE 8: Pollinations account/key body becomes quota telemetry without generation'
$empty=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
$q=[StatefulClanker.Router.QuotaIntelligence]::Observe('pollinations',200,$empty,'{"valid":true,"pollenBudget":12.5,"rateLimitEnabled":false}',$true)
Assert-True ([double]$q.remaining-eq12.5) 'Pollinations pollen budget was not parsed.'
$w=@($q.windows|Where-Object { $_.kind-eq'pollen_budget' }|Select-Object -First 1)
Assert-True ($w.Count-eq1 -and [string]$w[0].unit-eq'pollen') 'Pollinations pollen budget window was not recorded.'

Write-Host 'PASS: provider-specific free-capacity rules remain aggressive only when zero-cost status is provable.'

<# Static OpenRouter free-model catalog regression checks. #>
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$path=Join-Path $repo 'src\StatefulClanker.Tray\OpenRouterCatalog.cs'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "OPENROUTER CATALOG TEST FAILED: $Message"}}
$text=Get-Content -Raw -LiteralPath $path
$matches=[regex]::Matches($text,'new\("([^"]+)",\s*"([^"]+)",\s*"([^"]+)",\s*"(native|text)"\)')
Assert-True ($matches.Count -eq 21) "Expected 21 managed free text models, got $($matches.Count)."
$ids=@($matches|ForEach-Object{$_.Groups[1].Value});$models=@($matches|ForEach-Object{$_.Groups[2].Value})
Assert-True ((@($ids|Select-Object -Unique).Count) -eq 21) 'Connection ids must be unique.'
Assert-True ((@($models|Select-Object -Unique).Count) -eq 21) 'Model slugs must be unique.'
foreach($required in @('openrouter/free','cohere/north-mini-code:free','nvidia/nemotron-3-ultra-550b-a55b:free','poolside/laguna-s-2.1:free','stealth/union-alpha','z-ai/glm-5.2:free')){Assert-True ($models -contains $required) "Missing required model $required."}
foreach($excluded in @('google/lyria-3-clip-preview','google/lyria-3-pro-preview','nvidia/nemotron-3.5-content-safety:free')){Assert-True ($models -notcontains $excluded) "Excluded non-worker model is present: $excluded."}
$glm=@($matches|Where-Object{$_.Groups[2].Value-eq'z-ai/glm-5.2:free'})[0];Assert-True ($glm.Groups[4].Value-eq'text') 'GLM 5.2 must use text-tool mode because native tools are not advertised.'
Write-Host 'PASS: OpenRouter catalog has 21 free worker models, expected exclusions, and GLM 5.2 text-tool fallback.'

$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "PI CATALOG TEST FAILED: $Message"}}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-pi-'+[Guid]::NewGuid().ToString('N'))
$oldLocal=$env:LOCALAPPDATA
$env:LOCALAPPDATA=$temp
try {
    $root=Join-Path $temp 'StatefulClanker'
    New-Item -ItemType Directory -Force -Path $root|Out-Null
    @{
        schemaVersion=1
        connections=[ordered]@{
            Gemini=[ordered]@{protocol='gemini-native';authKind='x-goog-api-key';baseUrl='https://generativelanguage.googleapis.com/v1beta';apiKeyProtected='dummy'}
            Anthropic=[ordered]@{protocol='anthropic-messages';authKind='x-api-key';baseUrl='https://api.anthropic.com/v1';apiKeyProtected='dummy'}
            Local=[ordered]@{protocol='openai-chat';authKind='none';baseUrl='http://127.0.0.1:1234/v1'}
        }
    }|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $root 'connections.json') -Encoding UTF8
    @{
        schemaVersion=2
        entries=[ordered]@{
            'Gemini::gemini-test'=[ordered]@{connection='Gemini';model='gemini-test';displayName='Gemini Test';enabled=$true;contextLength=100000}
            'Anthropic::claude-test'=[ordered]@{connection='Anthropic';model='claude-test';displayName='Claude Test';enabled=$true;contextLength=100000}
            'Local::local-test'=[ordered]@{connection='Local';model='local-test';displayName='Local Test';enabled=$true;contextLength=32000}
        }
    }|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $root 'endpoints.json') -Encoding UTF8

    & (Join-Path $repo 'pi\Sync-PiCatalog.ps1')
    $path=Join-Path $root 'pi\models.json'
    Assert-True (Test-Path -LiteralPath $path) 'models.json was not generated.'
    $models=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json

    $g=$models.providers.'sc-gemini'
    Assert-True ($g.api-eq'google-generative-ai') 'Gemini did not map to Pi google-generative-ai.'
    Assert-True (-not[bool]$g.authHeader) 'Gemini incorrectly enabled Bearer auth.'
    Assert-True ([string]$g.apiKey -like '!*Get-Credential.ps1*') 'Gemini does not resolve its key through StatefulClanker.'

    $a=$models.providers.'sc-anthropic'
    Assert-True ($a.api-eq'anthropic-messages') 'Anthropic did not map to Pi anthropic-messages.'
    Assert-True (-not[bool]$a.authHeader) 'Anthropic incorrectly enabled Bearer auth.'
    Assert-True ([string]$a.apiKey -like '!*Get-Credential.ps1*') 'Anthropic does not resolve its key through StatefulClanker.'

    $l=$models.providers.'sc-local'
    Assert-True ($l.api-eq'openai-completions') 'Keyless OpenAI-compatible endpoint mapped incorrectly.'
    Assert-True ($l.apiKey-eq'statefulclanker-keyless') 'Keyless endpoint did not receive Pi placeholder key.'
    Assert-True ((Get-Content -Raw -LiteralPath $path) -notmatch 'dummy') 'Stored credential material leaked into Pi models.json.'

    Write-Host 'PASS: Pi catalog maps Gemini/Anthropic/keyless endpoints and keeps credentials behind the DPAPI bridge.'
} finally {
    $env:LOCALAPPDATA=$oldLocal
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

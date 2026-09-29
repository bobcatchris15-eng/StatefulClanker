$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$harness=Join-Path $repo 'StatefulClanker.ps1'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "PLANNING PREFLIGHT TEST FAILED: $Message"}}
function Write-Json([string]$Path,$Value){$Value|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $Path -Encoding UTF8}
function Invoke-Preflight([string]$Plan,[string]$Intent){
    $raw=& $harness plan preflight -Path $Plan -SourceRef $Intent 2>&1|Out-String
    return $raw
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-planning-preflight-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try{
    Push-Location $temp
    & $harness init|Out-Null
    & $harness goal -Message 'Exercise planning candidate preflight.'|Out-Null

    $intentPath=Join-Path $temp 'intent-valid.json'
    Write-Json $intentPath ([pscustomobject]@{
        objective='Exercise planning candidate preflight.'
        requirements=@([pscustomobject]@{id='REQ-VALID';kind='requirement';text='Create the bounded behavior.';source='human:test';authority='human'})
        constraints=@();invariants=@();nonGoals=@();decisions=@();preferences=@();openQuestions=@()
        successDefinition='The bounded behavior is observable.'
    })
    $valid=Join-Path $temp 'valid.scplan'
    @'
SCPLAN 1
plan valid-preflight
task t-valid
title Create bounded behavior
instruction Create the bounded behavior.
intent REQ-VALID
accept bounded behavior exists
end
'@|Set-Content -LiteralPath $valid -Encoding UTF8
    $result=Invoke-Preflight $valid $intentPath|ConvertFrom-Json
    Assert-True ([bool]$result.valid) 'Valid candidate did not pass preflight.'
    Assert-True ([int]$result.taskCount-eq1) 'Valid candidate task count is wrong.'

    $missing=Join-Path $temp 'missing-ref.scplan'
    (Get-Content -Raw $valid).Replace('REQ-VALID','REQ-MISSING')|Set-Content -LiteralPath $missing -Encoding UTF8
    $failed=$false
    try{[void](Invoke-Preflight $missing $intentPath)}catch{$failed=$_.Exception.Message -match 'missing Intent'}
    Assert-True $failed 'Dangling task Intent ref was accepted.'

    $noProof=Join-Path $temp 'no-proof.scplan'
    @'
SCPLAN 1
plan no-proof
task t-no-proof
title Unprovable task
instruction Do something without an acceptance surface.
intent REQ-VALID
end
'@|Set-Content -LiteralPath $noProof -Encoding UTF8
    $failed=$false
    try{[void](Invoke-Preflight $noProof $intentPath)}catch{$failed=$_.Exception.Message -match 'no acceptance/proof surface'}
    Assert-True $failed 'Task without proof surface was accepted.'

    $badIntent=Join-Path $temp 'intent-unprovenanced.json'
    Write-Json $badIntent ([pscustomobject]@{
        objective='Exercise planning candidate preflight.'
        requirements=@('REQ-VALID: planner prose masquerading as authority')
        constraints=@();invariants=@();nonGoals=@();decisions=@();preferences=@();openQuestions=@()
        successDefinition='The bounded behavior is observable.'
    })
    $failed=$false
    try{[void](Invoke-Preflight $valid $badIntent)}catch{$failed=$_.Exception.Message -match 'unprovenanced string'}
    Assert-True $failed 'Unprovenanced staged Intent entry was accepted.'

    Write-Host 'PASS: planning candidate preflight enforces graph proof, traceability, and staged Intent provenance.'
}finally{
    Pop-Location -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

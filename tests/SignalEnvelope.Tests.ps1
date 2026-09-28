$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "SIGNAL ENVELOPE TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-signals-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try{
    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Signals.ps1')
    Set-SCRoots $temp $temp
    New-Item -ItemType Directory -Force -Path (Join-Path $temp '.statefulclanker')|Out-Null
    Write-SCJson (Get-SCPath 'state.json') ([ordered]@{schemaVersion=4;projectId='test'})
    $task=[pscustomobject]@{id='t-1';title='test';instruction='do';acceptance=@();dependsOn=@();relations=@();retrieval=@();evidence=@();provider=$null;role='worker';humanGate=$false}
    Write-SCJson (Get-SCPath 'tasks/t-1.json') $task
    $signal=New-SCSignalEnvelope -Domain execution -Kind validator_rejection -Source @{component='validator';taskId='t-1'} -Subject @{type='task';id='t-1'} -Audience @(@{type='task';id='t-1';qualifier='next_attempt'}) -Authority corrective -Scope task -Freshness @{taskDefinitionHash=Get-SCTaskDefinitionHash $task} -Payload @{reasonCode='ACCEPTANCE_FAILED';summary='missing artifact'}
    Write-SCSignal $signal|Out-Null
    $read=@(Read-SCSignals execution 10)
    Assert-True ($read.Count-eq1) 'round trip count was wrong'
    Assert-True ([string]$read[0].id-eq[string]$signal.id) 'signal id changed during persistence'
    Assert-True (@(Get-SCSignalsForAudience task 't-1' 'next_attempt').Count-eq1) 'addressed lookup failed'
    Assert-True ([bool](Test-SCSignalFreshness $read[0] $task).fresh) 'unchanged task signal was stale'
    $expired=New-SCSignalEnvelope -Domain execution -Kind attempt_failed -Source @{component='worker'} -Subject @{type='task';id='t-1'} -Audience @(@{type='task';id='t-1'}) -Authority observed -Scope attempt -Freshness @{expiresAt=[datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o')} -Payload @{}
    Assert-True (-not[bool](Test-SCSignalFreshness $expired $task).fresh) 'expired signal remained fresh'
    $failed=$false
    try{New-SCSignalEnvelope -Domain execution -Kind bad -Source @{component='worker'} -Subject @{type='task';id='t-1'} -Audience @() -Authority observed -Scope task -Payload @{}|Out-Null}catch{$failed=$true}
    Assert-True $failed 'empty audience was accepted'
    Write-Host 'PASS: addressed execution signal scaffold.'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}

$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "CONTROL EVENT LEVEL TEST FAILED: $Message"}}
function Add-SCEvent([string]$Type,[string]$Text,$Data=$null){}
. (Join-Path $repo 'lib\StatefulClanker.Eventing.ps1')

Write-Host '  CONTROL LEVEL 1: normal lifecycle events remain durable FYI, not injected orchestrator work'
foreach($type in @('task.completed','state.proposal_rejected','task.retried','task.retried.transient')){
    Assert-True ((Get-SCControlEventLevel $type) -eq 'fyi') "$type incorrectly wakes the orchestrator."
}

Write-Host '  CONTROL LEVEL 2: plan repair remains actionable'
Assert-True ((Get-SCControlEventLevel 'task.plan_repair_required') -eq 'attention') 'Plan repair did not remain actionable.'
Write-Host 'PASS: control-event levels distinguish durable lifecycle history from orchestration work.'

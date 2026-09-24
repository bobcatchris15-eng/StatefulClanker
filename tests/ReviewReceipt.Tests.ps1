$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
. (Join-Path $repo 'lib\StatefulClanker.Execution.ps1')

function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "REVIEW RECEIPT TEST FAILED: $Message"}}
function Add-SCEvent { param($Type,$Message,$Data) }
function Get-SCConfig { return [pscustomobject]@{providers=[pscustomobject]@{}} }
function New-SCReviewPrompt { param($Task,$Run,$Compilation,$Stage); return 'review' }
function Get-SCPath { param([string]$Child); return $Child }
function Write-SCJson { param([string]$Path,$Value); $script:savedReceipt=$Value }
function Set-SCTelemetryVerdict { param([string]$AgentId,[string]$Verdict); $script:telemetryVerdict=$Verdict }
function Invoke-SCProvider {
    param($Task,$Prompt,$Stage,$ProviderOverride,$ParentAgentId,$Compilation,$WorkerSessionId,$ContinuationMessage,$EndpointOverride,$ConnectionOverride)
    return [pscustomobject]@{id='review-1';agentId='agent-1';exitCode=0;stdout='VERDICT: PASS';stderr=''}
}

$task=[pscustomobject]@{id='task-1'}
$run=[pscustomobject]@{agentId='worker-1';provider=$null}
$compilation=[pscustomobject]@{id='compile-1'}
$receipt=Invoke-SCReview $task $run $compilation 'validator'
Assert-True ($receipt.verdict-eq'PASS') 'Missing verdict property was not added to provider receipt.'
Assert-True ($script:savedReceipt.verdict-eq'PASS') 'Persisted review receipt lacks the parsed verdict.'
Assert-True ($script:telemetryVerdict-eq'PASS') 'Telemetry did not receive the parsed verdict.'
Write-Host 'PASS: validator review accepts a provider receipt without a predeclared verdict property.'

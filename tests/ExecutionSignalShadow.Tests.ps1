$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "EXECUTION SIGNAL TEST FAILED: $Message"}}
$execution=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.Execution.ps1')
$signals=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.Signals.ps1')
Assert-True ($signals.Contains('function Publish-SCExecutionSignal')) 'execution signal publisher missing'
Assert-True ($signals.Contains('function Publish-SCValidationSignal')) 'validation signal publisher missing'
Assert-True ($execution.Contains('Publish-SCValidationSignal $Task $receipt $Compilation')) 'validation receipts are not shadow-signaled'
Assert-True ($execution.Contains("worker_run_completed")) 'successful worker runs are not shadow-signaled'
Assert-True ($execution.Contains("worker_run_failed")) 'failed worker runs are not shadow-signaled'
Assert-True ($execution.Contains("-Kind context_requested")) 'context requests are not addressed to future attempts'
Assert-True ($execution.Contains("-Kind candidate_empty")) 'candidate preflight failures are not shadow-signaled'
Write-Host 'PASS: worker lifecycle emits shadow execution signals without replacing current receipts.'

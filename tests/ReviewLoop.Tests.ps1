$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "REVIEW LOOP TEST FAILED: $Message"}}

$execution=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.Execution.ps1')
$runtime=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')
$compiled=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.CompiledRouting.ps1')

$start=$execution.IndexOf('function Invoke-SCTask(')
$end=$execution.IndexOf('function Retry-SCTask',$start)
Assert-True ($start-ge0-and$end-gt$start) 'Could not isolate Invoke-SCTask.'
$taskLoop=$execution.Substring($start,$end-$start)

Write-Host '  REVIEW 1: ordinary task completion enters one acceptance gate, not an unconditional model review'
Assert-True ($taskLoop.Contains('Invoke-SCAcceptanceValidation $task $run $compilation')) 'Invoke-SCTask does not call the acceptance gate.'
Assert-True (-not$taskLoop.Contains('Invoke-SCReview $task $run $compilation ''critic''')) 'Invoke-SCTask still calls the critic.'

Write-Host '  REVIEW 2: validator failure returns to the same direct worker session'
Assert-True ($taskLoop.Contains('VALIDATOR REJECTED CANDIDATE')) 'Validator feedback continuation is missing.'
Assert-True ($taskLoop.Contains('worker.session_repair')) 'Same-session repair event is missing.'
Assert-True ($taskLoop.Contains('Get-SCReusableWorkerSessionId')) 'Task dispatch does not attempt to reuse an unfinished worker session.'

Write-Host '  REVIEW 3: direct sessions prefer their prior endpoint while compiled routing owns migration'
Assert-True ($runtime.Contains('function Set-SCWorkerSessionRoutePin')) 'Worker route pin helper is missing.'
Assert-True ($runtime.Contains('function Get-SCWorkerSessionRoutePin')) 'Worker route pin reader is missing.'
Assert-True ($compiled.Contains('Get-SCWorkerSessionRoutePin $WorkerSessionId')) 'Compiled router bridge does not consult the session endpoint preference.'
Assert-True ($compiled.Contains('Set-SCWorkerSessionRoutePin $WorkerSessionId')) 'Successful compiled routing does not update the session route preference.'
Assert-True ($compiled.Contains('routing.failover_succeeded')) 'Compiled route migration does not emit a failover-success event.'

Write-Host '  REVIEW 4: operator routing hints propagate through worker and validator'
Assert-True ($taskLoop.Contains('$EndpointOverride $ConnectionOverride')) 'Task routing hints are not propagated through the task cycle.'
Assert-True ($compiled.Contains('--connection')) 'Connection-level routing hint is not passed to the compiled router.'
Assert-True ($compiled.Contains('--strict-preferred')) 'Exact endpoint routing is not strict.'

Write-Host '  REVIEW 5: cold workers have a high turn ceiling'
Assert-True ($runtime.Contains('$hardCap=1024')) 'Direct worker hard ceiling is not 1024.'
Assert-True ($runtime.Contains("'small'{512}")) 'Small cold worker floor is not 512.'

Write-Host '  REVIEW 6: stagnation warning fires once when crossing the threshold'
Assert-True ($execution.Contains('if($same.Count-eq$threshold)')) 'Stagnation warning does not use threshold-crossing semantics.'
Assert-True (-not$execution.Contains('if($same.Count-ge$threshold)')) 'Stagnation warning still repeats on every non-advancing attempt after the threshold.'

Write-Host 'PASS: task acceptance is mechanical-first; direct sessions resume; compiled routing owns migration/operator pins; stagnation warnings are edge-triggered.'

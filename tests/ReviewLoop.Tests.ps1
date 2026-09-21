$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "REVIEW LOOP TEST FAILED: $Message"}}

$execution=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.Execution.ps1')
$runtime=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')

$start=$execution.IndexOf('function Invoke-SCTask([string]$RequestedTaskId,[string]$ProviderOverride) {')
$end=$execution.IndexOf('function Retry-SCTask',$start)
Assert-True ($start-ge0-and$end-gt$start) 'Could not isolate Invoke-SCTask.'
$taskLoop=$execution.Substring($start,$end-$start)

Write-Host '  REVIEW 1: ordinary task completion has one model review stage'
Assert-True ($taskLoop.Contains("Invoke-SCReview `$task `$run `$compilation 'validator'")) 'Invoke-SCTask does not call the validator.'
Assert-True (-not$taskLoop.Contains("Invoke-SCReview `$task `$run `$compilation 'critic'")) 'Invoke-SCTask still calls the critic.'

Write-Host '  REVIEW 2: validator failure returns to the same direct worker session'
Assert-True ($taskLoop.Contains('VALIDATOR REJECTED CANDIDATE')) 'Validator feedback continuation is missing.'
Assert-True ($taskLoop.Contains('worker.session_repair')) 'Same-session repair event is missing.'
Assert-True ($taskLoop.Contains('Get-SCReusableWorkerSessionId')) 'Task dispatch does not attempt to reuse an unfinished worker session.'

Write-Host '  REVIEW 3: resumed direct sessions are endpoint/model pinned'
Assert-True ($runtime.Contains('function Set-SCWorkerSessionRoutePin')) 'Worker route pin helper is missing.'
Assert-True ($runtime.Contains('function Get-SCWorkerSessionRoutePin')) 'Worker route pin reader is missing.'
Assert-True ($runtime.Contains('The session will not migrate to another endpoint.')) 'Pinned-session routing does not fail closed against migration.'

Write-Host '  REVIEW 4: cold workers have a high turn ceiling'
Assert-True ($runtime.Contains('$hardCap=1024')) 'Direct worker hard ceiling is not 1024.'
Assert-True ($runtime.Contains("'small'{128}")) 'Small cold worker floor is not 128.'

Write-Host 'PASS: ordinary task review is validator-only; failures resume the pinned worker session; cold-worker turn budget is raised.'

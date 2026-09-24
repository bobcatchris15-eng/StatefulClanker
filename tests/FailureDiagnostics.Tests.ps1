$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "FAILURE DIAGNOSTICS TEST FAILED: $Message"}}

. (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')
$script:responses=@('not json','{bad json','{"final":"recovered"}')
$script:responseIndex=0
$script:seenMessages=@()
function Get-SCEffectiveWorkerToolMode { return 'text' }
function Get-SCWorkerMaxSteps { return 5 }
function Get-SCWorkerToolRecords { return @([pscustomobject]@{wireName='finish';capability='builtin.finish';definition=@{}}) }
function Get-SCConnectionProtocol { return 'openai-chat' }
function Invoke-SCApiChat {
    param($Connection,$Messages,$Tools,$ToolMode)
    $script:seenMessages=@($Messages)
    return [pscustomobject]@{answer=$script:responses[$script:responseIndex++]}
}
function Add-SCApiUsage { }
function Get-SCAssistantMessage { param($Response,$Protocol);return [pscustomobject]@{content=$Response.answer} }
function Add-SCEvent { param($Type,$Message,$Data);$script:lastToolEvent=[pscustomobject]@{type=$Type;message=$Message;data=$Data} }

Write-Host '  FAILURE DIAGNOSTICS 1: malformed text-tool turns receive repair feedback before failure'
$result=Invoke-SCDirectWorkerLoop ([pscustomobject]@{}) 'prompt' ([pscustomobject]@{id='t-test'}) 'run'
Assert-True ($result-eq'recovered') 'Text-tool worker did not recover after malformed JSON.'
Assert-True (@($script:seenMessages|Where-Object{[string]$_.content -like 'TOOL_PROTOCOL_ERROR:*'}).Count-eq2) 'Malformed responses were not returned to the worker as repair feedback.'

Write-Host '  FAILURE DIAGNOSTICS 2: tool errors are durable and attributable'
Write-SCWorkerToolFailure ([pscustomobject]@{id='t-test'}) 'run' 'write_file' 'TOOL_ERROR: malformed arguments' 4
Assert-True ($script:lastToolEvent.type-eq'worker.tool_error') 'Tool failure event was not recorded.'
Assert-True ($script:lastToolEvent.data.tool-eq'write_file' -and $script:lastToolEvent.data.step-eq4) 'Tool failure lacks tool and step context.'

Write-Host '  FAILURE DIAGNOSTICS 3: request faults require diagnosis, not blind autofill retry'
$execution=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.Execution.ps1')
Assert-True ($execution.Contains("'diagnose-request'")) 'Endpoint request faults are not marked for diagnosis.'
Assert-True ($execution.Contains('routing.request_diagnosis_required')) 'Endpoint request fault event is missing.'
Assert-True ($execution.Contains('validator.request_diagnosis_required')) 'Validator request fault event is missing.'
$ui=Get-Content -Raw -LiteralPath (Join-Path $repo 'src\StatefulClanker.Tray\Program.cs')
Assert-True ($ui.Contains('[LATEST ENDPOINT / HARNESS ERROR]')) 'Task detail does not expose the latest routing error.'
Write-Host 'PASS: malformed tool output gets bounded repair and request faults surface for investigation.'

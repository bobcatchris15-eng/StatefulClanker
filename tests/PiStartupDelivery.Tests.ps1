$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "PI STARTUP DELIVERY TEST FAILED: $Message"}}

$extension=Get-Content -Raw -LiteralPath (Join-Path $repo 'pi\extensions\statefulclanker.ts')

Write-Host '  PI STARTUP DELIVERY 1: curated operator guidance reaches the system prompt'
Assert-True ($extension.Contains('PI_OPERATOR_BOOT_GUIDANCE,')) 'Bundled Pi no longer injects curated operator guidance into the system prompt.'
$guidance=[regex]::Match($extension,'(?s)const PI_OPERATOR_BOOT_GUIDANCE = \[(.*?)\]\.join')
Assert-True $guidance.Success 'Curated boot guidance is missing.'
Assert-True ($guidance.Value.Length -lt 2500) 'Boot guidance grew beyond the startup budget.'
foreach($tool in @('control_snapshot','autofill_status','task_list','task_show','task_recovery_context')){
    Assert-True ($guidance.Value.Contains($tool)) "Boot guidance omits $tool."
}

$bundledNode=Join-Path $repo 'install\pi-runtime\node.exe'
if(Test-Path -LiteralPath $bundledNode){
    Write-Host '  PI STARTUP DELIVERY 1b: bundled runtime receives the guide without a custom message'
    & $bundledNode (Join-Path $repo 'tests\PiStartupDelivery.Runtime.mjs')
    if($LASTEXITCODE-ne0){throw "Pi startup runtime check failed with exit code $LASTEXITCODE."}
}

Write-Host '  PI STARTUP DELIVERY 2: startup never queues a serialized operator manual into the interactive conversation'
Assert-True (-not $extension.Contains('statefulclanker-operator-manual')) 'Bundled Pi queues the full operator manual as an interactive custom message.'
Assert-True (-not $extension.Contains('queueOperatorManual')) 'Bundled Pi still has a startup path that queues the operator manual.'

Write-Host 'PASS: Pi injects a curated boot guide through the system prompt without queueing a large custom message.'

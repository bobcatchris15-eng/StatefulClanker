$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ROUTER ATTEMPT USAGE TEST FAILED: $Message"}}
function Invoke-SCProvider { throw 'CLI base should not be called.' }
. (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')
function New-TestAccumulator { return @{fallbackModel='fallback';apiRequests=0L;usageReports=0L;promptTokens=0L;completionTokens=0L;totalTokens=0L;modelUsage=@{};routeAttempts=0;routeHistory=@()} }
$attempts=@(
    [pscustomobject]@{endpoint='a';maxOutputTokens=100;usage=[pscustomobject]@{model='model-a';promptTokens=10;completionTokens=2;totalTokens=12;reported=$true};response=$null;diagnosis=$null},
    [pscustomobject]@{endpoint='a';maxOutputTokens=50;usage=[pscustomobject]@{model='model-a';promptTokens=0;completionTokens=0;totalTokens=0;reported=$false};response=$null;diagnosis=$null},
    [pscustomobject]@{endpoint='b';maxOutputTokens=100;usage=[pscustomobject]@{model='model-b';promptTokens=20;completionTokens=3;totalTokens=23;reported=$true};response=$null;diagnosis=$null}
)
$history=@([pscustomobject]@{endpoint='a'},[pscustomobject]@{endpoint='b'})
$response=[pscustomobject]@{model=$null;usage=[pscustomobject]@{prompt_tokens=30;completion_tokens=5;total_tokens=35};routerInferenceAttempts=$attempts;routerEndpoint='b';routerConnection='pool';routerModel='model-b';routerRouteAttempts=2;routerRouteHistory=$history}
$acc=New-TestAccumulator
Add-SCApiUsage $acc $response
Assert-True ($acc.apiRequests-eq3 -and $acc.usageReports-eq2) 'Every inference attempt must count once, with only two reported usages.'
Assert-True ($acc.promptTokens-eq30 -and $acc.completionTokens-eq5 -and $acc.totalTokens-eq35) 'Aggregate wrapper must not double-count attempt tokens.'
Assert-True ($acc.modelUsage['model-a'].requests-eq2 -and $acc.modelUsage['model-a'].usageReports-eq1 -and $acc.modelUsage['model-a'].totalTokens-eq12) 'First model retry usage must retain actual model attribution.'
Assert-True ($acc.modelUsage['model-b'].requests-eq1 -and $acc.modelUsage['model-b'].totalTokens-eq23 -and -not$acc.modelUsage.ContainsKey('fallback')) 'Mixed models must not be attributed to fallback model.'
Assert-True ($acc.routeAttempts-eq2 -and $acc.routeHistory.Count-eq2 -and $acc.lastEndpoint-eq'b') 'Route history must be accumulated once per router result.'
$empty=New-TestAccumulator
Add-SCApiUsage $empty ([pscustomobject]@{routerInferenceAttempts=@();usage=[pscustomobject]@{total_tokens=999}})
Assert-True ($empty.apiRequests-eq0 -and $empty.usageReports-eq0 -and $empty.totalTokens-eq0) 'No inference attempts must not create a phantom API call or count aggregate usage.'
$legacy=New-TestAccumulator
Add-SCApiUsage $legacy ([pscustomobject]@{usage=[pscustomobject]@{input_tokens=4;output_tokens=1}})
Assert-True ($legacy.apiRequests-eq1 -and $legacy.usageReports-eq1 -and $legacy.totalTokens-eq5 -and $legacy.modelUsage['fallback'].totalTokens-eq5) 'Legacy usage must retain single-call accounting.'
$failed=New-TestAccumulator
Add-SCRouterInferenceUsage $failed ([pscustomobject]@{inferenceAttempts=$attempts;routeAttempts=2;routeHistory=$history})
Assert-True ($failed.apiRequests-eq3 -and $failed.totalTokens-eq35 -and $failed.routeAttempts-eq0 -and $failed.routeHistory.Count-eq0) 'Failed inference usage must not duplicate receipt diagnostic route history.'
Write-Host 'PASS: router attempts account requests, reports, models and tokens without duplicate routes.'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-attempt-usage-'+[guid]::NewGuid().ToString('N'))
function Get-SCPath([string]$Name){return $temp}
function Get-SCProjectSessionId { return 'usage-test' }
function New-SCId([string]$Prefix){return "$Prefix-test"}
function Invoke-SCCompiledRouterCommand { return $script:routerResult }
$script:routerResult=[pscustomobject]@{ok=$true;data=[pscustomobject]@{ok=$true;usage=[pscustomobject]@{model=$null;promptTokens=30;completionTokens=5;totalTokens=35};model='model-b';endpoint='b';connection='pool';routeAttempts=2;routeHistory=$history;inferenceAttempts=$attempts;signalRef='test';assistant=[pscustomobject]@{content='done';tool_calls=@()}}}
try{
    $connection=[pscustomobject]@{model='fallback';maxTokens=100}
    $provider=[pscustomobject]@{name='router:auto';config=[pscustomobject]@{routerManaged=$true}}
    $bridged=Invoke-SCApiChat $connection @() @() 'text' $provider
    $bridgeUsage=New-TestAccumulator
    Add-SCApiUsage $bridgeUsage $bridged
    Assert-True ($bridgeUsage.apiRequests-eq3 -and $bridgeUsage.totalTokens-eq35) 'Router bridge must preserve attempt usage for the accumulator.'
    $script:routerResult.data.PSObject.Properties.Remove('inferenceAttempts')
    $legacyBridge=Invoke-SCApiChat $connection @() @() 'text' $provider
    $legacyBridgeUsage=New-TestAccumulator
    Add-SCApiUsage $legacyBridgeUsage $legacyBridge
    Assert-True ($legacyBridgeUsage.apiRequests-eq1 -and $legacyBridgeUsage.totalTokens-eq35) 'Older router results without attempts must remain compatible.'
}finally{
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
Write-Host 'PASS: inference bridge preserves attempt accounting and older router compatibility.'

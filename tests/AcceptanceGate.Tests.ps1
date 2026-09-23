$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ACCEPTANCE GATE TEST FAILED: $Message"}}

. (Join-Path $repo 'lib\StatefulClanker.Execution.ps1')

# Harness-independent stubs for gate policy tests.
function Add-SCEvent { param($Type,$Message,$Data) }
function Get-SCPath { param([string]$Child); return (Join-Path ([IO.Path]::GetTempPath()) $Child.Replace('/','\')) }
function Write-SCJson { param([string]$Path,$Value) }
function Set-SCProperty { param($Object,[string]$Name,$Value); if($Object.PSObject.Properties[$Name]){$Object.$Name=$Value}else{$Object|Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force} }

$task=[pscustomobject]@{id='t';title='task';instruction='do thing';acceptance=@('thing works');checks=@('dummy');semanticAcceptance=@()}
$run=[pscustomobject]@{id='r';exitCode=0;stdout='worker report';stderr=''}
$comp=[pscustomobject]@{id='c';ir=[pscustomobject]@{project=[pscustomobject]@{intent=[pscustomobject]@{contract=[pscustomobject]@{objective='x'}}}}}

Write-Host '  ACCEPTANCE 1: mechanical-only PASS performs zero inference'
$script:fallbackCalls=0
function Invoke-SCMechanicalAcceptance { param($Task); [pscustomobject]@{configured=$true;passed=$true;count=2;failed=0;checks=@()} }
function New-SCSyntheticValidationReceipt { param($Task,$Run,$Compilation,$Verdict,$Kind,$Summary,$Evidence); [pscustomobject]@{id='v1';verdict=$Verdict;validationKind=$Kind;stdout=$Summary;stderr='';exitCode=0} }
function Invoke-SCReview { $script:fallbackCalls++; throw 'fallback validator should not run' }
$v=Invoke-SCAcceptanceValidation $task $run $comp
Assert-True ($v.verdict-eq'PASS' -and $v.validationKind-eq'mechanical') 'Passing mechanical-only task did not accept mechanically.'
Assert-True ($script:fallbackCalls-eq0) 'Passing mechanical-only task invoked inference.'

Write-Host '  ACCEPTANCE 2: mechanical FAIL performs zero inference'
function Invoke-SCMechanicalAcceptance { param($Task); [pscustomobject]@{configured=$true;passed=$false;count=1;failed=1;checks=@([pscustomobject]@{index=1;exitCode=7;timedOut=$false;command='bad'})} }
$v=Invoke-SCAcceptanceValidation $task $run $comp
Assert-True ($v.verdict-eq'FAIL' -and $v.validationKind-eq'mechanical') 'Failing mechanical task did not fail mechanically.'
Assert-True ($script:fallbackCalls-eq0) 'Failing mechanical task invoked inference.'

Write-Host '  ACCEPTANCE 3: decisive Jev result avoids routed validator'
$task.semanticAcceptance=@('semantic requirement')
function Invoke-SCMechanicalAcceptance { param($Task); [pscustomobject]@{configured=$true;passed=$true;count=1;failed=0;checks=@()} }
function Invoke-SCJevAcceptance { param($Task,$Run,$Compilation,$Mechanical); [pscustomobject]@{available=$true;verdict='PASS';model='jev-test';decisions=@([pscustomobject]@{criterion='semantic requirement';probabilitySatisfied=.98;decision='pass'});usage=$null} }
$v=Invoke-SCAcceptanceValidation $task $run $comp
Assert-True ($v.verdict-eq'PASS' -and $v.validationKind-eq'jev') 'Decisive Jev result was not used.'
Assert-True ($script:fallbackCalls-eq0) 'Decisive Jev result invoked routed fallback.'

Write-Host '  ACCEPTANCE 4: unavailable Jev falls back to ordinary routed validator'
function Invoke-SCJevAcceptance { param($Task,$Run,$Compilation,$Mechanical); [pscustomobject]@{available=$false;reason='no key'} }
function Invoke-SCReview { param($Task,$Run,$Compilation,$Stage,$EndpointOverride,$ConnectionOverride); $script:fallbackCalls++; [pscustomobject]@{id='vf';verdict='PASS';validationKind='routed';stdout='VERDICT: PASS';stderr='';exitCode=0} }
$v=Invoke-SCAcceptanceValidation $task $run $comp
Assert-True ($v.verdict-eq'PASS' -and $script:fallbackCalls-eq1) 'Unavailable Jev did not fall back exactly once.'

Write-Host '  ACCEPTANCE 5: uncertain Jev falls back to ordinary routed validator'
function Invoke-SCJevAcceptance { param($Task,$Run,$Compilation,$Mechanical); [pscustomobject]@{available=$true;verdict='UNCERTAIN';model='jev-test';decisions=@()} }
$v=Invoke-SCAcceptanceValidation $task $run $comp
Assert-True ($v.verdict-eq'PASS' -and $script:fallbackCalls-eq2) 'Uncertain Jev did not fall back exactly once.'

Write-Host 'PASS: mechanical acceptance owns deterministic outcomes; Jev is preferred for semantic decisions; routed inference is fallback only.'

param([Parameter(Mandatory=$true)][string]$PromptFile)
$prompt = Get-Content -Raw -LiteralPath $PromptFile
if ($prompt -match 'You are the critic in StatefulClanker') {
    Write-Output 'VERDICT: PASS'
    Write-Output 'Mock critic accepted the worker receipt.'
    exit 0
}
if ($prompt -match 'You are the validator in StatefulClanker') {
    Write-Output 'VERDICT: PASS'
    Write-Output 'Mock validator accepted the evidence.'
    exit 0
}
Write-Output 'Mock worker completed the bounded task.'
exit 0

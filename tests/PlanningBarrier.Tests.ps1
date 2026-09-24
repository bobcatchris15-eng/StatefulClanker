$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-planning-barrier-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $temp 'planning')|Out-Null

function Assert-SCInitialized {}
function Get-SCPath([string]$Child){Join-Path $temp $Child}
function Test-SCDirectivesReconciled { $true }
function Get-SCState { [pscustomobject]@{pendingDirectiveIds=@()} }
function Invoke-SCTask {}
function Invoke-SCParallel {}

. (Join-Path $repo 'lib\StatefulClanker.DispatchGuard.ps1')

try {
    Assert-SCDispatchAuthority

    '{"schemaVersion":1,"sessionId":"planning-test","phase":"planning"}' |
        Set-Content -LiteralPath (Join-Path $temp 'planning\active.json') -Encoding UTF8

    $blocked=$false
    try { Assert-SCDispatchAuthority }
    catch { $blocked=$_.Exception.Message -match 'planning session' }
    if(-not$blocked){throw 'Planning barrier did not block dispatch.'}

    '{not-json' |
        Set-Content -LiteralPath (Join-Path $temp 'planning\active.json') -Encoding UTF8

    $failedClosed=$false
    try { Assert-SCDispatchAuthority }
    catch { $failedClosed=$_.Exception.Message -match 'unreadable' }
    if(-not$failedClosed){throw 'Malformed planning barrier did not fail closed.'}

    Write-Host 'PASS: planning barrier blocks dispatch and fails closed.'
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

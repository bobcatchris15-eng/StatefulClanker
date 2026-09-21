$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$script:StatefulClankerHome=$repo
. (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
. (Join-Path $repo 'lib\StatefulClanker.Context.ps1')
. (Join-Path $repo 'lib\StatefulClanker.ReflexiveKnowledge.ps1')

$null=Invoke-SCRpk 'status' @{} -AllowUnavailable
Write-Host 'PASS: reflexive knowledge host resolution does not assign the read-only $Host variable'

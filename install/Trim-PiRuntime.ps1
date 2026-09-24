[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RuntimeDir)

$ErrorActionPreference = 'Stop'
$runtime = (Resolve-Path -LiteralPath $RuntimeDir).Path
$platformDir = Join-Path $runtime 'node_modules\@earendil-works\pi-coding-agent\node_modules\@esbuild'
if (-not (Test-Path -LiteralPath $platformDir -PathType Container)) {
    throw "Pi's esbuild platform directory is missing: $platformDir"
}
$platformDir = (Resolve-Path -LiteralPath $platformDir).Path
$windowsBinary = Join-Path $platformDir 'win32-x64\esbuild.exe'
if (-not (Test-Path -LiteralPath $windowsBinary -PathType Leaf)) {
    throw "Pi's Windows x64 esbuild binary is missing: $windowsBinary"
}

$removedBytes = [long]0
foreach ($entry in Get-ChildItem -LiteralPath $platformDir -Directory) {
    if ($entry.Name -eq 'win32-x64') { continue }
    if ($entry.Parent.FullName -ne $platformDir) { throw "Unexpected platform path: $($entry.FullName)" }
    $removedBytes += (Get-ChildItem -LiteralPath $entry.FullName -Recurse -File | Measure-Object Length -Sum).Sum
    Remove-Item -LiteralPath $entry.FullName -Recurse -Force
}

Write-Host "  Removed $([math]::Round($removedBytes / 1MB, 1)) MB of non-Windows esbuild binaries."

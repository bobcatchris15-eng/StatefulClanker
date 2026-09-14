<# Build the StatefulClanker Windows installer.

   Generates the application icon, then compiles install\StatefulClanker.iss with
   Inno Setup. Output lands in install\output\StatefulClankerSetup-<version>.exe

   Requires Inno Setup 6:  winget install JRSoftware.InnoSetup
#>
[CmdletBinding()]
param(
    [string]$Version = '0.5.0',
    [switch]$IconOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$installDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $installDir
$iconPath = Join-Path $installDir 'StatefulClanker.ico'
$issPath = Join-Path $installDir 'StatefulClanker.iss'
$outDir = Join-Path $installDir 'output'

# ------------------------------------------------------------------- icon ----
function New-GlyphBitmap([int]$Size) {
    $bmp = New-Object Drawing.Bitmap $Size, $Size
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([Drawing.Color]::Transparent)
    $s = $Size / 32.0
    $brush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(69, 90, 100))
    $g.FillEllipse($brush, (1 * $s), (1 * $s), (30 * $s), (30 * $s))
    $pen = New-Object Drawing.Pen ([Drawing.Color]::White), (2.5 * $s)
    $g.DrawLine($pen, (11 * $s), (9 * $s), (8 * $s), (9 * $s))
    $g.DrawLine($pen, (8 * $s), (9 * $s), (8 * $s), (23 * $s))
    $g.DrawLine($pen, (8 * $s), (23 * $s), (11 * $s), (23 * $s))
    $g.DrawLine($pen, (21 * $s), (9 * $s), (24 * $s), (9 * $s))
    $g.DrawLine($pen, (24 * $s), (9 * $s), (24 * $s), (23 * $s))
    $g.DrawLine($pen, (24 * $s), (23 * $s), (21 * $s), (23 * $s))
    $white = New-Object Drawing.SolidBrush ([Drawing.Color]::White)
    $g.FillEllipse($white, (14 * $s), (14 * $s), (5 * $s), (5 * $s))
    $white.Dispose(); $pen.Dispose(); $brush.Dispose(); $g.Dispose()
    return $bmp
}

<# Write a multi-resolution .ico. Each entry is a PNG payload, which Windows has
   accepted since Vista and which avoids hand-rolling DIB masks. #>
function New-IcoFile([string]$Path, [int[]]$Sizes) {
    $pngs = @()
    foreach ($size in $Sizes) {
        $bmp = New-GlyphBitmap $size
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $pngs += , $ms.ToArray()
        $ms.Dispose(); $bmp.Dispose()
    }
    $fs = [IO.File]::Create($Path)
    try {
        $bw = New-Object IO.BinaryWriter $fs
        $bw.Write([uint16]0)                 # reserved
        $bw.Write([uint16]1)                 # type: icon
        $bw.Write([uint16]$Sizes.Count)
        $offset = 6 + (16 * $Sizes.Count)
        for ($i = 0; $i -lt $Sizes.Count; $i++) {
            $dim = if ($Sizes[$i] -ge 256) { 0 } else { $Sizes[$i] }
            $bw.Write([byte]$dim)            # width  (0 means 256)
            $bw.Write([byte]$dim)            # height
            $bw.Write([byte]0)               # palette count
            $bw.Write([byte]0)               # reserved
            $bw.Write([uint16]1)             # colour planes
            $bw.Write([uint16]32)            # bits per pixel
            $bw.Write([uint32]$pngs[$i].Length)
            $bw.Write([uint32]$offset)
            $offset += $pngs[$i].Length
        }
        foreach ($png in $pngs) { $bw.Write($png) }
        $bw.Flush()
    } finally { $fs.Dispose() }
}

Write-Host "Generating icon: $iconPath"
New-IcoFile $iconPath @(16, 32, 48, 64, 128, 256)
Write-Host "  $((Get-Item $iconPath).Length) bytes"
if ($IconOnly) { return }

# --------------------------------------------------------------- compile ----
function Find-Iscc {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'Inno Setup 6 not found. Install it with: winget install JRSoftware.InnoSetup'
}

$iscc = Find-Iscc
Write-Host "Inno Setup: $iscc"
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

$isccArgs = @("/DMyAppVersion=$Version", "/DRepoRoot=$repoRoot", "/O$outDir", $issPath)
& $iscc @isccArgs
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

$setup = Get-ChildItem -LiteralPath $outDir -Filter '*.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Host ''
Write-Host "Built: $($setup.FullName)" -ForegroundColor Green
Write-Host "       $([math]::Round($setup.Length / 1KB)) KB"

<# Build the StatefulClanker Windows installer.

   Generates the application icon, publishes the native WinForms tray host as a
   self-contained win-x64 executable, then compiles the Inno Setup installer.

   Build requirements:
     - .NET 8 SDK:     winget install Microsoft.DotNet.SDK.8
     - Inno Setup 6:   winget install JRSoftware.InnoSetup

   The installed application does not require a separate .NET runtime. PowerShell
   remains required because provider/runtime orchestration is intentionally scriptable.
#>
[CmdletBinding()]
param(
    [string]$Version = '0.8.28',
    [string]$PiVersion = '0.87.0',
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
$publishDir = Join-Path $installDir 'publish'
$routerPublishDir = Join-Path $installDir 'router-publish'
$trayProject = Join-Path $repoRoot 'src\StatefulClanker.Tray\StatefulClanker.Tray.csproj'
$routerProject = Join-Path $repoRoot 'src\StatefulClanker.Router\StatefulClanker.Router.csproj'
$piRuntimeDir = Join-Path $installDir 'pi-runtime'

function New-GlyphBitmap([int]$Size) {
    $bmp = New-Object Drawing.Bitmap $Size, $Size
    $g = [Drawing.Graphics]::FromImage($bmp);$g.SmoothingMode='AntiAlias';$g.Clear([Drawing.Color]::Transparent)
    $s=$Size/32.0;$brush=New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(69,90,100));$g.FillEllipse($brush,(1*$s),(1*$s),(30*$s),(30*$s))
    $pen=New-Object Drawing.Pen ([Drawing.Color]::White),(2.5*$s)
    $g.DrawLine($pen,(11*$s),(9*$s),(8*$s),(9*$s));$g.DrawLine($pen,(8*$s),(9*$s),(8*$s),(23*$s));$g.DrawLine($pen,(8*$s),(23*$s),(11*$s),(23*$s))
    $g.DrawLine($pen,(21*$s),(9*$s),(24*$s),(9*$s));$g.DrawLine($pen,(24*$s),(9*$s),(24*$s),(23*$s));$g.DrawLine($pen,(24*$s),(23*$s),(21*$s),(23*$s))
    $white=New-Object Drawing.SolidBrush ([Drawing.Color]::White);$g.FillEllipse($white,(14*$s),(14*$s),(5*$s),(5*$s))
    $white.Dispose();$pen.Dispose();$brush.Dispose();$g.Dispose();return $bmp
}

function New-IcoFile([string]$Path,[int[]]$Sizes) {
    $pngs=@();foreach($size in $Sizes){$bmp=New-GlyphBitmap $size;$ms=New-Object IO.MemoryStream;$bmp.Save($ms,[Drawing.Imaging.ImageFormat]::Png);$pngs+=,$ms.ToArray();$ms.Dispose();$bmp.Dispose()}
    $fs=[IO.File]::Create($Path)
    try{$bw=New-Object IO.BinaryWriter $fs;$bw.Write([uint16]0);$bw.Write([uint16]1);$bw.Write([uint16]$Sizes.Count);$offset=6+(16*$Sizes.Count)
        for($i=0;$i-lt$Sizes.Count;$i++){$dim=if($Sizes[$i]-ge256){0}else{$Sizes[$i]};$bw.Write([byte]$dim);$bw.Write([byte]$dim);$bw.Write([byte]0);$bw.Write([byte]0);$bw.Write([uint16]1);$bw.Write([uint16]32);$bw.Write([uint32]$pngs[$i].Length);$bw.Write([uint32]$offset);$offset+=$pngs[$i].Length}
        foreach($png in $pngs){$bw.Write($png)};$bw.Flush()
    }finally{$fs.Dispose()}
}

Write-Host "Generating icon: $iconPath"
New-IcoFile $iconPath @(16,32,48,64,128,256)
Write-Host "  $((Get-Item $iconPath).Length) bytes"
if($IconOnly){return}

function Find-DotNet {
    $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($cmd) {
        $sdkCheck = & $cmd.Source --list-sdks 2>&1
        if ($LASTEXITCODE -eq 0 -and $sdkCheck) { return $cmd.Source }
    }
    $candidates = @()
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe') }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe') }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            $sdkCheck = & $c --list-sdks 2>&1
            if ($LASTEXITCODE -eq 0 -and $sdkCheck) { return $c }
        }
    }
    throw 'The .NET 8 SDK is required to build the native Windows host. Install: winget install Microsoft.DotNet.SDK.8'
}

$dotnetPath = Find-DotNet
if(Test-Path -LiteralPath $publishDir){Remove-Item -LiteralPath $publishDir -Recurse -Force}
New-Item -ItemType Directory -Force -Path $publishDir|Out-Null
Write-Host "Publishing native Windows host using $dotnetPath..."
& $dotnetPath publish $trayProject -c Release -r win-x64 --self-contained true -o $publishDir `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false
if($LASTEXITCODE-ne0){throw "dotnet publish failed with exit code $LASTEXITCODE"}
$appExe=Join-Path $publishDir 'StatefulClanker.exe'
if(-not(Test-Path -LiteralPath $appExe)){throw "Publish succeeded but $appExe was not produced."}
Write-Host "  Native host: $([math]::Round((Get-Item $appExe).Length/1MB,1)) MB"
if(Test-Path -LiteralPath $routerPublishDir){Remove-Item -LiteralPath $routerPublishDir -Recurse -Force}
New-Item -ItemType Directory -Force -Path $routerPublishDir|Out-Null
Write-Host "Publishing compiled router/endpoint monitor..."
& $dotnetPath publish $routerProject -c Release -r win-x64 --self-contained true -o $routerPublishDir -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false
if($LASTEXITCODE-ne0){throw "router dotnet publish failed with exit code $LASTEXITCODE"}
$routerExe=Join-Path $routerPublishDir 'StatefulClanker.Router.exe'
if(-not(Test-Path -LiteralPath $routerExe)){throw "Router publish succeeded but $routerExe was not produced."}
Write-Host "  Compiled router: $([math]::Round((Get-Item $routerExe).Length/1MB,1)) MB"

function Find-NodeTool([string]$Name) {
    $cmd=Get-Command $Name -ErrorAction SilentlyContinue
    if($cmd){return $cmd.Source}
    throw "Bundling Pi requires $Name on the build machine. Install current Node.js (20+)."
}
$nodePath=Find-NodeTool 'node'
$npmPath=Find-NodeTool 'npm'
if(Test-Path -LiteralPath $piRuntimeDir){Remove-Item -LiteralPath $piRuntimeDir -Recurse -Force}
New-Item -ItemType Directory -Force -Path $piRuntimeDir|Out-Null
Write-Host "Bundling Pi coding agent $PiVersion..."
& $npmPath install --prefix $piRuntimeDir --omit=dev --no-audit --no-fund "@earendil-works/pi-coding-agent@$PiVersion"
if($LASTEXITCODE-ne0){throw "npm install for Pi failed with exit code $LASTEXITCODE"}
Copy-Item -LiteralPath $nodePath -Destination (Join-Path $piRuntimeDir 'node.exe') -Force
$piCli=Join-Path $piRuntimeDir 'node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.js'
if(-not(Test-Path -LiteralPath $piCli)){throw "Pi package installed but CLI was not found at $piCli"}
& (Join-Path $installDir 'Trim-PiRuntime.ps1') -RuntimeDir $piRuntimeDir
& (Join-Path $piRuntimeDir 'node.exe') $piCli --version
if($LASTEXITCODE-ne0){throw "Trimmed Pi runtime failed its startup check with exit code $LASTEXITCODE"}
Write-Host "  Pi runtime: $piRuntimeDir"

function Find-Iscc {
    $candidates=@()
    if($env:LOCALAPPDATA){$candidates+=,(Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')}
    $pf86=[Environment]::GetEnvironmentVariable('ProgramFiles(x86)');if($pf86){$candidates+=,(Join-Path $pf86 'Inno Setup 6\ISCC.exe')}
    if($env:ProgramFiles){$candidates+=,(Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')}
    foreach($c in $candidates){if(Test-Path -LiteralPath $c){return $c}}
    $cmd=Get-Command ISCC.exe -ErrorAction SilentlyContinue;if($cmd){return $cmd.Source}
    throw 'Inno Setup 6 not found. Install: winget install JRSoftware.InnoSetup'
}

$iscc=Find-Iscc;Write-Host "Inno Setup: $iscc"
if(-not(Test-Path -LiteralPath $outDir)){New-Item -ItemType Directory -Force -Path $outDir|Out-Null}
$isccArgs=@("/DMyAppVersion=$Version","/DRepoRoot=$repoRoot","/DPublishDir=$publishDir","/DRouterPublishDir=$routerPublishDir","/O$outDir",$issPath)
& $iscc @isccArgs
if($LASTEXITCODE-ne0){throw "ISCC failed with exit code $LASTEXITCODE"}
$setup=Get-ChildItem -LiteralPath $outDir -Filter '*.exe'|Sort-Object LastWriteTime -Descending|Select-Object -First 1
Write-Host '';Write-Host "Built: $($setup.FullName)" -ForegroundColor Green;Write-Host "       $([math]::Round($setup.Length/1MB,1)) MB"


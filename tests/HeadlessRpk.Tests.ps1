$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "HEADLESS RPK TEST FAILED: $Message"}}

$programPath=Join-Path $repo 'src\StatefulClanker.Tray\Program.cs'
$source=[IO.File]::ReadAllText($programPath)

Write-Host '  RPK HEADLESS 1: --rpk dispatch happens before WinForms and GUI mutex'
$main=$source.IndexOf('static int Main(string[] args)')
$rpk=$source.IndexOf('ReflexiveProjectKnowledge.Run', $main)
$winforms=$source.IndexOf('ApplicationConfiguration.Initialize()', $main)
$mutex=$source.IndexOf('Local\\StatefulClanker.WindowsHost', $main)
Assert-True ($main-ge0) 'Program.Main does not accept command-line arguments.'
Assert-True ($rpk-gt$main) 'Program.Main does not dispatch --rpk to ReflexiveProjectKnowledge.Run.'
Assert-True ($winforms-gt$rpk) '--rpk dispatch occurs after WinForms initialization.'
Assert-True ($mutex-gt$rpk) '--rpk dispatch occurs after the GUI single-instance mutex.'
Assert-True ($source.Contains('string.Equals(args[0], "--rpk"')) 'Program.Main does not explicitly recognize --rpk.'
Assert-True ($source.Contains('args.Skip(1).ToArray()')) '--rpk marker is not stripped before dispatching the RPK command.'

$exeCandidates=@(
    (Join-Path $repo 'src\StatefulClanker.Tray\bin\Release\net8.0-windows\StatefulClanker.exe'),
    (Join-Path $repo 'src\StatefulClanker.Tray\bin\Debug\net8.0-windows\StatefulClanker.exe')
)
$exe=$exeCandidates|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}|Select-Object -First 1
if($exe){
    Write-Host '  RPK HEADLESS 2: built --rpk process exits instead of becoming a tray host'
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-rpk-headless-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $temp|Out-Null
    try{
        $p=Start-Process -FilePath $exe -ArgumentList @('--rpk','status','--project',$temp) -PassThru -WindowStyle Hidden
        if(-not$p.WaitForExit(5000)){
            try{$p.Kill($true)}catch{}
            throw 'Built StatefulClanker.exe --rpk did not exit within 5 seconds; utility mode may have entered the GUI loop.'
        }
        Assert-True ($p.ExitCode-eq0) "Built --rpk status exited $($p.ExitCode)."
    }finally{
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}else{
    Write-Host '  RPK HEADLESS 2: skipped runtime check (tray binary has not been built yet)'
}

Write-Host 'PASS: RPK utility mode is routed before all tray/WinForms startup and exits headlessly.'

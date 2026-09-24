$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$script:StatefulClankerHome=$repo
. (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
. (Join-Path $repo 'lib\StatefulClanker.Context.ps1')
. (Join-Path $repo 'lib\StatefulClanker.ReflexiveKnowledge.ps1')

$null=Invoke-SCRpk 'status' @{} -AllowUnavailable
Write-Host 'PASS: reflexive knowledge host resolution does not assign the read-only $Host variable'

function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "RPK GRAPH TEST FAILED: $Message"}}

Write-Host '  RPK GRAPH 0: build tray project (Debug)'
$trayProj=Join-Path $repo 'src\StatefulClanker.Tray'
& dotnet build $trayProj -c Debug -nologo -v q
if($LASTEXITCODE -ne 0){throw "RPK GRAPH TEST FAILED: dotnet build exited $LASTEXITCODE"}

$exeCandidates=@(
    (Join-Path $repo 'src\StatefulClanker.Tray\bin\Debug\net8.0-windows\StatefulClanker.exe'),
    (Join-Path $repo 'src\StatefulClanker.Tray\bin\Release\net8.0-windows\StatefulClanker.exe')
)
$exe=$exeCandidates|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}|Select-Object -First 1
Assert-True ($null -ne $exe) 'Built StatefulClanker.exe not found after build.'

function Invoke-Rpk([string[]]$RpkArgs){
    # StatefulClanker.exe is a Windows-subsystem (WinForms) executable; the '&' operator
    # does not reliably capture its stdout, so redirect explicitly via Start-Process.
    $stdout=Join-Path ([IO.Path]::GetTempPath()) ('rpk-stdout-'+[guid]::NewGuid().ToString('N')+'.txt')
    $stderr=Join-Path ([IO.Path]::GetTempPath()) ('rpk-stderr-'+[guid]::NewGuid().ToString('N')+'.txt')
    try{
        $p=Start-Process -FilePath $exe -ArgumentList (@('--rpk')+$RpkArgs) -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if(-not $p.WaitForExit(15000)){ try{$p.Kill($true)}catch{}; throw "RPK GRAPH TEST FAILED: rpk $($RpkArgs -join ' ') did not exit within 15s" }
        $code=$p.ExitCode
        $out=Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue
        if($code -ne 0){throw "RPK GRAPH TEST FAILED: rpk $($RpkArgs -join ' ') exited $code : $out"}
        $line=($out -split "`r?`n" | Where-Object {$_.Trim().Length -gt 0} | Select-Object -Last 1)
        return $line | ConvertFrom-Json
    }finally{
        Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
    }
}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('statefulclanker-rpk-graph-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try{
    # tiny project: a lib file with a function, and a script that dot-sources it
    $libDir=Join-Path $temp 'lib'
    New-Item -ItemType Directory -Force -Path $libDir|Out-Null
    $libPath=Join-Path $libDir 'Helper.ps1'
    Set-Content -LiteralPath $libPath -Value "function Get-Widget {`n    return 1`n}`n" -Encoding utf8

    $mainPath=Join-Path $temp 'main.ps1'
    Set-Content -LiteralPath $mainPath -Value ". `$PSScriptRoot\lib\Helper.ps1`nGet-Widget`n" -Encoding utf8

    Write-Host '  RPK GRAPH 1: index twice — second run rehashes nothing unchanged'
    $r1=Invoke-Rpk @('index','--project',$temp)
    Assert-True ($r1.ok) 'first index did not report ok'
    Assert-True ($r1.changed -gt 0) 'first index reported no changed files'

    $r2=Invoke-Rpk @('index','--project',$temp)
    Assert-True ($r2.ok) 'second index did not report ok'
    Assert-True ($r2.changed -eq 0) "second index rehashed $($r2.changed) files that had not changed"
    Assert-True ($r2.unchangedSkipped -gt 0) 'second index did not report any unchangedSkipped files'

    Write-Host '  RPK GRAPH 2: stable symbol id survives a pure line shift'
    $q1="SELECT id FROM symbols WHERE name='Get-Widget'"
    $dbPath=Join-Path (Join-Path $temp '.clanker') 'reflexive-project-knowledge.sqlite'
    Assert-True (Test-Path -LiteralPath $dbPath) 'rpk sqlite db not found after indexing'

    function Get-SymbolId($NeighborsResult,[string]$Name){
        $defineEdge=$NeighborsResult.edges | Where-Object { $_.kind -eq 'defines' -and $_.src -eq 'lib/Helper.ps1' } | Select-Object -First 1
        if($null -eq $defineEdge){ return $null }
        return $defineEdge.dst
    }

    $n1=Invoke-Rpk @('neighbors','--project',$temp,'--path','lib/Helper.ps1','--depth','1')
    $idBefore=Get-SymbolId -NeighborsResult $n1 -Name 'Get-Widget'
    Assert-True ($null -ne $idBefore) 'symbol id not found before line shift'

    # shift the function down by two blank lines — content of the function is unchanged,
    # only its line number moves.
    Set-Content -LiteralPath $libPath -Value "`n`nfunction Get-Widget {`n    return 1`n}`n" -Encoding utf8
    $null=Invoke-Rpk @('index','--project',$temp)
    $n2=Invoke-Rpk @('neighbors','--project',$temp,'--path','lib/Helper.ps1','--depth','1')
    $idAfter=Get-SymbolId -NeighborsResult $n2 -Name 'Get-Widget'
    Assert-True ($null -ne $idAfter) 'symbol id not found after line shift'
    Assert-True ($idBefore -eq $idAfter) "symbol id changed across a line shift: $idBefore -> $idAfter"

    Write-Host '  RPK GRAPH 3: resolved dot-source edge from main.ps1 to lib/Helper.ps1'
    $n3=Invoke-Rpk @('neighbors','--project',$temp,'--path','main.ps1','--depth','1')
    $found=$false
    foreach($e in $n3.edges){
        if($e.kind -eq 'dot-sources' -and $e.src -eq 'main.ps1' -and $e.resolved -and $e.resolved -like '*lib/Helper.ps1'){ $found=$true }
    }
    Assert-True $found 'no resolved dot-sources edge found from main.ps1 to lib/Helper.ps1'

    Write-Host 'PASS: RPK graph indexing is incremental, stable-id, and resolves typed edges.'
}finally{
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

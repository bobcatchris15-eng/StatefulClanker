# Reflexive Project Knowledge (RPK): project-local graph + lessons.
# The native host owns SQLite. PowerShell remains the orchestration adapter.

function Get-SCRpkHost {
    # RPK is on the compilation hot path and may be invoked by several workers
    # concurrently. Never use `dotnet run` here: that implicitly restores/builds
    # the tray project and caused parallel workers to launch competing NuGet builds.
    $candidates=@(
        (Join-Path $script:StatefulClankerHome 'StatefulClanker.exe'),
        (Join-Path $script:StatefulClankerHome 'src\StatefulClanker.Tray\bin\Release\net8.0-windows\StatefulClanker.exe'),
        (Join-Path $script:StatefulClankerHome 'src\StatefulClanker.Tray\bin\Debug\net8.0-windows\StatefulClanker.exe')
    )
    foreach($candidate in $candidates){
        if(Test-Path -LiteralPath $candidate -PathType Leaf){
            return [pscustomobject]@{file=$candidate;prefix=@()}
        }
    }
    return $null
}
function Invoke-SCRpk([string]$Command,[hashtable]$Arguments=@{},[switch]$AllowUnavailable) {
    $rpkHost=Get-SCRpkHost
    if($null-eq$rpkHost){if($AllowUnavailable){return $null};throw 'RPK native host unavailable. Install StatefulClanker or build the tray project once; RPK will not build the application from a worker hot path.'}
    $args=@($rpkHost.prefix)
    if($args.Count-eq0){$args+='--rpk'}
    $args+=$Command;$args+='--project';$args+=(Get-SCRoot)
    foreach($key in $Arguments.Keys){$value=$Arguments[$key];if($null-eq$value){$args+='--'+$key;$args+=[string]$value}}
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$rpkHost.file;$psi.WorkingDirectory=Get-SCRoot;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($arg in $args){[void]$psi.ArgumentList.Add([string]$arg)}
    $p=New-Object Diagnostics.Process;$p.StartInfo=$psi
    try{[void]$p.Start();$stdout=$p.StandardOutput.ReadToEnd();$stderr=$p.StandardError.ReadToEnd();$p.WaitForExit();if($p.ExitCode-ne0){throw ("RPK {0} failed: {1}"-f$Command,($stderr+$stdout).Trim())};if([string]::IsNullOrWhiteSpace($stdout)){return $null};return $stdout|ConvertFrom-Json}finally{$p.Dispose()}
}
function Update-SCRpkIndex {[CmdletBinding()]param(); Invoke-SCRpk 'index'}
function Normalize-SCRpk {[CmdletBinding()]param(); Invoke-SCRpk 'normalize'}
function Get-SCRpkStatus {[CmdletBinding()]param(); Invoke-SCRpk 'status'}
function Search-SCRpkLessons([string]$Text,[string[]]$Paths=@(),[int]$Limit=8) {
    $r=Invoke-SCRpk 'query' @{text=$Text;paths=($Paths-join',');limit=$Limit} -AllowUnavailable
    if($null-eq$r){return @()};return @($r.lessons)
}
function Add-SCRpkLesson([string]$Title,[string]$Body,[string[]]$Tags=@(),[string[]]$Paths=@(),[string]$Source='worker',[double]$Confidence=.75) {
    Invoke-SCRpk 'lesson-add' @{title=$Title;body=$Body;tags=($Tags-join',');paths=($Paths-join',');source=$Source;confidence=$Confidence}
}
function Confirm-SCRpkLesson([string]$Id,[string]$Note='') {Invoke-SCRpk 'lesson-confirm' @{id=$Id;note=$Note}}
function Reject-SCRpkLesson([string]$Id,[string]$Note='') {Invoke-SCRpk 'lesson-reject' @{id=$Id;note=$Note}}
function Get-SCRpkNeighbors([string]$Path,[int]$Depth=1,[int]$Limit=50) {Invoke-SCRpk 'neighbors' @{path=$Path;depth=$Depth;limit=$Limit}}

# Compile relevant project muscle-memory as candidate context. It never becomes
# authority: current human directives and normalized Intent retain precedence.
$script:SCBaseRpkCompilation=(Get-Item Function:\New-SCCompilation).ScriptBlock
function New-SCCompilation($Task) {
    try{Update-SCRpkIndex|Out-Null}catch{Add-SCEvent 'rpk.index_failed' 'RPK indexing failed; continuing without project-memory context.' @{taskId=$Task.id;error=$_.Exception.Message}}
    $receipt=& $script:SCBaseRpkCompilation $Task
    if($null-eq$receipt-or$null-eq$receipt.ir){return $receipt}
    $paths=@();if($Task.PSObject.Properties['retrieval']){$paths=@($Task.retrieval|Where-Object{$_ -and $_ -notmatch '[*?]'})}
    $query=(([string]$Task.title)+' '+([string]$Task.instruction)+' '+(@($Task.acceptance)-join' '))
    $lessons=@(Search-SCRpkLessons $query $paths 8)
    Set-SCProperty $receipt.ir.sources 'reflexiveProjectKnowledge' ([ordered]@{authority='candidate project-local working knowledge; verify against current files and human/intent authority';lessons=$lessons})
    $receipt.contextFingerprint=Get-SCHashString (ConvertTo-SCJson $receipt.ir 24)
    Write-SCJson (Get-SCPath ("compilations/{0}.json"-f$receipt.id)) $receipt
    return $receipt
}

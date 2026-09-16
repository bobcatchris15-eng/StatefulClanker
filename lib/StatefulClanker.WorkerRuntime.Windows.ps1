# Windows PowerShell 5.1 lacks ProcessStartInfo.ArgumentList. Override the bounded
# command tool with -EncodedCommand so arbitrary PowerShell remains one safe process
# argument without relying on shell quoting or .NET 6+ APIs.
function Invoke-SCBoundedCommand([string]$Command,[int]$TimeoutSeconds=120) {
    if([string]::IsNullOrWhiteSpace($Command)){throw 'command required'}
    $shell=if(Get-Command pwsh.exe -ErrorAction SilentlyContinue){'pwsh.exe'}else{'powershell.exe'}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$shell;$psi.WorkingDirectory=Get-SCRoot;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.Arguments="-NoProfile -NonInteractive -EncodedCommand $encoded"
    $p=New-Object Diagnostics.Process;$p.StartInfo=$psi
    try {
        [void]$p.Start();$stdoutTask=$p.StandardOutput.ReadToEndAsync();$stderrTask=$p.StandardError.ReadToEndAsync()
        if(-not$p.WaitForExit([Math]::Max(1,$TimeoutSeconds)*1000)){try{$p.Kill()}catch{};return [ordered]@{exitCode=-2;stdout='';stderr="Command timed out after $TimeoutSeconds seconds."}}
        return [ordered]@{exitCode=$p.ExitCode;stdout=$stdoutTask.Result;stderr=$stderrTask.Result}
    } finally {$p.Dispose()}
}

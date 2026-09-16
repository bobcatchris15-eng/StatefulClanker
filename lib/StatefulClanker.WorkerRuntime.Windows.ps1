# Windows compatibility helpers for the direct worker runtime.
#
# Windows PowerShell 5.1 lacks ProcessStartInfo.ArgumentList, and PowerShell 7 may
# not have System.Security.Cryptography.ProtectedData loaded. Keep both operations
# on stable Win32/encoded-command primitives instead.

if(-not('StatefulClanker.Win32Dpapi' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace StatefulClanker {
  public static class Win32Dpapi {
    [StructLayout(LayoutKind.Sequential)] struct DATA_BLOB { public int cbData; public IntPtr pbData; }
    [DllImport("crypt32.dll", SetLastError=true, CharSet=CharSet.Auto)] static extern bool CryptUnprotectData(ref DATA_BLOB pDataIn, IntPtr ppszDataDescr, IntPtr pOptionalEntropy, IntPtr pvReserved, IntPtr pPromptStruct, int dwFlags, ref DATA_BLOB pDataOut);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr hMem);
    public static byte[] Unprotect(byte[] encrypted) {
      var input=new DATA_BLOB(); var output=new DATA_BLOB(); input.cbData=encrypted.Length; input.pbData=Marshal.AllocHGlobal(encrypted.Length); Marshal.Copy(encrypted,0,input.pbData,encrypted.Length);
      try { if(!CryptUnprotectData(ref input,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,0,ref output)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); var plain=new byte[output.cbData]; Marshal.Copy(output.pbData,plain,0,plain.Length); return plain; }
      finally { if(input.pbData!=IntPtr.Zero) Marshal.FreeHGlobal(input.pbData); if(output.pbData!=IntPtr.Zero) LocalFree(output.pbData); }
    }
  }
}
'@
}
function Unprotect-SCApiKey([string]$Protected) {
    if([string]::IsNullOrWhiteSpace($Protected)){return $null}
    try{return [Text.Encoding]::UTF8.GetString([StatefulClanker.Win32Dpapi]::Unprotect([Convert]::FromBase64String($Protected)))}catch{throw 'Could not decrypt API credential for the current Windows user.'}
}
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

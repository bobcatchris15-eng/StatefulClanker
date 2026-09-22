param([Parameter(Mandatory=$true)][string]$Connection)
$ErrorActionPreference='Stop'

# Windows PowerShell 5.1 does not reliably preload the assembly that exposes
# System.Security.Cryptography.ProtectedData. Pi invokes this bridge through
# powershell.exe, so load it explicitly before touching DPAPI-backed secrets.
try { Add-Type -AssemblyName System.Security -ErrorAction Stop }
catch {
    try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
    catch { throw "Unable to load Windows DPAPI support: $($_.Exception.Message)" }
}

$root=Join-Path $env:LOCALAPPDATA 'StatefulClanker'
$path=Join-Path $root 'connections.json'
if(-not(Test-Path -LiteralPath $path)){exit 2}
$doc=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json
$p=$doc.connections.PSObject.Properties[$Connection]
if($null-eq$p){exit 3}
$c=$p.Value
$key=$null
if($c.PSObject.Properties['apiKeyEnv'] -and $c.apiKeyEnv){$key=[Environment]::GetEnvironmentVariable([string]$c.apiKeyEnv)}
if(-not$key -and $c.PSObject.Properties['apiKeyProtected'] -and $c.apiKeyProtected){
    $bytes=[Convert]::FromBase64String([string]$c.apiKeyProtected)
    $plain=[System.Security.Cryptography.ProtectedData]::Unprotect(
        $bytes,$null,[System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    $key=[Text.Encoding]::UTF8.GetString($plain)
}
if([string]::IsNullOrWhiteSpace($key)){exit 4}
[Console]::Out.Write($key)

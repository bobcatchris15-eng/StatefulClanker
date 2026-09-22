param([Parameter(Mandatory=$true)][string]$Connection)
$ErrorActionPreference='Stop'
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
    $plain=[Security.Cryptography.ProtectedData]::Unprotect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    $key=[Text.Encoding]::UTF8.GetString($plain)
}
if([string]::IsNullOrWhiteSpace($key)){exit 4}
[Console]::Out.Write($key)

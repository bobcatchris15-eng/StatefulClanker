$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
[void][Reflection.Assembly]::LoadFrom((Join-Path $repo 'src/StatefulClanker.Router/bin/Debug/net8.0-windows/StatefulClanker.Router.dll'))
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-connections-'+[guid]::NewGuid().ToString('N'))
try {
 $store=[StatefulClanker.Router.RouterStore]::new($temp)
 $path=Join-Path $temp 'connections.json'
 '{"schemaVersion":2,"connections":[{"name":"mock","apiKeyProtected":"opaque"}]}' | Set-Content -LiteralPath $path
 $failed=$false
 try { [void]$store.LoadConnections() } catch { $failed=$_.Exception.ToString().Contains('connections must be an object') }
 if(-not $failed){throw 'Array-shaped connections silently lost credentials instead of reporting invalid config.'}
 '{"schemaVersion":2,"connections":{"mock":{"name":"mock","apiKeyProtected":"opaque"}}}' | Set-Content -LiteralPath $path
 $doc=$store.LoadConnections()
 if($doc.connections.Count -ne 1 -or $doc.connections['mock'].apiKeyProtected -ne 'opaque'){throw 'Valid profile credentials lost.'}
 'ConnectionDocument tests passed'
} finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force} }

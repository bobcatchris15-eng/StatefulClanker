$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
[void][Reflection.Assembly]::LoadFrom((Join-Path $repo 'src/StatefulClanker.Router/bin/Debug/net8.0-windows/StatefulClanker.Router.dll'))
function Check([bool]$value,[string]$why){if(-not $value){throw $why}}
$policy=[StatefulClanker.Router.FailurePolicy]
Check ($policy::ScopeFor('permission','403 Forbidden') -eq 'endpoint') 'generic403 must default endpoint'
Check ($policy::ScopeFor('permission','An active OpenCode Go subscription is required to use Go models.') -eq 'connection') 'Go subscription must block account'
Check ($policy::ScopeFor('permission','An active subscription is required for all models on this account.') -eq 'connection') 'explicit account subscription ignored'
Check ($policy::ScopeFor('permission','An active subscription is required for model fancy-llm.') -eq 'endpoint') 'model subscription poisoned account'
Check ($policy::ScopeFor('permission','The requested model subscription is expired') -eq 'endpoint') 'expired model subscription poisoned account'
Check ($policy::ScopeFor('permission','account subscription is inactive') -eq 'connection') 'account subscription ignored'
Check ($policy::ScopeFor('auth','HTTP401') -eq 'connection') 'auth must stay connection'
Check ($policy::ScopeFor('billing_exhausted','API budget exhausted.') -eq 'connection') 'budget must stay connection'
foreach($klass in @('permission','model_unavailable','rate_limited','server_error')){Check (-not $policy::IsCredentialProbeFailure($klass,'metadata endpoint failed')) 'metadata failure poisoned inference'}
Check ($policy::IsCredentialProbeFailure('auth','Invalid API key')) 'credential evidence ignored'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-scope-'+[guid]::NewGuid().ToString('N'))
try {
 $store=[StatefulClanker.Router.RouterStore]::new($temp)
 $signals=[StatefulClanker.Router.SignalStore]::new($temp)
 $reducer=[StatefulClanker.Router.RoutingHealthReducer]::new($store,$signals)
 $profile=[StatefulClanker.Router.ConnectionProfile]::new();$profile.name='mock'
 $entry=$reducer.RegisterFailure('pool:mock::m','endpoint','permission','403 Forbidden',$profile)
 Check ($entry.state -eq 'cooldown' -and [datetimeoffset]::Parse($entry.retryAfter) -gt [datetimeoffset]::UtcNow) 'endpoint permission not bounded'
 foreach($case in @(@('model','permission','thinkingmachines/inkling:free is only available on agentic harnesses.'),@('unknown','permission','403 Forbidden'),@('go','permission','An active OpenCode Go subscription is required to use Go models.'),@('auth','auth','Invalid API key'),@('budget','billing_exhausted','API budget exhausted.'))){
  [void]$reducer.RegisterFailure(('connection:'+$case[0]),'connection',$case[1],$case[2],$profile)
 }
 [void]$reducer.RegisterFailure('connection:long','connection','permission',(('x'*600)+' An active OpenCode Go subscription is required to use Go models.'),$profile)
 $reducer.NormalizeExpiredCooldowns()
 $health=$store.LoadHealth()
 foreach($id in @('model','unknown')){Check ($health.endpoints['connection:'+$id].state -eq 'healthy') 'legacy model/unknown permission not migrated'}
 foreach($id in @('go','auth','budget','long')){Check ($health.endpoints['connection:'+$id].state -ne 'healthy') 'true account block migrated'}
 $quota=[StatefulClanker.Router.QuotaObservation]::new();$quota.source='probe:test';$quota.remaining=10
 $reducer.RecordQuota('connection:go','connection',$quota,$profile)
 Check ($store.LoadHealth().endpoints['connection:go'].state -eq 'quarantined') 'available quota cleared subscription block'
 # Exercise the real metadata polling path, not only its policy helper.
 $engine=[StatefulClanker.Router.RouterEngine]::new($store)
 $monitor=[StatefulClanker.Router.EndpointMonitor]::new($engine)
 $observe=$monitor.GetType().GetMethod('ObserveOneConnectionAsync',[Reflection.BindingFlags]'Instance,NonPublic')
 foreach($status in @(403,404,429,500)){
  $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
  $job=Start-Job -ScriptBlock {
   param($port,$status)
   $l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);$l.Start()
   try{$c=$l.AcceptTcpClient();$stream=$c.GetStream();$r=[IO.StreamReader]::new($stream);while($r.ReadLine() -ne ''){}
    $body='{"error":{"message":"metadata endpoint unavailable"}}';$crlf="`r`n"
    $bytes=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status Error$crlf"+"Content-Length: $($body.Length)$crlf"+"Connection: close$crlf$crlf$body")
    $stream.Write($bytes,0,$bytes.Length);$c.Dispose()
   }finally{$l.Stop()}
  } -ArgumentList $port,$status
  try{
   Start-Sleep -Milliseconds 300
   $profile=[StatefulClanker.Router.ConnectionProfile]::new();$profile.name="probe$status";$profile.presetId='openrouter';$profile.baseUrl="http://127.0.0.1:$port/api/v1";$profile.authKind='none'
   $connections=[Collections.Generic.Dictionary[string,StatefulClanker.Router.ConnectionProfile]]::new();$connections.Add($profile.name,$profile)
   $task=$observe.Invoke($monitor,@($connections,[datetimeoffset]::UtcNow,[Threading.CancellationToken]::None));[void]$task.GetAwaiter().GetResult()
   Check (-not $store.LoadHealth().endpoints.ContainsKey("connection:probe$status")) "metadata HTTP$status poisoned connection"
  }finally{Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
 }
 $all=Get-ChildItem -LiteralPath $temp -Recurse -File|Where-Object Extension -eq '.jsonl'|ForEach-Object{Get-Content -LiteralPath $_.FullName}
 Check (($all -join "`n") -match 'policy-scope-corrected') 'scope migration not auditable'
 Write-Host 'PASS: connection health scope policy and migration'
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}

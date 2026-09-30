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
foreach($text in @('403 Forbidden: This account model subscription is expired. Other models remain available.','403 Forbidden: account has model foo disabled','active subscription is required for model foo on this account')){Check ($policy::ScopeFor('permission',$text) -eq 'endpoint') 'account/model proximity misclassified'}
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
 foreach($klass in @('auth','permission')){
  $msg=if($klass -eq 'auth'){'401 Invalid API key; Retry-After: 1'}else{'account subscription is inactive; Retry-After: 1'}
  $hard=$reducer.RegisterFailure(('connection:retry-'+$klass),'connection',$klass,$msg,$profile)
  Check ($hard.state -eq 'quarantined') 'account restriction timer permits inference'
 }
 $legacy=$store.LoadHealth();foreach($klass in @('auth','permission')){$old=$legacy.endpoints['connection:retry-'+$klass];$old.state='cooldown';$old.retryAfter=[datetimeoffset]::UtcNow.AddMinutes(-1).ToString('O')};$legacy.endpoints['connection:model'].lastSuccess='2020-01-01T00:00:00Z';$store.SaveHealth($legacy)
 $reducer.NormalizeExpiredCooldowns()
 $health=$store.LoadHealth()
 foreach($klass in @('auth','permission')){Check ($health.endpoints['connection:retry-'+$klass].state -eq 'quarantined') 'legacy timer unblocked account restriction'}
 Check ($health.endpoints['connection:model'].lastSuccess -eq '2020-01-01T00:00:00Z') 'migration fabricated inference success'
 foreach($id in @('model','unknown')){Check ($health.endpoints['connection:'+$id].state -eq 'healthy') 'legacy model/unknown permission not migrated'}
 foreach($id in @('go','auth','budget','long')){Check ($health.endpoints['connection:'+$id].state -ne 'healthy') 'true account block migrated'}
 $expired=$store.LoadHealth();$due=$expired.endpoints['pool:mock::m'];$due.retryAfter=[datetimeoffset]::UtcNow.AddMinutes(-1).ToString('O');$due.lastSuccess='2021-01-01T00:00:00Z';$store.SaveHealth($expired)
 $reducer.NormalizeExpiredCooldowns()
 Check ($store.LoadHealth().endpoints['pool:mock::m'].lastSuccess -eq '2021-01-01T00:00:00Z') 'cooldown expiry fabricated measured success'
 $expire=$reducer.GetType().GetMethod('TryExpireCooldown',[Reflection.BindingFlags]'Instance,NonPublic')
 Check (-not [bool]$expire.Invoke($reducer,@('connection:retry-auth',[datetimeoffset]::UtcNow))) 'stale timer cleared newer auth quarantine'
 Check (-not [bool]$expire.Invoke($reducer,@('connection:retry-permission',[datetimeoffset]::UtcNow))) 'stale timer cleared newer account quarantine'
 [void]$reducer.RegisterFailure('pool:future::m','endpoint','timeout','timeout',$null)
 Check (-not [bool]$expire.Invoke($reducer,@('pool:future::m',[datetimeoffset]::UtcNow))) 'stale timer cleared newer future cooldown'
 [void]$reducer.RegisterFailure('pool:due::m','endpoint','timeout','timeout',$null)
 $before=$store.LoadHealth();$before.endpoints['pool:due::m'].retryAfter=[datetimeoffset]::UtcNow.AddMinutes(-1).ToString('O');$store.SaveHealth($before)
 Check ([bool]$expire.Invoke($reducer,@('pool:due::m',[datetimeoffset]::UtcNow))) 'due cooldown did not expire'
 Check ($store.LoadHealth().endpoints['pool:due::m'].state -eq 'healthy') 'due cooldown health did not update'
 $quota=[StatefulClanker.Router.QuotaObservation]::new();$quota.source='probe:test';$quota.remaining=10
 $reducer.RecordQuota('connection:go','connection',$quota,$profile)
 Check ($store.LoadHealth().endpoints['connection:go'].state -eq 'quarantined') 'available quota cleared subscription block'
 # Exercise the real metadata polling path, not only its policy helper.
 $engine=[StatefulClanker.Router.RouterEngine]::new($store)
 $monitor=[StatefulClanker.Router.EndpointMonitor]::new($engine)
 [void]$reducer.RegisterFailure('connection:monitor-budget','connection','billing_exhausted','API budget exhausted.',$null)
 $tickDoc=$store.LoadHealth();$tickEntry=$tickDoc.endpoints['connection:monitor-budget'];$tickEntry.retryAfter=[datetimeoffset]::UtcNow.AddMinutes(5).ToString('O');$tickEntry.nextProbeAt=[datetimeoffset]::UtcNow.AddMinutes(-1).ToString('O');$tickEntry.lastSuccess='2022-01-01T00:00:00Z';$store.SaveHealth($tickDoc)
 [void]$monitor.TickAsync([Threading.CancellationToken]::None).GetAwaiter().GetResult()
 Check ($store.LoadHealth().endpoints['connection:monitor-budget'].state -eq 'cooldown') 'monitor stale probe timer cleared future billing cooldown'
 foreach($key in @('pool:monitor::m','connection:monitor-budget')){
  $scope=if($key.StartsWith('pool:')){'endpoint'}else{'connection'};$klass=if($scope -eq 'endpoint'){'timeout'}else{'billing_exhausted'}
  [void]$reducer.RegisterFailure($key,$scope,$klass,'timeout',$null)
  $tickDoc=$store.LoadHealth();$tickDoc.endpoints[$key].retryAfter=[datetimeoffset]::UtcNow.AddMinutes(-1).ToString('O');$tickDoc.endpoints[$key].nextProbeAt=$tickDoc.endpoints[$key].retryAfter;$tickDoc.endpoints[$key].lastSuccess='2022-01-01T00:00:00Z';$store.SaveHealth($tickDoc)
  [void]$monitor.TickAsync([Threading.CancellationToken]::None).GetAwaiter().GetResult()
  Check ($store.LoadHealth().endpoints[$key].state -eq 'healthy' -and $store.LoadHealth().endpoints[$key].lastSuccess -eq '2022-01-01T00:00:00Z') 'monitor expiry fabricated success'
 }
 Check ($store.LoadHealth().endpoints['connection:retry-auth'].state -eq 'quarantined') 'monitor tick unblocked auth'
 Check ($store.LoadHealth().endpoints['connection:retry-permission'].state -eq 'quarantined') 'monitor tick unblocked account restriction'
 $observe=$monitor.GetType().GetMethod('ObserveOneConnectionAsync',[Reflection.BindingFlags]'Instance,NonPublic')
 foreach($status in @(403,404,429,500)){
  $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
  $job=Start-Job -ScriptBlock {
   param($port,$status)
   $l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);$l.Start();Write-Output 'ready'
   try{$c=$l.AcceptTcpClient();$stream=$c.GetStream();$r=[IO.StreamReader]::new($stream);while($r.ReadLine() -ne ''){}
    $body='{"error":{"message":"metadata endpoint unavailable"}}';$crlf="`r`n"
    $bytes=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status Error$crlf"+"Content-Length: $($body.Length)$crlf"+"Connection: close$crlf$crlf$body")
    $stream.Write($bytes,0,$bytes.Length);$c.Dispose();Write-Output ('sent-'+$status)
   }finally{$l.Stop()}
  } -ArgumentList $port,$status
  try{
   $ready=$false;$deadline=[datetimeoffset]::UtcNow.AddSeconds(10)
   while([datetimeoffset]::UtcNow -lt $deadline){if(@(Receive-Job $job -Keep) -contains 'ready'){$ready=$true;break};Start-Sleep -Milliseconds 50}
   Check $ready 'metadata server did not become ready'
   $profile=[StatefulClanker.Router.ConnectionProfile]::new();$profile.name="probe$status";$profile.presetId='openrouter';$profile.baseUrl="http://127.0.0.1:$port/api/v1";$profile.authKind='none'
   $connections=[Collections.Generic.Dictionary[string,StatefulClanker.Router.ConnectionProfile]]::new();$connections.Add($profile.name,$profile)
   $task=$observe.Invoke($monitor,@($connections,[datetimeoffset]::UtcNow,[Threading.CancellationToken]::None));[void]$task.GetAwaiter().GetResult()
   [void](Wait-Job $job -Timeout 5)
   Check ($job.State -eq 'Completed' -and @(Receive-Job $job -Keep) -contains ('sent-'+$status)) 'metadata HTTP response was not served'
   Check (-not $store.LoadHealth().endpoints.ContainsKey("connection:probe$status")) "metadata HTTP$status poisoned connection"
  }finally{Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
 }
 $all=Get-ChildItem -LiteralPath $temp -Recurse -File|Where-Object Extension -eq '.jsonl'|ForEach-Object{Get-Content -LiteralPath $_.FullName}
 Check (($all -join "`n") -match 'cooldown-expired') 'cooldown expiry recovery not audited'
 Check (($all -join "`n") -match 'policy-scope-corrected') 'scope migration not auditable'
 Write-Host 'PASS: connection health scope policy and migration'
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}

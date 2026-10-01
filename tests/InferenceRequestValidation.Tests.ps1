param([string]$RouterPath)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$router=if($RouterPath){$RouterPath}else{Join-Path $repo 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe'}
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "INFERENCE INPUT TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-input-'+[guid]::NewGuid().ToString('N'))
$oldRoot=$env:SC_ROUTER_ROOT;$daemon=$null
try{
 New-Item -ItemType Directory -Path $temp|Out-Null;$env:SC_ROUTER_ROOT=$temp
 $file=Join-Path $temp 'request.json'
 function Invoke-Input([string]$Body){$Body|Set-Content -LiteralPath $file; $raw=& $router infer --request-file $file --endpoints impossible::endpoint; Assert-True ($LASTEXITCODE-eq0) "CLI failed: $raw";return ($raw|ConvertFrom-Json).data}
 $cases=@(
  @('{"tools":[{"name":"probe","parameters":{}}]}','INVALID_INFERENCE_REQUEST'),
  @('{"tools":[null]}','INVALID_INFERENCE_REQUEST'),
  @('{"toolMode":"native","tools":null}','INVALID_INFERENCE_REQUEST'),
  @('{"tools":[{"function":null}]}','INVALID_INFERENCE_REQUEST'),
  @('{"tools":[{"function":{"name":"bad name","parameters":{}}}]}','INVALID_INFERENCE_REQUEST'),
  @('{"tools":[{"function":{"name":"probe","parameters":[]}}]}','INVALID_INFERENCE_REQUEST'),
  @('{"messages":null}','INVALID_INFERENCE_REQUEST'),
  @('{"messages":[null]}','INVALID_INFERENCE_REQUEST'),
  @('{"toolMode":null}','INVALID_INFERENCE_REQUEST'),
  @('{"messages":[{"role":"assistant","tool_calls":[{"function":{"name":"probe","arguments":"broken"}}]}]}','CORRUPT_INPUT_TOOL_CALL'),
  @('{"messages":[{"role":"assistant","tool_calls":[{"function":{"name":"probe","arguments":"[]"}}]}]}','CORRUPT_INPUT_TOOL_CALL'),
  @('{"messages":[{"role":"assistant","tool_calls":[{"function":{"name":"bad name","arguments":"{}"}}]}]}','CORRUPT_INPUT_TOOL_CALL'),
  @('{"messages":[{"role":"assistant","tool_calls":[null]}]}','CORRUPT_INPUT_TOOL_CALL'),
  @('null','INVALID_INFERENCE_REQUEST'),
  @('{bad json','INVALID_INFERENCE_REQUEST')
 )
 foreach($case in $cases){if($case[1]-eq'CORRUPT_INPUT_TOOL_CALL'-and$null-eq$daemon){$daemon=Start-Process -FilePath $router -ArgumentList daemon -PassThru -WindowStyle Hidden};$result=Invoke-Input $case[0];Assert-True ($result.diagnosis.reasonCode-eq$case[1]) "Wrong diagnosis for $($case[0]): $($result|ConvertTo-Json -Depth 10)";Assert-True ($result.diagnosis.scope-eq'request') 'Input failure scope';Assert-True (-not $result.ok -and -not $result.healthChanged -and $result.routeAttempts-eq0 -and $result.endpoint-eq'') 'Input failure attempted routing or attributed endpoint'}
 Assert-True (-not(Test-Path (Join-Path $temp 'routing\health.json'))) 'Invalid input changed endpoint health'
 $missing=& $router infer --request-file (Join-Path $temp 'missing.json');Assert-True (($missing|ConvertFrom-Json).data.diagnosis.reasonCode-eq'INVALID_INFERENCE_REQUEST') 'Missing file was not structured'
 $valid=Invoke-Input '{"tools":[{"type":"function","function":{"name":"probe","description":"test","parameters":{"type":"object","properties":{}}}}],"maxRouteWaitSeconds":0}'
 Assert-True ($valid.diagnosis.reasonCode-eq'NO_ALLOWED_ENDPOINTS') 'Valid normalized tools did not reach routing'
 $legacy=Invoke-Input '{"toolMode":"text","tools":null,"maxRouteWaitSeconds":0}'
 Assert-True ($legacy.diagnosis.reasonCode-eq'NO_ALLOWED_ENDPOINTS') 'Existing PowerShell text-mode empty tools are incompatible'
 Write-Host 'PASS: CLI rejects invalid definitions before IPC and corrupt saved calls before routing; valid requests reach routing.'
}finally{
 $env:SC_ROUTER_ROOT=$oldRoot
 if($daemon-and-not$daemon.HasExited){Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue}
 if([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetTempPath())){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
}

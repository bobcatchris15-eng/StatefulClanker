param([string]$ProjectPath=(Get-Location).Path)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProjectPath=(Resolve-Path $ProjectPath).Path
$stateDir=Join-Path $ProjectPath '.statefulclanker'
$harness=Join-Path (Split-Path -Parent $PSScriptRoot) 'StatefulClanker.ps1'
function ReadJson([string]$p){if(-not(Test-Path $p)){return $null};$r=Get-Content -Raw -LiteralPath $p;if([string]::IsNullOrWhiteSpace($r)){return $null};$r|ConvertFrom-Json}
function ReadDir([string]$p){if(-not(Test-Path $p)){return @()};@(Get-ChildItem -LiteralPath $p -Filter '*.json' -File |ForEach-Object{ReadJson $_.FullName})}
function Reply($id,$result){[ordered]@{jsonrpc='2.0';id=$id;result=$result} | ConvertTo-Json -Depth 20 -Compress}
function Err($id,[int]$code,[string]$message){[ordered]@{jsonrpc='2.0';id=$id;error=[ordered]@{code=$code;message=$message}} | ConvertTo-Json -Depth 10 -Compress}
function TextResult($x){@{content=@(@{type='text';text=($x | ConvertTo-Json -Depth 20)})}}
function ToolList{
@(
@{name='project_status';description='Read StatefulClanker project state and task summary.';inputSchema=@{type='object';properties=@{}}},
@{name='telemetry_active';description='List currently active subagents.';inputSchema=@{type='object';properties=@{}}},
@{name='telemetry_history';description='List historical subagent telemetry.';inputSchema=@{type='object';properties=@{limit=@{type='integer';minimum=1;maximum=500}}}},
@{name='telemetry_run';description='Get one historical subagent run by agentId.';inputSchema=@{type='object';properties=@{agentId=@{type='string'}};required=@('agentId')}},
@{name='task_list';description='List task graph state.';inputSchema=@{type='object';properties=@{}}},
@{name='direction_add';description='Record human conversational direction into durable project events.';inputSchema=@{type='object';properties=@{message=@{type='string'}};required=@('message')}}
)
}
function CallTool([string]$name,$args){
switch($name){
'project_status'{$s=ReadJson(Join-Path $stateDir 'state.json');$tasks=ReadDir(Join-Path $stateDir 'tasks');return TextResult([ordered]@{state=$s;tasks=$tasks})}
'telemetry_active'{return TextResult(@(ReadDir(Join-Path $stateDir 'telemetry\active')|Sort-Object startedAt))}
'telemetry_history'{$limit=100;if($args-and$args.PSObject.Properties['limit']){$limit=[Math]::Min(500,[Math]::Max(1,[int]$args.limit))};$r=ReadDir(Join-Path $stateDir 'telemetry\runs') | Sort-Object startedAt -Descending | Select-Object -First $limit;return TextResult(@($r))}
'telemetry_run'{$p=Join-Path $stateDir("telemetry\runs\{0}.json"-f$args.agentId);$r=ReadJson $p;if(-not$r){throw"Unknown agentId: $($args.agentId)"};return TextResult $r}
'task_list'{return TextResult(@(ReadDir(Join-Path $stateDir 'tasks')|Sort-Object createdAt))}
'direction_add'{Push-Location $ProjectPath;try{&$harness event -Message ([string]$args.message)|Out-Null}finally{Pop-Location};return TextResult(@{recorded=$true})}
default{throw"Unknown tool: $name"}
}}
while($null-ne($line=[Console]::In.ReadLine())){
if([string]::IsNullOrWhiteSpace($line)){continue}
try{
$q=$line|ConvertFrom-Json;$method=[string]$q.method;$id=$q.id
switch($method){
'initialize'{Reply $id ([ordered]@{protocolVersion='2025-06-18';capabilities=@{tools=@{}};serverInfo=@{name='statefulclanker';version='0.2.0'}})}
'notifications/initialized'{}
'tools/list'{Reply $id (@{tools=ToolList})}
'tools/call'{$args=$q.params.arguments;Reply $id (CallTool ([string]$q.params.name) $args)}
default{if($null-ne$id){Err $id -32601 "Method not found: $method"}}
}
}catch{try{Err $null -32603 $_.Exception.Message}catch{}}
}

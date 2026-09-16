# StatefulClanker-owned minimal worker harness for direct inference backends.
# CLI providers continue through the existing provider harness path. API providers
# use machine-local connection profiles and this bounded coding/tool loop.

$script:SCInvokeProviderCliBase = ${function:Invoke-SCProvider}

function Get-SCMachineConnectionsPath {
    $root=Join-Path $env:LOCALAPPDATA 'StatefulClanker'
    if(-not(Test-Path -LiteralPath $root)){New-Item -ItemType Directory -Force -Path $root|Out-Null}
    return Join-Path $root 'connections.json'
}
function Get-SCMachineConnections {
    $path=Get-SCMachineConnectionsPath
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return [pscustomobject]@{schemaVersion=1;connections=[pscustomobject]@{}}}
    try{$cfg=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json}catch{throw "Invalid machine connection config: $path`n$($_.Exception.Message)"}
    if(-not$cfg.PSObject.Properties['connections']){$cfg|Add-Member -NotePropertyName connections -NotePropertyValue ([pscustomobject]@{}) -Force}
    return $cfg
}
function Get-SCMachineConnection([string]$Name) {
    if([string]::IsNullOrWhiteSpace($Name)){throw 'API provider requires a machine connection name.'}
    $cfg=Get-SCMachineConnections;$p=$cfg.connections.PSObject.Properties[$Name]
    if($null-eq$p){throw "Machine API connection '$Name' is not configured in $(Get-SCMachineConnectionsPath)."}
    return $p.Value
}
function Unprotect-SCApiKey([string]$Protected) {
    if([string]::IsNullOrWhiteSpace($Protected)){return $null}
    try{
        $bytes=[Convert]::FromBase64String($Protected)
        $plain=[Security.Cryptography.ProtectedData]::Unprotect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($plain)
    }catch{throw 'Could not decrypt API credential for the current Windows user.'}
}
function Get-SCApiKey($Connection) {
    if($Connection.PSObject.Properties['apiKeyEnv']-and$Connection.apiKeyEnv){return [Environment]::GetEnvironmentVariable([string]$Connection.apiKeyEnv)}
    if($Connection.PSObject.Properties['apiKeyProtected']-and$Connection.apiKeyProtected){return Unprotect-SCApiKey ([string]$Connection.apiKeyProtected)}
    return $null
}
function Get-SCApiUri($Connection) {
    $base=[string]$Connection.baseUrl;if([string]::IsNullOrWhiteSpace($base)){throw 'API connection baseUrl is required.'}
    if($Connection.PSObject.Properties['chatPath']-and$Connection.chatPath){return $base.TrimEnd('/')+'/'+([string]$Connection.chatPath).TrimStart('/')}
    if($base.TrimEnd('/') -match '/chat/completions$'){return $base.TrimEnd('/')}
    return $base.TrimEnd('/')+'/chat/completions'
}
function ConvertTo-SCHashtable($Object) {
    $h=@{};if($null-eq$Object){return $h}
    foreach($p in $Object.PSObject.Properties){$h[$p.Name]=[string]$p.Value};return $h
}
function New-SCApiHeaders($Connection) {
    $headers=@{'Accept'='application/json'}
    $key=Get-SCApiKey $Connection;if($key){$headers['Authorization']='Bearer '+$key}
    if($Connection.PSObject.Properties['headers']-and$Connection.headers){foreach($k in (ConvertTo-SCHashtable $Connection.headers).Keys){$headers[$k]=(ConvertTo-SCHashtable $Connection.headers)[$k]}}
    return $headers
}
function Resolve-SCWorkerPath([string]$Path,[switch]$AllowMissing) {
    if([string]::IsNullOrWhiteSpace($Path)){throw 'path required'}
    $root=[IO.Path]::GetFullPath((Get-SCRoot)).TrimEnd('\\','/')
    $candidate=if([IO.Path]::IsPathRooted($Path)){[IO.Path]::GetFullPath($Path)}else{[IO.Path]::GetFullPath((Join-Path $root $Path))}
    if(-not($candidate.Equals($root,[StringComparison]::OrdinalIgnoreCase)-or$candidate.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))){throw "Path escapes worker root: $Path"}
    if(-not$AllowMissing-and-not(Test-Path -LiteralPath $candidate)){throw "Path not found: $Path"}
    return $candidate
}
function Invoke-SCBoundedCommand([string]$Command,[int]$TimeoutSeconds=120) {
    if([string]::IsNullOrWhiteSpace($Command)){throw 'command required'}
    $shell=if(Get-Command pwsh.exe -ErrorAction SilentlyContinue){'pwsh.exe'}else{'powershell.exe'}
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$shell;$psi.WorkingDirectory=Get-SCRoot;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    [void]$psi.ArgumentList.Add('-NoProfile');[void]$psi.ArgumentList.Add('-NonInteractive');[void]$psi.ArgumentList.Add('-Command');[void]$psi.ArgumentList.Add($Command)
    $p=New-Object Diagnostics.Process;$p.StartInfo=$psi
    try{[void]$p.Start();$stdoutTask=$p.StandardOutput.ReadToEndAsync();$stderrTask=$p.StandardError.ReadToEndAsync();if(-not$p.WaitForExit($TimeoutSeconds*1000)){try{$p.Kill()}catch{};return [ordered]@{exitCode=-2;stdout='';stderr="Command timed out after $TimeoutSeconds seconds."}};$stdout=$stdoutTask.Result;$stderr=$stderrTask.Result;return [ordered]@{exitCode=$p.ExitCode;stdout=$stdout;stderr=$stderr}}finally{$p.Dispose()}
}
function Get-SCWorkerToolDefinitions {
    return @(
      @{type='function';function=@{name='read_file';description='Read a UTF-8 text file inside the worker root.';parameters=@{type='object';properties=@{path=@{type='string'};startLine=@{type='integer'};maxLines=@{type='integer'}};required=@('path')}}},
      @{type='function';function=@{name='search_text';description='Search text recursively or within a path.';parameters=@{type='object';properties=@{pattern=@{type='string'};path=@{type='string'};maxResults=@{type='integer'}};required=@('pattern')}}},
      @{type='function';function=@{name='write_file';description='Write complete UTF-8 text content to a file inside the worker root.';parameters=@{type='object';properties=@{path=@{type='string'};content=@{type='string'}};required=@('path','content')}}},
      @{type='function';function=@{name='replace_text';description='Replace one exact text block in a file. Fails unless the old text occurs exactly once.';parameters=@{type='object';properties=@{path=@{type='string'};old=@{type='string'};new=@{type='string'}};required=@('path','old','new')}}},
      @{type='function';function=@{name='run_command';description='Run a bounded PowerShell command in the worker root.';parameters=@{type='object';properties=@{command=@{type='string'};timeoutSeconds=@{type='integer'}};required=@('command')}}},
      @{type='function';function=@{name='git_diff';description='Return git status and diff for the worker checkout.';parameters=@{type='object';properties=@{}}}},
      @{type='function';function=@{name='finish';description='Finish the bounded task. Use summary for the final worker/reviewer output, including VERDICT lines when the task is a review.';parameters=@{type='object';properties=@{summary=@{type='string'}};required=@('summary')}}}
    )
}
function Get-SCArgValue($Args,[string]$Name,$Default=$null){if($Args-and$Args.PSObject.Properties[$Name]){return $Args.$Name};return $Default}
function Invoke-SCWorkerTool([string]$Name,$Args) {
    switch($Name){
      'read_file' { $path=Resolve-SCWorkerPath ([string](Get-SCArgValue $Args 'path'));$start=[Math]::Max(1,[int](Get-SCArgValue $Args 'startLine' 1));$max=[Math]::Min(2000,[Math]::Max(1,[int](Get-SCArgValue $Args 'maxLines' 400)));$lines=@(Get-Content -LiteralPath $path -Encoding UTF8);$slice=@($lines|Select-Object -Skip ($start-1) -First $max);return (($slice|ForEach-Object -Begin{$n=$start} -Process{"{0,5}: {1}"-f$n,$_ ;$n++})-join"`n") }
      'search_text' { $pattern=[string](Get-SCArgValue $Args 'pattern');$rel=[string](Get-SCArgValue $Args 'path' '.');$root=Resolve-SCWorkerPath $rel;$max=[Math]::Min(500,[Math]::Max(1,[int](Get-SCArgValue $Args 'maxResults' 100)));$files=if(Test-Path -LiteralPath $root -PathType Leaf){@((Get-Item -LiteralPath $root))}else{@(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.FullName -notmatch '[\\/]\.git[\\/]|[\\/]\.statefulclanker[\\/]'} )};$hits=@();foreach($f in $files){try{foreach($m in @(Select-String -LiteralPath $f.FullName -Pattern $pattern -SimpleMatch -ErrorAction Stop)){ $hits+=("{0}:{1}: {2}"-f($f.FullName.Substring((Get-SCRoot).Length).TrimStart('\\','/')),$m.LineNumber,$m.Line.Trim());if($hits.Count-ge$max){break}}}catch{};if($hits.Count-ge$max){break}};return ($hits-join"`n") }
      'write_file' { $path=Resolve-SCWorkerPath ([string](Get-SCArgValue $Args 'path')) -AllowMissing;$parent=Split-Path -Parent $path;if($parent-and-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null};[IO.File]::WriteAllText($path,[string](Get-SCArgValue $Args 'content'),(New-Object Text.UTF8Encoding($false)));return 'written' }
      'replace_text' { $path=Resolve-SCWorkerPath ([string](Get-SCArgValue $Args 'path'));$old=[string](Get-SCArgValue $Args 'old');$new=[string](Get-SCArgValue $Args 'new');$text=[IO.File]::ReadAllText($path);$first=$text.IndexOf($old,[StringComparison]::Ordinal);if($first-lt0){throw 'old text not found'};$second=$text.IndexOf($old,$first+$old.Length,[StringComparison]::Ordinal);if($second-ge0){throw 'old text occurs more than once'};$updated=$text.Substring(0,$first)+$new+$text.Substring($first+$old.Length);[IO.File]::WriteAllText($path,$updated,(New-Object Text.UTF8Encoding($false)));return 'replaced' }
      'run_command' { $timeout=[int](Get-SCArgValue $Args 'timeoutSeconds' 120);return ConvertTo-SCJson (Invoke-SCBoundedCommand ([string](Get-SCArgValue $Args 'command')) $timeout) 6 }
      'git_diff' { return ConvertTo-SCJson ([ordered]@{status=(Invoke-SCBoundedCommand 'git status --short' 30).stdout;diff=(Invoke-SCBoundedCommand 'git diff --no-ext-diff' 60).stdout}) 6 }
      'finish' { return [string](Get-SCArgValue $Args 'summary') }
      default { throw "Unknown worker tool: $Name" }
    }
}
function New-SCDirectWorkerSystemPrompt([string]$ToolMode) {
    $common=@'
You are a bounded StatefulClanker implementation worker. Complete only the supplied task. The supplied CURRENT HUMAN DIRECTIVES and normalized Intent are authoritative and read-only. Inspect before editing. Prefer small exact changes. Test your work when practical. Never silently reinterpret specification authority. If materially ambiguous after inspecting available context, finish with INTENT_QUESTION: <question> or INTENT_CONFLICT: <conflict>. If required context is missing, finish with CONTEXT_REQUEST: <specific context>. Do not plan unrelated work.
'@
    if($ToolMode-eq'text'){return $common+@'
This endpoint is configured for the text tool protocol. On every turn output exactly one compact JSON object and no markdown. To call a tool: {"tool":"read_file","arguments":{"path":"x"}}. To finish: {"final":"summary"}. Available tools: read_file, search_text, write_file, replace_text, run_command, git_diff, finish.
'@}
    return $common
}
function Invoke-SCApiChat($Connection,$Messages,$Tools,[string]$ToolMode) {
    $body=[ordered]@{model=[string]$Connection.model;messages=@($Messages)}
    if($ToolMode-ne'text'){$body.tools=$Tools;$body.tool_choice='auto'}
    if($Connection.PSObject.Properties['temperature']-and$null-ne$Connection.temperature){$body.temperature=[double]$Connection.temperature}
    if($Connection.PSObject.Properties['maxTokens']-and[int]$Connection.maxTokens-gt0){$body.max_tokens=[int]$Connection.maxTokens}
    if($Connection.PSObject.Properties['body']-and$Connection.body){foreach($p in $Connection.body.PSObject.Properties){$body[$p.Name]=$p.Value}}
    $json=$body|ConvertTo-Json -Depth 40 -Compress
    try{return Invoke-RestMethod -Method Post -Uri (Get-SCApiUri $Connection) -Headers (New-SCApiHeaders $Connection) -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 300}catch{throw "Direct inference request failed: $($_.Exception.Message)"}
}
function Get-SCAssistantMessage($Response) {
    if($null-eq$Response-or$null-eq$Response.choices-or@($Response.choices).Count-eq0){throw 'Inference endpoint returned no choices.'}
    return $Response.choices[0].message
}
function Invoke-SCDirectWorkerLoop($Connection,[string]$Prompt) {
    $toolMode=if($Connection.PSObject.Properties['toolMode']-and$Connection.toolMode){[string]$Connection.toolMode}else{'native'};if(@('native','text')-notcontains$toolMode){throw "Unsupported toolMode '$toolMode'."}
    $maxSteps=if($Connection.PSObject.Properties['maxSteps']){[Math]::Min(100,[Math]::Max(1,[int]$Connection.maxSteps))}else{24}
    $messages=@(@{role='system';content=New-SCDirectWorkerSystemPrompt $toolMode},@{role='user';content=$Prompt});$tools=Get-SCWorkerToolDefinitions
    for($step=1;$step-le$maxSteps;$step++){
        $response=Invoke-SCApiChat $Connection $messages $tools $toolMode;$m=Get-SCAssistantMessage $response
        if($toolMode-eq'text'){
            $raw=[string]$m.content;try{$cmd=$raw|ConvertFrom-Json}catch{throw "Text-tool model returned invalid JSON at step $step: $raw"}
            if($cmd.PSObject.Properties['final']){return [string]$cmd.final}
            if(-not$cmd.PSObject.Properties['tool']){throw "Text-tool model returned neither tool nor final at step $step."}
            $result=try{Invoke-SCWorkerTool ([string]$cmd.tool) $cmd.arguments}catch{"TOOL_ERROR: $($_.Exception.Message)"}
            if([string]$cmd.tool-eq'finish'){return [string]$result}
            $messages+=@{role='assistant';content=$raw};$messages+=@{role='user';content="TOOL_RESULT $($cmd.tool):`n$result"};continue
        }
        $calls=@();if($m.PSObject.Properties['tool_calls']-and$m.tool_calls){$calls=@($m.tool_calls)}
        if($calls.Count-eq0){if(-not[string]::IsNullOrWhiteSpace([string]$m.content)){return [string]$m.content};throw "Model returned no content or tool call at step $step."}
        $messages+=@{role='assistant';content=$m.content;tool_calls=@($calls)}
        foreach($call in $calls){$name=[string]$call.function.name;try{$args=if([string]::IsNullOrWhiteSpace([string]$call.function.arguments)){[pscustomobject]@{}}else{[string]$call.function.arguments|ConvertFrom-Json};$result=try{Invoke-SCWorkerTool $name $args}catch{"TOOL_ERROR: $($_.Exception.Message)"}}catch{$result="TOOL_ERROR: malformed arguments: $($_.Exception.Message)"};if($name-eq'finish'){return [string]$result};$messages+=@{role='tool';tool_call_id=[string]$call.id;content=[string]$result}}
    }
    throw "Direct worker exceeded maxSteps=$maxSteps without finishing."
}
function Invoke-SCDirectApiProvider($Task,[string]$Prompt,[string]$Stage,$ProviderRecord,[string]$ParentAgentId,$Compilation) {
    $connectionName=[string]$ProviderRecord.config.connection;$connection=Get-SCMachineConnection $connectionName
    $receiptId=New-SCId $Stage;$agentId=New-SCId 'agent';$promptPath=Get-SCPath ("prompts/{0}.txt"-f$receiptId);$Prompt|Set-Content -LiteralPath $promptPath -Encoding UTF8
    $stdoutPath=Get-SCPath ("runs/{0}.stdout.txt"-f$receiptId);$stderrPath=Get-SCPath ("runs/{0}.stderr.txt"-f$receiptId);$started=(Get-Date).ToUniversalTime();$compilationId=if($Compilation){$Compilation.id}else{$null};$fingerprint=if($Compilation){$Compilation.inputFingerprint}else{$null};$retrievedChars=0;if($Compilation-and$Compilation.ir.sources.retrieved){$retrievedChars=[int]$Compilation.ir.sources.retrieved.usedChars}
    $telemetry=[ordered]@{schemaVersion=3;agentId=$agentId;receiptId=$receiptId;parentAgentId=$ParentAgentId;taskId=$Task.id;taskTitle=$Task.title;stage=$Stage;provider=$ProviderRecord.name;backendType='api';connection=$connectionName;model=[string]$connection.model;lifecycle='running';processId=$null;startedAt=$started.ToString('o');heartbeatAt=$started.ToString('o');endedAt=$null;durationSeconds=$null;promptChars=$Prompt.Length;retrievedChars=$retrievedChars;compilationId=$compilationId;inputFingerprint=$fingerprint;command='direct-api';args=@();exitCode=$null;verdict=$null;stdoutPath=$stdoutPath;stderrPath=$stderrPath;error=$null}
    Save-SCActiveTelemetry $telemetry;Add-SCTelemetryEvent 'agent.started' $telemetry;$stdout='';$stderr='';$exitCode=-1
    try{$stdout=Invoke-SCDirectWorkerLoop $connection $Prompt;$stdout|Set-Content -LiteralPath $stdoutPath -Encoding UTF8;$exitCode=0}catch{$stderr=$_|Out-String;$stderr|Set-Content -LiteralPath $stderrPath -Encoding UTF8;$telemetry.error=$stderr;$exitCode=-1}
    $ended=(Get-Date).ToUniversalTime();$telemetry.lifecycle=if($exitCode-eq0){'completed'}else{'failed'};$telemetry.exitCode=$exitCode;$telemetry.endedAt=$ended.ToString('o');$telemetry.heartbeatAt=$telemetry.endedAt;$telemetry.durationSeconds=[math]::Round(($ended-$started).TotalSeconds,3);Complete-SCTelemetry $telemetry
    return [pscustomobject][ordered]@{schemaVersion=3;id=$receiptId;agentId=$agentId;taskId=$Task.id;stage=$Stage;provider=$ProviderRecord.name;backendType='api';connection=$connectionName;model=[string]$connection.model;compilationId=$compilationId;inputFingerprint=$fingerprint;command='direct-api';args=@();promptPath=$promptPath;startedAt=$started.ToString('o');endedAt=$ended.ToString('o');durationSeconds=$telemetry.durationSeconds;exitCode=$exitCode;stdout=$stdout;stderr=$stderr;verdict=$null}
}
function Invoke-SCProvider($Task,[string]$Prompt,[string]$Stage,[string]$ProviderOverride,[string]$ParentAgentId=$null,$Compilation=$null) {
    $record=Resolve-SCProvider $Task $ProviderOverride $Stage;$type=if($record.config.PSObject.Properties['type']){[string]$record.config.type}else{'cli'}
    if($type-eq'api'){return Invoke-SCDirectApiProvider $Task $Prompt $Stage $record $ParentAgentId $Compilation}
    return (& $script:SCInvokeProviderCliBase $Task $Prompt $Stage $ProviderOverride $ParentAgentId $Compilation)
}

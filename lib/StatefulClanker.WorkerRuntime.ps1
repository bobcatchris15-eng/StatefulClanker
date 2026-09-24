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
function Get-SCEffectiveApiConnection($ProviderRecord) {
    $connectionName=[string]$ProviderRecord.config.connection
    $base=Get-SCMachineConnection $connectionName
    $copy=[ordered]@{}
    foreach($p in $base.PSObject.Properties){$copy[$p.Name]=$p.Value}
    foreach($name in @('model','toolMode','maxSteps','maxTokens','temperature','chatPath','body')){
        if($ProviderRecord.config.PSObject.Properties[$name] -and $null-ne$ProviderRecord.config.$name){
            $copy[$name]=$ProviderRecord.config.$name
        }
    }
    if((-not$copy.Contains('model')) -or [string]::IsNullOrWhiteSpace([string]$copy.model)){
        throw "API endpoint '$($ProviderRecord.name)' does not specify a model. Add a discovered model to the project endpoint."
    }
    if((-not$copy.Contains('toolMode')) -or [string]::IsNullOrWhiteSpace([string]$copy.toolMode)){$copy['toolMode']='native'}
    return [pscustomobject]$copy
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
function Get-SCConnectionProtocol($Connection) {
    if($Connection.PSObject.Properties['protocol']-and$Connection.protocol){return [string]$Connection.protocol}
    return 'openai-chat'
}
function Get-SCEffectiveWorkerToolMode($Connection) {
    $toolMode=if($Connection.PSObject.Properties['toolMode']-and$Connection.toolMode){[string]$Connection.toolMode}else{'native'}
    if($toolMode-eq'native'){
        $model=if($Connection.PSObject.Properties['model']){[string]$Connection.model}else{''}
        $baseUrl=if($Connection.PSObject.Properties['baseUrl']){[string]$Connection.baseUrl}else{''}
        # Cohere's OpenAI-compatible surfaces do not reliably accept the canonical
        # role=tool continuation used by this worker (their tool_results require
        # provider-specific outputs). Use the text protocol so no native tool
        # request is emitted until a dedicated Cohere adapter exists.
        if($model-match'(?i)^cohere/'-or$baseUrl-match'(?i)(^|\.)cohere\.ai(?:/|$)'){return 'text'}
    }
    return $toolMode
}
function Get-SCConnectionAuthKind($Connection) {
    if($Connection.PSObject.Properties['authKind']-and$Connection.authKind){return ([string]$Connection.authKind).ToLowerInvariant()}
    if((Get-SCConnectionProtocol $Connection)-eq'anthropic-messages'){return 'x-api-key'}
    return 'bearer'
}
function Get-SCApiUri($Connection) {
    $base=[string]$Connection.baseUrl;if([string]::IsNullOrWhiteSpace($base)){throw 'API connection baseUrl is required.'}
    if($Connection.PSObject.Properties['chatPath']-and$Connection.chatPath){return $base.TrimEnd('/')+'/'+([string]$Connection.chatPath).TrimStart('/')}
    $protocol=Get-SCConnectionProtocol $Connection
    if($protocol-eq'anthropic-messages'){
        if($base.TrimEnd('/') -match '/v1/messages$'){return $base.TrimEnd('/')}
        return $base.TrimEnd('/')+'/v1/messages'
    }
    if($protocol-eq'gemini-native'){
        $model=([string]$Connection.model)-replace'^models/',''
        return $base.TrimEnd('/')+'/models/'+[uri]::EscapeDataString($model)+':generateContent'
    }
    if($base.TrimEnd('/') -match '/chat/completions$'){return $base.TrimEnd('/')}
    return $base.TrimEnd('/')+'/chat/completions'
}
function ConvertTo-SCHashtable($Object) {
    $h=@{};if($null-eq$Object){return $h}
    foreach($p in $Object.PSObject.Properties){$h[$p.Name]=[string]$p.Value};return $h
}
function Get-SCProjectSessionId {
    $root=[IO.Path]::GetFullPath((Get-SCStateRoot)).ToLowerInvariant().TrimEnd([char[]]'\/')
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$bytes=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($root))}finally{$sha.Dispose()}
    $g=New-Object 'byte[]' 16
    [Array]::Copy($bytes,$g,16)
    $g[6]=[byte]((($g[6]-band 0x0f)-bor 0x50))
    $g[8]=[byte]((($g[8]-band 0x3f)-bor 0x80))
    return ([guid]$g).ToString()
}
function New-SCApiHeaders($Connection) {
    $headers=@{'Accept'='application/json'}
    $key=Get-SCApiKey $Connection
    if($key){
        switch(Get-SCConnectionAuthKind $Connection){
            'x-api-key' {$headers['x-api-key']=$key}
            'x-goog-api-key' {$headers['x-goog-api-key']=$key}
            'none' {}
            default {$headers['Authorization']='Bearer '+$key}
        }
    }
    if($Connection.PSObject.Properties['headers']-and$Connection.headers){
        $extra=ConvertTo-SCHashtable $Connection.headers
        foreach($k in $extra.Keys){$headers[$k]=$extra[$k]}
    }
    # OpenCode uses a stable project session id for cache routing. The preset merely
    # declares the header; the user never has to manufacture or maintain its value.
    if($headers.ContainsKey('x-opencode-session')){$headers['x-opencode-session']=Get-SCProjectSessionId}
    return $headers
}
function Resolve-SCWorkerPath([string]$Path,[switch]$AllowMissing) {
    if([string]::IsNullOrWhiteSpace($Path)){throw 'path required'}
    $root=[IO.Path]::GetFullPath((Get-SCRoot)).TrimEnd([char[]]'\/')
    $candidate=if([IO.Path]::IsPathRooted($Path)){[IO.Path]::GetFullPath($Path)}else{[IO.Path]::GetFullPath((Join-Path $root $Path))}
    if(-not($candidate.Equals($root,[StringComparison]::OrdinalIgnoreCase)-or$candidate.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))){throw "Path escapes worker root: $Path"}
    if(-not$AllowMissing-and-not(Test-Path -LiteralPath $candidate)){throw "Path not found: $Path"}
    return $candidate
}

# Worker safety guards. These are intentionally narrow: they reject only a
# concrete attempt to leave the worker root, mutate orchestration/Git control
# state through a generic worker tool, or terminate StatefulClanker itself.
# Ordinary failures, rejected work, and hallucinated tool names do not halt
# subsequent worker operations.
function Get-SCWorkerBoundaryViolationLimit() {
    $cfg=try{Get-SCConfig}catch{$null}
    if($cfg -and $cfg.PSObject.Properties['workerBoundaryViolationLimit'] -and [int]$cfg.workerBoundaryViolationLimit -gt 0){
        return [int]$cfg.workerBoundaryViolationLimit
    }
    return 3
}
# Per-session boundary violation counters. Keyed by worker session id when one
# exists, otherwise by task id, so escalation is scoped to the running worker
# rather than accumulating across unrelated tasks.
$script:SCWorkerBoundaryViolationCounts=@{}
function Get-SCWorkerBoundaryKey($Task,[string]$WorkerSessionId) {
    if(-not[string]::IsNullOrWhiteSpace($WorkerSessionId)){return $WorkerSessionId}
    if($Task -and $Task.PSObject.Properties['id']){return [string]$Task.id}
    return 'unknown'
}
function Reset-SCWorkerBoundaryViolationCount($Task,[string]$WorkerSessionId) {
    $key=Get-SCWorkerBoundaryKey $Task $WorkerSessionId
    if($script:SCWorkerBoundaryViolationCounts.ContainsKey($key)){$script:SCWorkerBoundaryViolationCounts.Remove($key)}
}
# Records a blocked boundary escape as a first-class control-plane event
# (rather than a generic worker.tool_error) and returns the running count for
# this session/task so the caller can decide whether to escalate. The access
# itself is still blocked by the guard that calls this; this never authorizes it.
function Add-SCWorkerBoundaryViolation($Task,[string]$WorkerSessionId,[string]$Stage,[string]$ToolName,[string]$Kind,[string]$Attempted) {
    $key=Get-SCWorkerBoundaryKey $Task $WorkerSessionId
    $text=[string]$Attempted
    $truncated=if($text.Length-gt200){$text.Substring(0,200)+'...'}else{$text}
    $count=if($script:SCWorkerBoundaryViolationCounts.ContainsKey($key)){[int]$script:SCWorkerBoundaryViolationCounts[$key]+1}else{1}
    $script:SCWorkerBoundaryViolationCounts[$key]=$count
    $taskId=if($Task -and $Task.PSObject.Properties['id']){[string]$Task.id}else{$null}
    Add-SCEvent 'worker.boundary_violation' "Worker attempted a boundary-violating $Kind via $ToolName." @{taskId=$taskId;sessionId=$WorkerSessionId;stage=$Stage;tool=$ToolName;kind=$Kind;attempted=$truncated;count=$count}
    return $count
}
# Ends the worker turn loop and marks the task needs_rework once violations hit
# the configured (or default) threshold. Below threshold, work continues.
function Test-SCWorkerBoundaryEscalation($Task,[string]$WorkerSessionId,[string]$Stage,[int]$Count) {
    $limit=Get-SCWorkerBoundaryViolationLimit
    if($Count-lt$limit){return $false}
    $taskId=if($Task -and $Task.PSObject.Properties['id']){[string]$Task.id}else{$null}
    $reason="Worker boundary violations reached limit ($Count/$limit) in this session."
    Add-SCEvent 'worker.boundary_escalated' $reason @{taskId=$taskId;sessionId=$WorkerSessionId;stage=$Stage;count=$Count;limit=$limit}
    if($taskId){
        try{
            $t=Get-SCTask $taskId
            if($t){$t.status='needs_rework';$t.blockReason=$reason;Save-SCTask $t}
        }catch{}
    }
    Reset-SCWorkerBoundaryViolationCount $Task $WorkerSessionId
    return $true
}
function Resolve-SCWorkerToolPath([string]$Path,$Task,[string]$ToolName,[switch]$AllowMissing,[string]$Stage='worker',[string]$WorkerSessionId=$null) {
    try {
        if($AllowMissing){return Resolve-SCWorkerPath $Path -AllowMissing}
        return Resolve-SCWorkerPath $Path
    } catch {
        if($_.Exception.Message -match '^Path escapes worker root'){
            $kind=if($ToolName-in@('read_file','search_text','git_diff')){'read'}else{'write'}
            $count=Add-SCWorkerBoundaryViolation $Task $WorkerSessionId $Stage $ToolName $kind $Path
            if(Test-SCWorkerBoundaryEscalation $Task $WorkerSessionId $Stage $count){throw ("BOUNDARY_ESCALATED: "+$_.Exception.Message)}
        }
        throw
    }
}
function Assert-SCWorkerMutablePath([string]$ResolvedPath,$Task,[string]$ToolName,[string]$Stage='worker',[string]$WorkerSessionId=$null) {
    $root=[IO.Path]::GetFullPath((Get-SCRoot)).TrimEnd([char[]]'\/')
    $relative=if($ResolvedPath.Length-gt$root.Length){$ResolvedPath.Substring($root.Length).TrimStart([char[]]'\/')}else{''}
    $protected=(
        $relative.Equals('.statefulclanker',[StringComparison]::OrdinalIgnoreCase) -or
        $relative.StartsWith('.statefulclanker'+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
        $relative.Equals('.git',[StringComparison]::OrdinalIgnoreCase) -or
        $relative.StartsWith('.git'+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
    )
    if($protected){
        $count=Add-SCWorkerBoundaryViolation $Task $WorkerSessionId $Stage $ToolName 'control-state' $relative
        if(Test-SCWorkerBoundaryEscalation $Task $WorkerSessionId $Stage $count){throw "BOUNDARY_ESCALATED: Worker mutation of control state is forbidden: $relative"}
        throw "Worker mutation of control state is forbidden: $relative"
    }
}
function Test-SCWorkerCommandPathToken([string]$Token) {
    if([string]::IsNullOrWhiteSpace($Token)){return $null}
    $text=$Token.Trim().Trim('"').Trim("'")
    if($text -match '^--?[^=]+=(.+)$'){$text=$Matches[1].Trim().Trim('"').Trim("'")}
    if([string]::IsNullOrWhiteSpace($text)){return $null}

    # Common environment locations resolve outside the project and can otherwise
    # hide an escape from a static path check.
    if($text -match '(?i)\$env:(TEMP|TMP|USERPROFILE|APPDATA|LOCALAPPDATA|PROGRAMDATA|SYSTEMROOT|WINDIR)(?:[\\/]|$)'){
        return [pscustomobject]@{outside=$true;token=$Token;resolved='<external environment path>'}
    }
    if($text.StartsWith('~')){
        return [pscustomobject]@{outside=$true;token=$Token;resolved='<user profile>'}
    }

    # Switch exceptions belong to the command argument context, never to this
    # path validator: redirection targets must always be checked as paths.
    $looksPath=[IO.Path]::IsPathRooted($text) -or $text -match '(^|[\\/])\.\.([\\/]|$)'
    if(-not$looksPath){return $null}

    $probe=$text
    $wild=$probe.IndexOfAny([char[]]'*?')
    if($wild-ge0){$probe=$probe.Substring(0,$wild)}
    if([string]::IsNullOrWhiteSpace($probe)){$probe='.'}
    try {
        $root=[IO.Path]::GetFullPath((Get-SCRoot)).TrimEnd([char[]]'\/')
        $candidate=if([IO.Path]::IsPathRooted($probe)){[IO.Path]::GetFullPath($probe)}else{[IO.Path]::GetFullPath((Join-Path $root $probe))}
        $inside=$candidate.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
        return [pscustomobject]@{outside=(-not$inside);token=$Token;resolved=$candidate}
    } catch {
        return $null
    }
}
function Assert-SCWorkerCommandSafe([string]$Command,$Task,[string]$Stage='worker',[string]$WorkerSessionId=$null) {
    if([string]::IsNullOrWhiteSpace($Command)){throw 'command required'}

    $tokens=$null
    $parseErrors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput($Command,[ref]$tokens,[ref]$parseErrors)
    $classicSwitches=@{
        'cmd'=@('/?','/a','/c','/d','/k','/q','/s','/u','/v:on','/v:off','/e:on','/e:off','/f:on','/f:off')
        'dir'=@('/?','/4','/a','/b','/c','/d','/l','/n','/p','/q','/r','/s','/w','/x')
        'taskkill'=@('/?','/im','/pid','/f','/t')
    }
    foreach($cmd in @($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.CommandAst]},$true))){
        $elements=@($cmd.CommandElements)
        $commandName=[IO.Path]::GetFileNameWithoutExtension($cmd.GetCommandName())
        # Bare dir is a PowerShell alias, not the cmd.exe built-in.
        $classicCommand=if($commandName-in@('cmd','taskkill')){$commandName.ToLowerInvariant()}else{''}
        $awaitCmdCommand=$false
        # Element zero is the executable/cmdlet. An absolute executable path is
        # allowed; access performed by its arguments must remain in-project.
        for($i=1;$i-lt$elements.Count;$i++){
            $el=$elements[$i]
            $value=if($el -is [System.Management.Automation.Language.StringConstantExpressionAst]){[string]$el.Value}else{[string]$el.Extent.Text}
            if($awaitCmdCommand){
                $nestedName=[IO.Path]::GetFileNameWithoutExtension($value)
                $classicCommand=if($nestedName-in@('cmd','dir','taskkill')){$nestedName.ToLowerInvariant()}else{''}
                $awaitCmdCommand=$false
            }elseif($classicCommand-and$classicSwitches[$classicCommand]-contains$value.ToLowerInvariant()){
                if($classicCommand-eq'cmd'-and$value-in@('/c','/k')){$awaitCmdCommand=$true}
                continue
            }
            $check=Test-SCWorkerCommandPathToken $value
            if($check-and$check.outside){
                $count=Add-SCWorkerBoundaryViolation $Task $WorkerSessionId $Stage 'run_command' 'command' $Command
                if(Test-SCWorkerBoundaryEscalation $Task $WorkerSessionId $Stage $count){throw "BOUNDARY_ESCALATED: run_command path escapes worker root: $($check.token)"}
                throw "run_command path escapes worker root: $($check.token)"
            }
        }
        foreach($redir in @($cmd.Redirections)){
            $raw=([string]$redir.Extent.Text -replace '^\s*\d*\s*>+\s*','').Trim()
            if($raw -eq '/dev/null'){throw 'run_command uses PowerShell on Windows: /dev/null is not a valid redirection target. Use Out-Null or a file inside the worker root.'}
            $check=Test-SCWorkerCommandPathToken $raw
            if($check-and$check.outside){
                $count=Add-SCWorkerBoundaryViolation $Task $WorkerSessionId $Stage 'run_command' 'command' $Command
                if(Test-SCWorkerBoundaryEscalation $Task $WorkerSessionId $Stage $count){throw "BOUNDARY_ESCALATED: run_command redirection escapes worker root: $($check.token)"}
                throw "run_command redirection escapes worker root: $($check.token)"
            }
        }
    }

    $mutates='(?i)(Set-Content|Add-Content|Out-File|Remove-Item|Move-Item|Copy-Item|Rename-Item|New-Item|Clear-Content|Set-Item(?:Property)?|Remove-ItemProperty|\[IO\.File\]::(?:Write|Delete|Move|Copy)|(?:^|[;&|])\s*(?:del|erase|rm|rmdir|rd|move|copy)\b|(?:^|\s)\d*>>?\s*)'
    $control='(?i)(?:^|[\\/"\s])\.(?:statefulclanker|git)(?:[\\/"\s]|$)'
    if($Command-match$mutates-and$Command-match$control){
        $count=Add-SCWorkerBoundaryViolation $Task $WorkerSessionId $Stage 'run_command' 'control-state' $Command
        if(Test-SCWorkerBoundaryEscalation $Task $WorkerSessionId $Stage $count){throw 'BOUNDARY_ESCALATED: run_command may not mutate .statefulclanker or .git control state.'}
        throw 'run_command may not mutate .statefulclanker or .git control state.'
    }

    if($Command-match'(?i)\b(Stop-Process|taskkill(?:\.exe)?|kill(?:\.exe)?)\b' -and $Command-match'(?i)StatefulClanker|Clanker\.Tray'){
        throw 'Workers may not terminate StatefulClanker oversight processes.'
    }
}
function Invoke-SCBoundedCommand([string]$Command,[int]$TimeoutSeconds=120) {
    if([string]::IsNullOrWhiteSpace($Command)){throw 'command required'}
    $shell=if(Get-Command pwsh.exe -ErrorAction SilentlyContinue){'pwsh.exe'}else{'powershell.exe'}
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$shell;$psi.WorkingDirectory=Get-SCRoot;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    [void]$psi.ArgumentList.Add('-NoProfile');[void]$psi.ArgumentList.Add('-NonInteractive');[void]$psi.ArgumentList.Add('-Command');[void]$psi.ArgumentList.Add($Command)
    $p=New-Object Diagnostics.Process;$p.StartInfo=$psi
    try{[void]$p.Start();$stdoutTask=$p.StandardOutput.ReadToEndAsync();$stderrTask=$p.StandardError.ReadToEndAsync();if(-not$p.WaitForExit($TimeoutSeconds*1000)){try{$p.Kill()}catch{};return [ordered]@{exitCode=-2;stdout='';stderr="Command timed out after $TimeoutSeconds seconds."}};$stdout=$stdoutTask.Result;$stderr=$stderrTask.Result;return [ordered]@{exitCode=$p.ExitCode;stdout=$stdout;stderr=$stderr}}finally{$p.Dispose()}
}
function New-SCWorkerToolRecord([string]$Capability,[string]$WireName,[string]$Description,$Parameters,[string]$Kind='builtin',[string]$Source=$null,[string]$ExternalTool=$null) {
    return [ordered]@{capability=$Capability;wireName=$WireName;kind=$Kind;source=$Source;externalTool=$ExternalTool;definition=@{type='function';function=@{name=$WireName;description=$Description;parameters=$Parameters}}}
}
function Get-SCIntrinsicWorkerToolRecords($Task,[string]$Stage='worker') {
    $candidates=@(
      (New-SCWorkerToolRecord 'builtin.read_file' 'read_file' 'Read a UTF-8 text file inside the worker root.' @{type='object';properties=@{path=@{type='string'};startLine=@{type='integer'};maxLines=@{type='integer'}};required=@('path')}),
      (New-SCWorkerToolRecord 'builtin.search_text' 'search_text' 'Search text recursively or within a path.' @{type='object';properties=@{pattern=@{type='string'};path=@{type='string'};maxResults=@{type='integer'}};required=@('pattern')}),
      (New-SCWorkerToolRecord 'builtin.write_file' 'write_file' 'Write complete UTF-8 text content to a file inside the worker root.' @{type='object';properties=@{path=@{type='string'};content=@{type='string'}};required=@('path','content')}),
      (New-SCWorkerToolRecord 'builtin.replace_text' 'replace_text' 'Replace one exact text block in a file. Fails unless the old text occurs exactly once.' @{type='object';properties=@{path=@{type='string'};old=@{type='string'};new=@{type='string'}};required=@('path','old','new')}),
      (New-SCWorkerToolRecord 'builtin.run_command' 'run_command' 'Run a bounded PowerShell command in the worker root. Use Windows/PowerShell syntax and Out-Null, not /dev/null; absolute file paths must remain in this worker root.' @{type='object';properties=@{command=@{type='string'};timeoutSeconds=@{type='integer'}};required=@('command')}),
      (New-SCWorkerToolRecord 'builtin.git_diff' 'git_diff' 'Return git status and diff for the worker checkout.' @{type='object';properties=@{}}),
      (New-SCWorkerToolRecord 'intent.human.read' 'read_human_intent' 'Read an authoritative durable human/source artifact by human:<id> reference. Read-only.' @{type='object';properties=@{sourceRef=@{type='string';description='human:<id> optionally with #Lx-Ly'}};required=@('sourceRef')}),
      (New-SCWorkerToolRecord 'intent.normalized.read' 'read_normalized_intent' 'Read the current orchestrator-owned normalized Intent Contract plus current direct human directives. Read-only.' @{type='object';properties=@{}}),
      (New-SCWorkerToolRecord 'builtin.finish' 'finish' 'Submit the current work as a completion candidate. summary is required; expectedArtifacts and verification are claims for the harness to verify independently. Reviews may still use VERDICT lines in summary.' @{type='object';properties=@{summary=@{type='string'};expectedArtifacts=@{type='array';description='Exact project-relative paths that should exist in the submitted candidate; paths only, not prose.';items=@{type='string'}};verification=@{type='array';description='Commands/checks actually performed, stated compactly. Do not claim checks you did not run.';items=@{type='string'}}};required=@('summary')})
    )
    return @($candidates|Where-Object{Test-SCWorkerCapabilityAllowed ([string]$_.capability) $Task $Stage})
}
function Get-SCWorkerToolRecords($Task,[string]$Stage='worker') {
    $records=@(Get-SCIntrinsicWorkerToolRecords $Task $Stage)
    foreach($external in @(Get-SCExternalWorkerToolRecords $Task $Stage)){
        $records+=,(New-SCWorkerToolRecord ([string]$external.capability) ([string]$external.wireName) ([string]$external.description) $external.inputSchema 'mcp' ([string]$external.source) ([string]$external.tool))
    }
    return @($records)
}
function Get-SCArgValue($ToolArgs,[string]$Name,$Default=$null){if($ToolArgs-and$ToolArgs.PSObject.Properties[$Name]){return $ToolArgs.$Name};return $Default}
function Write-SCWorkerToolFailure($Task,[string]$Stage,[string]$ToolName,[string]$Result,[int]$Step) {
    if(-not$Result.StartsWith('TOOL_ERROR:')){return}
    Add-SCEvent 'worker.tool_error' $Result @{taskId=$Task.id;stage=$Stage;tool=$ToolName;step=$Step;error=$Result}
}
function Invoke-SCWorkerTool([string]$Name,$ToolArgs,$Task,[string]$Stage,$Registry,[string]$WorkerSessionId=$null) {
    $record=@($Registry|Where-Object{[string]$_.wireName-eq$Name}|Select-Object -First 1)
    if($record.Count-eq0){throw "Tool '$Name' is not authorized for this worker."}
    $record=$record[0];if(-not(Test-SCWorkerCapabilityAllowed ([string]$record.capability) $Task $Stage)){throw "Capability '$($record.capability)' is no longer authorized."}
    if([string]$record.kind-eq'mcp'){return Invoke-SCMcpSourceTool ([string]$record.source) ([string]$record.externalTool) $ToolArgs}
    switch($Name){
      'read_file' { $path=Resolve-SCWorkerToolPath ([string](Get-SCArgValue $ToolArgs 'path')) $Task 'read_file' -Stage $Stage -WorkerSessionId $WorkerSessionId;$start=[Math]::Max(1,[int](Get-SCArgValue $ToolArgs 'startLine' 1));$max=[Math]::Min(2000,[Math]::Max(1,[int](Get-SCArgValue $ToolArgs 'maxLines' 400)));$lines=@(Get-Content -LiteralPath $path -Encoding UTF8);$slice=@($lines|Select-Object -Skip ($start-1) -First $max);return (($slice|ForEach-Object -Begin{$n=$start} -Process{"{0,5}: {1}"-f$n,$_ ;$n++})-join"`n") }
      'search_text' { $pattern=[string](Get-SCArgValue $ToolArgs 'pattern');$rel=[string](Get-SCArgValue $ToolArgs 'path' '.');$root=Resolve-SCWorkerToolPath $rel $Task 'search_text' -Stage $Stage -WorkerSessionId $WorkerSessionId;$max=[Math]::Min(500,[Math]::Max(1,[int](Get-SCArgValue $ToolArgs 'maxResults' 100)));$files=if(Test-Path -LiteralPath $root -PathType Leaf){@((Get-Item -LiteralPath $root))}else{@(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.FullName -notmatch '[\\/]\.git[\\/]|[\\/]\.statefulclanker[\\/]'} )};$hits=@();foreach($f in $files){try{foreach($m in @(Select-String -LiteralPath $f.FullName -Pattern $pattern -SimpleMatch -ErrorAction Stop)){ $hits+=("{0}:{1}: {2}"-f($f.FullName.Substring((Get-SCRoot).Length).TrimStart([char[]]'\/')),$m.LineNumber,$m.Line.Trim());if($hits.Count-ge$max){break}}}catch{};if($hits.Count-ge$max){break}};return ($hits-join"`n") }
      'write_file' { $path=Resolve-SCWorkerToolPath ([string](Get-SCArgValue $ToolArgs 'path')) $Task 'write_file' -AllowMissing -Stage $Stage -WorkerSessionId $WorkerSessionId;Assert-SCWorkerMutablePath $path $Task 'write_file' $Stage $WorkerSessionId;$parent=Split-Path -Parent $path;if($parent-and-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null};[IO.File]::WriteAllText($path,[string](Get-SCArgValue $ToolArgs 'content'),(New-Object Text.UTF8Encoding($false)));return 'written' }
      'replace_text' { $path=Resolve-SCWorkerToolPath ([string](Get-SCArgValue $ToolArgs 'path')) $Task 'replace_text' -Stage $Stage -WorkerSessionId $WorkerSessionId;Assert-SCWorkerMutablePath $path $Task 'replace_text' $Stage $WorkerSessionId;$old=[string](Get-SCArgValue $ToolArgs 'old');$new=[string](Get-SCArgValue $ToolArgs 'new');$text=[IO.File]::ReadAllText($path);$first=$text.IndexOf($old,[StringComparison]::Ordinal);if($first-lt0){throw 'old text not found'};$second=$text.IndexOf($old,$first+$old.Length,[StringComparison]::Ordinal);if($second-ge0){throw 'old text occurs more than once'};$updated=$text.Substring(0,$first)+$new+$text.Substring($first+$old.Length);[IO.File]::WriteAllText($path,$updated,(New-Object Text.UTF8Encoding($false)));return 'replaced' }
      'run_command' { $command=[string](Get-SCArgValue $ToolArgs 'command');Assert-SCWorkerCommandSafe $command $Task $Stage $WorkerSessionId;$timeout=[int](Get-SCArgValue $ToolArgs 'timeoutSeconds' 120);return ConvertTo-SCModelText (Invoke-SCBoundedCommand $command $timeout) 6 }
      'git_diff' { return ConvertTo-SCModelText ([ordered]@{status=(Invoke-SCBoundedCommand 'git status --short' 30).stdout;diff=(Invoke-SCBoundedCommand 'git diff --no-ext-diff' 60).stdout}) 6 }
      'read_human_intent' { return ConvertTo-SCModelText (Resolve-SCHumanIntentArtifact ([string](Get-SCArgValue $ToolArgs 'sourceRef'))) 20 }
      'read_normalized_intent' { return ConvertTo-SCModelText (Get-SCNormalizedIntentView) 30 }
      'finish' { return [string](Get-SCArgValue $ToolArgs 'summary') }
      default { throw "Unknown worker tool: $Name" }
    }
}
function New-SCDirectWorkerSystemPrompt([string]$ToolMode,$Registry) {
    $available=@($Registry|ForEach-Object{"$($_.wireName) [$($_.capability)]"}) -join ', '
    $common="You are a bounded StatefulClanker implementation worker. Complete only the supplied task. CURRENT HUMAN DIRECTIVES and normalized Intent are authoritative and read-only. You may inspect direct human artifacts and the orchestrator's normalized interpretation through authorized read-only tools when needed. Inspect before editing. Prefer small exact changes. Test when practical. Never silently reinterpret specification authority. FILESYSTEM BOUNDARY: operate only inside the current project/worktree. Do not read or write project data through parent, absolute, user-profile, temp, or other outside paths; do not mutate .statefulclanker or .git control state directly; and do not terminate StatefulClanker processes. Installed executables may live outside the project, but their file arguments must remain inside the project. Boundary violations hard-trip the operator safety latch. If materially ambiguous after inspecting available authority, finish with INTENT_QUESTION: <question> or INTENT_CONFLICT: <conflict>. If required context is missing, finish with CONTEXT_REQUEST: <specific context>. Do not plan unrelated work. When you discover a durable project-specific trap, correction, file relationship, API quirk, or process rule that future workers should know, write a concise Reflexive Project Knowledge lesson when the authorized project_lesson_write tool is available; do not store guesses or generic programming advice. When reviewing a stale lesson, confirm or reject it only after checking current project evidence. For artifact-producing tasks, do not call finish until you have actually changed the required worktree artifacts. When calling finish, include expectedArtifacts and verification when you can; those are claims that StatefulClanker will check independently before spending critic inference. Only these tools are authorized for this invocation: $available"
    if($ToolMode-eq'text'){return $common+"`nThis endpoint uses the text tool protocol. On every turn output exactly one compact JSON object and no markdown. Tool call: {`"tool`":`"<authorized tool name>`",`"arguments`":{...}}. Finish: {`"final`":`"summary`"}."}
    return $common
}
function Get-SCWorkerMaxSteps($Connection,$Task,[string]$Stage='worker') {
    $cfg=try{Get-SCConfig}catch{$null}
    $taskSize=if($Task -and $Task.PSObject.Properties['size'] -and $Task.size){[string]$Task.size.ToLowerInvariant()}else{'small'}
    $hardCap=1024
    # Project-level settings are explicit operator policy and may deliberately lower the limit.
    if($cfg -and $cfg.PSObject.Properties['maxStepsBySize'] -and $cfg.maxStepsBySize.PSObject.Properties[$taskSize]){
        return [Math]::Min($hardCap,[Math]::Max(1,[int]$cfg.maxStepsBySize.$taskSize))
    }
    if($cfg -and $cfg.PSObject.Properties['maxSteps'] -and [int]$cfg.maxSteps -gt 0){
        return [Math]::Min($hardCap,[Math]::Max(1,[int]$cfg.maxSteps))
    }
    $connSteps=0
    if($Connection -and $Connection.PSObject.Properties['maxSteps'] -and [int]$Connection.maxSteps -gt 0){$connSteps=[int]$Connection.maxSteps}
    if($Stage-eq'run'){
        # Old connection profiles defaulted to 24. Cold implementation workers now get
        # a much larger floor so the harness, rather than an arbitrary turn count, is
        # normally what ends the session.
        $floor=switch($taskSize){'tiny'{512};'small'{512};'medium'{512};'large'{768};default{512}}
        return [Math]::Min($hardCap,[Math]::Max($floor,$connSteps))
    }
    if($connSteps-gt0){return [Math]::Min($hardCap,[Math]::Max(1,$connSteps))}
    switch($taskSize){
        'tiny'{return 16}
        'small'{return 24}
        'medium'{return 40}
        'large'{return 60}
        default{return 32}
    }
}
# StrictMode-safe field read for a value that may be a Hashtable (this project's
# tool/message literals, e.g. @{role='assistant';tool_calls=...}) OR a
# PSCustomObject (parsed JSON). $Obj.PSObject.Properties[$Name] does NOT see
# Hashtable keys -- it only reflects a Hashtable's own .NET members (Keys,
# Values, Count...) -- so that existence-check pattern silently reports a
# present hashtable key as missing. Under this project's Set-StrictMode -Version
# 2.0, a direct miss on either shape throws, so a real existence check is
# required rather than just trying the dot-access.
function Get-SCField($Obj,[string]$Name) {
    if($null-eq$Obj){return $null}
    if($Obj -is [System.Collections.IDictionary]){if($Obj.Contains($Name)){return $Obj[$Name]}else{return $null}}
    $p=$Obj.PSObject.Properties[$Name];if($p){return $p.Value};return $null
}
function ConvertTo-SCAnthropicTools($Tools) {
    $out=@()
    foreach($t in @($Tools)){
        $fn=Get-SCField $t 'function';if($null-eq$fn){continue}
        $out+=,[ordered]@{name=[string](Get-SCField $fn 'name');description=[string](Get-SCField $fn 'description');input_schema=(Get-SCField $fn 'parameters')}
    }
    return @($out)
}
# Translates this project's canonical OpenAI-shaped message history (role:
# system|user|assistant|tool, tool calls as assistant.tool_calls / role=tool
# replies) into Anthropic's Messages API shape: system is a separate top-level
# field, not a message; an assistant turn's tool calls become tool_use content
# blocks; and tool RESULTS become tool_result blocks inside a user turn (merging
# consecutive role=tool messages into one turn, since Anthropic expects all of a
# turn's tool results together, not one message per call the way OpenAI does).
function ConvertTo-SCAnthropicMessages($Messages) {
    $system=@();$out=@();$pendingResults=$null
    foreach($m in @($Messages)){
        $role=[string]$m.role
        if($role-eq'system'){$system+=,[string]$m.content;continue}
        if($role-eq'tool'){
            if($null-eq$pendingResults){$pendingResults=@()}
            $pendingResults+=,[ordered]@{type='tool_result';tool_use_id=[string]$m.tool_call_id;content=[string]$m.content}
            continue
        }
        if($pendingResults){$out+=,[ordered]@{role='user';content=@($pendingResults)};$pendingResults=$null}
        if($role-eq'assistant'){
            $blocks=@()
            $mContent=Get-SCField $m 'content';if(-not[string]::IsNullOrWhiteSpace([string]$mContent)){$blocks+=,[ordered]@{type='text';text=[string]$mContent}}
            $mToolCalls=Get-SCField $m 'tool_calls'
            if($mToolCalls){
                foreach($call in @($mToolCalls)){
                    $callFn=Get-SCField $call 'function';$callArgs=if($callFn){Get-SCField $callFn 'arguments'}else{$null}
                    $input=try{if([string]::IsNullOrWhiteSpace([string]$callArgs)){[pscustomobject]@{}}else{[string]$callArgs|ConvertFrom-Json}}catch{[pscustomobject]@{}}
                    $blocks+=,[ordered]@{type='tool_use';id=[string](Get-SCField $call 'id');name=[string](Get-SCField $callFn 'name');input=$input}
                }
            }
            $out+=,[ordered]@{role='assistant';content=@($blocks)}
            continue
        }
        $out+=,[ordered]@{role='user';content=[string]$m.content}
    }
    if($pendingResults){$out+=,[ordered]@{role='user';content=@($pendingResults)}}
    return [ordered]@{system=($system-join"`n`n");messages=@($out)}
}
function ConvertTo-SCGeminiTools($Tools) {
    $decl=@()
    foreach($t in @($Tools)){
        $fn=Get-SCField $t 'function';if($null-eq$fn){continue}
        $decl+=,[ordered]@{name=[string](Get-SCField $fn 'name');description=[string](Get-SCField $fn 'description');parameters=(Get-SCField $fn 'parameters')}
    }
    if($decl.Count-eq0){return @()}
    return @([ordered]@{functionDeclarations=@($decl)})
}
function ConvertTo-SCGeminiMessages($Messages) {
    $system=@();$contents=@();$callNames=@{}
    foreach($m in @($Messages)){
        $role=[string](Get-SCField $m 'role')
        if($role-eq'system'){$system+=,[string](Get-SCField $m 'content');continue}
        if($role-eq'assistant'){
            $parts=@();$text=Get-SCField $m 'content'
            if(-not[string]::IsNullOrWhiteSpace([string]$text)){$parts+=,[ordered]@{text=[string]$text}}
            foreach($call in @(Get-SCField $m 'tool_calls')){
                $fn=Get-SCField $call 'function';if($null-eq$fn){continue}
                $name=[string](Get-SCField $fn 'name');$id=[string](Get-SCField $call 'id')
                if($id){$callNames[$id]=$name}
                $raw=Get-SCField $fn 'arguments'
                $args=try{if([string]::IsNullOrWhiteSpace([string]$raw)){[pscustomobject]@{}}else{[string]$raw|ConvertFrom-Json}}catch{[pscustomobject]@{}}
                $parts+=,[ordered]@{functionCall=[ordered]@{name=$name;args=$args}}
            }
            if($parts.Count-gt0){$contents+=,[ordered]@{role='model';parts=@($parts)}}
            continue
        }
        if($role-eq'tool'){
            $id=[string](Get-SCField $m 'tool_call_id');$name=if($callNames.ContainsKey($id)){$callNames[$id]}else{'tool'}
            $contents+=,[ordered]@{role='user';parts=@([ordered]@{functionResponse=[ordered]@{name=$name;response=[ordered]@{result=[string](Get-SCField $m 'content')}}})}
            continue
        }
        $contents+=,[ordered]@{role='user';parts=@([ordered]@{text=[string](Get-SCField $m 'content')})}
    }
    return [ordered]@{system=($system-join[Environment]::NewLine+[Environment]::NewLine);contents=@($contents)}
}
function Invoke-SCApiChat($Connection,$Messages,$Tools,[string]$ToolMode) {
    $protocol=Get-SCConnectionProtocol $Connection
    if($protocol-eq'anthropic-messages'){
        $translated=ConvertTo-SCAnthropicMessages $Messages
        $body=[ordered]@{model=[string]$Connection.model;messages=$translated.messages}
        if($translated.system){$body.system=$translated.system}
        if($ToolMode-ne'text'){$body.tools=ConvertTo-SCAnthropicTools $Tools}
        $body.max_tokens=if($Connection.PSObject.Properties['maxTokens']-and[int]$Connection.maxTokens-gt0){[int]$Connection.maxTokens}else{4096}
        if($Connection.PSObject.Properties['temperature']-and$null-ne$Connection.temperature){$body.temperature=[double]$Connection.temperature}
        if($Connection.PSObject.Properties['body']-and$Connection.body){foreach($p in $Connection.body.PSObject.Properties){$body[$p.Name]=$p.Value}}
    } elseif($protocol-eq'gemini-native'){
        $translated=ConvertTo-SCGeminiMessages $Messages
        $body=[ordered]@{contents=@($translated.contents)}
        if($translated.system){$body.systemInstruction=[ordered]@{parts=@([ordered]@{text=$translated.system})}}
        if($ToolMode-ne'text'){
            $geminiTools=@(ConvertTo-SCGeminiTools $Tools)
            if($geminiTools.Count-gt0){$body.tools=$geminiTools;$body.toolConfig=[ordered]@{functionCallingConfig=[ordered]@{mode='AUTO'}}}
        }
        $generation=[ordered]@{}
        if($Connection.PSObject.Properties['temperature']-and$null-ne$Connection.temperature){$generation.temperature=[double]$Connection.temperature}
        if($Connection.PSObject.Properties['maxTokens']-and[int]$Connection.maxTokens-gt0){$generation.maxOutputTokens=[int]$Connection.maxTokens}
        if($generation.Count-gt0){$body.generationConfig=$generation}
        if($Connection.PSObject.Properties['body']-and$Connection.body){foreach($p in $Connection.body.PSObject.Properties){$body[$p.Name]=$p.Value}}
    } else {
        $body=[ordered]@{model=[string]$Connection.model;messages=@($Messages)}
        if($ToolMode-ne'text'){$body.tools=$Tools;$body.tool_choice='auto'}
        if($Connection.PSObject.Properties['temperature']-and$null-ne$Connection.temperature){$body.temperature=[double]$Connection.temperature}
        if($Connection.PSObject.Properties['maxTokens']-and[int]$Connection.maxTokens-gt0){$body.max_tokens=[int]$Connection.maxTokens}
        if((Get-SCApiUri $Connection)-match'(?i)openrouter\.ai'){$body.usage=[ordered]@{include=$true}}
        if($Connection.PSObject.Properties['body']-and$Connection.body){foreach($p in $Connection.body.PSObject.Properties){$body[$p.Name]=$p.Value}}
    }
    $json=$body|ConvertTo-Json -Depth 40 -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    $uri=Get-SCApiUri $Connection
    $headers=New-SCApiHeaders $Connection
    $timeout=300
    if($Connection.PSObject.Properties['requestTimeoutSeconds'] -and [int]$Connection.requestTimeoutSeconds-gt0){
        $timeout=[Math]::Min(1800,[Math]::Max(15,[int]$Connection.requestTimeoutSeconds))
    }
    try{
        # Do not automatically replay an ambiguous failed POST against the same
        # endpoint. The router owns failover; a timeout may have reached the model
        # and duplicating it can waste quota or mutate a persistent session twice.
        return Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $timeout
    }catch{
        $ex=$_;$status=0;$response=$null
        if($ex.Exception -and $ex.Exception.PSObject.Properties['Response'] -and $ex.Exception.Response){
            $response=$ex.Exception.Response
            try{$status=[int]$response.StatusCode}catch{}
        }
        $headerParts=@()
        if($response-and$response.PSObject.Properties['Headers']-and$response.Headers){
            foreach($name in @(
                'Retry-After','RateLimit','RateLimit-Policy','RateLimit-Remaining','RateLimit-Reset',
                'X-RateLimit-Limit','X-RateLimit-Remaining','X-RateLimit-Reset',
                'X-RateLimit-Limit-Requests','X-RateLimit-Remaining-Requests','X-RateLimit-Reset-Requests',
                'X-RateLimit-Limit-Tokens','X-RateLimit-Remaining-Tokens','X-RateLimit-Reset-Tokens',
                'Anthropic-RateLimit-Requests-Limit','Anthropic-RateLimit-Requests-Remaining','Anthropic-RateLimit-Requests-Reset',
                'Anthropic-RateLimit-Tokens-Limit','Anthropic-RateLimit-Tokens-Remaining','Anthropic-RateLimit-Tokens-Reset',
                'Anthropic-RateLimit-Input-Tokens-Limit','Anthropic-RateLimit-Input-Tokens-Remaining','Anthropic-RateLimit-Input-Tokens-Reset',
                'Anthropic-RateLimit-Output-Tokens-Limit','Anthropic-RateLimit-Output-Tokens-Remaining','Anthropic-RateLimit-Output-Tokens-Reset'
            )){
                try{
                    $value=$null
                    if($response.Headers.PSObject.Methods['TryGetValues']){
                        $values=$null
                        if($response.Headers.TryGetValues($name,[ref]$values)){$value=(@($values)-join',')}
                    }elseif($response.Headers[$name]){$value=[string]$response.Headers[$name]}
                    if($value){$headerParts+=("${name}: $value")}
                }catch{}
            }
        }
        $detail=''
        try{if($ex.ErrorDetails-and$ex.ErrorDetails.Message){$detail=[string]$ex.ErrorDetails.Message}}catch{}
        if($detail.Length-gt2000){$detail=$detail.Substring(0,2000)}
        $statusText=if($status-gt0){" HTTP $status"}else{''}
        $metadata=if($headerParts.Count){[Environment]::NewLine+($headerParts-join[Environment]::NewLine)}else{''}
        $bodyDetail=if($detail){" Body: $detail"}else{''}
        $requestShape=" Protocol: $protocol; tool mode: $ToolMode; request fields: $(@($body.Keys)-join',')."
        throw "Direct inference request failed${statusText}: $($ex.Exception.Message)$metadata$bodyDetail$requestShape Inspect the endpoint's request format and the harness serializer before retrying this task unchanged."
    }
}
function Get-SCResponseDiagnostic($Response,[int]$MaximumLength=240) {
    if($null-eq$Response){return 'response was null'}
    $detail=''
    $error=Get-SCField $Response 'error'
    if($error){$detail=[string](Get-SCField $error 'message')}
    if([string]::IsNullOrWhiteSpace($detail)){$detail=[string](Get-SCField $Response 'message')}
    if([string]::IsNullOrWhiteSpace($detail)){
        try{$detail=$Response|ConvertTo-Json -Depth 6 -Compress -ErrorAction Stop}catch{$detail=$Response.GetType().FullName}
    }
    $detail=($detail -replace '[\r\n\t]+',' ').Trim()
    if($detail.Length-gt$MaximumLength){$detail=$detail.Substring(0,$MaximumLength)+'â€¦'}
    return $detail
}
function Get-SCAssistantMessage($Response,[string]$Protocol='openai-chat') {
    if($Protocol-eq'gemini-native'){
        $candidates=Get-SCField $Response 'candidates'
        if($null-eq$candidates-or@($candidates).Count-eq0){throw ('Gemini endpoint returned no candidates. Diagnostic: '+(Get-SCResponseDiagnostic $Response))}
        $content=Get-SCField (@($candidates)[0]) 'content';$parts=Get-SCField $content 'parts'
        if(@($parts).Count-eq0){throw ('Gemini endpoint returned no message parts. Diagnostic: '+(Get-SCResponseDiagnostic $Response))}
        $texts=@();$calls=@();$n=0
        foreach($part in $parts){
            $text=Get-SCField $part 'text';if(-not[string]::IsNullOrWhiteSpace([string]$text)){$texts+=,[string]$text}
            $fc=Get-SCField $part 'functionCall'
            if($fc){
                $n++;$args=Get-SCField $fc 'args';if($null-eq$args){$args=[pscustomobject]@{}}
                $calls+=,[pscustomobject]@{id=('gemini-{0}-{1}'-f$n,[string](Get-SCField $fc 'name'));type='function';function=[pscustomobject]@{name=[string](Get-SCField $fc 'name');arguments=($args|ConvertTo-Json -Depth 30 -Compress)}}
            }
        }
        return [pscustomobject]@{content=($texts-join[Environment]::NewLine);tool_calls=@($calls)}
    }
    if($Protocol-eq'anthropic-messages'){
        # Normalize Anthropic's content-block array into the same {content;tool_calls}
        # shape OpenAI's choices[0].message already has, so the rest of the worker
        # loop (Invoke-SCDirectWorkerLoop) never needs to know which protocol answered.
        $content=Get-SCField $Response 'content'
        if($null-eq$content){throw ('Inference endpoint returned no content. Diagnostic: '+(Get-SCResponseDiagnostic $Response))}
        $textParts=@();$toolCalls=@()
        foreach($block in @($content)){
            $type=[string](Get-SCField $block 'type')
            if($type-eq'text'){$textParts+=,[string](Get-SCField $block 'text')}
            elseif($type-eq'tool_use'){
                $argsJson=((Get-SCField $block 'input')|ConvertTo-Json -Depth 30 -Compress)
                $toolCalls+=,[pscustomobject]@{id=[string](Get-SCField $block 'id');type='function';function=[pscustomobject]@{name=[string](Get-SCField $block 'name');arguments=$argsJson}}
            }
        }
        return [pscustomobject]@{content=($textParts-join"`n");tool_calls=@($toolCalls)}
    }
    $choices=Get-SCField $Response 'choices'
    if($null-eq$choices-or@($choices).Count-eq0){throw ('Inference endpoint returned no choices. Diagnostic: '+(Get-SCResponseDiagnostic $Response))}
    $message=Get-SCField (@($choices)[0]) 'message'
    if($null-eq$message){throw ('Inference endpoint returned no choice message. Diagnostic: '+(Get-SCResponseDiagnostic $Response))}
    return $message
}
function Get-SCApiUsageValue($Usage,[string[]]$Names) {
    if($null-eq$Usage){return 0L}
    foreach($name in $Names){if($Usage.PSObject.Properties[$name]){try{return [long]$Usage.$name}catch{}}}
    return 0L
}
function Add-SCApiUsage($Accumulator,$Response) {
    if($null-eq$Accumulator-or$null-eq$Response){return}
    $model=if($Response.PSObject.Properties['model']-and-not[string]::IsNullOrWhiteSpace([string]$Response.model)){[string]$Response.model}elseif($Accumulator.ContainsKey('fallbackModel')){[string]$Accumulator.fallbackModel}else{''}
    $prompt=0L;$completion=0L;$total=0L;$reported=$false
    if($Response.PSObject.Properties['usage']-and$Response.usage){$reported=$true;$prompt=Get-SCApiUsageValue $Response.usage @('prompt_tokens','input_tokens');$completion=Get-SCApiUsageValue $Response.usage @('completion_tokens','output_tokens');$total=Get-SCApiUsageValue $Response.usage @('total_tokens');if($total-le0-and($prompt-gt0-or$completion-gt0)){$total=$prompt+$completion}}
    elseif($Response.PSObject.Properties['usageMetadata']-and$Response.usageMetadata){$reported=$true;$prompt=Get-SCApiUsageValue $Response.usageMetadata @('promptTokenCount');$completion=Get-SCApiUsageValue $Response.usageMetadata @('candidatesTokenCount');$total=Get-SCApiUsageValue $Response.usageMetadata @('totalTokenCount');if($total-le0-and($prompt-gt0-or$completion-gt0)){$total=$prompt+$completion}}
    $Accumulator.apiRequests=[long]$Accumulator.apiRequests+1;if($reported){$Accumulator.usageReports=[long]$Accumulator.usageReports+1};$Accumulator.promptTokens=[long]$Accumulator.promptTokens+$prompt;$Accumulator.completionTokens=[long]$Accumulator.completionTokens+$completion;$Accumulator.totalTokens=[long]$Accumulator.totalTokens+$total
    if(-not[string]::IsNullOrWhiteSpace($model)){$map=$Accumulator.modelUsage;if(-not$map.ContainsKey($model)){$map[$model]=[ordered]@{model=$model;requests=0L;usageReports=0L;promptTokens=0L;completionTokens=0L;totalTokens=0L}};$row=$map[$model];$row.requests=[long]$row.requests+1;if($reported){$row.usageReports=[long]$row.usageReports+1};$row.promptTokens=[long]$row.promptTokens+$prompt;$row.completionTokens=[long]$row.completionTokens+$completion;$row.totalTokens=[long]$row.totalTokens+$total}
}

function Ensure-SCWorkerSessionLayout {
    $dir=Get-SCPath 'worker-sessions'
    if(-not(Test-Path -LiteralPath $dir)){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    return $dir
}
function Get-SCWorkerSessionPath([string]$SessionId) {
    if([string]::IsNullOrWhiteSpace($SessionId)){throw 'worker session id required'}
    return Join-Path (Ensure-SCWorkerSessionLayout) ($SessionId+'.json')
}
function Get-SCWorkerSession([string]$SessionId) {
    $path=Get-SCWorkerSessionPath $SessionId
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    return Read-SCJson $path
}
function Save-SCWorkerSession($Session) {
    Set-SCProperty $Session 'updatedAt' ([datetimeoffset]::UtcNow.ToString('o'))
    Write-SCJson (Get-SCWorkerSessionPath ([string]$Session.id)) $Session
}
function Get-SCRouteSnapshotReceipt {
    $selectedAt=[datetimeoffset]::UtcNow.ToString('o')
    $catalogPath=$null
    $catalogFingerprint=$null
    $catalogLastWriteUtc=$null
    $configPath=$null
    $configFingerprint=$null
    $configLastWriteUtc=$null
    try{
        if(Get-Command Get-SCMachineEndpointCatalogPath -ErrorAction SilentlyContinue){
            $catalogPath=[string](Get-SCMachineEndpointCatalogPath)
            if(Test-Path -LiteralPath $catalogPath -PathType Leaf){
                $catalogFingerprint=Get-SCFileHashValue $catalogPath
                $catalogLastWriteUtc=(Get-Item -LiteralPath $catalogPath).LastWriteTimeUtc.ToString('o')
            }
        }
    }catch{}
    try{
        $configPath=Get-SCPath 'config.json'
        if(Test-Path -LiteralPath $configPath -PathType Leaf){
            $configFingerprint=Get-SCFileHashValue $configPath
            $configLastWriteUtc=(Get-Item -LiteralPath $configPath).LastWriteTimeUtc.ToString('o')
        }
    }catch{}
    return [pscustomobject][ordered]@{selectedAt=$selectedAt;catalogPath=$catalogPath;catalogFingerprint=$catalogFingerprint;catalogLastWriteUtc=$catalogLastWriteUtc;configPath=$configPath;configFingerprint=$configFingerprint;configLastWriteUtc=$configLastWriteUtc}
}
function New-SCWorkerSession([string]$SessionId,$Task,$Compilation,[string]$Prompt,[string]$ToolMode,$Registry) {
    if([string]::IsNullOrWhiteSpace($SessionId)){$SessionId=New-SCId 'wsess'}
    $existing=Get-SCWorkerSession $SessionId
    if($existing){return $existing}
    $now=[datetimeoffset]::UtcNow.ToString('o')
    $session=[pscustomobject][ordered]@{
        schemaVersion=1;id=$SessionId;taskId=[string]$Task.id;status='active';backend='stateful-direct';workRoot=(Get-SCRoot);
        compilationId=if($Compilation){[string]$Compilation.id}else{$null};
        inputFingerprint=if($Compilation){[string]$Compilation.inputFingerprint}else{$null};
        toolMode=$ToolMode;candidateNumber=0;noArtifactCount=0;mutationToolCalls=0;turn=0;
        createdAt=$now;updatedAt=$now;completedAt=$null;
        pinnedEndpoint=$null;pinnedConnection=$null;pinnedModel=$null;
        providerHistory=@();appliedContinuations=@();messages=@(
            [ordered]@{role='system';content=(New-SCDirectWorkerSystemPrompt $ToolMode $Registry)},
            [ordered]@{role='user';content=$Prompt}
        );
        candidateClaim=$null;baselineCheckpointId=$null;latestCheckpointId=$null;checkpoints=@()
    }
    Save-SCWorkerSession $session
    $baseline=New-SCWorkerCheckpoint $SessionId 'baseline' $null $null
    $session=Get-SCWorkerSession $SessionId
    if($baseline){Set-SCProperty $session 'baselineCheckpointId' ([string]$baseline.id);Set-SCProperty $session 'latestCheckpointId' ([string]$baseline.id);Save-SCWorkerSession $session}
    Add-SCEvent 'worker.session_started' "Started worker session $SessionId for $($Task.id)." @{taskId=$Task.id;sessionId=$SessionId;compilationId=if($Compilation){$Compilation.id}else{$null}}
    return (Get-SCWorkerSession $SessionId)
}
function Add-SCWorkerSessionProvider([string]$SessionId,[string]$Endpoint,[string]$Connection,[string]$Model) {
    $s=Get-SCWorkerSession $SessionId;if($null-eq$s){return}
    $history=@($s.providerHistory)
    $history+=,[ordered]@{ts=[datetimeoffset]::UtcNow.ToString('o');endpoint=$Endpoint;connection=$Connection;model=$Model}
    Set-SCProperty $s 'providerHistory' @($history);Save-SCWorkerSession $s
}
function Get-SCWorkerSessionRoutePin([string]$SessionId) {
    $s=Get-SCWorkerSession $SessionId
    if($null-eq$s-or-not$s.PSObject.Properties['pinnedEndpoint']-or[string]::IsNullOrWhiteSpace([string]$s.pinnedEndpoint)){return $null}
    return [pscustomobject][ordered]@{
        endpoint=[string]$s.pinnedEndpoint
        connection=if($s.PSObject.Properties['pinnedConnection']){[string]$s.pinnedConnection}else{$null}
        model=if($s.PSObject.Properties['pinnedModel']){[string]$s.pinnedModel}else{$null}
    }
}
function Set-SCWorkerSessionRoutePin([string]$SessionId,[string]$Endpoint,[string]$Connection,[string]$Model) {
    if([string]::IsNullOrWhiteSpace($SessionId)-or[string]::IsNullOrWhiteSpace($Endpoint)){return}
    $s=Get-SCWorkerSession $SessionId;if($null-eq$s){return}
    $old=if($s.PSObject.Properties['pinnedEndpoint']){[string]$s.pinnedEndpoint}else{''}
    $oldConnection=if($s.PSObject.Properties['pinnedConnection']){[string]$s.pinnedConnection}else{''}
    $oldModel=if($s.PSObject.Properties['pinnedModel']){[string]$s.pinnedModel}else{''}
    $changed=$old-and($old-ne$Endpoint-or($oldConnection-and$oldConnection-ne$Connection)-or($oldModel-and$oldModel-ne$Model))
    if(-not$old-or$changed){
        Set-SCProperty $s 'pinnedEndpoint' $Endpoint
        Set-SCProperty $s 'pinnedConnection' $Connection
        Set-SCProperty $s 'pinnedModel' $Model
        Save-SCWorkerSession $s
        if($changed){
            Add-SCEvent 'worker.session_route_migrated' "Migrated worker session $SessionId from $old / $oldModel to $Endpoint / $Model." @{sessionId=$SessionId;taskId=$s.taskId;previousEndpoint=$old;previousConnection=$oldConnection;previousModel=$oldModel;endpoint=$Endpoint;connection=$Connection;model=$Model}
        }else{
            Add-SCEvent 'worker.session_route_pinned' "Pinned worker session $SessionId to $Endpoint / $Model." @{sessionId=$SessionId;taskId=$s.taskId;endpoint=$Endpoint;connection=$Connection;model=$Model}
        }
    }
}
function Get-SCReusableWorkerSessionId($Task) {
    if($null-eq$Task-or-not$Task.PSObject.Properties['latestWorkerSessionId']-or[string]::IsNullOrWhiteSpace([string]$Task.latestWorkerSessionId)){return $null}
    $id=[string]$Task.latestWorkerSessionId
    $s=Get-SCWorkerSession $id
    if($null-eq$s-or[string]$s.taskId-ne[string]$Task.id){return $null}
    $status=if($s.PSObject.Properties['status']){[string]$s.status}else{'active'}
    if(@('completed','stale','no-artifact','plan-repair','failed','context-fault')-contains$status){return $null}
    return $id
}
function Add-SCWorkerSessionContinuation([string]$SessionId,[string]$Text) {
    if([string]::IsNullOrWhiteSpace($Text)){return}
    $s=Get-SCWorkerSession $SessionId;if($null-eq$s){return}
    $key=Get-SCHashString $Text
    if(@($s.appliedContinuations)-contains$key){return}
    $messages=@($s.messages);$messages+=,[ordered]@{role='user';content=$Text}
    $applied=@($s.appliedContinuations)+$key
    Set-SCProperty $s 'messages' @($messages);Set-SCProperty $s 'appliedContinuations' @($applied);Save-SCWorkerSession $s
}
function Add-SCWorkerSessionMessage([string]$SessionId,$Message) {
    $s=Get-SCWorkerSession $SessionId;if($null-eq$s){return}
    $messages=@($s.messages);$messages+=,$Message;Set-SCProperty $s 'messages' @($messages);Save-SCWorkerSession $s
}
function Set-SCWorkerCandidateClaim([string]$SessionId,$Args,[string]$FallbackSummary=$null) {
    $s=Get-SCWorkerSession $SessionId;if($null-eq$s){return}
    $summary=if($Args){[string](Get-SCArgValue $Args 'summary' $FallbackSummary)}else{$FallbackSummary}
    $expected=if($Args){@(Get-SCArgValue $Args 'expectedArtifacts' @())}else{@()}
    $verification=if($Args){@(Get-SCArgValue $Args 'verification' @())}else{@()}
    $n=if($s.PSObject.Properties['candidateNumber']){[int]$s.candidateNumber+1}else{1}
    Set-SCProperty $s 'candidateNumber' $n
    Set-SCProperty $s 'candidateClaim' ([pscustomobject][ordered]@{candidateNumber=$n;summary=$summary;expectedArtifacts=@($expected);verification=@($verification);submittedAt=[datetimeoffset]::UtcNow.ToString('o')})
    Save-SCWorkerSession $s
}
function Add-SCWorkerMutationToolCall([string]$SessionId,[string]$ToolName) {
    if(@('write_file','replace_text','run_command')-notcontains$ToolName){return}
    $s=Get-SCWorkerSession $SessionId;if($null-eq$s){return}
    $n=if($s.PSObject.Properties['mutationToolCalls']){[int]$s.mutationToolCalls+1}else{1}
    Set-SCProperty $s 'mutationToolCalls' $n;Save-SCWorkerSession $s
}
function Test-SCWorkerGitRepo {
    try{
        $inside=& git -C (Get-SCRoot) rev-parse --is-inside-work-tree 2>$null|Select-Object -First 1
        return ([string]$inside).Trim()-eq'true'
    }catch{return $false}
}
function New-SCWorkerGitSnapshot([string]$SessionId,[int]$Sequence,[string]$Kind) {
    if(-not(Test-SCWorkerGitRepo)){return $null}
    $root=Get-SCRoot;$tmp=Join-Path ([IO.Path]::GetTempPath()) ("sc-index-"+[guid]::NewGuid().ToString('N'))
    $old=$env:GIT_INDEX_FILE
    try{
        $env:GIT_INDEX_FILE=$tmp
        & git -C $root read-tree HEAD 2>$null
        if($LASTEXITCODE-ne0){return $null}
        & git -C $root add -A -- . 2>$null
        if($LASTEXITCODE-ne0){return $null}
        $tree=([string](& git -C $root write-tree 2>$null|Select-Object -First 1)).Trim()
        $parent=([string](& git -C $root rev-parse HEAD 2>$null|Select-Object -First 1)).Trim()
        if(-not$tree-or-not$parent){return $null}
        $message="StatefulClanker checkpoint $SessionId/$Sequence ($Kind)"
        $commit=([string](& git -C $root -c user.name=StatefulClanker -c user.email=statefulclanker@localhost commit-tree $tree -p $parent -m $message 2>$null|Select-Object -First 1)).Trim()
        if(-not$commit){return $null}
        $ref="refs/statefulclanker/checkpoints/$SessionId/$Sequence"
        & git -C $root update-ref $ref $commit 2>$null
        if($LASTEXITCODE-ne0){return $null}
        return [pscustomobject][ordered]@{commit=$commit;tree=$tree;ref=$ref}
    }finally{
        if($null-eq$old){Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue}else{$env:GIT_INDEX_FILE=$old}
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
function New-SCWorkerCheckpoint([string]$SessionId,[string]$Kind,[string]$Endpoint,[string]$Model) {
    $s=Get-SCWorkerSession $SessionId;if($null-eq$s){return $null}
    $seq=@($s.checkpoints).Count
    $git=New-SCWorkerGitSnapshot $SessionId $seq $Kind
    $cp=[pscustomobject][ordered]@{
        id="$SessionId-cp-$seq";sequence=$seq;kind=$Kind;createdAt=[datetimeoffset]::UtcNow.ToString('o');
        endpoint=$Endpoint;model=$Model;git=($null-ne$git);
        commit=if($git){$git.commit}else{$null};tree=if($git){$git.tree}else{$null};ref=if($git){$git.ref}else{$null}
    }
    $points=@($s.checkpoints)+$cp;Set-SCProperty $s 'checkpoints' @($points);Set-SCProperty $s 'latestCheckpointId' ([string]$cp.id);Save-SCWorkerSession $s
    return $cp
}
function Restore-SCWorkerCheckpoint([string]$SessionId,[string]$CheckpointId) {
    $s=Get-SCWorkerSession $SessionId;if($null-eq$s){throw "Unknown worker session: $SessionId"}
    $cp=@($s.checkpoints|Where-Object{[string]$_.id-eq$CheckpointId}|Select-Object -First 1)
    if($cp.Count-eq0){throw "Unknown worker checkpoint: $CheckpointId"}
    $cp=$cp[0];if(-not[bool]$cp.git-or-not$cp.commit){throw "Checkpoint $CheckpointId has no restorable Git snapshot."}
    $root=if($s.PSObject.Properties['workRoot'] -and $s.workRoot){[string]$s.workRoot}else{Get-SCRoot}
    if(-not(Test-Path -LiteralPath $root -PathType Container)){throw "Worker worktree no longer exists: $root"}
    & git -C $root clean -fd 2>$null|Out-Null
    & git -C $root restore --source ([string]$cp.commit) --staged --worktree -- . 2>$null
    if($LASTEXITCODE-ne0){throw "Could not restore checkpoint $CheckpointId."}
    Add-SCEvent 'worker.checkpoint_restored' "Restored worker checkpoint $CheckpointId." @{sessionId=$SessionId;checkpointId=$CheckpointId;taskId=$s.taskId}
    return $cp
}
function Get-SCWorkerCandidatePreflight([string]$SessionId,$Task) {
    $s=Get-SCWorkerSession $SessionId;if($null-eq$s){return [pscustomobject]@{material=$true;reason='no direct-session metadata';session=$null}}
    $baseline=@($s.checkpoints|Where-Object{[string]$_.id-eq[string]$s.baselineCheckpointId}|Select-Object -First 1)
    $candidate=New-SCWorkerCheckpoint $SessionId 'candidate' $null $null
    $kind=if($Task.PSObject.Properties['outputKind'] -and $Task.outputKind){([string]$Task.outputKind).ToLowerInvariant()}else{'change'}
    $requiresArtifact=@('research','diagnosis','answer','none','no-change')-notcontains$kind
    $material=$true;$reason=$null
    if($requiresArtifact){
        if($baseline.Count-gt0 -and $baseline[0].tree -and $candidate -and $candidate.tree){
            $material=([string]$baseline[0].tree-ne[string]$candidate.tree)
            if(-not$material){$reason='candidate worktree tree is identical to the session baseline'}
        }elseif([int]$s.mutationToolCalls-le0){
            $material=$false;$reason='candidate produced no observed mutation tool calls and no Git snapshot comparison was available'
        }
    }
    $missing=@()
    if($s.candidateClaim -and $s.candidateClaim.PSObject.Properties['expectedArtifacts']){
        foreach($rel in @($s.candidateClaim.expectedArtifacts)){
            if([string]::IsNullOrWhiteSpace([string]$rel)){continue}
            try{$p=Resolve-SCWorkerPath ([string]$rel) -AllowMissing;if(-not(Test-Path -LiteralPath $p)){$missing+=,[string]$rel}}catch{$missing+=,[string]$rel}
        }
    }
    if($missing.Count-gt0){$material=$false;$reason="claimed artifacts are missing: $($missing-join', ')"}
    return [pscustomobject][ordered]@{material=$material;requiresArtifact=$requiresArtifact;reason=$reason;missingArtifacts=@($missing);candidateCheckpointId=if($candidate){$candidate.id}else{$null};candidateNumber=[int]$s.candidateNumber;session=$s}
}
function Add-SCWorkerNoArtifact([string]$SessionId,[string]$Reason) {
    $s=Get-SCWorkerSession $SessionId;if($null-eq$s){return 0}
    $n=if($s.PSObject.Properties['noArtifactCount']){[int]$s.noArtifactCount+1}else{1}
    Set-SCProperty $s 'noArtifactCount' $n;Save-SCWorkerSession $s
    Add-SCEvent 'worker.candidate_no_artifact' "Worker session $SessionId submitted a candidate without required artifacts." @{sessionId=$SessionId;taskId=$s.taskId;count=$n;reason=$Reason}
    return $n
}
function Close-SCWorkerSession([string]$SessionId,[string]$Status) {
    if([string]::IsNullOrWhiteSpace($SessionId)){return}
    $s=Get-SCWorkerSession $SessionId;if($null-eq$s){return}
    Set-SCProperty $s 'status' $Status
    if($Status-eq'completed'){Set-SCProperty $s 'completedAt' ([datetimeoffset]::UtcNow.ToString('o'))}
    Save-SCWorkerSession $s
    try{
        $task=Get-SCTask ([string]$s.taskId)
        if($task.PSObject.Properties['activeWorkerSessionId']-and[string]$task.activeWorkerSessionId-eq$SessionId){
            Set-SCProperty $task 'activeWorkerSessionId' $null
            Save-SCTask $task
        }
    }catch{}
}

function Invoke-SCDirectWorkerLoop($Connection,[string]$Prompt,$Task,[string]$Stage='worker',$UsageAccumulator=$null,[string]$WorkerSessionId=$null,[string]$ContinuationMessage=$null,$ProviderRecord=$null,$Compilation=$null) {
    $toolMode=Get-SCEffectiveWorkerToolMode $Connection;if(@('native','text')-notcontains$toolMode){throw "Unsupported toolMode '$toolMode'."}
    $maxSteps=Get-SCWorkerMaxSteps $Connection $Task $Stage
    $registry=@(Get-SCWorkerToolRecords $Task $Stage);if($registry.Count-eq0){throw 'No worker capabilities are authorized for this invocation.'}
    if($Stage-eq'run' -and $WorkerSessionId){
        $session=New-SCWorkerSession $WorkerSessionId $Task $Compilation $Prompt $toolMode $registry
        if([string]$session.toolMode-ne$toolMode){throw "Worker session $WorkerSessionId uses toolMode '$($session.toolMode)' and cannot resume on '$toolMode' without transcript conversion."}
        if($Compilation -and $session.PSObject.Properties['inputFingerprint'] -and [string]$session.inputFingerprint-ne[string]$Compilation.inputFingerprint){
            $refresh="REFRESHED COMPILED TASK CONTEXT. This packet supersedes older task-context messages while preserving the work and reasoning already in this session:"+[Environment]::NewLine+$Prompt
            Add-SCWorkerSessionContinuation $WorkerSessionId $refresh
            $session=Get-SCWorkerSession $WorkerSessionId
            Set-SCProperty $session 'compilationId' ([string]$Compilation.id)
            Set-SCProperty $session 'inputFingerprint' ([string]$Compilation.inputFingerprint)
        }
        Set-SCProperty $session 'status' 'active';Save-SCWorkerSession $session
        Add-SCWorkerSessionContinuation $WorkerSessionId $ContinuationMessage
        if($ProviderRecord){Add-SCWorkerSessionProvider $WorkerSessionId ([string]$ProviderRecord.name) ([string]$ProviderRecord.config.connection) ([string]$ProviderRecord.config.model)}
        $session=Get-SCWorkerSession $WorkerSessionId
        $messages=@($session.messages)
    }else{
        $messages=@(@{role='system';content=New-SCDirectWorkerSystemPrompt $toolMode $registry},@{role='user';content=$Prompt})
    }
    $tools=@($registry|ForEach-Object{$_.definition})
    $protocol=Get-SCConnectionProtocol $Connection
    $malformedTextTurns=0
    for($step=1;$step-le$maxSteps;$step++){
        $response=Invoke-SCApiChat $Connection $messages $tools $toolMode
        if($WorkerSessionId -and $ProviderRecord){Set-SCWorkerSessionRoutePin $WorkerSessionId ([string]$ProviderRecord.name) ([string]$ProviderRecord.config.connection) ([string]$ProviderRecord.config.model)}
        Add-SCApiUsage $UsageAccumulator $response
        $m=Get-SCAssistantMessage $response $protocol
        if($toolMode-eq'text'){
            $raw=[string]$m.content
            if($WorkerSessionId){Add-SCWorkerSessionMessage $WorkerSessionId ([ordered]@{role='assistant';content=$raw})}
            try{$cmd=$raw|ConvertFrom-Json -ErrorAction Stop}catch{
                $malformedTextTurns++
                if($malformedTextTurns-ge3){throw ("Text-tool model returned invalid JSON on {0} consecutive turns. Last response: {1}"-f$malformedTextTurns,$raw)}
                $repair='TOOL_PROTOCOL_ERROR: Your last response was not valid JSON. Return exactly one JSON object with either tool and arguments or final. Do not include markdown. Parsing error: '+$_.Exception.Message
                $messages+=@{role='user';content=$repair}
                if($WorkerSessionId){Add-SCWorkerSessionMessage $WorkerSessionId ([ordered]@{role='user';content=$repair})}
                continue
            }
            $malformedTextTurns=0
            if($cmd.PSObject.Properties['final']){
                if($WorkerSessionId){Set-SCWorkerCandidateClaim $WorkerSessionId $null ([string]$cmd.final);New-SCWorkerCheckpoint $WorkerSessionId 'candidate-submit' ([string]$ProviderRecord.name) ([string]$Connection.model)|Out-Null}
                return [string]$cmd.final
            }
            if(-not$cmd.PSObject.Properties['tool']){
                $repair='TOOL_PROTOCOL_ERROR: JSON was valid but had neither tool nor final. Return exactly one authorized tool call or a final summary.'
                $messages+=@{role='user';content=$repair}
                if($WorkerSessionId){Add-SCWorkerSessionMessage $WorkerSessionId ([ordered]@{role='user';content=$repair})}
                continue
            }
            $toolName=[string]$cmd.tool
            $result=try{Invoke-SCWorkerTool $toolName $cmd.arguments $Task $Stage $registry $WorkerSessionId}catch{"TOOL_ERROR: $($_.Exception.Message)"}
            if(([string]$result) -match 'BOUNDARY_ESCALATED:'){throw "Worker turn loop ended: boundary violation limit reached. $result"}
            Write-SCWorkerToolFailure $Task $Stage $toolName ([string]$result) $step
            if($WorkerSessionId -and -not([string]$result).StartsWith('TOOL_ERROR:')){Add-SCWorkerMutationToolCall $WorkerSessionId $toolName}
            if($toolName-eq'finish'){
                if($WorkerSessionId){Set-SCWorkerCandidateClaim $WorkerSessionId $cmd.arguments ([string]$result);New-SCWorkerCheckpoint $WorkerSessionId 'candidate-submit' ([string]$ProviderRecord.name) ([string]$Connection.model)|Out-Null}
                return [string]$result
            }
            $toolResult="TOOL_RESULT "+$toolName+":"+[Environment]::NewLine+[string]$result
            $messages+=@{role='assistant';content=$raw};$messages+=@{role='user';content=$toolResult}
            if($WorkerSessionId){
                Add-SCWorkerSessionMessage $WorkerSessionId ([ordered]@{role='user';content=$toolResult})
                New-SCWorkerCheckpoint $WorkerSessionId 'api-turn' ([string]$ProviderRecord.name) ([string]$Connection.model)|Out-Null
                $session=Get-SCWorkerSession $WorkerSessionId;Set-SCProperty $session 'turn' ([int]$session.turn+1);Save-SCWorkerSession $session
            }
            continue
        }
        $calls=@();if($m.PSObject.Properties['tool_calls']-and$m.tool_calls){$calls=@($m.tool_calls)}
        if($calls.Count-eq0){
            $replyContent=if($m.PSObject.Properties['content'] -and $null-ne$m.content){[string]$m.content}else{''}
            if(-not[string]::IsNullOrWhiteSpace($replyContent)){
                $assistant=[ordered]@{role='assistant';content=$replyContent}
                $messages+=$assistant
                if($WorkerSessionId){Add-SCWorkerSessionMessage $WorkerSessionId $assistant;Set-SCWorkerCandidateClaim $WorkerSessionId $null $replyContent;New-SCWorkerCheckpoint $WorkerSessionId 'candidate-submit' ([string]$ProviderRecord.name) ([string]$Connection.model)|Out-Null}
                return $replyContent
            }
            throw "Model returned no content or tool call at step $step."
        }
        $toolCallContent=if($m.PSObject.Properties['content'] -and $null-ne$m.content){[string]$m.content}else{''}
        $assistant=[ordered]@{role='assistant';content=$toolCallContent;tool_calls=@($calls)}
        $messages+=$assistant
        if($WorkerSessionId){Add-SCWorkerSessionMessage $WorkerSessionId $assistant}
        $finished=$false;$finishResult=$null
        foreach($call in $calls){
            $name=[string]$call.function.name
            try{
                $args=if([string]::IsNullOrWhiteSpace([string]$call.function.arguments)){[pscustomobject]@{}}else{[string]$call.function.arguments|ConvertFrom-Json}
                $result=try{Invoke-SCWorkerTool $name $args $Task $Stage $registry $WorkerSessionId}catch{"TOOL_ERROR: $($_.Exception.Message)"}
            }catch{$args=[pscustomobject]@{};$result="TOOL_ERROR: malformed arguments: $($_.Exception.Message)"}
            if(([string]$result) -match 'BOUNDARY_ESCALATED:'){throw "Worker turn loop ended: boundary violation limit reached. $result"}
            Write-SCWorkerToolFailure $Task $Stage $name ([string]$result) $step
            if($WorkerSessionId -and -not([string]$result).StartsWith('TOOL_ERROR:')){Add-SCWorkerMutationToolCall $WorkerSessionId $name}
            if($name-eq'finish'){
                if($WorkerSessionId){Set-SCWorkerCandidateClaim $WorkerSessionId $args ([string]$result)}
                $finished=$true;$finishResult=[string]$result
                $toolMessage=[ordered]@{role='tool';tool_call_id=[string]$call.id;content=("Candidate submitted for review: "+[string]$result)}
                $messages+=$toolMessage
                if($WorkerSessionId){Add-SCWorkerSessionMessage $WorkerSessionId $toolMessage}
                continue
            }
            if($finished){
                $toolMessage=[ordered]@{role='tool';tool_call_id=[string]$call.id;content='SKIPPED: a completion candidate was already submitted in this turn.'}
                $messages+=$toolMessage
                if($WorkerSessionId){Add-SCWorkerSessionMessage $WorkerSessionId $toolMessage}
                continue
            }
            $toolMessage=[ordered]@{role='tool';tool_call_id=[string]$call.id;content=[string]$result}
            $messages+=$toolMessage
            if($WorkerSessionId){Add-SCWorkerSessionMessage $WorkerSessionId $toolMessage}
        }
        if($WorkerSessionId){
            $cpKind=if($finished){'candidate-submit'}else{'api-turn'}
            New-SCWorkerCheckpoint $WorkerSessionId $cpKind ([string]$ProviderRecord.name) ([string]$Connection.model)|Out-Null
            $session=Get-SCWorkerSession $WorkerSessionId;Set-SCProperty $session 'turn' ([int]$session.turn+1);Save-SCWorkerSession $session
        }
        if($finished){return $finishResult}
    }
    throw "Direct worker exceeded maxSteps=$maxSteps without finishing."
}

function Invoke-SCDirectApiProvider($Task,[string]$Prompt,[string]$Stage,$ProviderRecord,[string]$ParentAgentId,$Compilation,[string]$WorkerSessionId=$null,[string]$ContinuationMessage=$null) {
    $connectionName=[string]$ProviderRecord.config.connection
    $connection=Get-SCEffectiveApiConnection $ProviderRecord
    $receiptId=New-SCId $Stage;$agentId=New-SCId 'agent';$promptPath=Get-SCPath ("prompts/{0}.txt"-f$receiptId);$Prompt|Set-Content -LiteralPath $promptPath -Encoding UTF8
    $stdoutPath=Get-SCPath ("runs/{0}.stdout.txt"-f$receiptId);$stderrPath=Get-SCPath ("runs/{0}.stderr.txt"-f$receiptId);$started=(Get-Date).ToUniversalTime();$compilationId=if($Compilation){$Compilation.id}else{$null};$fingerprint=if($Compilation){$Compilation.inputFingerprint}else{$null};$retrievedChars=0;if($Compilation-and$Compilation.ir.sources.retrieved){$retrievedChars=[int]$Compilation.ir.sources.retrieved.usedChars}
    $capabilities=@(Get-SCWorkerToolRecords $Task $Stage|ForEach-Object{[string]$_.capability})
    $usage=@{fallbackModel=[string]$connection.model;apiRequests=0L;usageReports=0L;promptTokens=0L;completionTokens=0L;totalTokens=0L;modelUsage=@{}}
    $telemetry=[ordered]@{schemaVersion=4;agentId=$agentId;receiptId=$receiptId;parentAgentId=$ParentAgentId;taskId=$Task.id;taskTitle=$Task.title;stage=$Stage;role=$Task.role;provider=$ProviderRecord.name;endpoint=$ProviderRecord.name;backendType='api';connection=$connectionName;model=[string]$connection.model;actualModels=@();modelUsage=@();apiRequests=0L;usageReports=0L;promptTokens=0L;completionTokens=0L;totalTokens=0L;capabilities=$capabilities;lifecycle='running';processId=$PID;startedAt=$started.ToString('o');heartbeatAt=$started.ToString('o');endedAt=$null;durationSeconds=$null;promptChars=$Prompt.Length;retrievedChars=$retrievedChars;compilationId=$compilationId;inputFingerprint=$fingerprint;command='direct-api';args=@();exitCode=$null;verdict=$null;stdoutPath=$stdoutPath;stderrPath=$stderrPath;error=$null}
    Save-SCActiveTelemetry $telemetry;Add-SCTelemetryEvent 'agent.started' $telemetry;$stdout='';$stderr='';$exitCode=-1
    try{$stdout=Invoke-SCDirectWorkerLoop $connection $Prompt $Task $Stage $usage $WorkerSessionId $ContinuationMessage $ProviderRecord $Compilation;$stdout|Set-Content -LiteralPath $stdoutPath -Encoding UTF8;$exitCode=0}catch{$stderr=$_|Out-String;$stderr|Set-Content -LiteralPath $stderrPath -Encoding UTF8;$telemetry.error=$stderr;$exitCode=-1}
    $modelUsage=@($usage.modelUsage.Values|Sort-Object model);$telemetry.apiRequests=[long]$usage.apiRequests;$telemetry.usageReports=[long]$usage.usageReports;$telemetry.promptTokens=[long]$usage.promptTokens;$telemetry.completionTokens=[long]$usage.completionTokens;$telemetry.totalTokens=[long]$usage.totalTokens;$telemetry.modelUsage=$modelUsage;$telemetry.actualModels=@($modelUsage|ForEach-Object{[string]$_.model})
    $ended=(Get-Date).ToUniversalTime();$telemetry.lifecycle=if($exitCode-eq0){'completed'}else{'failed'};$telemetry.exitCode=$exitCode;$telemetry.endedAt=$ended.ToString('o');$telemetry.heartbeatAt=$telemetry.endedAt;$telemetry.durationSeconds=[math]::Round(($ended-$started).TotalSeconds,3);Complete-SCTelemetry $telemetry
    return [pscustomobject][ordered]@{schemaVersion=4;id=$receiptId;agentId=$agentId;taskId=$Task.id;stage=$Stage;provider=$ProviderRecord.name;endpoint=$ProviderRecord.name;backendType='api';workerSessionId=$WorkerSessionId;workerSessionResumable=([bool]($Stage-eq'run' -and $WorkerSessionId));connection=$connectionName;model=[string]$connection.model;actualModels=@($telemetry.actualModels);modelUsage=@($telemetry.modelUsage);apiRequests=$telemetry.apiRequests;usageReports=$telemetry.usageReports;promptTokens=$telemetry.promptTokens;completionTokens=$telemetry.completionTokens;totalTokens=$telemetry.totalTokens;capabilities=$capabilities;compilationId=$compilationId;inputFingerprint=$fingerprint;command='direct-api';args=@();promptPath=$promptPath;startedAt=$started.ToString('o');endedAt=$ended.ToString('o');durationSeconds=$telemetry.durationSeconds;exitCode=$exitCode;stdout=$stdout;stderr=$stderr;verdict=$null}
}

function Invoke-SCProvider($Task,[string]$Prompt,[string]$Stage,[string]$ProviderOverride,[string]$ParentAgentId=$null,$Compilation=$null,[string]$WorkerSessionId=$null,[string]$ContinuationMessage=$null,[string]$EndpointOverride=$null,[string]$ConnectionOverride=$null) {
    # -Provider is reserved for an explicitly configured compatibility CLI backend.
    # API routing uses the compiled router and may be narrowed with -Connection or
    # pinned exactly with -Endpoint.
    if($ProviderOverride){
        $cfg=Get-SCConfig
        if($cfg.PSObject.Properties['providers'] -and $cfg.providers -and $cfg.providers.PSObject.Properties[$ProviderOverride]){
            $entry=$cfg.providers.PSObject.Properties[$ProviderOverride].Value
            if(-not($entry.PSObject.Properties['disabled'] -and [bool]$entry.disabled)){
                Add-SCEvent 'routing.explicit_cli_override' "Using explicitly requested compatibility CLI backend $ProviderOverride." @{taskId=$Task.id;stage=$Stage;provider=$ProviderOverride}
                return & $script:SCInvokeProviderCliBase $Task $Prompt $Stage $ProviderOverride $ParentAgentId $Compilation
            }
        }
    }

    if($ProviderOverride){throw "Unknown or disabled compatibility CLI backend '$ProviderOverride'. Use -Connection for a provider/account pool or -Endpoint for an exact API endpoint."}

    if(-not(Get-Command Test-SCCompiledRouterAvailable -ErrorAction SilentlyContinue) -or -not(Test-SCCompiledRouterAvailable)){
        throw 'The compiled StatefulClanker router is required for automatic dispatch but is not available. Repair the router installation instead of falling back to legacy PowerShell routing.'
    }
    return Invoke-SCProviderViaCompiledRouter $Task $Prompt $Stage $ParentAgentId $Compilation $WorkerSessionId $ContinuationMessage $EndpointOverride $ConnectionOverride
}

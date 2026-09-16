# Extensions layered over McpCore so both stdio and Streamable HTTP expose the same
# Windows-resident control-plane behavior without duplicating the core tool surface.

$script:SCBaseInvokeMcpRpc = (Get-Item Function:\Invoke-McpRpc).ScriptBlock

function Get-McpResidentActiveProject {
    $path=Join-Path (Join-Path $env:LOCALAPPDATA 'StatefulClanker') 'active-project.txt'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    try{$value=(Get-Content -Raw -LiteralPath $path).Trim()}catch{return $null}
    if([string]::IsNullOrWhiteSpace($value)){return $null}
    if(-not(Test-Path -LiteralPath $value -PathType Container)){return $null}
    return (Resolve-Path -LiteralPath $value).Path
}

# Explicit project argument wins. An explicit -ProjectPath/session default is next
# for headless compatibility. Otherwise follow the active project selected by the
# resident Windows application.
function Get-McpProject($Arguments) {
    $candidate=$null
    if($Arguments-and$Arguments.PSObject.Properties['project']-and$Arguments.project){
        $candidate=[string]$Arguments.project
    } elseif($script:McpDefaultProject) {
        $candidate=$script:McpDefaultProject
    } else {
        $candidate=Get-McpResidentActiveProject
    }
    if([string]::IsNullOrWhiteSpace($candidate)){throw 'No active project. Select one in StatefulClanker or pass "project" explicitly.'}
    if(-not(Test-Path -LiteralPath $candidate -PathType Container)){throw "Project path does not exist: $candidate"}
    return (Resolve-Path -LiteralPath $candidate).Path
}

function Get-SCControlPlaneInstructions {
    @'
You are the human-facing StatefulClanker orchestrator. Use MCP to steer the resident application; provider CLI workers are disposable execution sessions, not the planner.

Interrogate intent aggressively before substantial planning. When your host offers a structured question/questionnaire/quiz tool, prefer it whenever two competent implementations could differ materially. Ask contrastive questions, record rejected interpretations as constraints/non-goals when useful, and do not make material product choices merely to keep execution moving.

Capture durable human direction with direction_add. It returns a human:<id> source reference. Preserve relevant source and intent references in plans/tasks.

Decompose work semantically into independently understandable and independently verifiable cold-start tasks. Prefer tiny/small/medium tasks when separation is natural; do not split work by regex, line count, file count, or arbitrary token thresholds. Task size is a planning/routing hint, not a computed metric.

Prefer plan_apply with SCPLAN 1 for substantial plans. SCPLAN is line-oriented and cheap to grep/Get-Content. Each task should include its bounded outcome, observable acceptance criteria, dependencies, retrieval selectors, semantic size, and relevant source/intent references.

Do not implement project work in the conversational thread when it belongs in a worker task. StatefulClanker compiles context, launches configured provider CLIs such as codex/agy/claude/opencode, persists receipts, and applies critic/validator gates.

Workers must never weaken the authoritative Intent Contract. INTENT_QUESTION, INTENT_CONFLICT, and CONTEXT_REQUEST are non-advancing escalations to resolve before retrying.
'@
}

function New-SCExtendedTools {
    @(
        @{name='plan_apply';description='Apply a compact SCPLAN 1 plan directly from text. Preferred for conversational planning because no intermediate local file is required.';inputSchema=@{type='object';properties=@{project=@{type='string'};text=@{type='string';description='Complete SCPLAN 1 document.'}};required=@('text')}},
        @{name='source_add';description='Persist verbatim human/source text as a durable human:<id> artifact and return its reference. Use direction_add instead when the text is new execution-relevant human direction.';inputSchema=@{type='object';properties=@{project=@{type='string'};text=@{type='string'}};required=@('text')}},
        @{name='source_get';description='Read a durable source by reference, including optional #Lx-Ly ranges.';inputSchema=@{type='object';properties=@{project=@{type='string'};sourceRef=@{type='string'}};required=@('sourceRef')}},
        @{name='source_list';description='List durable human/source artifacts recorded for the project.';inputSchema=@{type='object';properties=@{project=@{type='string'}}}}
    )
}

function Invoke-SCExtendedTool([string]$Name,$Arguments) {
    $project=Get-McpProject $Arguments
    Assert-McpInitialized $project
    switch($Name) {
        'plan_apply' {
            $text=Get-McpArgRequired $Arguments 'text'
            if($text -notmatch '(?m)^\s*SCPLAN\s+1\s*$'){throw 'plan_apply requires a complete SCPLAN 1 document.'}
            $temp=Join-Path ([IO.Path]::GetTempPath()) ("statefulclanker-{0}.scplan"-f[Guid]::NewGuid().ToString('N'))
            try{
                [IO.File]::WriteAllText($temp,$text,(New-Object Text.UTF8Encoding($false)))
                $result=Invoke-McpHarness $project @('plan','import','-Path',$temp)
                return New-McpTextResult ([ordered]@{applied=$true;output=$result.stdout})
            } finally {Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
        }
        'source_add' {
            $text=Get-McpArgRequired $Arguments 'text'
            $result=Invoke-McpHarness $project @('source','add','-Message',$text)
            $sourceRef=([string]$result.stdout).Trim()
            return New-McpTextResult ([ordered]@{sourceRef=$sourceRef;output=$result.stdout})
        }
        'source_get' {
            $ref=Get-McpArgRequired $Arguments 'sourceRef'
            $result=Invoke-McpHarness $project @('source','show','-SourceRef',$ref)
            return New-McpTextResult ([ordered]@{sourceRef=$ref;text=$result.stdout})
        }
        'source_list' {
            $result=Invoke-McpHarness $project @('source','list')
            return New-McpTextResult $result.stdout
        }
        default {throw "Unknown extended tool: $Name"}
    }
}

function Invoke-SCDirectionAdd($Arguments) {
    $project=Get-McpProject $Arguments;Assert-McpInitialized $project
    $message=Get-McpArgRequired $Arguments 'message'
    $result=Invoke-McpHarness $project @('event','-Message',$message)
    $sourceRef=$null
    if(([string]$result.stdout)-match '(human:[A-Za-z0-9_.-]+)'){$sourceRef=$Matches[1]}
    return New-McpTextResult ([ordered]@{recorded=$true;sourceRef=$sourceRef;invalidatesOlderCompilations=$true;output=$result.stdout})
}

function Invoke-SCSemanticTaskAdd($Arguments) {
    $project=Get-McpProject $Arguments;Assert-McpInitialized $project
    $title=Get-McpArgRequired $Arguments 'title';$instruction=Get-McpArgRequired $Arguments 'instruction'
    $cli=@('task','add','-Title',$title,'-Instruction',$instruction)
    $taskId=Get-McpArgOptional $Arguments 'taskId';if($taskId){$cli+=@('-TaskId',$taskId)}
    $size=Get-McpArgOptional $Arguments 'size';if($size){$cli+=@('-Size',$size)}
    $provider=Get-McpArgOptional $Arguments 'provider';if($provider){$cli+=@('-Provider',$provider)}
    foreach($pair in @(@('accept','-Accept'),@('dependsOn','-DependsOn'),@('retrieval','-Retrieval'),@('evidence','-Evidence'),@('relation','-Relation'),@('source','-Source'),@('intentRef','-IntentRef'))) {
        $values=Get-McpArgArray $Arguments $pair[0];if($values.Count-gt 0){$cli+=$pair[1];$cli+=,$values}
    }
    if($Arguments-and$Arguments.PSObject.Properties['humanGate']-and[bool]$Arguments.humanGate){$cli+='-HumanGate'}
    $result=Invoke-McpHarness $project $cli
    return New-McpTextResult ([ordered]@{taskId=([string]$result.stdout).Trim();output=$result.stdout})
}

function Invoke-McpRpc($Request) {
    $method=[string]$Request.method
    if($method-eq'initialize') {
        $response=& $script:SCBaseInvokeMcpRpc $Request
        if($response-and$response.result){$response.result['instructions']=Get-SCControlPlaneInstructions}
        return $response
    }
    if($method-eq'tools/list') {
        $response=& $script:SCBaseInvokeMcpRpc $Request
        if($response-and$response.result) {
            $tools=@($response.result.tools)
            $task=@($tools|Where-Object{[string]$_.name-eq'task_add'}|Select-Object -First 1)
            if($task.Count-gt 0) {
                $props=$task[0].inputSchema.properties
                $props['size']=@{type='string';enum=@('tiny','small','medium','large');description='Semantic size assigned by the conversational planner; never inferred mechanically.'}
                $props['source']=@{type='array';items=@{type='string'};description='Durable human/source references such as human:h-...#L1-L4.'}
                $props['intentRef']=@{type='array';items=@{type='string'};description='Governing intent requirement/constraint/invariant identifiers.'}
            }
            $plan=@($tools|Where-Object{[string]$_.name-eq'plan_import'}|Select-Object -First 1)
            if($plan.Count-gt 0){$plan[0].description='Import a JSON or compact SCPLAN 1 task graph from a local file path.'}
            $direction=@($tools|Where-Object{[string]$_.name-eq'direction_add'}|Select-Object -First 1)
            if($direction.Count-gt 0){$direction[0].description='Record human direction verbatim as a durable human:<id> source, advance direction revision, and return the source reference.'}
            $response.result.tools=@($tools + (New-SCExtendedTools))
        }
        return $response
    }
    if($method-eq'tools/call') {
        $name=[string]$Request.params.name;$args=$null;if($Request.params.PSObject.Properties['arguments']){$args=$Request.params.arguments}
        if(@('plan_apply','source_add','source_get','source_list') -contains $name) {
            try{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=(Invoke-SCExtendedTool $name $args)}}catch{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=@{isError=$true;content=@(@{type='text';text=("Tool '{0}' failed: {1}"-f$name,$_.Exception.Message)})}}}
        }
        if($name-eq'direction_add') {
            try{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=(Invoke-SCDirectionAdd $args)}}catch{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=@{isError=$true;content=@(@{type='text';text=("Tool 'direction_add' failed: {0}"-f$_.Exception.Message)})}}}
        }
        if($name-eq'task_add'-and$args-and($args.PSObject.Properties['size']-or$args.PSObject.Properties['source']-or$args.PSObject.Properties['intentRef'])) {
            try{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=(Invoke-SCSemanticTaskAdd $args)}}catch{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=@{isError=$true;content=@(@{type='text';text=("Tool 'task_add' failed: {0}"-f$_.Exception.Message)})}}}
        }
    }
    return (& $script:SCBaseInvokeMcpRpc $Request)
}

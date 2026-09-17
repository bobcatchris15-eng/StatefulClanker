# First-class MCP authoring surface for task capability profiles and task-local narrowing.
$script:SCBaseInvokeMcpRpcTaskCaps=(Get-Item Function:\Invoke-McpRpc).ScriptBlock

function Invoke-SCCapabilityTaskAdd($Arguments) {
    $project=Get-McpProject $Arguments;Assert-McpInitialized $project
    $title=Get-McpArgRequired $Arguments 'title';$instruction=Get-McpArgRequired $Arguments 'instruction';$cli=@('task','add','-Title',$title,'-Instruction',$instruction)
    foreach($pair in @(@('taskId','-TaskId'),@('size','-Size'),@('provider','-Provider'),@('role','-Role'),@('capabilityProfile','-CapabilityProfile'))){$value=Get-McpArgOptional $Arguments $pair[0];if($value){$cli+=@($pair[1],$value)}}
    foreach($pair in @(@('accept','-Accept'),@('dependsOn','-DependsOn'),@('retrieval','-Retrieval'),@('evidence','-Evidence'),@('relation','-Relation'),@('source','-Source'),@('intentRef','-IntentRef'),@('toolAllow','-ToolAllow'),@('toolDeny','-ToolDeny'))){$values=@(Get-McpArgArray $Arguments $pair[0]);if($values.Count-gt0){$cli+=$pair[1];$cli+=,$values}}
    if($Arguments-and$Arguments.PSObject.Properties['humanGate']-and[bool]$Arguments.humanGate){$cli+='-HumanGate'}
    $result=Invoke-McpHarness $project $cli;return New-McpTextResult ([ordered]@{taskId=([string]$result.stdout).Trim();output=$result.stdout})
}

function Invoke-McpRpc($Request) {
    $method=[string]$Request.method
    if($method-eq'tools/list'){
        $response=& $script:SCBaseInvokeMcpRpcTaskCaps $Request
        if($response-and$response.result){
            $task=@($response.result.tools|Where-Object{[string]$_.name-eq'task_add'}|Select-Object -First 1)
            if($task.Count-gt0){
                $props=$task[0].inputSchema.properties
                $props['capabilityProfile']=@{type='string';description='Optional machine-defined worker capability profile. Profiles only narrow machine grants.'}
                $props['toolAllow']=@{type='array';items=@{type='string'};description='Task-local capability allow patterns. This can only narrow inherited access.'}
                $props['toolDeny']=@{type='array';items=@{type='string'};description='Task-local capability deny patterns. Deny always wins.'}
            }
        }
        return $response
    }
    if($method-eq'tools/call'-and[string]$Request.params.name-eq'task_add'){
        $args=$Request.params.arguments;$hasCaps=$args-and($args.PSObject.Properties['capabilityProfile']-or$args.PSObject.Properties['toolAllow']-or$args.PSObject.Properties['toolDeny'])
        if($hasCaps){try{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=(Invoke-SCCapabilityTaskAdd $args)}}catch{return [ordered]@{jsonrpc='2.0';id=$Request.id;result=@{isError=$true;content=@(@{type='text';text=("Tool 'task_add' failed: {0}"-f$_.Exception.Message)})}}}}
    }
    return & $script:SCBaseInvokeMcpRpcTaskCaps $Request
}

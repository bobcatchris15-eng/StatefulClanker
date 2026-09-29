$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$harness=Join-Path $repo 'StatefulClanker.ps1'
$plannerProject=Join-Path $repo 'src\StatefulClanker.Planner\StatefulClanker.Planner.csproj'
$planningMock=Join-Path $PSScriptRoot 'PlanningMockProvider.ps1'
$pwsh=(Get-Process -Id $PID).Path
$dotnet=Get-Command dotnet -ErrorAction SilentlyContinue
if(-not$dotnet){throw 'dotnet SDK is required for PlanningRuntime.Tests.ps1'}
function Invoke-Planner([string[]]$PlannerArgs){
    $raw=& $dotnet.Source run --project $plannerProject -- @PlannerArgs 2>&1|Out-String
    if($LASTEXITCODE-ne0){throw "Planner command failed: $raw"}
    $r=$raw|ConvertFrom-Json
    if(-not[bool]$r.ok){throw [string]$r.error}
    return $r.data
}
function Last-Json($Raw){
    $lines=@(([string]$Raw)-split[Environment]::NewLine|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
    if($lines.Count-eq0){throw 'No JSON output.'}
    return $lines[-1]|ConvertFrom-Json
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-planning-runtime-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try{
    Push-Location $temp
    & $harness init|Out-Null
    & $harness goal -Message 'Exercise the planning inference runtime.'|Out-Null
    $cfgPath=Join-Path $temp '.statefulclanker\config.json'
    $cfg=Get-Content -Raw -LiteralPath $cfgPath|ConvertFrom-Json
    $cfg.providers|Add-Member -NotePropertyName mock -NotePropertyValue ([pscustomobject]@{command=$pwsh;args=@('-NoProfile','-File',$planningMock,'-PromptFile','{promptFile}');mode='prompt-file'}) -Force
    $cfg|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $cfgPath -Encoding UTF8

    $begin=Invoke-Planner @('begin','--project',$temp,'--reason','planning runtime test')
    $settled=Invoke-Planner @('settle','--project',$temp)
    if(-not[bool]$settled.settled){throw 'Planning runtime test failed to settle.'}

    $brief=Join-Path $temp 'brief.txt'
    'Plan a bounded change without mutating implementation state.'|Set-Content -LiteralPath $brief -Encoding UTF8

    $single=Last-Json (& $harness planning run-pass -Role architecture -Path $brief -Provider mock 2>&1|Out-String)
    if([string]$single.participant.role-ne'architecture'){throw 'Single planning pass role was not persisted.'}
    if([string]$single.participant.status-ne'complete'){throw 'Single planning pass did not complete.'}
    if(-not$single.artifact.id){throw 'Single planning pass produced no durable artifact.'}
    if($null-eq$single.artifact.structured-or[string]::IsNullOrWhiteSpace([string]$single.artifact.structured.summary)){throw 'Single planning pass did not persist structured output.'}

    $recipe=Last-Json (& $harness planning run-recipe -Path $brief -Provider mock 2>&1|Out-String)
    if(-not[bool]$recipe.completed){throw 'Planning recipe did not complete.'}
    if(@($recipe.roles).Count-ne8){throw "Expected 8 planning roles, got $(@($recipe.roles).Count)."}
    if([string]$recipe.finalArtifact.role-ne'reconciler'){throw 'Planning recipe did not end in reconciler artifact.'}
    if($null-eq$recipe.finalArtifact.structured-or-not([string]$recipe.finalArtifact.structured.planText).TrimStart().StartsWith('SCPLAN 1',[StringComparison]::Ordinal)){throw 'Planning recipe final artifact is not a structured reconciled SCPLAN.'}

    $participants=Last-Json (& $harness planning participants 2>&1|Out-String)
    $artifacts=Last-Json (& $harness planning artifacts 2>&1|Out-String)
    $recipes=Last-Json (& $harness planning recipes 2>&1|Out-String)
    if(@($participants).Count-lt9){throw 'Planning participant registry did not retain pass history.'}
    if(@($artifacts).Count-lt9){throw 'Planning artifact registry did not retain pass outputs.'}
    if(@($recipes).Count-ne1-or[string]$recipes[0].status-ne'complete'){throw 'Planning recipe generation was not durably recorded complete.'}
    if([string]$recipes[0].id-ne[string]$recipe.recipeId){throw 'Planning recipe result did not match durable recipe generation.'}
    $recipeArtifacts=@($artifacts|Where-Object{[string]$_.recipeId-eq[string]$recipe.recipeId})
    if($recipeArtifacts.Count-ne8){throw "Expected 8 artifacts in recipe generation, got $($recipeArtifacts.Count)."}

    . (Join-Path $repo 'mcp\StatefulClanker.McpCore.ps1')
    . (Join-Path $repo 'mcp\StatefulClanker.McpExtensions.ps1')
    Set-McpDefaultProject $temp
    function Invoke-PlanningTool([int]$Id,$Arguments){
        $rpc=Invoke-McpRpc ([pscustomobject]@{jsonrpc='2.0';id=$Id;method='tools/call';params=[pscustomobject]@{name='planning_control';arguments=$Arguments}})
        if($rpc.result.PSObject.Properties['isError']-and[bool]$rpc.result.isError){throw [string]$rpc.result.content[0].text}
        return $rpc.result.content[0].text|ConvertFrom-Json
    }

    $mcpRecipe=Invoke-PlanningTool 801 ([pscustomobject]@{action='runRecipe';project=$temp;brief='Plan the same bounded change as an independent recipe generation.';provider='mock'})
    if(-not[bool]$mcpRecipe.completed){throw 'planning_control runRecipe did not complete.'}
    if([string]$mcpRecipe.recipeId-eq[string]$recipe.recipeId){throw 'MCP planning recipe reused a prior recipe generation id.'}
    $mcpRecipes=Invoke-PlanningTool 802 ([pscustomobject]@{action='recipes';project=$temp})
    if(@($mcpRecipes).Count-ne2){throw "Expected two durable recipe generations through MCP, got $(@($mcpRecipes).Count)."}

    $question=Invoke-PlanningTool 803 ([pscustomobject]@{
        action='ask';project=$temp;text='Which integration seam is authoritative?';why='Changes implementation boundary';impact='high';owner='human';blocking=$true
        affectedRefs=@('REQ-INTEGRATION');alternatives=@('seam-a','seam-b');questionEvidence=@('Both seams exist in current repository evidence.')
    })
    if(@($question.affectedRefs)-notcontains'REQ-INTEGRATION'){throw 'planning_control ask lost affected refs.'}
    if(@($question.alternatives).Count-ne2){throw 'planning_control ask lost alternatives.'}
    $answered=Invoke-PlanningTool 804 ([pscustomobject]@{action='answer';project=$temp;questionId=$question.id;text='seam-a';resolutionSource='human'})
    if([string]$answered.resolutionSource-ne'human'){throw 'planning_control answer lost resolution provenance.'}

    [void](Invoke-Planner @('cancel','--project',$temp,'--reason','recipe test complete'))

    Write-Host '  PLANNING RUNTIME E2E: MCP owns begin -> settle -> candidate -> accept -> apply'
    'Durable planning lifecycle evidence.'|Set-Content -LiteralPath (Join-Path $temp 'planning-spec.txt') -Encoding UTF8
    $mcpBegin=Invoke-PlanningTool 805 ([pscustomobject]@{action='begin';project=$temp;reason='MCP end-to-end planning lifecycle'})
    if([string]$mcpBegin.phase-ne'quiescing'){throw 'planning_control begin did not establish quiescing ownership.'}
    $mcpSettle=Invoke-PlanningTool 806 ([pscustomobject]@{action='settle';project=$temp})
    if(-not[bool]$mcpSettle.settled){throw 'planning_control settle did not freeze the baseline.'}

    $planText=@'
SCPLAN 1
plan mcp-end-to-end
summary Exercise the complete planning_control handoff path.

task mcp-planned-task
title MCP planned task
instruction Preserve the bounded planning lifecycle evidence.
size small
source file:planning-spec.txt
accept planning lifecycle evidence remains present
end
'@
    $mcpCandidate=Invoke-PlanningTool 807 ([pscustomobject]@{action='candidate';project=$temp;planText=$planText;summary='MCP candidate preflight and staging'})
    if(-not$mcpCandidate.id-or-not$mcpCandidate.planSha256){throw 'planning_control candidate did not stage a frozen plan.'}
    $mcpHandoff=Invoke-PlanningTool 808 ([pscustomobject]@{action='accept';project=$temp;candidateId=[string]$mcpCandidate.id})
    if([string]$mcpHandoff.status-ne'accepted'){throw 'planning_control accept did not produce an accepted handoff.'}
    $mcpApplied=Invoke-PlanningTool 809 ([pscustomobject]@{action='apply';project=$temp})
    if(-not[bool]$mcpApplied.applied){throw 'planning_control apply did not commit the accepted handoff.'}
    if(Test-Path -LiteralPath (Join-Path $temp '.statefulclanker\planning\active.json')){throw 'Planning barrier survived successful MCP apply/release.'}
    $appliedTask=Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\tasks\mcp-planned-task.json')|ConvertFrom-Json
    if([string]$appliedTask.id-ne'mcp-planned-task'){throw 'Applied MCP planning handoff did not install the replacement task graph.'}
    $appliedState=Get-Content -Raw -LiteralPath (Join-Path $temp '.statefulclanker\state.json')|ConvertFrom-Json
    if([string]$appliedState.activePlanId-ne[string]$mcpApplied.transaction.appliedPlanId){throw 'Applied plan id does not match the committed MCP planning transaction.'}

    Write-Host 'PASS: planning runtime persists isolated recipe generations, provenance-rich questions, and the complete MCP planning handoff lifecycle.'
}finally{
    Pop-Location -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

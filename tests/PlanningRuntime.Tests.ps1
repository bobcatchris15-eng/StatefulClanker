$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$harness=Join-Path $repo 'StatefulClanker.ps1'
$plannerProject=Join-Path $repo 'src\StatefulClanker.Planner\StatefulClanker.Planner.csproj'
$mockCmd=Join-Path $PSScriptRoot 'MockProvider.cmd'
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
    $cfg.providers|Add-Member -NotePropertyName mock -NotePropertyValue ([pscustomobject]@{command='cmd.exe';args=@('/d','/c',$mockCmd);mode='prompt-file'}) -Force
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

    $recipe=Last-Json (& $harness planning run-recipe -Path $brief -Provider mock 2>&1|Out-String)
    if(-not[bool]$recipe.completed){throw 'Planning recipe did not complete.'}
    if(@($recipe.roles).Count-ne8){throw "Expected 8 planning roles, got $(@($recipe.roles).Count)."}
    if([string]$recipe.finalArtifact.role-ne'reconciler'){throw 'Planning recipe did not end in reconciler artifact.'}

    $participants=Last-Json (& $harness planning participants 2>&1|Out-String)
    $artifacts=Last-Json (& $harness planning artifacts 2>&1|Out-String)
    $recipes=Last-Json (& $harness planning recipes 2>&1|Out-String)
    if(@($participants).Count-lt9){throw 'Planning participant registry did not retain pass history.'}
    if(@($artifacts).Count-lt9){throw 'Planning artifact registry did not retain pass outputs.'}
    if(@($recipes).Count-ne1-or[string]$recipes[0].status-ne'complete'){throw 'Planning recipe generation was not durably recorded complete.'}
    if([string]$recipes[0].id-ne[string]$recipe.recipeId){throw 'Planning recipe result did not match durable recipe generation.'}
    $recipeArtifacts=@($artifacts|Where-Object{[string]$_.recipeId-eq[string]$recipe.recipeId})
    if($recipeArtifacts.Count-ne8){throw "Expected 8 artifacts in recipe generation, got $($recipeArtifacts.Count)."}

    [void](Invoke-Planner @('cancel','--project',$temp,'--reason','test complete'))
    Write-Host 'PASS: planning runtime persists session-scoped participants/artifacts and executes the fixed specialist recipe.'
}finally{
    Pop-Location -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

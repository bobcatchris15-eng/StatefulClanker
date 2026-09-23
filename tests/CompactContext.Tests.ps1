$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "COMPACT CONTEXT TEST FAILED: $Message"}}

. (Join-Path $repo 'lib\StatefulClanker.Core.ps1')

Write-Host '  COMPACT CONTEXT 1: repeated record keys collapse into one schema row'
$tasks=@()
foreach($i in 1..24){
    $tasks+=,[ordered]@{
        id=("t-{0:d2}"-f$i)
        status=$(if($i%3-eq0){'complete'}elseif($i%2-eq0){'ready'}else{'pending'})
        attempts=$i%4
        title=("bounded task {0}"-f$i)
    }
}
$fixture=[ordered]@{
    project=[ordered]@{goal='Build a deterministic orchestration harness';revision=17;held=$false}
    tasks=$tasks
    acceptance=@('build passes','state persists','routing remains available')
    note=('first line'+[Environment]::NewLine+'second line')
}
$json=$fixture|ConvertTo-Json -Depth 12
$compact=ConvertTo-SCModelText $fixture 12
Assert-True ($compact.Contains('[id|status|attempts|title]')) 'Homogeneous task records were not schema-compressed.'
Assert-True (-not$compact.Contains('"id":')) 'Compact projection still emits JSON key syntax.'
Assert-True (-not$compact.Contains('{"')) 'Compact projection still emits JSON object punctuation.'
Assert-True ($compact.Contains('goal=Build a deterministic orchestration harness')) 'Scalar project fact was lost.'
Assert-True ($compact.Contains('t-24')) 'Late table row was lost.'
Assert-True ($compact.Contains('note:')) 'Multiline field label was lost.'
Assert-True ($compact.Contains('  second line')) 'Multiline field body was lost.'
$pathProjection=ConvertTo-SCModelText ([ordered]@{path='C:\work\project\src\file.cs'}) 4
Assert-True ($pathProjection.Contains('C:\work\project\src\file.cs')) 'Compact projection unnecessarily escaped ordinary Windows path separators.'
Assert-True (-not$pathProjection.Contains('C:\\work')) 'Compact projection regressed to JSON-style doubled backslashes.'

Write-Host '  COMPACT CONTEXT 2: projection is materially smaller than pretty JSON for repetitive state'
Assert-True ($compact.Length-lt[int]($json.Length*.72)) "Expected at least 28% character reduction; JSON=$($json.Length), compact=$($compact.Length)."

Write-Host '  COMPACT CONTEXT 3: compact text is a projection, while durable/wire formats remain JSON'
$core=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
$mcp=Get-Content -Raw -LiteralPath (Join-Path $repo 'mcp\StatefulClanker.McpCore.ps1')
Assert-True ($core.Contains('ConvertTo-SCJson $Value 30 | Set-Content')) 'Durable Write-SCJson no longer writes canonical JSON.'
Assert-True ($core.Contains('$raw|ConvertFrom-Json')) 'Durable Read-SCJson no longer reads canonical JSON.'
Assert-True ($mcp.Contains('ConvertTo-Json -InputObject $Value -Depth 30')) 'MCP canonical text result no longer preserves JSON objects.'

Write-Host '  COMPACT CONTEXT 4: worker/reviewer/project-review prompts use compact projections'
$context=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.Context.ps1')
$projectReview=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.ProjectReview.ps1')
$execution=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.Execution.ps1')
Assert-True ($context.Contains('ConvertTo-SCModelText $Compilation.ir 22')) 'Worker/reviewer compiled context is not compact-projected.'
Assert-True (-not$context.Contains('ConvertTo-SCJson $Compilation.ir 22')) 'Worker/reviewer still embeds pretty JSON compilation state.'
Assert-True ($context.Contains('ConvertTo-SCModelText $acceptanceEvidence 16')) 'Mechanical evidence is not compact-projected for fallback review.'
Assert-True ($projectReview.Contains('ConvertTo-SCModelText $Packet 20')) 'Whole-project review packet is not compact-projected.'
Assert-True ($execution.Contains('$stateProjection=ConvertTo-SCModelText $state 20')) 'Jev state is not compact-projected.'
Assert-True ($execution.Contains('@{state=$stateProjection;model=$model;questions=$questions}|ConvertTo-Json')) 'Jev JSON envelope/questions were not preserved around compact state.'

Write-Host '  COMPACT CONTEXT 5: Pi compaction and selected high-volume read tools project compactly'
$pi=Get-Content -Raw -LiteralPath (Join-Path $repo 'pi\extensions\statefulclanker.ts')
Assert-True ($pi.Contains('function compactModelText(')) 'Pi compact serializer is missing.'
Assert-True (-not$pi.Contains('function packetJson(')) 'Pi reality compaction still owns a pretty-JSON packet helper.'
Assert-True ($pi.Contains('const COMPACT_TOOL_RESULTS = new Set([')) 'Pi high-volume tool projection set is missing.'
foreach($tool in @('task_recovery_context','control_snapshot','task_list','task_show','autofill_status')){
    Assert-True ($pi.Contains('"' + $tool + '"')) "Pi does not compact high-volume tool result: $tool"
}
Assert-True ($pi.Contains('STATEFULCLANKER COMPACT PROJECTION')) 'Pi projected tool results are not explicitly labeled.'

Write-Host '  COMPACT CONTEXT 6: direct-worker read/command results avoid JSON reinjection'
$runtime=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')
foreach($needle in @(
    "return ConvertTo-SCModelText (Invoke-SCBoundedCommand",
    "return ConvertTo-SCModelText ([ordered]@{status=",
    "return ConvertTo-SCModelText (Resolve-SCHumanIntentArtifact",
    "return ConvertTo-SCModelText (Get-SCNormalizedIntentView"
)){
    Assert-True ($runtime.Contains($needle)) "Direct worker still reinjects verbose structured output: $needle"
}

Write-Host '  COMPACT CONTEXT 7: external worker MCP results are projected after transport'
$workerPolicy=Get-Content -Raw -LiteralPath (Join-Path $repo 'lib\StatefulClanker.WorkerPolicy.ps1')
Assert-True ($workerPolicy.Contains('function ConvertTo-SCWorkerMcpModelText')) 'External MCP JSON text has no compact projection adapter.'
Assert-True ($workerPolicy.Contains('ConvertTo-SCModelText $result 30 -MaxChars 48000')) 'Structured external MCP result is still serialized verbosely into worker context.'
Assert-True ($workerPolicy.Contains('$trim|ConvertFrom-Json')) 'JSON-looking external MCP text is not recognized before projection.'

Write-Host 'PASS: JSON remains canonical while repeated model context uses deterministic compact projections.'

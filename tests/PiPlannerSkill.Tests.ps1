$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "PI PLANNER SKILL TEST FAILED: $Message"}}

$extension=Get-Content -Raw -LiteralPath (Join-Path $repo 'pi\extensions\statefulclanker.ts')
$launcher=Get-Content -Raw -LiteralPath (Join-Path $repo 'pi\pi.cmd')
$planner=Get-Content -Raw -LiteralPath (Join-Path $repo 'skills\statefulclanker-planner\SKILL.md')

Write-Host '  PI PLANNER 1: planner is a valid named Pi skill'
Assert-True ($planner.StartsWith("---")) 'Planner skill is missing YAML frontmatter.'
Assert-True ($planner.Contains('name: statefulclanker-planner')) 'Planner skill name is missing.'
Assert-True ($planner.Contains('description: Use whenever planning')) 'Planner skill description does not advertise planning/decomposition intent.'

Write-Host '  PI PLANNER 2: bundled and fallback Pi advertise the planner skill'
Assert-True ($launcher.Contains('--skill "%~dp0..\skills\statefulclanker-planner\SKILL.md"')) 'Pi launcher does not pass the planner skill explicitly.'
Assert-True (([regex]::Matches($launcher,'--skill "%~dp0..\\skills\\statefulclanker-planner\\SKILL.md"')).Count-eq2) 'Both bundled and global Pi launch paths must advertise the planner skill.'

Write-Host '  PI PLANNER 3: planning turns inject the full methodology before inference'
Assert-True ($extension.Contains('function planningIntent(prompt: string): boolean')) 'Planning intent detector is missing.'
Assert-True ($extension.Contains('readPlannerSkill()')) 'Planner skill loader is missing.'
Assert-True ($extension.Contains('if (planningIntent(event.prompt))')) 'before_agent_start does not activate planning mode from the user prompt.'
Assert-True ($extension.Contains('MANDATORY STATEFULCLANKER PLANNING MODE')) 'Planning injection is not mandatory/explicit.'
Assert-True ($extension.Contains('readPlannerSkill(),')) 'Planning turn does not inject the full planner skill.'

Write-Host '  PI PLANNER 4: ordinary turns do not retain planner bulk'
Assert-True ($extension.Contains('delete event.systemPromptOptions.sections.statefulclankerPlanner')) 'Planner system-prompt section is not removed for non-planning turns.'

Write-Host '  PI PLANNER 5: expected planning phrases are covered'
foreach($needle in @('planning','decompos','task\\s+(?:list|graph','scplan','map\\s+out')){
    Assert-True ($extension -match $needle) "Planner trigger family missing: $needle"
}

Write-Host 'PASS: bundled Pi advertises the planner skill and automatically invokes it only for planning/decomposition turns.'

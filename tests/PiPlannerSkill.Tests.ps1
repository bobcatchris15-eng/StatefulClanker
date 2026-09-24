$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "PI PLANNER ROLE TEST FAILED: $Message"}}

$extension=Get-Content -Raw -LiteralPath (Join-Path $repo 'pi\extensions\statefulclanker.ts')
$launcher=Get-Content -Raw -LiteralPath (Join-Path $repo 'pi\pi.cmd')
$interrogate=Get-Content -Raw -LiteralPath (Join-Path $repo 'pi\interrogate.cmd')
$planner=Get-Content -Raw -LiteralPath (Join-Path $repo 'skills\statefulclanker-planner\SKILL.md')
$interrogator=Get-Content -Raw -LiteralPath (Join-Path $repo 'skills\statefulclanker-interrogator\SKILL.md')

Write-Host '  PI ROLE 1: planning skills are valid named skills'
Assert-True ($planner.StartsWith('---')) 'Planner skill is missing YAML frontmatter.'
Assert-True ($planner.Contains('name: statefulclanker-planner')) 'Planner skill name is missing.'
Assert-True ($interrogator.StartsWith('---')) 'Interrogator skill is missing YAML frontmatter.'
Assert-True ($interrogator.Contains('name: statefulclanker-interrogator')) 'Interrogator skill name is missing.'

Write-Host '  PI ROLE 2: normal Pi is Operator-only'
Assert-True ($launcher.Contains('STATEFULCLANKER_PI_ROLE=operator')) 'Default Pi role is not Operator.'
Assert-True ($launcher.Contains('--skill "%~dp0..\skills\statefulclanker\SKILL.md"')) 'Operator launcher does not load Operator skill.'
Assert-True (-not$launcher.Contains(':launch_operator' + [Environment]::NewLine + 'if exist "%~dp0runtime\node.exe" (' + [Environment]::NewLine + '  "%~dp0runtime\node.exe" "%~dp0runtime\node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.js" --extension "%~dp0extensions\statefulclanker.ts" --skill "%~dp0..\skills\statefulclanker-planner\SKILL.md"')) 'Operator path still directly loads planner skill.'

Write-Host '  PI ROLE 3: Interrogator is an explicit launcher'
Assert-True ($interrogate.Contains('STATEFULCLANKER_PI_ROLE=interrogator')) 'Interrogator launcher does not select Interrogator role.'
Assert-True ($launcher.Contains(':launch_interrogator')) 'Pi launcher has no Interrogator branch.'
Assert-True ($launcher.Contains('--skill "%~dp0..\skills\statefulclanker-interrogator\SKILL.md" --skill "%~dp0..\skills\statefulclanker-planner\SKILL.md"')) 'Interrogator path does not load both Interrogator and decomposition skills.'

Write-Host '  PI ROLE 4: extension uses explicit role, not prompt guessing'
Assert-True ($extension.Contains('STATEFULCLANKER_PI_ROLE')) 'Extension does not read explicit conversation role.'
Assert-True ($extension.Contains('CONVERSATION_ROLE === "interrogator"')) 'Extension has no Interrogator role branch.'
Assert-True (-not$extension.Contains('function planningIntent(prompt: string): boolean')) 'Prompt-based planning intent detector still exists.'
Assert-True (-not$extension.Contains('planningIntent(event.prompt)')) 'Prompt text still switches Operator into planning mode.'
Assert-True ($extension.Contains('Deliberate planning/replanning belongs to a separately launched Interrogator session')) 'Operator prompt does not preserve the role boundary.'

Write-Host '  PI ROLE 5: Interrogator does not run Operator event supervision'
Assert-True ($extension.Contains('if (CONVERSATION_ROLE === "operator") {')) 'Operator-only event supervision guard is missing.'
Assert-True ($extension.Contains('if (CONVERSATION_ROLE === "operator") void poll();')) 'Interrogator would still poll execution recovery events.'

Write-Host 'PASS: bundled Pi has explicit mutually exclusive Operator and Interrogator conversation roles.'

$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "PI REALITY COMPACTION TEST FAILED: $Message"}}

$extensionPath=Join-Path $repo 'pi\extensions\statefulclanker.ts'
Assert-True (Test-Path -LiteralPath $extensionPath) 'Bundled Pi extension is missing.'
$source=Get-Content -Raw -LiteralPath $extensionPath

Write-Host '  PI COMPACTION 1: bundled Pi owns compaction'
Assert-True ($source.Contains('pi.on("session_before_compact"')) 'No session_before_compact handler is registered.'
Assert-True ($source.Contains('statefulclanker-reality-v1')) 'Reality compaction strategy marker is missing.'
Assert-True (-not $source.Contains('modelRegistry.complete(')) 'Reality compaction must not spend an inference request on summarization.'

Write-Host '  PI COMPACTION 2: checkpoint is rebuilt from current reality'
foreach($needle in @('name: "control_snapshot"','name: "autofill_status"','name: "task_list"','execFileSync("git"','CURRENT FILE SNAPSHOTS','CURRENT WORKTREE DIFF')){
    Assert-True ($source.Contains($needle)) "Reality source missing: $needle"
}

Write-Host '  PI COMPACTION 3: Pi keeps its recent raw tail'
Assert-True ($source.Contains('firstKeptEntryId: event.preparation.firstKeptEntryId')) 'Compaction no longer retains Pi''s selected recent tail.'
Assert-True ($source.Contains('tokensBefore: event.preparation.tokensBefore')) 'Compaction no longer reports the original context size.'

Write-Host '  PI COMPACTION 4: historical material is subordinate and bounded'
Assert-True ($source.Contains('ARCHIVAL CARRYOVER — LOW AUTHORITY')) 'Prior summary is not explicitly marked low-authority.'
Assert-True ($source.Contains('USER EVIDENCE FROM THE DISCARDED HISTORY')) 'Discarded human messages are not retained as evidence.'
$budget=[regex]::Match($source,'REALITY_PACKET_MAX_CHARS\s*=\s*(\d+)')
Assert-True $budget.Success 'Reality packet budget constant is missing.'
Assert-True ([int]$budget.Groups[1].Value -ge 90000) 'Reality packet is too small to dominate the retained working context.'

Write-Host '  PI COMPACTION 5: Pi file-operation continuity survives custom compaction'
Assert-True ($source.Contains('readFiles: stringList(fileOps.read)')) 'Read-file history is not carried through compaction details.'
Assert-True ($source.Contains('modifiedFiles: stringList(fileOps.edited ?? fileOps.modified)')) 'Modified-file history is not carried through compaction details.'

Write-Host '  PI COMPACTION 6: routine turn-end refresh is aggressive but not pathological'
Assert-True ($source.Contains('pi.on("turn_end"')) 'No proactive turn-end compaction trigger is registered.'
Assert-True ($source.Contains('REALITY_COMPACTION_TRIGGER_FRACTION = 0.45')) 'Proactive compaction no longer targets roughly 45% context usage.'
Assert-True ($source.Contains('REALITY_COMPACTION_MAX_TRIGGER_TOKENS = 64_000')) 'Large-context models can drift too far before reality refresh.'
Assert-True ($source.Contains('REALITY_COMPACTION_MIN_TURNS = 2')) 'Compaction churn guard is missing.'
Assert-True ($source.Contains('ctx.compact({')) 'Turn-end policy does not actually trigger Pi compaction.'

Write-Host '  PI COMPACTION 7: packet budget scales down for small-context models'
Assert-True ($source.Contains('Math.floor(contextWindow * 1.5)')) 'Reality packet budget is not scaled to model context size.'

Write-Host 'PASS: bundled Pi compaction is reality-first, proactive, request-free, bounded, and retains the recent raw tail.'

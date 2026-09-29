param([Parameter(Mandatory=$true)][string]$PromptFile)
$prompt=Get-Content -Raw -LiteralPath $PromptFile
$role=''
if($prompt -match '(?m)^Role:\s*([^\r\n]+)'){$role=$Matches[1].Trim().ToLowerInvariant()}
$plan=@'
SCPLAN 1
plan mock-planning
summary Mock planning candidate.

task mock-planned-task
title Mock planned task
instruction Preserve the bounded planning fixture.
size small
source file:brief.txt
accept bounded planning fixture remains present
end
'@
switch($role){
    'decomposition' {
        [ordered]@{summary='mock decomposition';obligationsCovered=@();openQuestions=@();planText=$plan}|ConvertTo-Json -Depth 12 -Compress
    }
    'reconciler' {
        [ordered]@{summary='mock reconciliation';projectGoal=$null;intentContract=$null;directiveChanges=@();planText=$plan;openQuestions=@();unresolvedConflicts=@()}|ConvertTo-Json -Depth 12 -Compress
    }
    default {
        [ordered]@{summary=("mock "+$role);observations=@();obligations=@();assumptions=@();questions=@();risks=@();evidence=@()}|ConvertTo-Json -Depth 12 -Compress
    }
}
exit 0

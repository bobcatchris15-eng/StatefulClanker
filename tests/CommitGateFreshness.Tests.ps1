$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "COMMIT GATE TEST FAILED: $Message"}}

. (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
. (Join-Path $repo 'lib\StatefulClanker.Context.ps1')
. (Join-Path $repo 'lib\StatefulClanker.Execution.ps1')
. (Join-Path $repo 'lib\StatefulClanker.ReflexiveKnowledge.ps1')
. (Join-Path $repo 'lib\StatefulClanker.Semantics.ps1')

$tmp=Join-Path ([IO.Path]::GetTempPath()) ("sc-commitgate-"+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp|Out-Null
try{
    Write-Host '  COMMIT GATE 1: RPK forwards non-null arguments and omits null ones'
    $echo=Join-Path $tmp 'echo-args.ps1'
    Set-Content -LiteralPath $echo -Value '@{argv=@($args)}|ConvertTo-Json -Compress' -Encoding UTF8
    $pwshPath=(Get-Process -Id $PID).Path
    function Get-SCRpkHost { return [pscustomobject]@{file=$pwshPath;prefix=@('-NoProfile','-File',$echo)} }
    function Get-SCRoot { return $tmp }
    $out=Invoke-SCRpk 'lesson-add' @{body='keep the mutex';path=$null}
    $argv=@($out.argv)
    Assert-True ($argv -contains '--body') 'RPK dropped a non-null argument key.'
    Assert-True ($argv[[array]::IndexOf($argv,'--body')+1]-eq'keep the mutex') 'RPK did not forward the argument value.'
    Assert-True (-not($argv -contains '--path')) 'RPK forwarded a null argument.'

    Write-Host '  COMMIT GATE 2: disabled validator still enforces mechanical checks'
    $script:rejected=$null
    function Get-SCConfig { return [pscustomobject]@{validatorEnabled=$false} }
    function Invoke-SCMechanicalAcceptanceCommand { param([string]$Command,[int]$Index,$Task) [pscustomobject]@{index=$Index;command=$Command;passed=$false;exitCode=1;timedOut=$false;startedAt='now';durationSeconds=0;output='boom'} }
    function Reject-SCProposal { param($Proposal,$Reasons) $script:rejected=@($Reasons) }
    function Save-SCProposal { param($Proposal) }
    function Save-SCTask { param($Task) }
    function Add-SCProgressRecord { param($Task,$Compilation,$Ok,$Outcome,$Detail) }
    $task=[pscustomobject]@{id='t1';status='validating';blockReason=$null;checks=@('exit 1')}
    $proposal=[pscustomobject]@{id='p1';status='pending';evidence=[pscustomobject]@{validationVerdict=$null}}
    $ok=Commit-SCProposal $task $proposal ([pscustomobject]@{id='c1'})
    Assert-True (-not$ok) 'Commit succeeded despite a failing mechanical check with the validator disabled.'
    Assert-True ($null-ne$script:rejected -and (($script:rejected -join ';') -match 'mechanical check 1 failed')) 'Rejection did not name the failing mechanical check.'
    Assert-True ([string]$task.status-eq'needs_rework') 'Task was not sent back for rework.'

    Write-Host '  COMMIT GATE 3: commit freshness excuses the worker''s own edits but not later ones'
    $gitRoot=Join-Path $tmp 'proj';New-Item -ItemType Directory -Force -Path $gitRoot|Out-Null
    & git -C $gitRoot init -q;& git -C $gitRoot config core.autocrlf false
    $file=Join-Path $gitRoot 'a.txt';[IO.File]::WriteAllText($file,"worker output`n")
    & git -C $gitRoot add a.txt;$tree=([string](& git -C $gitRoot write-tree)).Trim()
    function Get-SCWorkerSession { param([string]$SessionId) [pscustomobject]@{workRoot=$gitRoot;checkpoints=@([pscustomobject]@{id='s-cp-1';tree=$tree})} }
    $prop=[pscustomobject]@{evidence=[pscustomobject]@{workerSessionId='s';candidateCheckpointId='s-cp-1'}}
    $snap=Get-SCProposalCandidateSnapshot $prop
    Assert-True ($null-ne$snap -and $snap.tree-eq$tree) 'Candidate snapshot was not resolved from proposal evidence.'
    Assert-True (Test-SCFileMatchesCandidate $snap 'a.txt' $file) 'File identical to the candidate was treated as changed underneath the worker.'
    [IO.File]::WriteAllText($file,"someone else edited this`n")
    Assert-True (-not(Test-SCFileMatchesCandidate $snap 'a.txt' $file)) 'File edited after the candidate was not detected.'
    Remove-Item -LiteralPath $file
    Assert-True (-not(Test-SCFileMatchesCandidate $snap 'a.txt' $file)) 'File deleted after the candidate was not detected.'
    Assert-True (Test-SCFileMatchesCandidate $snap 'never-existed.txt' (Join-Path $gitRoot 'never-existed.txt')) 'File absent from both candidate and disk was flagged.'
    Assert-True ($null-eq(Get-SCProposalCandidateSnapshot ([pscustomobject]@{evidence=[pscustomobject]@{runId='r'}}))) 'Proposal without a worker session produced a snapshot.'
}finally{
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS: RPK argument forwarding, validator-off mechanical gate, and commit-time read-set freshness.'

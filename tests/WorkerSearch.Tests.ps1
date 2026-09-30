$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "WORKER SEARCH TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-search-'+[guid]::NewGuid().ToString('N'))
$work=Join-Path $temp '.statefulclanker/worktrees/search'
$priorLocal=$env:LOCALAPPDATA
$env:LOCALAPPDATA=Join-Path $temp 'local'
New-Item -ItemType Directory -Force -Path (Join-Path $work 'src'),(Join-Path $work '.statefulclanker'),$env:LOCALAPPDATA|Out-Null
try{
    . (Join-Path $repo 'lib/StatefulClanker.Core.ps1')
    . (Join-Path $repo 'lib/StatefulClanker.WorkerPolicy.ps1')
    . (Join-Path $repo 'lib/StatefulClanker.WorkerRuntime.ps1')
    Set-SCRoots $work $temp
    function Add-SCEvent {param($Type,$Message,$Data)}
    'literal needle.* and needle.*'|Set-Content (Join-Path $work 'src/found.txt')
    'literal needle.* secret'|Set-Content (Join-Path $work '.statefulclanker/secret.txt')
    'needleABC'|Set-Content (Join-Path $work 'src/regex.txt')
    $task=[pscustomobject]@{id='search';role='worker'}
    $registry=@(Get-SCIntrinsicWorkerToolRecords $task)
    $result=Invoke-SCWorkerTool 'search_text' @{path='.';pattern='needle.*'} $task 'worker' $registry|ConvertFrom-Json
    Assert-True ($result.matches.Count-eq1-and$result.matches[0]-match'found.txt') 'nested worktree search excluded legitimate files or used regex'
    Assert-True ($result.filesExcluded-eq1-and$result.filesSearched-eq2) 'search coverage or control-state exclusion is wrong'
    $empty=Invoke-SCWorkerTool 'search_text' @{path='src';pattern='absent'} $task 'worker' $registry|ConvertFrom-Json
    Assert-True ($empty.matches.Count-eq0-and$empty.filesSearched-eq2-and$empty.matching-eq'literal') 'no-match result is ambiguous'
    $file=Invoke-SCWorkerTool 'search_text' @{path='src/found.txt';pattern='needle.*'} $task 'worker' $registry|ConvertFrom-Json
    Assert-True ($file.matches.Count-eq1-and$file.matches[0]-notmatch'\.statefulclanker') 'single-file result is not relative to worker root'
    Save-SCWorkerSession ([pscustomobject]@{id='notes-session';candidateNumber=0})
    Set-SCWorkerCandidateClaim 'notes-session' @{summary='Finished';warningsForSuccessor=@('UI not tested');uncertainties=@(('x'*700));negativeFindings=@('parser hypothesis ruled out')}
    $claim=(Get-SCWorkerSession 'notes-session').candidateClaim
    Assert-True ($claim.warningsForSuccessor-contains'UI not tested'-and$claim.negativeFindings-contains'parser hypothesis ruled out') 'finish claim lost advisory handoff notes'
    Assert-True ($claim.uncertainties[0].Length-le500-and$claim.uncertainties[0]-match'\[truncated\]') 'bounded candidate notes dropped limits or failed to mark truncation'
    Write-Host 'PASS: nested worktree literal search, exclusion, relative paths and no-match coverage.'
}finally{$env:LOCALAPPDATA=$priorLocal;Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}

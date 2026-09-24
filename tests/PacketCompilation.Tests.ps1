$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
$harness=Join-Path $repo 'StatefulClanker.ps1'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "PACKET COMPILATION TEST FAILED: $Message"}}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-packetcompile-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
Push-Location $temp
try{
    & $harness init | Out-Null

    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Eventing.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Context.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Directives.ps1')
    . (Join-Path $repo 'lib\StatefulClanker.Intent.ps1')

    'evidence for retrieval'|Set-Content -LiteralPath (Join-Path $temp 'evidence.txt') -Encoding UTF8
    function New-SCTestTask([string]$Id) {
        [pscustomobject]@{
            schemaVersion=4;id=$Id;title='sample task';instruction='do the thing';outputKind='change';acceptance=@('it works');
            dependsOn=@();relations=@();retrieval=@();evidence=@('evidence.txt');checks=@();semanticAcceptance=@();provider=$null;role='worker';humanGate=$false;
            status='pending';stateRevision=0;controlRevision=0;attemptCount=0;criticRejectCount=0;validatorRejectCount=0;
            activeWorkerSessionId=$null;latestWorkerSessionId=$null;latestRunId=$null;latestCompilationId=$null;
            latestProposalId=$null;latestCritiqueId=$null;latestValidationId=$null;blockReason=$null;
            createdAt=(Get-Date).ToUniversalTime().ToString('o');updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        }
    }

    Write-Host '  PACKET 1: sections present, capped, and included in read-set when data exists'
    function Search-SCRpkLessons([string]$Text,[string[]]$Paths,[int]$Limit) {
        return @(1..7|ForEach-Object{[pscustomobject]@{id="lesson-$_";title="Lesson $_";body=('x'*700);status=$(if($_-eq 2){'needs_review'}elseif($_-eq 3){'rejected'}else{'confirmed'})}})
    }
    function Get-SCRpkNeighbors([string]$Path,[int]$Depth,[int]$Limit) {
        return [pscustomobject]@{neighbors=@(1..50|ForEach-Object{[pscustomobject]@{path="src/file$_.ps1";relation='calls'}})}
    }
    $task1=New-SCTestTask 'task-with-data'
    $progressDir=Get-SCPath 'progress';New-Item -ItemType Directory -Force -Path $progressDir|Out-Null
    for($i=1;$i-le 5;$i++){
        $rec=[pscustomobject]@{schemaVersion=1;id="progress-$i";ts=(Get-Date).ToUniversalTime().AddMinutes(-$i).ToString('o');taskId=$task1.id;compilationId=$null;inputFingerprint=$null;advanced=$false;outcome="attempt-$i";reason=("reason text $i")}
        Write-SCJson (Join-Path $progressDir "progress-$i.json") $rec
    }
    $receipt1=New-SCCompilation $task1
    Assert-True ($receipt1.ir.sources.Contains('projectLessons')) 'projectLessons section missing when lessons exist.'
    Assert-True (@($receipt1.ir.sources.projectLessons.items).Count-eq 5) "projectLessons was not capped to 5 (got $(@($receipt1.ir.sources.projectLessons.items).Count))."
    Assert-True (-not(@($receipt1.ir.sources.projectLessons.items)|Where-Object{$_.status-eq'rejected'})) 'A rejected lesson leaked into projectLessons.'
    Assert-True ((@($receipt1.ir.sources.projectLessons.items)|Where-Object{$_.status-eq'needs_review'}|Select-Object -First 1).unverified-eq$true) 'needs_review lesson was not flagged unverified.'
    Assert-True ($receipt1.ir.sources.Contains('codeNeighbours')) 'codeNeighbours section missing when neighbours exist.'
    Assert-True (@($receipt1.ir.sources.codeNeighbours.items).Count-eq 40) "codeNeighbours was not capped to 40 (got $(@($receipt1.ir.sources.codeNeighbours.items).Count))."
    Assert-True ($receipt1.ir.sources.Contains('attemptHistory')) 'attemptHistory section missing when progress records exist.'
    Assert-True (@($receipt1.ir.sources.attemptHistory.items).Count-eq 3) "attemptHistory was not capped to 3 (got $(@($receipt1.ir.sources.attemptHistory.items).Count))."
    Assert-True ([string]$receipt1.ir.sources.attemptHistory.items[0].outcome-eq'attempt-1') 'attemptHistory was not newest-first.'
    Assert-True ($receipt1.readSet.Contains('projectLessonsHash')-and $receipt1.readSet.Contains('codeNeighboursHash')-and $receipt1.readSet.Contains('attemptHistoryHash')) 'New sections were not folded into readSet hashes.'
    Assert-True (@($receipt1.contextFaults).Count-eq 0) 'Unexpected context faults recorded when RPK succeeded.'

    Write-Host '  PACKET 2: sections omitted cleanly when empty'
    function Search-SCRpkLessons([string]$Text,[string[]]$Paths,[int]$Limit) { return @() }
    function Get-SCRpkNeighbors([string]$Path,[int]$Depth,[int]$Limit) { return $null }
    $task2=New-SCTestTask 'task-no-data'
    $receipt2=New-SCCompilation $task2
    Assert-True (-not$receipt2.ir.sources.Contains('projectLessons')) 'Empty projectLessons was not omitted.'
    Assert-True (-not$receipt2.ir.sources.Contains('codeNeighbours')) 'Empty codeNeighbours was not omitted.'
    Assert-True (-not$receipt2.ir.sources.Contains('attemptHistory')) 'Empty attemptHistory was not omitted for a task with no prior attempts.'
    Assert-True (@($receipt2.contextFaults).Count-eq 0) 'Empty-but-available RPK results should not be recorded as faults.'

    Write-Host '  PACKET 3: an unavailable/throwing RPK host never fails compilation, and is recorded as a fault'
    function Search-SCRpkLessons([string]$Text,[string[]]$Paths,[int]$Limit) { throw 'RPK host unreachable' }
    function Get-SCRpkNeighbors([string]$Path,[int]$Depth,[int]$Limit) { throw 'RPK host unreachable' }
    $task3=New-SCTestTask 'task-rpk-down'
    $receipt3=$null
    $receipt3=New-SCCompilation $task3
    Assert-True ($null-ne$receipt3) 'Compilation failed outright when RPK threw.'
    Assert-True (-not$receipt3.ir.sources.Contains('projectLessons')) 'projectLessons should be absent when RPK throws.'
    Assert-True (-not$receipt3.ir.sources.Contains('codeNeighbours')) 'codeNeighbours should be absent when RPK throws.'
    Assert-True (@($receipt3.contextFaults).Count-eq 2) "Expected 2 recorded context faults for a throwing RPK, got $(@($receipt3.contextFaults).Count)."
    Assert-True ((@($receipt3.contextFaults)|Where-Object{$_.source-eq'projectLessons'}).reason-match'RPK host unreachable') 'projectLessons fault reason was not recorded.'
    Assert-True ((@($receipt3.contextFaults)|Where-Object{$_.source-eq'codeNeighbours'}).reason-match'RPK host unreachable') 'codeNeighbours fault reason was not recorded.'
    $faultsLog=Get-SCPath 'telemetry/context-faults.jsonl'
    Assert-True (Test-Path -LiteralPath $faultsLog) 'context-faults.jsonl was not written.'
    Assert-True ((Get-Content -Raw -LiteralPath $faultsLog) -match 'RPK host unreachable') 'Fault was not appended to the context-faults log.'
}finally{
    Pop-Location
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS: packet compilation adds bounded lessons/neighbours/attempt-history sections and never fails on RPK unavailability.'

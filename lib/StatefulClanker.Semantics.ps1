# Preserve planner semantics in the actual compiled IR seen by workers/reviewers,
# include current reconciled human directives, and make canonical-state artifacts
# participate correctly in freshness even when WorkRoot is a git worktree.

$script:SCBaseNewCompilation = (Get-Item Function:\New-SCCompilation).ScriptBlock
$script:SCBaseCompilationFreshness = (Get-Item Function:\Test-SCCompilationFreshness).ScriptBlock

function Resolve-SCSourceReference([string]$SourceRef) {
    if([string]::IsNullOrWhiteSpace($SourceRef)){return $null}
    $base=$SourceRef;$start=$null;$end=$null
    if($SourceRef -match '^(.*)#L(\d+)(?:-L?(\d+))?$') {$base=$Matches[1];$start=[int]$Matches[2];$end=if($Matches[3]){[int]$Matches[3]}else{$start}}
    $full=$null;$authority='source';$relative=$null
    if($base -match '^human:(.+)$') {$id=$Matches[1];$relative=(".statefulclanker/input/{0}.txt"-f$id);$full=Get-SCPath ("input/{0}.txt"-f$id);$authority='human-source'}
    elseif($base -match '^(?:file|docs):(.+)$') {$relative=$Matches[1];$full=Join-Path (Get-SCRoot) $relative}
    else { return $null }
    if(-not(Test-Path -LiteralPath $full -PathType Leaf)){return $null}
    if($null-ne$start) {$all=@(Get-Content -LiteralPath $full);$lo=[Math]::Max(1,$start);$hi=[Math]::Min($all.Count,$end);$text=if($lo-gt$hi){''}else{$all[($lo-1)..($hi-1)] -join "`r`n"}}
    else {$text=Get-Content -Raw -LiteralPath $full;if($null-eq$text){$text=''}}
    return [ordered]@{ref=$SourceRef;baseRef=$base;path=$relative;fullPath=$full;authority=$authority;lineStart=$start;lineEnd=$end;content=[string]$text;sha256=Get-SCFileHashValue $full}
}

function New-SCCompilation($Task) {
    if(-not(Test-SCDirectivesReconciled)) {
        $state=Get-SCState;$pending=if($state.PSObject.Properties['pendingDirectiveIds']){@($state.pendingDirectiveIds)-join', '}else{'unknown'}
        throw "Current human directives changed and the Intent Contract has not been reconciled yet. Pending directive(s): $pending. The control plane must reconcile intent before dispatch."
    }
    $receipt = & $script:SCBaseNewCompilation $Task
    if($null-eq$receipt-or$null-eq$receipt.ir-or$null-eq$receipt.ir.task){return $receipt}
    $sizeValue='small';if($Task.PSObject.Properties['size']-and$Task.size){$sizeValue=[string]$Task.size}
    $sources=@(Get-SCCurrentTaskSourceRefs $Task);$intentRefs=@();if($Task.PSObject.Properties['intentRefs']){$intentRefs=@($Task.intentRefs)};$directives=Get-SCCurrentDirectiveSnapshot
    Set-SCProperty $receipt.ir.task 'size' $sizeValue;Set-SCProperty $receipt.ir.task 'sources' $sources;Set-SCProperty $receipt.ir.task 'intentRefs' $intentRefs
    Set-SCProperty $receipt.ir.task 'capabilityProfile' $(if($Task.PSObject.Properties['capabilityProfile']){$Task.capabilityProfile}else{$null})
    Set-SCProperty $receipt.ir.task 'toolPolicy' $(if($Task.PSObject.Properties['toolPolicy']){$Task.toolPolicy}else{$null})
    Set-SCProperty $receipt.ir.project 'stateRoot' (Get-SCStateRoot)
    Set-SCProperty $receipt.ir.project 'humanDirectives' ([ordered]@{authority='current latest direct human word by directive scope; superseded history excluded';revision=[int]$directives.revision;hash=[string]$directives.hash;items=@($directives.items);sourceAccess='Current directive sourceRef human:<id> maps to <stateRoot>\.statefulclanker\input\<id>.txt. Inspect that verbatim source when wording needs verification; do not treat directives/history as current authority.'})
    Set-SCProperty $receipt.readSet 'directiveRevision' ([int]$directives.revision);Set-SCProperty $receipt.readSet 'directiveHash' ([string]$directives.hash)
    $receipt.inputFingerprint=Get-SCHashString (ConvertTo-SCJson $receipt.readSet 22);$receipt.contextFingerprint=Get-SCHashString (ConvertTo-SCJson $receipt.ir 24)
    Write-SCJson (Get-SCPath ("compilations/{0}.json"-f$receipt.id)) $receipt;return $receipt
}

function Get-SCProposalCandidateSnapshot($Proposal) {
    if($null-eq$Proposal-or$null-eq$Proposal.evidence){return $null}
    $ev=$Proposal.evidence
    if(-not($ev.PSObject.Properties['workerSessionId'] -and $ev.workerSessionId -and $ev.PSObject.Properties['candidateCheckpointId'] -and $ev.candidateCheckpointId)){return $null}
    if(-not(Get-Command Get-SCWorkerSession -ErrorAction SilentlyContinue)){return $null}
    $s=Get-SCWorkerSession ([string]$ev.workerSessionId);if($null-eq$s){return $null}
    $cp=@($s.checkpoints|Where-Object{[string]$_.id-eq[string]$ev.candidateCheckpointId}|Select-Object -First 1)
    if($cp.Count-eq0-or-not$cp[0].tree){return $null}
    $root=if($s.PSObject.Properties['workRoot'] -and $s.workRoot){[string]$s.workRoot}else{Get-SCRoot}
    return [pscustomobject]@{tree=[string]$cp[0].tree;root=$root}
}
function Test-SCFileMatchesCandidate($Snapshot,[string]$Relative,[string]$FullPath) {
    # The worker's own edit is not staleness: the file must still hold exactly what the candidate snapshot recorded.
    $gitPath=$Relative -replace '\\','/'
    $expected="$(& git -C $Snapshot.root rev-parse --verify --quiet ("{0}:{1}"-f$Snapshot.tree,$gitPath) 2>$null|Select-Object -First 1)".Trim()
    $exists=Test-Path -LiteralPath $FullPath -PathType Leaf
    if(-not$expected){return (-not$exists)}
    if(-not$exists){return $false}
    $actual="$(& git -C $Snapshot.root hash-object --path $gitPath -- $FullPath 2>$null|Select-Object -First 1)".Trim()
    return ($actual-eq$expected)
}
function Test-SCCompilationFreshness($Compilation,[string]$Mode='commit',$Proposal=$null) {
    $base = & $script:SCBaseCompilationFreshness $Compilation 'commit';$reasons=@($base.reasons)
    if($Compilation.readSet.PSObject.Properties['directiveRevision']) {$directives=Get-SCCurrentDirectiveSnapshot;if([int]$directives.revision-ne[int]$Compilation.readSet.directiveRevision-or[string]$directives.hash-ne[string]$Compilation.readSet.directiveHash){$reasons+='current human directives changed'}}
    if(-not(Test-SCDirectivesReconciled)){$reasons+='current human directives are awaiting intent reconciliation'}
    if($Mode-eq'dispatch') {
        foreach($fileRead in @($Compilation.readSet.files)) {$relative=[string]$fileRead.path;$full=if($relative -match '^[.]statefulclanker[\\/]'){Join-Path (Get-SCStateRoot) $relative}else{Join-Path (Get-SCRoot) $relative};$current=Get-SCFileHashValue $full;if([string]$current-ne[string]$fileRead.sha256){$reasons+="context file changed before dispatch: $relative"}}
    }elseif($Mode-eq'commit') {
        # Without a candidate snapshot the worker's own edits are indistinguishable from outside ones, so only direct sessions are checked.
        $snapshot=Get-SCProposalCandidateSnapshot $Proposal
        if($snapshot){
            foreach($fileRead in @($Compilation.readSet.files)) {
                $relative=[string]$fileRead.path;if($relative -match '^[.]statefulclanker[\\/]'){continue}
                $full=Join-Path (Get-SCRoot) $relative;$current=Get-SCFileHashValue $full
                if([string]$current-eq[string]$fileRead.sha256){continue}
                if(-not(Test-SCFileMatchesCandidate $snapshot $relative $full)){$reasons+="context file changed underneath worker before commit: $relative"}
            }
        }
    }
    return [ordered]@{fresh=($reasons.Count-eq0);mode=$Mode;checkedAt=(Get-Date).ToUniversalTime().ToString('o');reasons=@($reasons)}
}

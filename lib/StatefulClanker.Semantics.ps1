# Preserve planner semantics in the actual compiled IR seen by workers/reviewers,
# include the current reconciled human-directive snapshot, and make canonical-state
# source artifacts participate correctly in freshness even when WorkRoot is a git
# worktree and StateRoot remains the canonical project state.

$script:SCBaseNewCompilation = (Get-Item Function:\New-SCCompilation).ScriptBlock
$script:SCBaseCompilationFreshness = (Get-Item Function:\Test-SCCompilationFreshness).ScriptBlock

# Plan.ps1 defines the source-reference grammar. Human sources live under the
# canonical StateRoot, not WorkRoot, so override resolution after Plan.ps1 loads.
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
    $sources=@(Get-SCCurrentTaskSourceRefs $Task)
    $intentRefs=@();if($Task.PSObject.Properties['intentRefs']){$intentRefs=@($Task.intentRefs)}
    $directives=Get-SCCurrentDirectiveSnapshot

    Set-SCProperty $receipt.ir.task 'size' $sizeValue
    Set-SCProperty $receipt.ir.task 'sources' $sources
    Set-SCProperty $receipt.ir.task 'intentRefs' $intentRefs
    Set-SCProperty $receipt.ir.project 'stateRoot' (Get-SCStateRoot)
    Set-SCProperty $receipt.ir.project 'humanDirectives' ([ordered]@{
        authority='current latest direct human word by directive scope; superseded history excluded'
        revision=[int]$directives.revision
        hash=[string]$directives.hash
        items=@($directives.items)
        sourceAccess='Current directive sourceRef human:<id> maps to <stateRoot>\.statefulclanker\input\<id>.txt. Inspect that verbatim source when wording needs verification; do not treat directives/history as current authority.'
    })
    Set-SCProperty $receipt.readSet 'directiveRevision' ([int]$directives.revision)
    Set-SCProperty $receipt.readSet 'directiveHash' ([string]$directives.hash)
    $receipt.inputFingerprint=Get-SCHashString (ConvertTo-SCJson $receipt.readSet 22)
    $receipt.contextFingerprint=Get-SCHashString (ConvertTo-SCJson $receipt.ir 24)
    Write-SCJson (Get-SCPath ("compilations/{0}.json"-f$receipt.id)) $receipt
    return $receipt
}

function Test-SCCompilationFreshness($Compilation,[string]$Mode='commit') {
    $base = & $script:SCBaseCompilationFreshness $Compilation 'commit';$reasons=@($base.reasons)
    if($Compilation.readSet.PSObject.Properties['directiveRevision']) {$directives=Get-SCCurrentDirectiveSnapshot;if([int]$directives.revision-ne[int]$Compilation.readSet.directiveRevision-or[string]$directives.hash-ne[string]$Compilation.readSet.directiveHash){$reasons+='current human directives changed'}}
    if(-not(Test-SCDirectivesReconciled)){$reasons+='current human directives are awaiting intent reconciliation'}
    if($Mode-eq'dispatch') {
        foreach($fileRead in @($Compilation.readSet.files)) {
            $relative=[string]$fileRead.path;$full=if($relative -match '^[.]statefulclanker[\\/]'){Join-Path (Get-SCStateRoot) $relative}else{Join-Path (Get-SCRoot) $relative}
            $current=Get-SCFileHashValue $full;if([string]$current-ne[string]$fileRead.sha256){$reasons+="context file changed before dispatch: $relative"}
        }
    }
    return [ordered]@{fresh=($reasons.Count-eq0);mode=$Mode;checkedAt=(Get-Date).ToUniversalTime().ToString('o');reasons=@($reasons)}
}

# Preserve planner semantics in the actual compiled IR seen by workers/reviewers,
# and make canonical-state source artifacts participate correctly in freshness even
# when the worker's WorkRoot is a separate git worktree.

$script:SCBaseNewCompilation = (Get-Item Function:\New-SCCompilation).ScriptBlock
$script:SCBaseCompilationFreshness = (Get-Item Function:\Test-SCCompilationFreshness).ScriptBlock

# Plan.ps1 defines the source-reference grammar. Human sources live under the
# canonical StateRoot, not WorkRoot, so override resolution after Plan.ps1 loads.
function Resolve-SCSourceReference([string]$SourceRef) {
    if([string]::IsNullOrWhiteSpace($SourceRef)){return $null}
    $base=$SourceRef;$start=$null;$end=$null
    if($SourceRef -match '^(.*)#L(\d+)(?:-L?(\d+))?$') {
        $base=$Matches[1];$start=[int]$Matches[2];$end=if($Matches[3]){[int]$Matches[3]}else{$start}
    }

    $full=$null;$authority='source';$relative=$null
    if($base -match '^human:(.+)$') {
        $id=$Matches[1]
        $relative=(".statefulclanker/input/{0}.txt"-f$id)
        $full=Get-SCPath ("input/{0}.txt"-f$id)
        $authority='human-source'
    } elseif($base -match '^(?:file|docs):(.+)$') {
        $relative=$Matches[1]
        $full=Join-Path (Get-SCRoot) $relative
    } else { return $null }
    if(-not(Test-Path -LiteralPath $full -PathType Leaf)){return $null}

    if($null-ne$start) {
        $all=@(Get-Content -LiteralPath $full)
        $lo=[Math]::Max(1,$start);$hi=[Math]::Min($all.Count,$end)
        $text=if($lo-gt$hi){''}else{$all[($lo-1)..($hi-1)] -join "`r`n"}
    } else {
        $text=Get-Content -Raw -LiteralPath $full;if($null-eq$text){$text=''}
    }
    return [ordered]@{ref=$SourceRef;baseRef=$base;path=$relative;fullPath=$full;authority=$authority;lineStart=$start;lineEnd=$end;content=[string]$text;sha256=Get-SCFileHashValue $full}
}

function New-SCCompilation($Task) {
    $receipt = & $script:SCBaseNewCompilation $Task
    if($null-eq$receipt-or$null-eq$receipt.ir-or$null-eq$receipt.ir.task){return $receipt}
    $sizeValue='small';if($Task.PSObject.Properties['size']-and$Task.size){$sizeValue=[string]$Task.size}
    $sources=@();if($Task.PSObject.Properties['sources']){$sources=@($Task.sources)}
    $intentRefs=@();if($Task.PSObject.Properties['intentRefs']){$intentRefs=@($Task.intentRefs)}
    Set-SCProperty $receipt.ir.task 'size' $sizeValue
    Set-SCProperty $receipt.ir.task 'sources' $sources
    Set-SCProperty $receipt.ir.task 'intentRefs' $intentRefs
    $receipt.contextFingerprint=Get-SCHashString (ConvertTo-SCJson $receipt.ir 24)
    Write-SCJson (Get-SCPath ("compilations/{0}.json"-f$receipt.id)) $receipt
    return $receipt
}

function Test-SCCompilationFreshness($Compilation,[string]$Mode='commit') {
    # Run the original non-filesystem authority checks using commit mode. Dispatch
    # file freshness is repeated below with the correct root per source class.
    $base = & $script:SCBaseCompilationFreshness $Compilation 'commit'
    $reasons=@($base.reasons)
    if($Mode-eq'dispatch') {
        foreach($fileRead in @($Compilation.readSet.files)) {
            $relative=[string]$fileRead.path
            $full=if($relative -match '^[.]statefulclanker[\\/]') {
                Join-Path (Get-SCStateRoot) $relative
            } else {
                Join-Path (Get-SCRoot) $relative
            }
            $current=Get-SCFileHashValue $full
            if([string]$current-ne[string]$fileRead.sha256){$reasons+="context file changed before dispatch: $relative"}
        }
    }
    return [ordered]@{fresh=($reasons.Count-eq0);mode=$Mode;checkedAt=(Get-Date).ToUniversalTime().ToString('o');reasons=@($reasons)}
}

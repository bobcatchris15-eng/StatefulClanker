# Preserve planner semantics in the actual compiled IR seen by workers/reviewers.
# Context.ps1 deliberately stays generic; this wrapper enriches the durable receipt
# after its read-set/retrieval work and recomputes the exact context fingerprint.

$script:SCBaseNewCompilation = (Get-Item Function:\New-SCCompilation).ScriptBlock

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

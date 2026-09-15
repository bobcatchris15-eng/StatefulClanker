<# Cross-process durable-state lock diagnostic build. #>
$script:SCLockDepth = 0
$script:SCLockOwnerThreadId = $null
$script:SCLockHandle = $null

function Invoke-SCLocked([scriptblock]$Body, [int]$TimeoutSeconds = 3) {
    $threadId=[System.Threading.Thread]::CurrentThread.ManagedThreadId
    if($script:SCLockDepth -gt 0 -and $script:SCLockOwnerThreadId -eq $threadId){
        $script:SCLockDepth++
        $nestedResult=$null
        try{$nestedResult=@(& $Body)}finally{$script:SCLockDepth--}
        if($nestedResult.Count-eq 0){return};if($nestedResult.Count-eq 1){return $nestedResult[0]};return $nestedResult
    }
    $lockPath=Get-SCPath 'state.lock';$parent=Split-Path -Parent $lockPath
    if($parent-and-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
    $caller='unknown';try{$stack=@(Get-PSCallStack);if($stack.Count-gt 1){$caller=[string]$stack[1].FunctionName}}catch{}
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds);$stream=$null
    while($null-eq$stream){
        try{$stream=[System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)}
        catch [System.IO.IOException]{if([DateTime]::UtcNow-ge$deadline){throw "Timed out after ${TimeoutSeconds}s waiting for StatefulClanker state lock in $caller (thread $threadId, depth $($script:SCLockDepth))."};Start-Sleep -Milliseconds 25}
        catch [System.UnauthorizedAccessException]{if([DateTime]::UtcNow-ge$deadline){throw "Timed out after ${TimeoutSeconds}s waiting for StatefulClanker state lock in ${caller}: $($_.Exception.Message)"};Start-Sleep -Milliseconds 25}
    }
    $script:SCLockHandle=$stream;$script:SCLockOwnerThreadId=$threadId;$script:SCLockDepth=1;$result=$null
    try{$result=@(& $Body)}finally{$script:SCLockDepth=0;$script:SCLockOwnerThreadId=$null;$script:SCLockHandle=$null;$stream.Dispose()}
    if($result.Count-eq 0){return};if($result.Count-eq 1){return $result[0]};return $result
}

function Write-SCJson([string]$TargetPath,$Value) {
    Write-Host "TRACE Write-SCJson enter $TargetPath"
    $parent=Split-Path -Parent $TargetPath;if($parent-and-not(Test-Path $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
    $tmp="$TargetPath.tmp"
    Write-Host "TRACE Write-SCJson serialize-begin $TargetPath"
    $json=ConvertTo-SCJson $Value 30
    Write-Host "TRACE Write-SCJson serialize-end $TargetPath chars=$($json.Length)"
    $json|Set-Content -LiteralPath $tmp -Encoding UTF8
    Write-Host "TRACE Write-SCJson temp-written $TargetPath"
    Move-Item -Force -LiteralPath $tmp -Destination $TargetPath
    Write-Host "TRACE Write-SCJson exit $TargetPath"
}
function Get-SCTask([string]$Id) {
    Write-Host "TRACE Get-SCTask enter $Id"
    $task=Invoke-SCLocked { Read-SCJson (Get-SCPath ("tasks/{0}.json"-f$Id)) }
    Write-Host "TRACE Get-SCTask exit $Id"
    if($null-eq$task){throw "Unknown task: $Id"};return $task
}
function Save-SCTask($Task) {
    Write-Host "TRACE Save-SCTask enter $($Task.id)"
    Invoke-SCLocked {$revision=0;if($Task.PSObject.Properties['stateRevision']){$revision=[int]$Task.stateRevision};Set-SCProperty $Task 'stateRevision' ($revision+1);Set-SCProperty $Task 'updatedAt' ((Get-Date).ToUniversalTime().ToString('o'));Write-SCJson (Get-SCPath ("tasks/{0}.json"-f$Task.id)) $Task}
    Write-Host "TRACE Save-SCTask exit $($Task.id)"
}

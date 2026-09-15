<# Cross-process durable-state lock.

   Diagnostic build: fail quickly with the calling function when a durable-state
   lock cannot be acquired. This makes CI identify the exact contending state
   operation instead of leaving a background job parked for the full smoke timeout.
#>
$script:SCLockDepth = 0
$script:SCLockOwnerThreadId = $null
$script:SCLockHandle = $null

function Invoke-SCLocked([scriptblock]$Body, [int]$TimeoutSeconds = 3) {
    $threadId=[System.Threading.Thread]::CurrentThread.ManagedThreadId

    if($script:SCLockDepth -gt 0 -and $script:SCLockOwnerThreadId -eq $threadId){
        $script:SCLockDepth++
        $nestedResult=$null
        try{$nestedResult=@(& $Body)}finally{$script:SCLockDepth--}
        if($nestedResult.Count-eq 0){return}
        if($nestedResult.Count-eq 1){return $nestedResult[0]}
        return $nestedResult
    }

    $lockPath=Get-SCPath 'state.lock'
    $parent=Split-Path -Parent $lockPath
    if($parent-and-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}

    $caller='unknown'
    try{$stack=@(Get-PSCallStack);if($stack.Count-gt 1){$caller=[string]$stack[1].FunctionName}}catch{}
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $stream=$null
    while($null-eq$stream){
        try{
            $stream=[System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        }catch [System.IO.IOException]{
            if([DateTime]::UtcNow-ge$deadline){throw "Timed out after ${TimeoutSeconds}s waiting for StatefulClanker state lock in $caller (thread $threadId, depth $($script:SCLockDepth))."}
            Start-Sleep -Milliseconds 25
        }catch [System.UnauthorizedAccessException]{
            if([DateTime]::UtcNow-ge$deadline){throw "Timed out after ${TimeoutSeconds}s waiting for StatefulClanker state lock in $caller: $($_.Exception.Message)"}
            Start-Sleep -Milliseconds 25
        }
    }

    $script:SCLockHandle=$stream;$script:SCLockOwnerThreadId=$threadId;$script:SCLockDepth=1
    $result=$null
    try{$result=@(& $Body)}finally{$script:SCLockDepth=0;$script:SCLockOwnerThreadId=$null;$script:SCLockHandle=$null;$stream.Dispose()}
    if($result.Count-eq 0){return}
    if($result.Count-eq 1){return $result[0]}
    return $result
}

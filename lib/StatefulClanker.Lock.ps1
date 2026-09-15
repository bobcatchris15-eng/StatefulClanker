<# Cross-process durable-state lock.

   The original implementation used a named System.Threading.Mutex. A smoke run
   exposed a nasty boundary: after a native provider returned successfully, the
   next state read could wait forever on the mutex even though no other worker was
   active. Mutex ownership is thread-affine; that is a poor fit for a PowerShell
   harness that crosses runspaces, jobs and native-process boundaries.

   This implementation uses an exclusively opened lock file instead. File handles
   are process-crash-safe (the OS closes them when the process dies), work across
   the independent PowerShell processes used by parallel execution, and are not
   thread-owned kernel mutexes. Same-thread nesting is handled explicitly because
   Core intentionally nests locked helpers (Update-SCReadiness -> Get/Save task).
#>
$script:SCLockDepth = 0
$script:SCLockOwnerThreadId = $null
$script:SCLockHandle = $null

function Invoke-SCLocked([scriptblock]$Body, [int]$TimeoutSeconds = 120) {
    $threadId=[System.Threading.Thread]::CurrentThread.ManagedThreadId

    # Reentrant call on the same PowerShell execution thread. The outer call owns
    # the actual file handle; nested helpers only advance/decrement depth.
    if($script:SCLockDepth -gt 0 -and $script:SCLockOwnerThreadId -eq $threadId){
        $script:SCLockDepth++
        try{return (& $Body)}finally{$script:SCLockDepth--}
    }

    $lockPath=Get-SCPath 'state.lock'
    $parent=Split-Path -Parent $lockPath
    if($parent-and-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}

    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $stream=$null
    while($null-eq$stream){
        try{
            $stream=[System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        }catch [System.IO.IOException]{
            if([DateTime]::UtcNow-ge$deadline){throw "Timed out after ${TimeoutSeconds}s waiting for the StatefulClanker state lock."}
            Start-Sleep -Milliseconds 25
        }catch [System.UnauthorizedAccessException]{
            if([DateTime]::UtcNow-ge$deadline){throw "Timed out after ${TimeoutSeconds}s waiting for the StatefulClanker state lock: $($_.Exception.Message)"}
            Start-Sleep -Milliseconds 25
        }
    }

    $script:SCLockHandle=$stream
    $script:SCLockOwnerThreadId=$threadId
    $script:SCLockDepth=1
    try{
        return (& $Body)
    }finally{
        $script:SCLockDepth=0
        $script:SCLockOwnerThreadId=$null
        $script:SCLockHandle=$null
        $stream.Dispose()
    }
}

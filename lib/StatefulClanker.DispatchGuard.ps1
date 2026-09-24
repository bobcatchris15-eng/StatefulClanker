# Final dispatch authority gate. Loaded after Execution + Concurrency so the check
# happens before either path can mark tasks running, create worktrees, or launch a
# provider process.

$script:SCDispatchGuardTaskBase = (Get-Item Function:\Invoke-SCTask).ScriptBlock
$script:SCDispatchGuardParallelBase = (Get-Item Function:\Invoke-SCParallel).ScriptBlock

function Get-SCPlanningBarrier {
    $path=Get-SCPath 'planning/active.json'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    try {
        $raw=Get-Content -Raw -LiteralPath $path
        if([string]::IsNullOrWhiteSpace($raw)){throw 'empty planning barrier'}
        return ($raw|ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "Dispatch blocked: planning barrier exists but is unreadable. Fail closed until .statefulclanker/planning/active.json is repaired or deliberately cleared. $($_.Exception.Message)"
    }
}

function Assert-SCDispatchAuthority {
    Assert-SCInitialized
    $planning=Get-SCPlanningBarrier
    if($null-ne$planning){
        $phase=if($planning.PSObject.Properties['phase']){[string]$planning.phase}else{'unknown'}
        $session=if($planning.PSObject.Properties['sessionId']){[string]$planning.sessionId}else{'unknown'}
        throw "Dispatch blocked: project is owned by planning session $session (phase: $phase). Finish/cancel the planning handoff before implementation resumes."
    }
    if(Test-SCDirectivesReconciled){return}
    $state=Get-SCState
    $pending=if($state.PSObject.Properties['pendingDirectiveIds']){@($state.pendingDirectiveIds)-join', '}else{'unknown'}
    throw "Dispatch blocked: current human directives have not been reconciled into Intent. Pending directive(s): $pending. The conversational control plane must resolve ambiguity/contradictions and commit intent_apply before launching workers."
}

function Assert-SCNoAutofillConflict {
    $managed=Get-Variable -Name SCManagedChild -Scope Script -ErrorAction SilentlyContinue
    if($managed-and[bool]$managed.Value){return}
    if(-not(Get-Command Get-SCAutofillStatus -ErrorAction SilentlyContinue)){return}
    $autofill=Get-SCAutofillStatus
    if($autofill){
        if($autofill.PSObject.Properties['state'] -and $autofill.state -eq 'paused'){return}
        throw "Dispatch is owned by the resident autofill supervisor (PID $($autofill.pid)). Add/ready work normally and let autofill fill available slots, or request 'autofill stop' or 'autofill_control' (action: 'pause' or 'stop') before manual execution."
    }
}

function Invoke-SCTask([string]$RequestedTaskId,[string]$ProviderOverride) {
    Assert-SCDispatchAuthority
    Assert-SCNoAutofillConflict
    return (& $script:SCDispatchGuardTaskBase $RequestedTaskId $ProviderOverride)
}

function Invoke-SCParallel([int]$MaxConcurrent,[string]$ProviderOverride,[string]$HarnessPath,[switch]$NoMerge) {
    Assert-SCDispatchAuthority
    Assert-SCNoAutofillConflict
    return (& $script:SCDispatchGuardParallelBase $MaxConcurrent $ProviderOverride $HarnessPath -NoMerge:$NoMerge)
}

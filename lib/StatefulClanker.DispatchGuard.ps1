# Final dispatch authority gate. Loaded after Execution + Concurrency so the check
# happens before either path can mark tasks running, create worktrees, or launch a
# provider process.

$script:SCDispatchGuardTaskBase = (Get-Item Function:\Invoke-SCTask).ScriptBlock
$script:SCDispatchGuardParallelBase = (Get-Item Function:\Invoke-SCParallel).ScriptBlock

function Assert-SCDispatchAuthority {
    Assert-SCInitialized
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
    if($autofill){throw "Dispatch is owned by the resident autofill supervisor (PID $($autofill.pid)). Add/ready work normally and let autofill fill available slots, or request 'autofill stop' before manual execution."}
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

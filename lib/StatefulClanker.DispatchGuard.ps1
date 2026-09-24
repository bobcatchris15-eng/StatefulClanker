# Final dispatch authority gate. Loaded after Execution + Concurrency so the check
# happens before either path can mark tasks running, create worktrees, or launch a
# provider process.

$script:SCDispatchGuardTaskBase = (Get-Item Function:\Invoke-SCTask).ScriptBlock
$script:SCDispatchGuardParallelBase = (Get-Item Function:\Invoke-SCParallel).ScriptBlock

function Assert-SCDispatchAuthority {
    Assert-SCInitialized
    $state=Get-SCState
    $cfg=Get-SCConfig
    if($state.activePlanId -and [bool]$cfg.requireHumanApprovalForPlan -and -not[bool]$state.planApproved){throw "Dispatch blocked: active plan $($state.activePlanId) requires human approval."}
    if(Test-SCDirectivesReconciled){return}
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

function Invoke-SCTask([string]$RequestedTaskId,[string]$ProviderOverride,[string]$EndpointOverride=$null,[string]$ConnectionOverride=$null) {
    Assert-SCDispatchAuthority
    Assert-SCNoAutofillConflict
    return (& $script:SCDispatchGuardTaskBase $RequestedTaskId $ProviderOverride $EndpointOverride $ConnectionOverride)
}

function Invoke-SCParallel([int]$MaxConcurrent,[string]$ProviderOverride,[string]$HarnessPath,[switch]$NoMerge,[string]$Endpoint=$null,[string]$Connection=$null) {
    Assert-SCDispatchAuthority
    Assert-SCNoAutofillConflict
    return (& $script:SCDispatchGuardParallelBase $MaxConcurrent $ProviderOverride $HarnessPath -NoMerge:$NoMerge -Endpoint:$Endpoint -Connection:$Connection)
}

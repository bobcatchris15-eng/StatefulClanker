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

function Invoke-SCTask([string]$RequestedTaskId,[string]$ProviderOverride) {
    Assert-SCDispatchAuthority
    return (& $script:SCDispatchGuardTaskBase $RequestedTaskId $ProviderOverride)
}

function Invoke-SCParallel([int]$MaxConcurrent,[string]$ProviderOverride,[string]$HarnessPath,[switch]$NoMerge) {
    Assert-SCDispatchAuthority
    return (& $script:SCDispatchGuardParallelBase $MaxConcurrent $ProviderOverride $HarnessPath -NoMerge:$NoMerge)
}

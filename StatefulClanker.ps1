<# StatefulClanker: durable-state orchestration for cold-start CLI workers. #>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Position=0)][string]$Command='status',
    [Parameter(Position=1)][string]$Subcommand,
    [string]$Title,[string]$Instruction,[string[]]$Accept,[string[]]$DependsOn,
    [string[]]$Retrieval,[string[]]$Evidence,[string[]]$Relation,[string]$Provider,[string]$Role='worker',
    [string]$Size='small',[string[]]$Source,[string[]]$IntentRef,[string]$SourceRef,
    [string]$DirectiveId,[string]$Scope,[long]$Since=0,[int]$Limit=100,[string]$MinimumLevel,
    [switch]$HumanGate,[string]$TaskId,[string]$Path,[string]$Reason,[string]$Message,[string]$RunId,[string]$CompilationId,
    [int]$Parallel,[string]$StateRoot,[switch]$NoMerge
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$script:StatefulClankerHome=$PSScriptRoot
$runtimeRef='5368d094cad76aaac6e39cf237d876e12c7eb84f'
$runtimeNames=@('StatefulClanker.Core.ps1','StatefulClanker.Eventing.ps1','StatefulClanker.Context.ps1','StatefulClanker.Plan.ps1','StatefulClanker.Directives.ps1','StatefulClanker.Semantics.ps1','StatefulClanker.Execution.ps1','StatefulClanker.Routing.ps1','StatefulClanker.Intent.ps1','StatefulClanker.Concurrency.ps1','StatefulClanker.ProjectReview.ps1')
$checkedOutLib=Join-Path $PSScriptRoot 'lib'
$useCheckedOut=$true
foreach($name in $runtimeNames){if(-not(Test-Path -LiteralPath (Join-Path $checkedOutLib $name) -PathType Leaf)){$useCheckedOut=$false;break}}
if($useCheckedOut){
    $runtimeLib=$checkedOutLib
}else{
    $runtimeLib=Join-Path (Join-Path (Join-Path (Get-Location).Path '.statefulclanker') 'runtime') $runtimeRef
    if(-not(Test-Path -LiteralPath $runtimeLib)){New-Item -ItemType Directory -Force -Path $runtimeLib|Out-Null}
    foreach($name in $runtimeNames){
        $target=Join-Path $runtimeLib $name
        if(-not(Test-Path -LiteralPath $target -PathType Leaf)){
            $uri="https://raw.githubusercontent.com/bobcatchris15-eng/StatefulClanker/$runtimeRef/lib/$name"
            try{Invoke-WebRequest -Uri $uri -UseBasicParsing -OutFile $target}catch{throw "StatefulClanker runtime module '$name' is missing and could not be fetched from pinned ref $runtimeRef. Use a full repository checkout or restore network access. $($_.Exception.Message)"}
        }
    }
}
. (Join-Path $runtimeLib 'StatefulClanker.Core.ps1')
. (Join-Path $runtimeLib 'StatefulClanker.Eventing.ps1')
. (Join-Path $runtimeLib 'StatefulClanker.Context.ps1')
. (Join-Path $runtimeLib 'StatefulClanker.Plan.ps1')
. (Join-Path $runtimeLib 'StatefulClanker.Directives.ps1')
. (Join-Path $runtimeLib 'StatefulClanker.Semantics.ps1')
. (Join-Path $runtimeLib 'StatefulClanker.Execution.ps1')
. (Join-Path $runtimeLib 'StatefulClanker.Routing.ps1')
. (Join-Path $runtimeLib 'StatefulClanker.Intent.ps1')
. (Join-Path $runtimeLib 'StatefulClanker.Concurrency.ps1')
. (Join-Path $runtimeLib 'StatefulClanker.ProjectReview.ps1')

# -StateRoot lets a cycle run inside a git worktree while reading and writing the
# one canonical .statefulclanker in the main tree. Without it the cycle would look
# for durable state inside the worktree, where it does not exist.
# A -StateRoot cycle is a worktree child managed by the parallel scheduler. It must
# not run its own project review: the scheduler runs one for the whole batch.
$script:SCManagedChild=$false
if($StateRoot){Set-SCRoots (Get-Location).Path $StateRoot;$script:SCManagedChild=$true}

if($Command.ToLowerInvariant()-ne'init'-and(Test-Path (Get-SCPath 'state.json'))){Upgrade-SCStateLayout;Ensure-SCInputLayout;Ensure-SCDirectiveLayout;Ensure-SCControlEventLayout}

switch($Command.ToLowerInvariant()){
'init'{Initialize-SC;Ensure-SCInputLayout;Ensure-SCDirectiveLayout;Ensure-SCControlEventLayout;break}
'goal'{$text=if($Message){$Message}elseif($Subcommand){$Subcommand}else{$Title};Set-SCGoal $text;break}
'status'{Show-SCStatus;break}
'task'{if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='list'};switch($Subcommand.ToLowerInvariant()){'add'{Add-SCTask;break};'list'{Update-SCReadiness;Get-SCTasks|Sort-Object createdAt|Select-Object id,status,size,attemptCount,role,humanGate,title|Format-Table -AutoSize;break};'show'{if(-not$TaskId){throw '-TaskId required.'};Get-SCTask $TaskId|ConvertTo-SCJson -Depth 16|Write-Host;break};'retry'{Retry-SCTask $TaskId;break};default{throw "Unknown task subcommand: $Subcommand"}};break}
'plan'{if($null-eq$Subcommand){$Subcommand=''};switch($Subcommand.ToLowerInvariant()){'import'{if(-not$Path){throw '-Path required.'};Import-SCPlan $Path;break};'approve'{Approve-SCPlan;break};default{throw "Unknown plan subcommand: $Subcommand"}};break}
'source'{Show-SCSources $Subcommand $SourceRef $Message;break}
'directive'{Show-SCDirectives $Subcommand $DirectiveId $Message $Scope $IntentRef $SourceRef $Reason;break}
'events'{Get-SCControlEventsSince $Since $Limit $MinimumLevel|ConvertTo-SCJson -Depth 16|Write-Host;break}
'intent'{if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='show'};switch($Subcommand.ToLowerInvariant()){'show'{Show-SCIntent 'show';break};'history'{Show-SCIntent 'history';break};'escalations'{Show-SCIntent 'escalations';break};'replace'{Replace-SCIntentContract $Path $Reason;break};default{throw "Unknown intent subcommand: $Subcommand"}};break}
'run'{if($Parallel -gt 0 -or $Subcommand -eq 'parallel'){Invoke-SCParallel $Parallel $Provider $PSCommandPath -NoMerge:$NoMerge}else{Invoke-SCTask $TaskId $Provider};break}
'complete'{Complete-SCTask $TaskId;break}
'block'{Block-SCTask $TaskId $Reason;break}
'event'{Add-SCDirection $Message;break}
'provider'{if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='list'};if($Subcommand.ToLowerInvariant()-eq'list'){Show-SCProviders}else{throw "Unknown provider subcommand: $Subcommand"};break}
'telemetry'{Show-SCTelemetry $Subcommand $RunId;break}
'context'{Show-SCContext $Subcommand $CompilationId;break}
'progress'{Show-SCProgress $Subcommand;break}
'review'{if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='history'};if($Subcommand.ToLowerInvariant()-eq'run'){Invoke-SCProjectReview 'manual' -Force|Out-Null}else{Show-SCProjectReviews $Subcommand $RunId};break}
'hold'{if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='status'};switch($Subcommand.ToLowerInvariant()){'clear'{Clear-SCProjectHold;break};'status'{$h=Get-SCProjectHold;if($h){Write-Host "HELD since $($h.since): $($h.reason) (review $($h.reviewId))"}else{Write-Host 'Not held.'};break};default{throw "Unknown hold subcommand: $Subcommand"}};break}
default{throw "Unknown command: $Command"}
}

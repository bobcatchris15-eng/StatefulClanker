<# StatefulClanker: durable-state orchestration for cold-start CLI workers. #>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Position=0)][string]$Command='status',
    [Parameter(Position=1)][string]$Subcommand,
    [string]$Title,[string]$Instruction,[string[]]$Accept,[string[]]$DependsOn,
    [string[]]$Retrieval,[string[]]$Evidence,[string[]]$Relation,[string]$Provider,[string]$Role='worker',
    [switch]$HumanGate,[string]$TaskId,[string]$Path,[string]$Reason,[string]$Message,[string]$RunId,[string]$CompilationId
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$script:StatefulClankerHome=$PSScriptRoot
. (Join-Path $PSScriptRoot "lib\StatefulClanker.Core.ps1")
. (Join-Path $PSScriptRoot "lib\StatefulClanker.Context.ps1")
. (Join-Path $PSScriptRoot "lib\StatefulClanker.Execution.ps1")

if($Command.ToLowerInvariant()-ne'init'-and(Test-Path (Get-SCPath 'state.json'))){Upgrade-SCStateLayout}

switch($Command.ToLowerInvariant()){
'init'{Initialize-SC;break}
'goal'{$text=if($Message){$Message}elseif($Subcommand){$Subcommand}else{$Title};Set-SCGoal $text;break}
'status'{Show-SCStatus;break}
'task'{if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='list'};switch($Subcommand.ToLowerInvariant()){'add'{Add-SCTask;break};'list'{Update-SCReadiness;Get-SCTasks|Sort-Object createdAt|Select-Object id,status,attemptCount,role,humanGate,title|Format-Table -AutoSize;break};'show'{if(-not$TaskId){throw '-TaskId required.'};Get-SCTask $TaskId|ConvertTo-SCJson -Depth 16|Write-Host;break};'retry'{Retry-SCTask $TaskId;break};default{throw "Unknown task subcommand: $Subcommand"}};break}
'plan'{if($null-eq$Subcommand){$Subcommand=''};switch($Subcommand.ToLowerInvariant()){'import'{if(-not$Path){throw '-Path required.'};Import-SCPlan $Path;break};'approve'{Approve-SCPlan;break};default{throw "Unknown plan subcommand: $Subcommand"}};break}
'run'{Invoke-SCTask $TaskId $Provider;break}
'complete'{Complete-SCTask $TaskId;break}
'block'{Block-SCTask $TaskId $Reason;break}
'event'{if(-not$Message){throw '-Message required.'};Add-SCEvent 'user.note' $Message;Write-Host 'Event recorded.';break}
'provider'{if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='list'};if($Subcommand.ToLowerInvariant()-eq'list'){Show-SCProviders}else{throw "Unknown provider subcommand: $Subcommand"};break}
'telemetry'{Show-SCTelemetry $Subcommand $RunId;break}
'context'{Show-SCContext $Subcommand $CompilationId;break}
'progress'{Show-SCProgress $Subcommand;break}
default{throw "Unknown command: $Command"}
}

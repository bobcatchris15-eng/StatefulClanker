# Current human directives: the latest direct human word for each named decision.
#
# Current directives are worker-facing authority evidence. Superseded revisions are
# kept only under directives/history for audit/debugging and are never compiled into
# ordinary worker context. A directive change requires the orchestrator to reconcile
# the normalized Intent Contract before new work may be compiled.

$script:SCBaseDirectiveRetrieval = (Get-Item Function:\Get-SCRetrievalPacket).ScriptBlock

function Ensure-SCDirectiveLayout {
    Assert-SCInitialized
    foreach($child in @('directives','directives/current','directives/history')) {
        $path=Get-SCPath $child
        if(-not(Test-Path -LiteralPath $path)){New-Item -ItemType Directory -Force -Path $path|Out-Null}
    }
}
function Assert-SCDirectiveId([string]$Id) {
    if([string]::IsNullOrWhiteSpace($Id)){throw 'Directive id required.'}
    if($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'){throw "Directive id '$Id' must use letters, numbers, dot, underscore, or hyphen."}
}
function Get-SCDirectivePath([string]$Id) { Assert-SCDirectiveId $Id;return Get-SCPath ("directives/current/{0}.json"-f$Id) }
function Get-SCCurrentDirective([string]$Id) { Ensure-SCDirectiveLayout;return Read-SCJson (Get-SCDirectivePath $Id) }
function Get-SCCurrentDirectives {
    Ensure-SCDirectiveLayout
    return @(Get-ChildItem -LiteralPath (Get-SCPath 'directives/current') -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { try{Read-SCJson $_.FullName}catch{} } | Where-Object{$null-ne$_})
}
function Get-SCDirectiveHash($Directives=$null) {
    if($null-eq$Directives){$Directives=Get-SCCurrentDirectives}
    $projection=@($Directives|Sort-Object id|ForEach-Object{[ordered]@{id=$_.id;scope=$_.scope;revision=$_.revision;text=$_.text;sourceRef=$_.sourceRef;intentRefs=@($_.intentRefs)}})
    return Get-SCHashString (ConvertTo-SCJson $projection 16)
}
function Get-SCDirectiveRevision { $state=Get-SCState;if($state.PSObject.Properties['directiveRevision']){return [int]$state.directiveRevision};return 0 }
function Get-SCCurrentDirectiveSnapshot { $items=@(Get-SCCurrentDirectives);return [ordered]@{revision=(Get-SCDirectiveRevision);hash=(Get-SCDirectiveHash $items);items=$items} }

function Set-SCDirectiveReconciliationPending([string]$DirectiveId) {
    $state=Get-SCState;$current=if($state.PSObject.Properties['directiveRevision']){[int]$state.directiveRevision}else{0}
    Set-SCProperty $state 'directiveRevision' ($current+1);Set-SCProperty $state 'directiveReconciliationRequired' $true
    $pending=@();if($state.PSObject.Properties['pendingDirectiveIds']){$pending=@($state.pendingDirectiveIds)};if($pending -notcontains $DirectiveId){$pending+=,$DirectiveId};Set-SCProperty $state 'pendingDirectiveIds' @($pending);Save-SCState $state
    return [int]$state.directiveRevision
}
function Test-SCDirectivesReconciled {
    $state=Get-SCState;if($state.PSObject.Properties['directiveReconciliationRequired']-and[bool]$state.directiveReconciliationRequired){return $false}
    $current=Get-SCDirectiveRevision;$reconciled=if($state.PSObject.Properties['directiveReconciledRevision']){[int]$state.directiveReconciledRevision}else{0};return ($reconciled-ge$current)
}

# A task created under an older directive may still contain the old human:<id> ref.
# Detect directive-origin source artifacts and omit them once their directive has
# been replaced/retired. Generic source artifacts are unaffected.
function Test-SCSupersededDirectiveSource([string]$SourceRef) {
    if([string]::IsNullOrWhiteSpace($SourceRef)-or$SourceRef -notmatch '^human:([^#]+)'){return $false}
    $id=$Matches[1];$meta=Read-SCJson (Get-SCPath ("input/{0}.meta.json"-f$id));if($null-eq$meta){return $false}
    if([string]$meta.kind-ne'directive'-or[string]::IsNullOrWhiteSpace([string]$meta.origin)){return $false}
    $current=Get-SCCurrentDirective ([string]$meta.origin);if($null-eq$current){return $true}
    $base=([string]$SourceRef -split '#',2)[0];$currentBase=([string]$current.sourceRef -split '#',2)[0]
    return ($base-ne$currentBase)
}
function Get-SCCurrentTaskSourceRefs($Task) {
    $out=@();if($null-eq$Task-or-not$Task.PSObject.Properties['sources']){return @()}
    foreach($src in @($Task.sources)){if(-not(Test-SCSupersededDirectiveSource ([string]$src))){$out+=,[string]$src}}
    return @($out)
}
function Get-SCRetrievalPacket($Task) {
    $copy=(ConvertTo-SCJson $Task 24)|ConvertFrom-Json
    Set-SCProperty $copy 'sources' @(Get-SCCurrentTaskSourceRefs $Task)
    return (& $script:SCBaseDirectiveRetrieval $copy)
}

function Invalidate-SCTasksForIntentRefs([string[]]$IntentRefs,[string]$DirectiveId,[string]$Why) {
    $refs=@($IntentRefs|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}|ForEach-Object{[string]$_});if($refs.Count-eq0){return @()}
    $changed=@()
    foreach($task in @(Get-SCTasks)) {
        $taskRefs=if($task.PSObject.Properties['intentRefs']){@($task.intentRefs|ForEach-Object{[string]$_})}else{@()};$hit=$false
        foreach($ref in $refs){if($taskRefs -contains $ref){$hit=$true;break}};if(-not$hit){continue}
        if([string]$task.status-eq'running') {Add-SCEvent 'task.intent_changed_inflight' "Directive '$DirectiveId' changed while $($task.id) was running; its compilation will fail freshness before commit." @{taskId=$task.id;directiveId=$DirectiveId;intentRefs=$refs};continue}
        $was=[string]$task.status;$task.status='stale';$task.blockReason="Human directive '$DirectiveId' changed: $Why";Save-SCTask $task
        Add-SCEvent 'task.invalidated' "Invalidated $($task.id) because human directive '$DirectiveId' changed." @{taskId=$task.id;directiveId=$DirectiveId;intentRefs=$refs;previousStatus=$was;reason=$Why};$changed+=,[string]$task.id
    }
    return @($changed)
}

function Set-SCHumanDirective([string]$Id,[string]$Text,[string]$Scope=$null,[string]$SourceRef=$null,[string[]]$IntentRefs=@(),[string]$Reason=$null) {
    Assert-SCInitialized;Ensure-SCDirectiveLayout;Assert-SCDirectiveId $Id;if([string]::IsNullOrWhiteSpace($Text)){throw 'Directive text required.'}
    if([string]::IsNullOrWhiteSpace($SourceRef)) {$source=New-SCHumanSource $Text 'directive' $Id;$SourceRef=[string]$source.ref}
    else {$resolved=Resolve-SCSourceReference $SourceRef;if($null-eq$resolved){throw "Directive source not found: $SourceRef"}}

    $path=Get-SCDirectivePath $Id;$previous=Read-SCJson $path;$next=1
    if($previous) {$next=[int]$previous.revision+1;$historyDir=Get-SCPath ("directives/history/{0}"-f$Id);if(-not(Test-Path -LiteralPath $historyDir)){New-Item -ItemType Directory -Force -Path $historyDir|Out-Null};Write-SCJson (Join-Path $historyDir ("revision-{0:d4}.json"-f[int]$previous.revision)) $previous}
    $record=[ordered]@{schemaVersion=1;id=$Id;scope=if($Scope){$Scope}else{$Id};revision=$next;text=$Text;sourceRef=$SourceRef;intentRefs=@($IntentRefs|Where-Object{$_}|ForEach-Object{[string]$_});updatedAt=(Get-Date).ToUniversalTime().ToString('o');reason=$Reason;authority='latest direct human word for this directive scope'}
    Write-SCJson $path $record;$globalRevision=Set-SCDirectiveReconciliationPending $Id
    $why=if($Reason){$Reason}else{'latest direct human wording changed'};$invalidated=@(Invalidate-SCTasksForIntentRefs $record.intentRefs $Id $why)
    Add-SCEvent 'directive.revised' "Human directive '$Id' revised to $next." @{directiveId=$Id;directiveRevision=$next;globalDirectiveRevision=$globalRevision;scope=$record.scope;sourceRef=$SourceRef;intentRefs=@($record.intentRefs);invalidatedTasks=$invalidated;reason=$Reason}
    Add-SCEvent 'directive.reconciliation_required' "Intent must be reconciled after human directive '$Id' changed." @{directiveId=$Id;globalDirectiveRevision=$globalRevision;sourceRef=$SourceRef;invalidatedTasks=$invalidated}
    return $record
}

function Retire-SCHumanDirective([string]$Id,[string]$Reason=$null) {
    Assert-SCInitialized;Ensure-SCDirectiveLayout;Assert-SCDirectiveId $Id;$path=Get-SCDirectivePath $Id;$previous=Read-SCJson $path;if($null-eq$previous){throw "Unknown current directive: $Id"}
    $historyDir=Get-SCPath ("directives/history/{0}"-f$Id);if(-not(Test-Path -LiteralPath $historyDir)){New-Item -ItemType Directory -Force -Path $historyDir|Out-Null};Set-SCProperty $previous 'retiredAt' ((Get-Date).ToUniversalTime().ToString('o'));Set-SCProperty $previous 'retireReason' $Reason;Write-SCJson (Join-Path $historyDir ("revision-{0:d4}-retired.json"-f[int]$previous.revision)) $previous;Remove-Item -LiteralPath $path -Force
    $globalRevision=Set-SCDirectiveReconciliationPending $Id;$why=if($Reason){$Reason}else{'human removed this directive'};$invalidated=@(Invalidate-SCTasksForIntentRefs @($previous.intentRefs) $Id $why)
    Add-SCEvent 'directive.retired' "Human directive '$Id' retired." @{directiveId=$Id;globalDirectiveRevision=$globalRevision;intentRefs=@($previous.intentRefs);invalidatedTasks=$invalidated;reason=$Reason}
    Add-SCEvent 'directive.reconciliation_required' "Intent must be reconciled after human directive '$Id' was retired." @{directiveId=$Id;globalDirectiveRevision=$globalRevision;invalidatedTasks=$invalidated}
    return $previous
}
function Get-SCDirectiveHistory([string]$Id) {Ensure-SCDirectiveLayout;Assert-SCDirectiveId $Id;$dir=Get-SCPath ("directives/history/{0}"-f$Id);if(-not(Test-Path -LiteralPath $dir)){return @()};return @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File|Sort-Object Name|ForEach-Object{Read-SCJson $_.FullName})}
function Show-SCDirectives([string]$Subcommand,[string]$Id=$null,[string]$Text=$null,[string]$Scope=$null,[string[]]$IntentRefs=@(),[string]$SourceRef=$null,[string]$Reason=$null) {
    if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='list'}
    switch($Subcommand.ToLowerInvariant()) {
        'list' { Get-SCCurrentDirectives|Select-Object id,scope,revision,updatedAt,sourceRef,@{n='text';e={$_.text}}|Format-Table -Wrap -AutoSize;break }
        'show' { if(-not$Id){throw '-DirectiveId required.'};$d=Get-SCCurrentDirective $Id;if($null-eq$d){throw "Unknown current directive: $Id"};$d|ConvertTo-SCJson -Depth 16|Write-Host;break }
        'history' { if(-not$Id){throw '-DirectiveId required.'};Get-SCDirectiveHistory $Id|ConvertTo-SCJson -Depth 16|Write-Host;break }
        'set' { $d=Set-SCHumanDirective $Id $Text $Scope $SourceRef $IntentRefs $Reason;$d|ConvertTo-SCJson -Depth 16|Write-Host;break }
        'retire' { $d=Retire-SCHumanDirective $Id $Reason;$d|ConvertTo-SCJson -Depth 16|Write-Host;break }
        default { throw "Unknown directive subcommand: $Subcommand" }
    }
}

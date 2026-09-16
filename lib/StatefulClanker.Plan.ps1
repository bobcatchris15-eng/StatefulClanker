# StatefulClanker compact plan + durable source support.
# Loaded after Core/Context so these definitions intentionally extend/override a
# few generic runtime helpers without forcing a state-schema flag day.

function Ensure-SCInputLayout {
    foreach($child in @('input','plans')) {
        $target=Get-SCPath $child
        if(-not(Test-Path -LiteralPath $target)){New-Item -ItemType Directory -Force -Path $target|Out-Null}
    }
}

function New-SCHumanSource([string]$Text,[string]$Kind='chat',[string]$Origin=$null) {
    Assert-SCInitialized
    if([string]::IsNullOrWhiteSpace($Text)){throw 'Source text required.'}
    Ensure-SCInputLayout
    $id=New-SCId 'h'
    $txtPath=Get-SCPath ("input/{0}.txt"-f$id)
    $metaPath=Get-SCPath ("input/{0}.meta.json"-f$id)
    # Preserve the user's wording verbatim. Set-Content adds only the terminating
    # newline; metadata is kept separately so it cannot contaminate quoted source.
    [IO.File]::WriteAllText($txtPath,$Text,(New-Object Text.UTF8Encoding($false)))
    $lines=if($Text.Length-eq 0){0}else{(@($Text -split "`r?`n")).Count}
    $ref="human:$id"
    Write-SCJson $metaPath ([ordered]@{schemaVersion=1;id=$id;ref=$ref;kind=$Kind;origin=$Origin;createdAt=(Get-Date).ToUniversalTime().ToString('o');lineCount=$lines;sha256=Get-SCFileHashValue $txtPath})
    Add-SCEvent 'source.captured' "Captured $ref" @{sourceRef=$ref;kind=$Kind;origin=$Origin;lineCount=$lines}
    return [ordered]@{id=$id;ref=$ref;path=$txtPath;metaPath=$metaPath;lineCount=$lines}
}

function Get-SCSourceRecords {
    Ensure-SCInputLayout
    return @(Get-ChildItem -LiteralPath (Get-SCPath 'input') -Filter '*.meta.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc |
        ForEach-Object { try { Read-SCJson $_.FullName } catch { } } |
        Where-Object { $null-ne$_ })
}

function Get-SCSourceByRef([string]$SourceRef) {
    if([string]::IsNullOrWhiteSpace($SourceRef)){return $null}
    if($SourceRef -notmatch '^human:([^#]+)'){return $null}
    $id=$Matches[1]
    $meta=Get-SCPath ("input/{0}.meta.json"-f$id)
    if(-not(Test-Path -LiteralPath $meta)){return $null}
    return Read-SCJson $meta
}

function Resolve-SCSourceReference([string]$SourceRef) {
    if([string]::IsNullOrWhiteSpace($SourceRef)){return $null}
    $base=$SourceRef;$start=$null;$end=$null
    if($SourceRef -match '^(.*)#L(\d+)(?:-L?(\d+))?$') {
        $base=$Matches[1];$start=[int]$Matches[2];$end=if($Matches[3]){[int]$Matches[3]}else{$start}
    }

    $full=$null;$authority='source';$display=$base
    if($base -match '^human:(.+)$') {
        $id=$Matches[1];$full=Get-SCPath ("input/{0}.txt"-f$id);$authority='human-source';$display="@human/$id"
    } elseif($base -match '^(?:file|docs):(.+)$') {
        $rel=$Matches[1];$full=Join-Path (Get-SCRoot) $rel;$authority='source';$display=$rel
    } else { return $null }
    if(-not(Test-Path -LiteralPath $full -PathType Leaf)){return $null}

    $all=@(Get-Content -LiteralPath $full)
    if($null-ne$start) {
        $lo=[Math]::Max(1,$start);$hi=[Math]::Min($all.Count,$end)
        if($lo-gt$hi){$text=''}else{$text=($all[($lo-1)..($hi-1)] -join "`r`n")}
    } else {
        $text=Get-Content -Raw -LiteralPath $full
        if($null-eq$text){$text=''}
    }
    return [ordered]@{ref=$SourceRef;baseRef=$base;path=$display;fullPath=$full;authority=$authority;lineStart=$start;lineEnd=$end;content=[string]$text;sha256=Get-SCFileHashValue $full}
}

function Add-SCDirection([string]$Text) {
    Assert-SCInitialized
    if([string]::IsNullOrWhiteSpace($Text)){throw '-Message required.'}
    $source=New-SCHumanSource $Text 'direction' 'conversation'
    $state=Get-SCState;$current=if($state.PSObject.Properties['directionRevision']){[int]$state.directionRevision}else{0}
    Set-SCProperty $state 'directionRevision' ($current+1);Save-SCState $state
    Add-SCEvent 'user.note' $Text @{directionRevision=$state.directionRevision;sourceRef=$source.ref}
    Write-Host "Direction recorded: $($source.ref)"
}

function Read-SCCompactPlan([string]$Path) {
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Plan not found: $Path"}
    $lines=@(Get-Content -LiteralPath $Path)
    $first=$null
    foreach($raw in $lines){$trim=$raw.Trim();if($trim -and -not$trim.StartsWith('#')){$first=$trim;break}}
    if($first-ne'SCPLAN 1'){throw 'Compact plan must begin with SCPLAN 1.'}

    $plan=[ordered]@{name='Compact plan';summary='';sources=@();intent=@();tasks=@();warnings=@()}
    $task=$null;$ids=@{}
    foreach($raw in $lines) {
        $line=$raw.Trim()
        if(-not$line -or $line.StartsWith('#') -or $line-eq'SCPLAN 1'){continue}
        $parts=$line -split '\s+',2;$key=$parts[0].ToLowerInvariant();$value=if($parts.Count-gt 1){$parts[1].Trim()}else{''}
        if($key-eq'task') {
            if($null-ne$task){throw "Nested task before 'end': $value"}
            if([string]::IsNullOrWhiteSpace($value)){throw 'task requires an id.'}
            if($ids.ContainsKey($value)){throw "Duplicate task id: $value"};$ids[$value]=$true
            $task=[ordered]@{id=$value;title='';instruction='';size='small';sources=@();intentRefs=@();acceptance=@();dependsOn=@();relations=@();retrieval=@();evidence=@();provider=$null;role='worker';humanGate=$false;unknown=@()}
            continue
        }
        if($key-eq'end') {
            if($null-eq$task){throw "Unexpected end outside a task."}
            if([string]::IsNullOrWhiteSpace($task.title)){throw "Task $($task.id) is missing title."}
            if([string]::IsNullOrWhiteSpace($task.instruction)){throw "Task $($task.id) is missing instruction."}
            $plan.tasks+=,[pscustomobject]$task;$task=$null;continue
        }

        if($null-eq$task) {
            switch($key) {
                'title' {$task.title=$value}
                'instruction' {$task.instruction=$value}
                'size' {if(@('tiny','small','medium','large') -notcontains $value.ToLowerInvariant()){throw "Task $($task.id) has invalid size '$value'."};$task.size=$value.ToLowerInvariant()}
                'source' {$task.sources+=,$value}
                'intent' {$task.intentRefs+=,$value}
                'accept' {$task.acceptance+=,$value}
                'depends' {$task.dependsOn+=,$value}
                'relation' { $rp=$value -split '\s+',2;if($rp.Count-lt 2){throw "Task $($task.id) relation requires type and target."};$task.relations+=,[pscustomobject]@{type=$rp[0];target=$rp[1]} }
                'retrieve' {$task.retrieval+=,$value}
                'evidence' {$task.evidence+=,$value}
                'provider' {$task.provider=$value}
                'role' {$task.role=$value}
                'human-gate' {if($value -notmatch '^(?i:true|false)$'){throw "Task $($task.id) human-gate must be true or false."};$task.humanGate=[bool]::Parse($value)}
                default {$task.unknown+=,$line;$plan.warnings+=,"Task $($task.id): unknown field '$key' ignored."}
            }
        } else {
            switch($key) {
                'plan' {$plan.name=$value}
                'summary' {$plan.summary=$value}
                'source' {$plan.sources+=,$value}
                'intent' {$plan.intent+=,$value}
                default {$plan.warnings+=,"Plan: unknown field '$key' ignored."}
            }
        }
    }
    if($null-ne$task){throw "Task $($task.id) is missing terminating 'end'."}
    if($plan.tasks.Count-eq 0){throw 'Plan contains no tasks.'}
    return [pscustomobject]$plan
}

function Get-SCPlanInput([string]$PlanPath) {
    $resolved=(Resolve-Path -LiteralPath $PlanPath).Path
    if([IO.Path]::GetExtension($resolved).Equals('.scplan',[StringComparison]::OrdinalIgnoreCase)) {
        return [ordered]@{resolved=$resolved;format='scplan';plan=Read-SCCompactPlan $resolved}
    }
    return [ordered]@{resolved=$resolved;format='json';plan=Read-SCJson $resolved}
}

function Import-SCPlan([string]$PlanPath) {
    Assert-SCInitialized
    if(-not(Test-Path -LiteralPath $PlanPath)){throw "Plan not found: $PlanPath"}
    Ensure-SCInputLayout
    $input=Get-SCPlanInput $PlanPath;$plan=$input.plan
    if($null-eq$plan-or$null-eq$plan.tasks){throw 'Plan must contain tasks.'}
    $planId=New-SCId 'plan';$name=if($plan.PSObject.Properties['name']){[string]$plan.name}else{'Imported plan'};$summary=if($plan.PSObject.Properties['summary']){[string]$plan.summary}else{''}
    $planRecord=[ordered]@{schemaVersion=3;id=$planId;name=$name;summary=$summary;format=$input.format;source=$input.resolved;sourceRefs=if($plan.PSObject.Properties['sources']){@($plan.sources)}else{@()};intentRefs=if($plan.PSObject.Properties['intent']){@($plan.intent)}else{@()};importedAt=(Get-Date).ToUniversalTime().ToString('o');tasks=@($plan.tasks)}
    Write-SCJson (Get-SCPath ("plans/{0}.json"-f$planId)) $planRecord
    if($input.format-eq'scplan'){Copy-Item -LiteralPath $input.resolved -Destination (Get-SCPath ("plans/{0}.scplan"-f$planId)) -Force}

    foreach($item in @($plan.tasks)) {
        $id=if($item.PSObject.Properties['id']-and$item.id){[string]$item.id}else{New-SCId 'task'}
        if(Test-Path (Get-SCPath ("tasks/{0}.json"-f$id))){throw "Plan task id already exists: $id"}
        $itemAcceptance=if($item.PSObject.Properties['acceptance']){@($item.acceptance)}else{@()};$itemDepends=if($item.PSObject.Properties['dependsOn']){@($item.dependsOn)}else{@()};$itemRelations=if($item.PSObject.Properties['relations']){@($item.relations)}else{@()};$itemRetrieval=if($item.PSObject.Properties['retrieval']){@($item.retrieval)}else{@()};$itemEvidence=if($item.PSObject.Properties['evidence']){@($item.evidence)}else{@()}
        $itemProvider=if($item.PSObject.Properties['provider']-and$item.provider){[string]$item.provider}else{$null};$itemRole=if($item.PSObject.Properties['role']-and$item.role){[string]$item.role}else{'worker'};$itemHumanGate=if($item.PSObject.Properties['humanGate']){[bool]$item.humanGate}else{$false}
        $task=New-SCTaskObject $id ([string]$item.title) ([string]$item.instruction) $itemAcceptance $itemDepends $itemRelations $itemRetrieval $itemEvidence $itemProvider $itemRole $itemHumanGate
        Set-SCProperty $task 'size' (if($item.PSObject.Properties['size']-and$item.size){[string]$item.size}else{'small'})
        Set-SCProperty $task 'sources' (if($item.PSObject.Properties['sources']){@($item.sources)}else{@()})
        Set-SCProperty $task 'intentRefs' (if($item.PSObject.Properties['intentRefs']){@($item.intentRefs)}else{@()})
        Save-SCTask $task
    }
    $state=Get-SCState;$state.activePlanId=$planId;$cfg=Get-SCConfig;$state.planApproved=-not[bool]$cfg.requireHumanApprovalForPlan;Save-SCState $state;Update-SCReadiness
    Add-SCEvent 'plan.imported' "Imported $planId" @{taskCount=@($plan.tasks).Count;format=$input.format;sourceRefs=$planRecord.sourceRefs;intentRefs=$planRecord.intentRefs}
    foreach($warning in @(if($plan.PSObject.Properties['warnings']){$plan.warnings}else{@()})){Write-Warning $warning}
    Write-Host "Imported $planId ($($input.format), $(@($plan.tasks).Count) tasks)"
}

function Get-SCTaskDefinitionHash($Task) {
    $definition=[ordered]@{title=$Task.title;instruction=$Task.instruction;size=if($Task.PSObject.Properties['size']){$Task.size}else{'small'};sources=if($Task.PSObject.Properties['sources']){@($Task.sources)}else{@()};intentRefs=if($Task.PSObject.Properties['intentRefs']){@($Task.intentRefs)}else{@()};acceptance=@($Task.acceptance);dependsOn=@($Task.dependsOn);relations=if($Task.PSObject.Properties['relations']){@($Task.relations)}else{@()};retrieval=@($Task.retrieval);evidence=@($Task.evidence);provider=$Task.provider;role=$Task.role;humanGate=[bool]$Task.humanGate}
    return Get-SCHashString (ConvertTo-SCJson $definition 16)
}

function Add-SCTask {
    if([string]::IsNullOrWhiteSpace($Title)){throw '-Title is required.'};if([string]::IsNullOrWhiteSpace($Instruction)){throw '-Instruction is required.'}
    $id=if($TaskId){$TaskId}else{New-SCId 'task'};if(@(Get-SCTasks|Where-Object{$_.id-eq$id}).Count-gt 0){throw "Task exists: $id"}
    $task=New-SCTaskObject $id $Title $Instruction @($Accept) @($DependsOn) @($Relation) @($Retrieval) @($Evidence) $Provider $Role ([bool]$HumanGate)
    $sizeValue=if($Size){$Size.ToLowerInvariant()}else{'small'};if(@('tiny','small','medium','large') -notcontains $sizeValue){throw "Invalid -Size '$Size'."}
    Set-SCProperty $task 'size' $sizeValue;Set-SCProperty $task 'sources' @($Source);Set-SCProperty $task 'intentRefs' @($IntentRef)
    Save-SCTask $task;Update-SCReadiness;Add-SCEvent 'task.created' $Title @{taskId=$id;size=$sizeValue;sources=@($Source);intentRefs=@($IntentRef);relations=@($task.relations)};Write-Host $id
}

function Get-SCRetrievalPacket($Task) {
    $cfg=Get-SCConfig;$budget=if($cfg.PSObject.Properties['workingSetBudgetChars']){[int]$cfg.workingSetBudgetChars}else{24000};$maxFile=if($cfg.PSObject.Properties['maxFileChars']){[int]$cfg.maxFileChars}else{8000};$remaining=$budget;$items=@();$seen=@{};$unmatched=@();$unmatchedSources=@();$selectors=@()

    foreach($src in @(if($Task.PSObject.Properties['sources']){$Task.sources}else{@()})) {
        if($remaining-le 0){break};$resolved=Resolve-SCSourceReference ([string]$src);if($null-eq$resolved){$unmatchedSources+=[string]$src;continue}
        $key="source:$($resolved.ref)";if($seen.ContainsKey($key)){continue};$seen[$key]=$true
        $text=[string]$resolved.content;$take=[Math]::Min([Math]::Min($text.Length,$maxFile),$remaining);$excerpt=if($take-gt 0){$text.Substring(0,$take)}else{''}
        $items+=[ordered]@{path=$resolved.path;selector=$resolved.ref;kind='source';authority=$resolved.authority;chars=$take;fullChars=$text.Length;truncated=($text.Length-gt$take);sha256=$resolved.sha256;content=$excerpt};$remaining-=$take
    }
    foreach($s in @($Task.evidence)){if(-not[string]::IsNullOrWhiteSpace([string]$s)){$selectors+=[ordered]@{selector=[string]$s;kind='evidence';authority='evidence'}}}
    foreach($s in @($Task.retrieval)){if(-not[string]::IsNullOrWhiteSpace([string]$s)){$selectors+=[ordered]@{selector=[string]$s;kind='retrieval';authority='context'}}}
    foreach($entry in $selectors) {
        if($remaining-le 0){break};$pattern=[string]$entry.selector;$matches=@(Resolve-SCSelector $pattern);if($matches.Count-eq 0){$unmatched+=$pattern;continue}
        foreach($match in $matches) {
            if($remaining-le 0){break};$full=$match.FullName;if($full.StartsWith((Get-SCDir),[StringComparison]::OrdinalIgnoreCase)){continue};if($seen.ContainsKey($full)){continue};$seen[$full]=$true
            try{$text=Get-Content -Raw -LiteralPath $full}catch{continue};if($null-eq$text){$text=''};$take=[Math]::Min([Math]::Min($text.Length,$maxFile),$remaining);$excerpt=if($take-gt 0){$text.Substring(0,$take)}else{''};$relative=($full.Substring((Get-SCRoot).Length)-replace'^[\\/]+','')
            $items+=[ordered]@{path=$relative;selector=$pattern;kind=$entry.kind;authority=$entry.authority;chars=$take;fullChars=$text.Length;truncated=($text.Length-gt$take);sha256=Get-SCFileHashValue $full;content=$excerpt};$remaining-=$take
        }
    }
    return [ordered]@{budgetChars=$budget;usedChars=($budget-$remaining);remainingChars=$remaining;budgetExhausted=($remaining-le 0);unmatchedSelectors=@($unmatched);unmatchedSourceRefs=@($unmatchedSources);items=@($items)}
}

function Show-SCSources([string]$Subcommand,[string]$Ref=$null,[string]$Text=$null) {
    if([string]::IsNullOrWhiteSpace($Subcommand)){$Subcommand='list'}
    switch($Subcommand.ToLowerInvariant()) {
        'list' { Get-SCSourceRecords | Select-Object ref,kind,createdAt,lineCount,origin | Format-Table -AutoSize;break }
        'show' { if(-not$Ref){throw '-SourceRef required.'};$resolved=Resolve-SCSourceReference $Ref;if($null-eq$resolved){throw "Source not found: $Ref"};Write-Host $resolved.content;break }
        'add' { $src=New-SCHumanSource $Text 'source' 'cli';Write-Host $src.ref;break }
        default { throw "Unknown source subcommand: $Subcommand" }
    }
}

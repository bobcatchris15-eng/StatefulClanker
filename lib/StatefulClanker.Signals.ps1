# Addressed signal envelope storage and validation.
$script:SCSignalDomains=@('execution','routing','project')
$script:SCSignalAuthorities=@('observed','corrective','advisory','authoritative')
$script:SCSignalPayloadMaxChars=16384

function Get-SCSignalDirectory([string]$Domain='execution') {
    if($script:SCSignalDomains-notcontains$Domain){throw "Invalid signal domain '$Domain'."}
    return Get-SCPath ("signals/{0}"-f$Domain)
}

function Assert-SCSignalToken([string]$Value,[string]$Name) {
    if([string]::IsNullOrWhiteSpace($Value)){throw "Signal $Name is required."}
    if($Value-notmatch'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'){throw "Signal $Name '$Value' contains unsupported characters."}
}

function ConvertTo-SCSignalMap($Value,[string]$Name,[bool]$AllowNull=$false) {
    if($null-eq$Value){if($AllowNull){return [ordered]@{}};throw "Signal $Name is required."}
    if($Value-is[System.Collections.IDictionary]){$out=[ordered]@{};foreach($key in $Value.Keys){$out[[string]$key]=$Value[$key]};return $out}
    $out=[ordered]@{}
    foreach($p in $Value.PSObject.Properties){if($p.MemberType-in@('Property','NoteProperty','AliasProperty','ScriptProperty')){$out[[string]$p.Name]=$p.Value}}
    if($out.Count-eq0-and-not$AllowNull){throw "Signal $Name must be an object."}
    return $out
}

function Test-SCSignalEnvelope($Signal,[switch]$ThrowOnError) {
    $errors=New-Object Collections.Generic.List[string]
    if($null-eq$Signal){$errors.Add('signal is null')}
    else{
        foreach($name in @('id','domain','kind','authority','scope')){
            try{Assert-SCSignalToken ([string]$Signal.$name) $name}catch{$errors.Add($_.Exception.Message)}
        }
        if([string]::IsNullOrWhiteSpace([string]$Signal.createdAt)){$errors.Add('createdAt is required')}
        if([int]$Signal.schemaVersion-ne1){$errors.Add('schemaVersion must be 1')}
        if($script:SCSignalDomains-notcontains[string]$Signal.domain){$errors.Add("unsupported domain '$($Signal.domain)'")}
        if($script:SCSignalAuthorities-notcontains[string]$Signal.authority){$errors.Add("unsupported authority '$($Signal.authority)'")}
        $created=[datetimeoffset]::MinValue
        if(-not[datetimeoffset]::TryParse([string]$Signal.createdAt,[ref]$created)){$errors.Add('createdAt is not a timestamp')}
        try{$source=ConvertTo-SCSignalMap $Signal.source 'source';Assert-SCSignalToken ([string]$source.component) 'source.component'}catch{$errors.Add($_.Exception.Message)}
        try{$subject=ConvertTo-SCSignalMap $Signal.subject 'subject';Assert-SCSignalToken ([string]$subject.type) 'subject.type';Assert-SCSignalToken ([string]$subject.id) 'subject.id'}catch{$errors.Add($_.Exception.Message)}
        $addresses=@($Signal.audience)
        if($addresses.Count-eq0){$errors.Add('audience must contain at least one address')}
        foreach($a in $addresses){
            try{$address=ConvertTo-SCSignalMap $a 'audience';Assert-SCSignalToken ([string]$address.type) 'audience.type';Assert-SCSignalToken ([string]$address.id) 'audience.id'}catch{$errors.Add($_.Exception.Message)}
        }
        try{$payload=(ConvertTo-SCJson $Signal.payload 20);if($payload.Length-gt$script:SCSignalPayloadMaxChars){$errors.Add('payload exceeds signal size limit')}}catch{$errors.Add('payload is not serializable')}
    }
    if($errors.Count-gt0-and$ThrowOnError){throw ("Invalid signal envelope: "+($errors-join'; '))}
    return [pscustomobject]@{valid=($errors.Count-eq0);errors=@($errors)}
}

function New-SCSignalEnvelope {
    param(
        [Parameter(Mandatory=$true)][string]$Domain,
        [Parameter(Mandatory=$true)][string]$Kind,
        [Parameter(Mandatory=$true)]$Source,
        [Parameter(Mandatory=$true)]$Subject,
        [Parameter(Mandatory=$true)]$Audience,
        [Parameter(Mandatory=$true)][string]$Authority,
        [Parameter(Mandatory=$true)][string]$Scope,
        $Freshness=$null,
        $Payload=$null,
        [string]$Id=$null
    )
    $signal=[pscustomobject][ordered]@{
        schemaVersion=1
        id=if($Id){$Id}else{New-SCId 'sig'}
        domain=$Domain
        kind=$Kind
        createdAt=[datetimeoffset]::UtcNow.ToString('o')
        source=ConvertTo-SCSignalMap $Source 'source'
        subject=ConvertTo-SCSignalMap $Subject 'subject'
        audience=@($Audience|ForEach-Object{ConvertTo-SCSignalMap $_ 'audience'})
        authority=$Authority
        scope=$Scope
        freshness=ConvertTo-SCSignalMap $Freshness 'freshness' $true
        payload=if($null-eq$Payload){[ordered]@{}}else{ConvertTo-SCSignalMap $Payload 'payload' $true}
    }
    Test-SCSignalEnvelope $signal -ThrowOnError|Out-Null
    return $signal
}

function Write-SCSignal($Signal) {
    Assert-SCInitialized
    Test-SCSignalEnvelope $Signal -ThrowOnError|Out-Null
    $when=[datetimeoffset]::Parse([string]$Signal.createdAt)
    $path=Join-Path (Get-SCSignalDirectory ([string]$Signal.domain)) ($when.UtcDateTime.ToString('yyyy-MM-dd')+'.jsonl')
    $line=(ConvertTo-SCJson $Signal 24)-replace'[\r\n]+',''
    Invoke-SCLocked { Add-SCTextLine $path $line }|Out-Null

    # Execution signals immediately refresh the deterministic per-task projection
    # when the reducer is available. This makes "append -> reduce -> persist"
    # the normal path rather than waiting for the next worker compilation.
    if([string]$Signal.domain-eq'execution' -and
       (Get-Command Get-SCExecutionProjection -ErrorAction SilentlyContinue) -and
       (Get-Command Write-SCExecutionProjection -ErrorAction SilentlyContinue)){
        $taskId=$null
        try{
            $subject=Get-SCSignalValue $Signal 'subject'
            if([string](Get-SCSignalValue $subject 'type')-eq'task'){
                $taskId=[string](Get-SCSignalValue $subject 'id')
                if(-not[string]::IsNullOrWhiteSpace($taskId)){
                    $task=Get-SCTask $taskId
                    Write-SCExecutionProjection (Get-SCExecutionProjection $task)|Out-Null
                }
            }
        }catch{
            try{Add-SCEvent 'projection.refresh_failed' $_.Exception.Message @{signalId=$Signal.id;taskId=if($taskId){$taskId}else{$null}}}catch{}
        }
    }
    return $Signal
}

function Read-SCSignals([string]$Domain='execution',[int]$Limit=200) {
    $dir=Get-SCSignalDirectory $Domain
    if(-not(Test-Path -LiteralPath $dir -PathType Container)){return @()}
    $out=New-Object Collections.Generic.List[object]
    foreach($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.jsonl' -File|Sort-Object Name -Descending)){
        $lines=@(Get-Content -LiteralPath $file.FullName|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
        for($i=$lines.Count-1;$i-ge0;$i--){
            try{$out.Add(($lines[$i]|ConvertFrom-Json))}catch{}
            if($Limit-gt0-and$out.Count-ge$Limit){return @($out|ForEach-Object{$_})}
        }
    }
    return @($out|ForEach-Object{$_})
}

function Get-SCSignalsForAudience {
    param([string]$AudienceType,[string]$AudienceId,[string]$Qualifier=$null,[string]$Domain='execution',[int]$Limit=200)
    $matches=@()
    foreach($signal in @(Read-SCSignals $Domain $Limit)){
        foreach($address in @($signal.audience)){
            if([string]$address.type-ne$AudienceType-or[string]$address.id-ne$AudienceId){continue}
            if($Qualifier-and[string]$address.qualifier-ne$Qualifier){continue}
            $matches+=$signal
            break
        }
    }
    return @($matches)
}

function Get-SCSignalValue($Object,[string]$Name) {
    if($null-eq$Object){return $null}
    if($Object-is[System.Collections.IDictionary]){
        if($Object.Contains($Name)){return $Object[$Name]}
        return $null
    }
    $property=$Object.PSObject.Properties[$Name]
    if($null-ne$property){return $property.Value}
    return $null
}

function Get-SCSignalEntries($Object) {
    if($null-eq$Object){return @()}
    if($Object-is[System.Collections.IDictionary]){
        return @($Object.Keys|ForEach-Object{[pscustomobject]@{Name=[string]$_;Value=$Object[$_]}})
    }
    return @($Object.PSObject.Properties|ForEach-Object{[pscustomobject]@{Name=[string]$_.Name;Value=$_.Value}})
}

function Test-SCSignalFreshness($Signal,$Task=$null) {
    $reasons=New-Object Collections.Generic.List[string]
    $freshness=Get-SCSignalValue $Signal 'freshness'
    if($null-eq$freshness){return [pscustomobject]@{fresh=$true;reasons=@()}}
    $expiresRaw=Get-SCSignalValue $freshness 'expiresAt'
    if($expiresRaw){
        $expires=[datetimeoffset]::MinValue
        if(-not[datetimeoffset]::TryParse([string]$expiresRaw,[ref]$expires)){$reasons.Add('invalid expiry')}
        elseif($expires-le[datetimeoffset]::UtcNow){$reasons.Add('expired')}
    }
    $definitionHash=Get-SCSignalValue $freshness 'taskDefinitionHash'
    if($definitionHash){
        if($null-eq$Task-and[string](Get-SCSignalValue $Signal.subject 'type')-eq'task'){try{$Task=Get-SCTask ([string](Get-SCSignalValue $Signal.subject 'id'))}catch{}}
        if($null-eq$Task){$reasons.Add('task unavailable for definition freshness')}
        elseif((Get-SCTaskDefinitionHash $Task)-ne[string]$definitionHash){$reasons.Add('task definition changed')}
    }
    $fileHashes=Get-SCSignalValue $freshness 'fileHashes'
    $controlRevision=Get-SCSignalValue $freshness 'taskControlRevision'
    if($null-ne$controlRevision-and$Task-and(Get-SCTaskControlRevision $Task)-ne[int]$controlRevision){$reasons.Add('task control revision changed')}
    $directionRevision=Get-SCSignalValue $freshness 'directionRevision'
    if($null-ne$directionRevision-and[int](Get-SCState).directionRevision-ne[int]$directionRevision){$reasons.Add('human direction changed')}
    if($fileHashes){
        foreach($entry in @(Get-SCSignalEntries $fileHashes)){
            $full=Join-Path (Get-SCRoot) ([string]$entry.Name)
            if((Get-SCFileHashValue $full)-ne[string]$entry.Value){$reasons.Add("file changed: $($entry.Name)")}
        }
    }
    return [pscustomobject]@{fresh=($reasons.Count-eq0);reasons=@($reasons)}
}

function Publish-SCExecutionSignal {
    param(
        [Parameter(Mandatory=$true)][string]$Kind,
        [Parameter(Mandatory=$true)]$Task,
        [Parameter(Mandatory=$true)][string]$Component,
        [Parameter(Mandatory=$true)][string]$Scope,
        [string]$Authority='observed',
        [string]$Qualifier=$null,
        $Payload=$null,
        $SourceExtra=$null,
        $Freshness=$null
    )
    try{
        $source=[ordered]@{component=$Component;taskId=[string]$Task.id}
        if($SourceExtra){foreach($p in (ConvertTo-SCSignalMap $SourceExtra 'sourceExtra' $true).GetEnumerator()){$source[$p.Key]=$p.Value}}
        $address=[ordered]@{type='task';id=[string]$Task.id}
        if($Qualifier){$address['qualifier']=$Qualifier}
        if($null-eq$Freshness){
            $Freshness=[ordered]@{taskDefinitionHash=Get-SCTaskDefinitionHash $Task}
            if($Authority-eq'corrective'-or$Kind-in@('validation_error','retrieval_anomaly')){
                $Freshness['taskControlRevision']=Get-SCTaskControlRevision $Task
                $Freshness['directionRevision']=[int](Get-SCState).directionRevision
            }
        }
        $signal=New-SCSignalEnvelope -Domain execution -Kind $Kind -Source $source -Subject @{type='task';id=[string]$Task.id} -Audience @($address) -Authority $Authority -Scope $Scope -Freshness $Freshness -Payload $Payload
        Write-SCSignal $signal|Out-Null
        return $signal
    }catch{
        try{Add-SCEvent 'signal.shadow_write_failed' $_.Exception.Message @{taskId=$Task.id;kind=$Kind;component=$Component}}catch{}
        return $null
    }
}


function Publish-SCValidationSignal($Task,$Receipt,$Compilation) {
    if($null-eq$Receipt){return $null}
    $stage=if($Receipt.PSObject.Properties['stage']){[string]$Receipt.stage}else{'validator'}
    $verdict=if($Receipt.PSObject.Properties['verdict']){[string]$Receipt.verdict}else{'ERROR'}
    if($stage-eq'critic'){
        $kind='critic_advisory';$authority='advisory';$qualifier=$null
    }elseif($verdict-eq'PASS'){
        $kind='validation_passed';$authority='observed';$qualifier=$null
    }elseif($verdict-eq'FAIL'){
        $kind='validator_rejection';$authority='corrective';$qualifier='next_attempt'
    }else{
        $kind='validation_error';$authority='observed';$qualifier=$null
    }
    $summary=if($Receipt.PSObject.Properties['stdout']){[string]$Receipt.stdout}else{''}
    if($summary.Length-gt800){$summary=$summary.Substring(0,800)}
    $validationKind=if($Receipt.PSObject.Properties['validationKind']){[string]$Receipt.validationKind}else{$null}
    return Publish-SCExecutionSignal -Kind $kind -Task $Task -Component $stage -Scope task -Authority $authority -Qualifier $qualifier -SourceExtra @{validationId=[string]$Receipt.id;compilationId=if($Compilation){[string]$Compilation.id}else{$null}} -Payload @{verdict=$verdict;validationKind=$validationKind;summary=$summary;evidenceRefs=@("validation:$($Receipt.id)")}
}

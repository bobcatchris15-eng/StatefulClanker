# Durable, sequenced control-plane event stream.
#
# events.jsonl remains the complete low-level project log. control/events.jsonl is
# the human-facing/control-plane inbox: ordered, cursor-addressable, classified by
# whether a conversational orchestrator merely needs to know, should pay attention,
# or must return to the human before affected work can safely continue.

$script:SCBaseAddEvent = (Get-Item Function:\Add-SCEvent).ScriptBlock

function Ensure-SCControlEventLayout {
    Assert-SCInitialized
    $dir=Get-SCPath 'control'
    if(-not(Test-Path -LiteralPath $dir)){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    $events=Get-SCPath 'control/events.jsonl'
    if(-not(Test-Path -LiteralPath $events)){''|Set-Content -LiteralPath $events -Encoding UTF8}
    $statePath=Get-SCPath 'control/state.json'
    if(-not(Test-Path -LiteralPath $statePath)){Write-SCJson $statePath ([ordered]@{schemaVersion=1;lastSequence=0;updatedAt=(Get-Date).ToUniversalTime().ToString('o')})}
}

function Get-SCControlEventLevel([string]$Type,$Data=$null) {
    if([string]::IsNullOrWhiteSpace($Type)){return 'fyi'}
    if($Type -match '^(intent\.escalated|directive\.reconciliation_required|project\.hold\.set|human\.required)'){return 'human_required'}
    if($Data) {
        $verdict=$null;$passed=$null
        if($Data-is[System.Collections.IDictionary]) {if($Data.Contains('verdict')){$verdict=[string]$Data['verdict']};if($Data.Contains('passed')){$passed=$Data['passed']}}
        else {if($Data.PSObject.Properties['verdict']){$verdict=[string]$Data.verdict};if($Data.PSObject.Properties['passed']){$passed=$Data.passed}}
        if($verdict-eq'FAIL'){return 'attention'}
        if($null-ne$passed-and-not[bool]$passed){return 'attention'}
    }
    if($Type -match '(failed|failure|blocked|invalidated|stale|conflict|fault|hold|retry|rejected|warning)'){return 'attention'}
    if($Type -match '^(intent\.revised|directive\.(revised|retired)|plan\.imported|task\.(completed|complete)|state\.committed|project\.review)'){return 'attention'}
    return 'fyi'
}

function Publish-SCControlEvent([string]$Type,[string]$Text,$Data=$null,[string]$Level=$null) {
    Ensure-SCControlEventLayout
    if([string]::IsNullOrWhiteSpace($Level)){$Level=Get-SCControlEventLevel $Type $Data}
    if(@('fyi','attention','human_required') -notcontains $Level){throw "Invalid control event level '$Level'."}
    $record=Invoke-SCLocked {
        $statePath=Get-SCPath 'control/state.json';$controlState=Read-SCJson $statePath;$last=0
        if($controlState-and$controlState.PSObject.Properties['lastSequence']){$last=[long]$controlState.lastSequence}
        $sequence=$last+1;$evt=[ordered]@{schemaVersion=1;sequence=$sequence;id=New-SCId 'control';ts=(Get-Date).ToUniversalTime().ToString('o');level=$Level;type=$Type;message=$Text;data=$Data}
        ((ConvertTo-SCJson $evt 14)-replace"`r?`n",'')|Add-Content -LiteralPath (Get-SCPath 'control/events.jsonl') -Encoding UTF8
        Write-SCJson $statePath ([ordered]@{schemaVersion=1;lastSequence=$sequence;updatedAt=$evt.ts})
        return [pscustomobject]$evt
    }
    return $record
}

function Add-SCEvent([string]$Type,[string]$Text,$Data=$null) {
    & $script:SCBaseAddEvent $Type $Text $Data
    [void](Publish-SCControlEvent $Type $Text $Data)
}

function Get-SCControlCursor {
    Ensure-SCControlEventLayout;$state=Read-SCJson (Get-SCPath 'control/state.json')
    if($null-eq$state-or-not$state.PSObject.Properties['lastSequence']){return 0};return [long]$state.lastSequence
}

function Get-SCControlEventsSince([long]$Since=0,[int]$Limit=100,[string]$MinimumLevel=$null) {
    Ensure-SCControlEventLayout;$limitValue=[Math]::Min(1000,[Math]::Max(1,$Limit));$rank=@{fyi=0;attention=1;human_required=2};$minRank=0
    if($MinimumLevel){if(-not$rank.ContainsKey($MinimumLevel)){throw "Invalid minimum level '$MinimumLevel'."};$minRank=[int]$rank[$MinimumLevel]}
    $out=@()
    foreach($line in @(Get-Content -LiteralPath (Get-SCPath 'control/events.jsonl')|Where-Object{$_})) {
        try{$evt=$line|ConvertFrom-Json}catch{continue};if([long]$evt.sequence-le$Since){continue}
        $level=if($evt.PSObject.Properties['level']){[string]$evt.level}else{'fyi'};$eventRank=if($rank.ContainsKey($level)){[int]$rank[$level]}else{0};if($eventRank-lt$minRank){continue}
        $out+=,$evt;if($out.Count-ge$limitValue){break}
    }
    return @($out)
}

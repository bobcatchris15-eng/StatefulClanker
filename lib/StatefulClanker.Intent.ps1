function Ensure-SCIntentLayout {
    Assert-SCInitialized
    $dir=Get-SCPath 'intent'
    $history=Get-SCPath 'intent/history'
    if(-not(Test-Path -LiteralPath $dir)){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    if(-not(Test-Path -LiteralPath $history)){New-Item -ItemType Directory -Force -Path $history|Out-Null}
}
function New-SCIntentContract {
    $state=Get-SCState
    return [ordered]@{
        schemaVersion=1
        revision=0
        updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        objective=[string]$state.goal
        requirements=@()
        constraints=@()
        invariants=@()
        nonGoals=@()
        decisions=@()
        preferences=@()
        openQuestions=@()
        successDefinition=''
        authority=[ordered]@{owner='orchestrator';workers='read-only'}
    }
}
function Get-SCIntentContract {
    Ensure-SCIntentLayout
    $path=Get-SCPath 'intent/contract.json'
    $contract=Read-SCJson $path
    if($null-eq$contract){
        $contract=New-SCIntentContract
        Write-SCJson $path $contract
        Write-SCJson (Get-SCPath 'intent/history/revision-0000.json') $contract
        Add-SCEvent 'intent.initialized' 'Initialized authoritative intent contract.' @{revision=0}
    }
    return $contract
}
function Get-SCIntentHash($Contract=$null) {
    if($null-eq$Contract){$Contract=Get-SCIntentContract}
    return Get-SCHashString (ConvertTo-SCJson $Contract 24)
}
function Assert-SCIntentShape($Contract) {
    if($null-eq$Contract){throw 'Intent contract is empty.'}
    foreach($field in @('objective','requirements','constraints','invariants','nonGoals','decisions','preferences','openQuestions','successDefinition')){
        if(-not$Contract.PSObject.Properties[$field]){throw "Intent contract missing required field '$field'."}
    }
}
function Save-SCIntentRevision($Contract,[string]$Reason) {
    Assert-SCIntentShape $Contract
    Ensure-SCIntentLayout
    $current=Get-SCIntentContract
    $next=[int]$current.revision+1
    Set-SCProperty $Contract 'schemaVersion' 1
    Set-SCProperty $Contract 'revision' $next
    Set-SCProperty $Contract 'updatedAt' ((Get-Date).ToUniversalTime().ToString('o'))
    Set-SCProperty $Contract 'authority' ([ordered]@{owner='orchestrator';workers='read-only'})
    $historyPath=Get-SCPath ("intent/history/revision-{0:d4}.json"-f$next)
    Write-SCJson $historyPath $Contract
    Write-SCJson (Get-SCPath 'intent/contract.json') $Contract
    $state=Get-SCState
    $direction=if($state.PSObject.Properties['directionRevision']){[int]$state.directionRevision}else{0}
    Set-SCProperty $state 'directionRevision' ($direction+1)
    Set-SCProperty $state 'intentRevision' $next
    Save-SCState $state
    Add-SCEvent 'intent.revised' "Intent contract revised to $next." @{revision=$next;reason=$Reason;hash=(Get-SCIntentHash $Contract)}
    return $Contract
}
function Replace-SCIntentContract([string]$Path,[string]$Reason) {
    if([string]::IsNullOrWhiteSpace($Path)){throw '-Path required.'}
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Intent file not found: $Path"}
    $contract=Read-SCJson (Resolve-Path -LiteralPath $Path).Path
    $saved=Save-SCIntentRevision $contract $Reason
    Write-Host "Intent revision $($saved.revision) committed."
}
function Show-SCIntent([string]$Mode='show') {
    $contract=Get-SCIntentContract
    switch(([string]$Mode).ToLowerInvariant()){
        'show' { $contract|ConvertTo-SCJson -Depth 24|Write-Host;break }
        'history' {
            Get-ChildItem -LiteralPath (Get-SCPath 'intent/history') -Filter 'revision-*.json' -File|Sort-Object Name|ForEach-Object {
                $c=Read-SCJson $_.FullName
                [pscustomobject]@{revision=$c.revision;updatedAt=$c.updatedAt;objective=$c.objective;path=$_.Name}
            }|Format-Table -AutoSize
            break
        }
        default { throw "Unknown intent subcommand: $Mode" }
    }
}

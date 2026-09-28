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

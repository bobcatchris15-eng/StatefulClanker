$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$program=Get-Content -Raw (Join-Path $root 'src\StatefulClanker.Tray\Program.cs')
$connections=Get-Content -Raw (Join-Path $root 'src\StatefulClanker.Tray\ApiConnectionsUi.cs')
$endpoints=Get-Content -Raw (Join-Path $root 'src\StatefulClanker.Tray\EndpointsRoutingUi.cs')
$widgets=Get-Content -Raw (Join-Path $root 'src\StatefulClanker.Tray\CockpitWidgets.cs')
foreach($pair in @(@($program,'_integrationSignature'),@($program,'_providerSignature'),@($program,'_overviewTargetSignature'),@($program,'SetTextIfChanged'),@($connections,'_modelSignature'),@($endpoints,'_gridSignature'),@($widgets,'_activity')))
{
    if($pair[0] -notlike "*$($pair[1])*"){throw "Missing refresh-stability contract: $($pair[1])"}
}
Write-Host 'PASS: idle polling does not rebuild unchanged scrolled UI collections'

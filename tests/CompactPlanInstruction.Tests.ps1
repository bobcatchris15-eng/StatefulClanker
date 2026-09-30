$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-plan-instruction-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
    $path=Join-Path $temp 'instruction.scplan'
    @('SCPLAN 1','plan parser-proof','task proof','title Parser proof','instruction Preserve every word after the keyword, including the artifact path docs/proof.md.','accept Artifact exists and has verified evidence.','end')|Set-Content $path
    . (Join-Path $repo 'lib/StatefulClanker.CapabilityTasks.ps1')
    foreach($module in @('StatefulClanker.Plan.ps1','StatefulClanker.CapabilityTasks.ps1')){
        . (Join-Path $repo "lib/$module")
        $plan=Read-SCCompactPlan $path
        if($plan.tasks[0].instruction-ne'Preserve every word after the keyword, including the artifact path docs/proof.md.'){throw "Instruction remainder truncated by $module"}
        if($plan.tasks[0].acceptance[0]-ne'Artifact exists and has verified evidence.'){throw "Acceptance field dropped by $module"}
    }
    Write-Host 'PASS: both compact-plan definitions preserve full instruction and acceptance values.'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}

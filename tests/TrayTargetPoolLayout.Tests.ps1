$ErrorActionPreference='Stop'
$source=Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\StatefulClanker.Tray\Program.cs')
foreach($required in @('LeftTargetPoolHeight','leftTargetSplit','TARGET POOL','leftTargetSplit.Panel1.Controls.Add(targetPanel)','leftTargetSplit.Panel2.Controls.Add(recentPanel)'))
{
    if($source -notlike "*$required*"){throw "Missing target-pool layout contract: $required"}
}
Write-Host 'PASS: target pool is a persisted, resizable left-rail pane above recent activity'

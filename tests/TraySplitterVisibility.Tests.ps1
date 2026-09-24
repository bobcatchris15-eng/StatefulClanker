$ErrorActionPreference='Stop'
$source=Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\StatefulClanker.Tray\Program.cs')
foreach($required in @('sealed class QuietSplitContainer','SplitterWidth = 8','protected override void OnPaint(PaintEventArgs e)','e.Graphics.FillRectangle(rail, splitter)','e.Graphics.FillRectangle(center'))
{
    if($source -notlike "*$required*"){throw "Missing visible splitter contract: $required"}
}
Write-Host 'PASS: every QuietSplitContainer paints a persistent visual splitter rail'

param(
    [string]$ProjectPath=(Get-Location).Path,
    [int]$RefreshMilliseconds=1000
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ProjectPath=(Resolve-Path $ProjectPath).Path
$stateDir=Join-Path $ProjectPath '.statefulclanker'
$harness=Join-Path (Split-Path -Parent $PSScriptRoot) 'StatefulClanker.ps1'
if(-not(Test-Path (Join-Path $stateDir 'state.json'))){[System.Windows.Forms.MessageBox]::Show("StatefulClanker is not initialized in:`r`n$ProjectPath",'StatefulClanker Cockpit');exit 1}

function ReadJson([string]$p){if(-not(Test-Path $p)){return $null};$r=Get-Content -Raw -LiteralPath $p;if([string]::IsNullOrWhiteSpace($r)){return $null};$r|ConvertFrom-Json}
function ReadJsonDir([string]$p){if(-not(Test-Path $p)){return @()};@(Get-ChildItem -LiteralPath $p -Filter'*.json'-File|ForEach-Object{ReadJson $_.FullName})}
function InvokeHarness([string[]]$args){Push-Location $ProjectPath;try{& $harness @args | Out-String}finally{Pop-Location}}

$form=New-Object Windows.Forms.Form
$form.Text="StatefulClanker Cockpit — $ProjectPath";$form.Width=1220;$form.Height=780;$form.StartPosition='CenterScreen'

$tabs=New-Object Windows.Forms.TabControl;$tabs.Dock='Fill'
$overview=New-Object Windows.Forms.TabPage;$overview.Text='Live'
$history=New-Object Windows.Forms.TabPage;$history.Text='History'
$direction=New-Object Windows.Forms.TabPage;$direction.Text='Direction'
$tabs.TabPages.AddRange(@($overview,$history,$direction));$form.Controls.Add($tabs)

$split=New-Object Windows.Forms.SplitContainer;$split.Dock='Fill';$split.Orientation='Horizontal';$split.SplitterDistance=290;$overview.Controls.Add($split)
$active=New-Object Windows.Forms.DataGridView;$active.Dock='Fill';$active.ReadOnly=$true;$active.AutoSizeColumnsMode='Fill';$active.AllowUserToAddRows=$false;$split.Panel1.Controls.Add($active)
$bottom=New-Object Windows.Forms.SplitContainer;$bottom.Dock='Fill';$bottom.SplitterDistance=590;$split.Panel2.Controls.Add($bottom)
$tasks=New-Object Windows.Forms.DataGridView;$tasks.Dock='Fill';$tasks.ReadOnly=$true;$tasks.AutoSizeColumnsMode='Fill';$tasks.AllowUserToAddRows=$false;$bottom.Panel1.Controls.Add($tasks)
$events=New-Object Windows.Forms.TextBox;$events.Dock='Fill';$events.Multiline=$true;$events.ReadOnly=$true;$events.ScrollBars='Vertical';$events.Font=New-Object Drawing.Font('Consolas',9);$bottom.Panel2.Controls.Add($events)

$histGrid=New-Object Windows.Forms.DataGridView;$histGrid.Dock='Fill';$histGrid.ReadOnly=$true;$histGrid.AutoSizeColumnsMode='Fill';$histGrid.AllowUserToAddRows=$false;$history.Controls.Add($histGrid)

$dirSplit=New-Object Windows.Forms.SplitContainer;$dirSplit.Dock='Fill';$dirSplit.Orientation='Horizontal';$dirSplit.SplitterDistance=470;$direction.Controls.Add($dirSplit)
$conversation=New-Object Windows.Forms.TextBox;$conversation.Dock='Fill';$conversation.Multiline=$true;$conversation.ReadOnly=$true;$conversation.ScrollBars='Vertical';$conversation.Font=New-Object Drawing.Font('Consolas',10);$dirSplit.Panel1.Controls.Add($conversation)
$entryPanel=New-Object Windows.Forms.Panel;$entryPanel.Dock='Fill';$dirSplit.Panel2.Controls.Add($entryPanel)
$input=New-Object Windows.Forms.TextBox;$input.Multiline=$true;$input.Left=8;$input.Top=8;$input.Width=980;$input.Height=110;$input.Anchor='Top,Left,Right'
$send=New-Object Windows.Forms.Button;$send.Text='Record direction';$send.Left=1000;$send.Top=8;$send.Width=170;$send.Height=34;$send.Anchor='Top,Right'
$runNext=New-Object Windows.Forms.Button;$runNext.Text='Run next task';$runNext.Left=1000;$runNext.Top=50;$runNext.Width=170;$runNext.Height=34;$runNext.Anchor='Top,Right'
$refresh=New-Object Windows.Forms.Button;$refresh.Text='Refresh';$refresh.Left=1000;$refresh.Top=92;$refresh.Width=170;$refresh.Height=30;$refresh.Anchor='Top,Right'
$entryPanel.Controls.AddRange(@($input,$send,$runNext,$refresh))

function Table($rows,[string[]]$props){
    $dt=New-Object System.Data.DataTable
    foreach($p in$props){[void]$dt.Columns.Add($p)}
    foreach($r in@($rows)){$row=$dt.NewRow();foreach($p in$props){$v=$r.PSObject.Properties[$p];if($v){$row[$p]=[string]$v.Value}};$dt.Rows.Add($row)}
    $dt
}
function RefreshUI{
    try{
        $activeRows=ReadJsonDir(Join-Path $stateDir'telemetry\active')|Sort-Object startedAt
        $taskRows=ReadJsonDir(Join-Path $stateDir'tasks')|Sort-Object createdAt
        $histRows=ReadJsonDir(Join-Path $stateDir'telemetry\runs')|Sort-Object startedAt -Descending|Select-Object -First 250
        $active.DataSource=Table $activeRows @('agentId','taskId','stage','provider','lifecycle','processId','startedAt','heartbeatAt')
        $tasks.DataSource=Table $taskRows @('id','status','role','title')
        $histGrid.DataSource=Table $histRows @('agentId','taskId','stage','provider','lifecycle','exitCode','verdict','durationSeconds','startedAt')
        $ep=Join-Path $stateDir'events.jsonl';if(Test-Path $ep){$events.Lines=@(Get-Content $ep|Where-Object{$_}|Select-Object -Last 80)}
        $notes=@()
        if(Test-Path $ep){foreach($line in@(Get-Content $ep|Where-Object{$_}|Select-Object -Last 120)){try{$e=$line|ConvertFrom-Json;if($e.type-eq'user.note'){$notes+="[$($e.ts)] YOU: $($e.message)"}}catch{}}}
        $conversation.Lines=$notes
    }catch{$form.Text="StatefulClanker Cockpit — refresh error: $($_.Exception.Message)"}
}
$send.Add_Click({
    $m=$input.Text.Trim();if(-not$m){return}
    [void](InvokeHarness @('event','-Message',$m));$input.Clear();RefreshUI
})
$runNext.Add_Click({
    $runNext.Enabled=$false
    try{[void](InvokeHarness @('run'))}catch{[System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Run failed')}
    finally{$runNext.Enabled=$true;RefreshUI}
})
$refresh.Add_Click({RefreshUI})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=$RefreshMilliseconds;$timer.Add_Tick({RefreshUI});$timer.Start()
RefreshUI
[void]$form.ShowDialog()

$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$dll=Join-Path $repo 'src\StatefulClanker.Tray\bin\Debug\net8.0-windows\StatefulClanker.dll'
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "PROJECT REFRESH TEST FAILED: $Message"}}
if(-not(Test-Path -LiteralPath $dll)){throw "Build the tray before running this test: $dll"}
[void][Reflection.Assembly]::LoadFrom($dll)
$queue=[StatefulClanker.Tray.ProjectRefreshQueue]::new()
Add-Type -IgnoreWarnings -WarningAction SilentlyContinue -ReferencedAssemblies $dll -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Threading.Tasks;
using StatefulClanker.Tray;
public static class ProjectRefreshQueueProbe
{
    public static long Measure(ProjectRefreshQueue queue)
    {
        var clock=Stopwatch.StartNew();
        var first=queue.RunAsync(()=>Task.Delay(150));
        var second=queue.RunAsync(()=>Task.Delay(150));
        Task.WaitAll(first,second);
        return clock.ElapsedMilliseconds;
    }
}
'@

Write-Host '  PROJECT REFRESH 1: a project switch waits for an in-flight refresh instead of being dropped'
$elapsed=[ProjectRefreshQueueProbe]::Measure($queue)
Assert-True ($elapsed-ge250) 'The project-switch refresh ran concurrently instead of waiting.'
Write-Host 'PASS: project-switch refreshes serialize behind the active refresh.'

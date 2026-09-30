$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$dll=Join-Path $repo 'src\StatefulClanker.Tray\bin\Debug\net8.0-windows\StatefulClanker.dll'
$assembly=[Reflection.Assembly]::LoadFrom($dll)
if($null -eq $assembly.GetType('StatefulClanker.Tray.WatcherRefreshGate')){throw 'WATCHER REFRESH FAILED: no bounded event gate exists; watcher events still marshal individually.'}
Add-Type -IgnoreWarnings -WarningAction SilentlyContinue -ReferencedAssemblies @($dll,'System.Threading.Tasks.Parallel') -TypeDefinition @'
using System;
using System.Threading.Tasks;
using StatefulClanker.Tray;
public static class WatcherRefreshProbe
{
    static void Check(bool value,string message) { if(!value) throw new Exception(message); }
    public static void Run()
    {
        var gate=new WatcherRefreshGate();
        Check(!gate.TryBeginRefresh(),"Idle polling requested a refresh");
        Parallel.For(0,100000,_=>gate.MarkDirty());
        Check(gate.TryBeginRefresh(),"Burst was lost");
        Parallel.For(0,100000,_=>{gate.MarkDirty(); Check(!gate.TryBeginRefresh(),"Overlapping refresh admitted");});
        gate.CompleteRefresh();
        Check(gate.TryBeginRefresh(),"Events during refresh were lost");
        gate.CompleteRefresh();
        Check(!gate.TryBeginRefresh(),"Burst left duplicate refreshes queued");
        gate.MarkDirty();
        gate.Dispose();
        Parallel.For(0,1000,_=>gate.MarkDirty());
        Check(!gate.TryBeginRefresh(),"Disposed gate admitted work");
        gate.CompleteRefresh();
        Check(!gate.TryBeginRefresh(),"Completion reopened disposed gate");
    }
}
'@
[WatcherRefreshProbe]::Run()
Write-Host 'PASS: concurrent event bursts coalesce, in-flight changes survive, and disposal prevents work.'

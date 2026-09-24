# Small transport helper for MCP 2026-07-28 subscriptions/listen.
#
# The durable notification bus is the project's control/state.json sequence number.
# A subscription is deliberately level-triggered: whenever that cursor changes, the
# server emits notifications/resources/updated for the control-events resource. The
# client then refetches the resource or calls control_events_since. No project event
# exists only in this stream, so disconnects never lose state.

if(-not('StatefulClanker.SubscriptionPumpV2' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Linq;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace StatefulClanker {
    // V2: event-driven via FileSystemWatcher, with a slow safety poll (>=5s) instead of
    // a 500ms busy loop. Type name is versioned so an already-loaded V1 type in a long-lived
    // session is never mistaken for this shape.
    public static class SubscriptionPumpV2 {
        const int DebounceMs = 250;
        const int SafetyPollMs = 5000;

        class Watch {
            public CancellationTokenSource Cts = new CancellationTokenSource();
            public AutoResetEvent Signal = new AutoResetEvent(false);
            public FileSystemWatcher ActiveWatcher;
            public FileSystemWatcher ControlWatcher;
            public string CurrentControlDir = "";
            public Timer DebounceTimer;
            public readonly object Gate = new object();

            public void Debounce() {
                lock(Gate) {
                    if (DebounceTimer == null) DebounceTimer = new Timer(_ => Signal.Set(), null, DebounceMs, Timeout.Infinite);
                    else DebounceTimer.Change(DebounceMs, Timeout.Infinite);
                }
            }
            public void Immediate() { Signal.Set(); }

            public void Dispose() {
                try { if (ActiveWatcher != null) { ActiveWatcher.EnableRaisingEvents = false; ActiveWatcher.Dispose(); } } catch { }
                try { if (ControlWatcher != null) { ControlWatcher.EnableRaisingEvents = false; ControlWatcher.Dispose(); } } catch { }
                try { if (DebounceTimer != null) DebounceTimer.Dispose(); } catch { }
                try { Cts.Dispose(); } catch { }
            }
        }

        static readonly ConcurrentDictionary<string,Watch> Stdio = new ConcurrentDictionary<string,Watch>();
        static readonly Regex SeqRx = new Regex("\\\"lastSequence\\\"\\s*:\\s*(\\d+)", RegexOptions.Compiled);

        static string E(string s) {
            if (s == null) return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");
        }
        static string Ack(string id, string uri) {
            return "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"notifications\":{\"resourceSubscriptions\":[\""+E(uri)+"\"]},\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\""+E(id)+"\"}}}";
        }
        static string Updated(string id, string uri) {
            return "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\""+E(uri)+"\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\""+E(id)+"\"}}}";
        }
        static string Project(string activeProjectFile, string projectOverride) {
            try {
                if (!String.IsNullOrWhiteSpace(projectOverride) && Directory.Exists(projectOverride)) return projectOverride;
                if (!File.Exists(activeProjectFile)) return "";
                var project = File.ReadAllText(activeProjectFile).Trim();
                return Directory.Exists(project) ? project : "";
            } catch { return ""; }
        }
        static long Cursor(string activeProjectFile, string projectOverride) {
            try {
                var project=Project(activeProjectFile,projectOverride); if(project.Length==0) return 0;
                var state = Path.Combine(project, ".statefulclanker", "control", "state.json");
                if (!File.Exists(state)) return 0;
                var m = SeqRx.Match(File.ReadAllText(state));
                long n; return m.Success && long.TryParse(m.Groups[1].Value, out n) ? n : 0;
            } catch { return 0; }
        }
        static void Sse(NetworkStream stream, string json) {
            var bytes=Encoding.UTF8.GetBytes("event: message\ndata: "+json+"\n\n");
            stream.Write(bytes,0,bytes.Length); stream.Flush();
        }
        static void KeepAlive(NetworkStream stream) {
            var bytes=Encoding.UTF8.GetBytes(": keepalive\n\n");
            stream.Write(bytes,0,bytes.Length); stream.Flush();
        }

        // (Re)binds the control-directory watcher to the currently active project. Called
        // both at startup and on every wake so a project retarget (active-project.txt change,
        // or a projectOverride whose directory just came into existence) is picked up even if
        // the active-file watcher itself missed the edge.
        static void RebindControlWatcher(Watch w, string activeProjectFile, string projectOverride) {
            var project = Project(activeProjectFile, projectOverride);
            var dir = project.Length == 0 ? "" : Path.Combine(project, ".statefulclanker", "control");
            if (dir == w.CurrentControlDir) return;
            try { if (w.ControlWatcher != null) { w.ControlWatcher.EnableRaisingEvents = false; w.ControlWatcher.Dispose(); } } catch { }
            w.ControlWatcher = null;
            w.CurrentControlDir = dir;
            if (dir.Length == 0 || !Directory.Exists(dir)) return;
            try {
                var fsw = new FileSystemWatcher(dir, "state.json");
                fsw.NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime;
                FileSystemEventHandler onChange = (s, e) => w.Debounce();
                RenamedEventHandler onRename = (s, e) => w.Debounce();
                fsw.Changed += onChange; fsw.Created += onChange; fsw.Renamed += onRename;
                fsw.Error += (s, e) => w.Immediate(); // buffer overflow etc: force an immediate rescan
                fsw.EnableRaisingEvents = true;
                w.ControlWatcher = fsw;
            } catch { }
        }

        static void SetupActiveWatcher(Watch w, string activeProjectFile, string projectOverride) {
            if (!String.IsNullOrWhiteSpace(projectOverride)) return; // fixed target, nothing to retarget
            try {
                var dir = Path.GetDirectoryName(activeProjectFile);
                var file = Path.GetFileName(activeProjectFile);
                if (String.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return;
                var fsw = new FileSystemWatcher(dir, file);
                fsw.NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.CreationTime;
                FileSystemEventHandler onChange = (s, e) => w.Debounce();
                RenamedEventHandler onRename = (s, e) => w.Debounce();
                fsw.Changed += onChange; fsw.Created += onChange; fsw.Renamed += onRename;
                fsw.Error += (s, e) => w.Immediate();
                fsw.EnableRaisingEvents = true;
                w.ActiveWatcher = fsw;
            } catch { }
        }

        public static void StartHttp(TcpClient client, string activeProjectFile, string projectOverride, string id, string uri) {
            var w = new Watch();
            var thread=new Thread(()=>{
                try {
                    using(client) using(var stream=client.GetStream()) {
                        var head="HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n";
                        var hb=Encoding.ASCII.GetBytes(head); stream.Write(hb,0,hb.Length); stream.Flush();
                        Sse(stream,Ack(id,uri));
                        SetupActiveWatcher(w, activeProjectFile, projectOverride);
                        RebindControlWatcher(w, activeProjectFile, projectOverride);
                        var last=Cursor(activeProjectFile,projectOverride); var keep=DateTime.UtcNow;
                        while(true) {
                            w.Signal.WaitOne(SafetyPollMs);
                            RebindControlWatcher(w, activeProjectFile, projectOverride);
                            var now=Cursor(activeProjectFile,projectOverride);
                            if(now!=last) { last=now; Sse(stream,Updated(id,uri)); keep=DateTime.UtcNow; }
                            else if((DateTime.UtcNow-keep).TotalSeconds>=15) { KeepAlive(stream); keep=DateTime.UtcNow; }
                        }
                    }
                } catch { } finally { w.Dispose(); }
            });
            thread.IsBackground=true; thread.Name="StatefulClanker MCP HTTP subscription"; thread.Start();
        }

        public static void StartStdio(string activeProjectFile, string projectOverride, string id, string uri) {
            Watch old; if(Stdio.TryRemove(id,out old)) { old.Cts.Cancel(); old.Signal.Set(); old.Dispose(); }
            var w=new Watch(); Stdio[id]=w;
            var thread=new Thread(()=>{
                try {
                    Console.Out.WriteLine(Ack(id,uri)); Console.Out.Flush();
                    SetupActiveWatcher(w, activeProjectFile, projectOverride);
                    RebindControlWatcher(w, activeProjectFile, projectOverride);
                    var last=Cursor(activeProjectFile,projectOverride);
                    while(!w.Cts.IsCancellationRequested) {
                        w.Signal.WaitOne(SafetyPollMs);
                        if (w.Cts.IsCancellationRequested) break;
                        RebindControlWatcher(w, activeProjectFile, projectOverride);
                        var now=Cursor(activeProjectFile,projectOverride);
                        if(now!=last) { last=now; Console.Out.WriteLine(Updated(id,uri)); Console.Out.Flush(); }
                    }
                } catch { } finally {
                    w.Dispose();
                    Watch removed; Stdio.TryRemove(id,out removed);
                }
            });
            thread.IsBackground=true; thread.Name="StatefulClanker MCP stdio subscription"; thread.Start();
        }

        public static void Stop(string id) { Watch w; if(Stdio.TryRemove(id,out w)) { w.Cts.Cancel(); w.Signal.Set(); w.Dispose(); } }
        public static void StopAll() { foreach(var kv in Stdio.ToArray()) { Watch w; if(Stdio.TryRemove(kv.Key,out w)) { w.Cts.Cancel(); w.Signal.Set(); w.Dispose(); } } }
    }
}
'@
}

$script:SCControlEventsResource='statefulclanker://project/current/control-events'
$script:SCActiveProjectFile=Join-Path (Join-Path $env:LOCALAPPDATA 'StatefulClanker') 'active-project.txt'

function Get-SCSubscriptionResource($Rpc) {
    if($null-eq$Rpc-or-not$Rpc.PSObject.Properties['params']-or$null-eq$Rpc.params){return $null}
    if(-not$Rpc.params.PSObject.Properties['notifications']-or$null-eq$Rpc.params.notifications){return $null}
    if(-not$Rpc.params.notifications.PSObject.Properties['resourceSubscriptions']){return $null}
    foreach($uri in @($Rpc.params.notifications.resourceSubscriptions)){if([string]$uri-eq$script:SCControlEventsResource){return $script:SCControlEventsResource}}
    return $null
}

function Start-SCHttpControlSubscription($Client,$Rpc) {
    $uri=Get-SCSubscriptionResource $Rpc;if(-not$uri){return $false}
    $override=if($script:McpDefaultProject){[string]$script:McpDefaultProject}else{''}
    [StatefulClanker.SubscriptionPumpV2]::StartHttp($Client,$script:SCActiveProjectFile,$override,[string]$Rpc.id,$uri);return $true
}
function Start-SCStdioControlSubscription($Rpc) {
    $uri=Get-SCSubscriptionResource $Rpc;if(-not$uri){return $false}
    $override=if($script:McpDefaultProject){[string]$script:McpDefaultProject}else{''}
    [StatefulClanker.SubscriptionPumpV2]::StartStdio($script:SCActiveProjectFile,$override,[string]$Rpc.id,$uri);return $true
}
function Stop-SCStdioSubscription([string]$RequestId) { [StatefulClanker.SubscriptionPumpV2]::Stop($RequestId) }
function Stop-SCAllStdioSubscriptions { [StatefulClanker.SubscriptionPumpV2]::StopAll() }

# Small transport helper for MCP 2026-07-28 subscriptions/listen.
#
# The durable notification bus is the project's control/state.json sequence number.
# A subscription is deliberately level-triggered: whenever that cursor changes, the
# server emits notifications/resources/updated for the control-events resource. The
# client then refetches the resource or calls control_events_since. No project event
# exists only in this stream, so disconnects never lose state.

if(-not('StatefulClanker.SubscriptionPump' -as [type])) {
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
    public static class SubscriptionPump {
        static readonly ConcurrentDictionary<string,CancellationTokenSource> Stdio = new ConcurrentDictionary<string,CancellationTokenSource>();
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
        static long Cursor(string activeProjectFile) {
            try {
                if (!File.Exists(activeProjectFile)) return 0;
                var project = File.ReadAllText(activeProjectFile).Trim();
                if (project.Length == 0 || !Directory.Exists(project)) return 0;
                var state = Path.Combine(project, ".statefulclanker", "control", "state.json");
                if (!File.Exists(state)) return 0;
                var m = SeqRx.Match(File.ReadAllText(state));
                long n;
                return m.Success && long.TryParse(m.Groups[1].Value, out n) ? n : 0;
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

        public static void StartHttp(TcpClient client, string activeProjectFile, string id, string uri) {
            var thread=new Thread(()=>{
                try {
                    using(client) using(var stream=client.GetStream()) {
                        var head="HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n";
                        var hb=Encoding.ASCII.GetBytes(head); stream.Write(hb,0,hb.Length); stream.Flush();
                        Sse(stream,Ack(id,uri));
                        var last=Cursor(activeProjectFile); var keep=DateTime.UtcNow;
                        while(true) {
                            Thread.Sleep(500);
                            var now=Cursor(activeProjectFile);
                            if(now!=last) { last=now; Sse(stream,Updated(id,uri)); keep=DateTime.UtcNow; }
                            else if((DateTime.UtcNow-keep).TotalSeconds>=15) { KeepAlive(stream); keep=DateTime.UtcNow; }
                        }
                    }
                } catch { }
            });
            thread.IsBackground=true; thread.Name="StatefulClanker MCP HTTP subscription"; thread.Start();
        }

        public static void StartStdio(string activeProjectFile, string id, string uri) {
            CancellationTokenSource old;
            if(Stdio.TryRemove(id,out old)) old.Cancel();
            var cts=new CancellationTokenSource(); Stdio[id]=cts;
            var thread=new Thread(()=>{
                try {
                    Console.Out.WriteLine(Ack(id,uri)); Console.Out.Flush();
                    var last=Cursor(activeProjectFile);
                    while(!cts.IsCancellationRequested) {
                        Thread.Sleep(500); var now=Cursor(activeProjectFile);
                        if(now!=last) { last=now; Console.Out.WriteLine(Updated(id,uri)); Console.Out.Flush(); }
                    }
                } catch { }
                CancellationTokenSource removed; Stdio.TryRemove(id,out removed);
            });
            thread.IsBackground=true; thread.Name="StatefulClanker MCP stdio subscription"; thread.Start();
        }

        public static void Stop(string id) {
            CancellationTokenSource cts; if(Stdio.TryRemove(id,out cts)) cts.Cancel();
        }
        public static void StopAll() {
            foreach(var kv in Stdio.ToArray()) { CancellationTokenSource cts; if(Stdio.TryRemove(kv.Key,out cts)) cts.Cancel(); }
        }
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
    foreach($uri in @($Rpc.params.notifications.resourceSubscriptions)){
        if([string]$uri-eq$script:SCControlEventsResource){return $script:SCControlEventsResource}
    }
    return $null
}

function Start-SCHttpControlSubscription($Client,$Rpc) {
    $uri=Get-SCSubscriptionResource $Rpc
    if(-not$uri){return $false}
    [StatefulClanker.SubscriptionPump]::StartHttp($Client,$script:SCActiveProjectFile,[string]$Rpc.id,$uri)
    return $true
}
function Start-SCStdioControlSubscription($Rpc) {
    $uri=Get-SCSubscriptionResource $Rpc
    if(-not$uri){return $false}
    [StatefulClanker.SubscriptionPump]::StartStdio($script:SCActiveProjectFile,[string]$Rpc.id,$uri)
    return $true
}
function Stop-SCStdioSubscription([string]$RequestId) { [StatefulClanker.SubscriptionPump]::Stop($RequestId) }
function Stop-SCAllStdioSubscriptions { [StatefulClanker.SubscriptionPump]::StopAll() }

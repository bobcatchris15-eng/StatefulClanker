using System.Diagnostics;
using System.Text.Json;

namespace StatefulClanker.Router;

internal static class Program
{
    static readonly JsonSerializerOptions Json=new(){WriteIndented=false,PropertyNameCaseInsensitive=true};

    static async Task<int> Main(string[] args)
    {
        var store=new RouterStore();
        var pipeName=RouterNames.PipeName(store.Root);

        if(args.Length>0 && string.Equals(args[0],"daemon",StringComparison.OrdinalIgnoreCase))
            return await RunDaemonAsync(store,pipeName);

        var request=ParseRequest(args);
        if(request is null)
        {
            Console.Error.WriteLine("Usage: StatefulClanker.Router <ping|snapshot|acquire|release|heartbeat|success|failure> [options]");
            return 2;
        }

        RouterResponse response;
        try
        {
            response=await SendWithDaemonAsync(pipeName,request);
        }
        catch(Exception ex)
        {
            response=RouterResponse.Fail("Router service unavailable: "+ex.Message);
        }

        Console.WriteLine(JsonSerializer.Serialize(response,Json));
        return response.ok?0:1;
    }

    static async Task<int> RunDaemonAsync(RouterStore store,string pipeName)
    {
        var mutexHash=pipeName.Split('.').Last();
        using var mutex=new Mutex(true,"Local\\StatefulClankerRouterDaemon-"+mutexHash,out var created);
        if(!created) return 0;

        var engine=new RouterEngine(store);
        var server=new RouterPipeServer(pipeName,engine);
        var monitor=new EndpointMonitor(engine);
        var freeCapacity=new FreeCapacityManager(engine);
        using var cts=new CancellationTokenSource();

        Console.CancelKeyPress+=(s,e)=>{e.Cancel=true;cts.Cancel();};
        AppDomain.CurrentDomain.ProcessExit+=(s,e)=>cts.Cancel();

        await Task.WhenAll(
            server.RunAsync(cts.Token),
            monitor.RunAsync(cts.Token),
            freeCapacity.RunAsync(cts.Token));
        return 0;
    }

    static RouterRequest? ParseRequest(string[] args)
    {
        if(args.Length==0) return new RouterRequest{op="snapshot"};
        var op=args[0].ToLowerInvariant();
        if(op is not ("ping" or "snapshot" or "acquire" or "release" or "heartbeat" or "success" or "failure")) return null;
        var map=new Dictionary<string,string?>(StringComparer.OrdinalIgnoreCase);
        for(var i=1;i<args.Length;i++)
        {
            if(!args[i].StartsWith("--")) continue;
            var key=args[i][2..];
            var value=(i+1<args.Length && !args[i+1].StartsWith("--"))?args[++i]:"true";
            map[key]=value;
        }
        return new RouterRequest
        {
            op=op,
            preferred=Get(map,"preferred"),
            preferredConnection=Get(map,"connection"),
            strictPreferred=bool.TryParse(Get(map,"strict-preferred"),out var sp)&&sp,
            sessionId=Get(map,"session"),
            requireTools=bool.TryParse(Get(map,"require-tools"),out var rt)&&rt,
            ownerPid=int.TryParse(Get(map,"owner-pid"),out var pid)?pid:0,
            lease=Get(map,"lease"),
            endpoint=Get(map,"endpoint"),
            failureClass=Get(map,"class"),
            message=Get(map,"message")
        };
    }

    static string? Get(Dictionary<string,string?> map,string key) => map.TryGetValue(key,out var v)?v:null;

    static async Task<RouterResponse> SendWithDaemonAsync(string pipeName,RouterRequest request)
    {
        try { return await RouterPipeClient.SendAsync(pipeName,request,500); }
        catch { }

        var exe=Environment.ProcessPath ?? throw new InvalidOperationException("Cannot determine router executable path.");
        Process.Start(new ProcessStartInfo
        {
            FileName=exe,
            Arguments="daemon",
            UseShellExecute=false,
            CreateNoWindow=true,
            WorkingDirectory=AppContext.BaseDirectory
        });

        Exception? last=null;
        for(var i=0;i<40;i++)
        {
            await Task.Delay(100);
            try { return await RouterPipeClient.SendAsync(pipeName,request,750); }
            catch(Exception ex){last=ex;}
        }
        throw new IOException("Router daemon did not become ready.",last);
    }
}

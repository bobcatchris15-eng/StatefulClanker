using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace StatefulClanker.Router;

public static class RouterNames
{
    public static string PipeName(string root)
    {
        var hash=Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(root))).ToLowerInvariant()[..12];
        return "StatefulClanker.Router.v1."+hash;
    }
}

public sealed class RouterPipeServer
{
    readonly string _pipeName;
    readonly RouterEngine _engine;
    readonly JsonSerializerOptions _json=new(){PropertyNameCaseInsensitive=true};

    public RouterPipeServer(string pipeName,RouterEngine engine){_pipeName=pipeName;_engine=engine;}

    public async Task RunAsync(CancellationToken token)
    {
        while(!token.IsCancellationRequested)
        {
            var pipe=new NamedPipeServerStream(_pipeName,PipeDirection.InOut,NamedPipeServerStream.MaxAllowedServerInstances,
                PipeTransmissionMode.Byte,PipeOptions.Asynchronous);
            try
            {
                await pipe.WaitForConnectionAsync(token);
                _=Task.Run(()=>HandleAsync(pipe,token),CancellationToken.None);
            }
            catch
            {
                pipe.Dispose();
                if(token.IsCancellationRequested) break;
            }
        }
    }

    async Task HandleAsync(NamedPipeServerStream pipe,CancellationToken token)
    {
        await using var owned=pipe;
        using var reader=new StreamReader(pipe,Encoding.UTF8,false,4096,true);
        using var writer=new StreamWriter(pipe,new UTF8Encoding(false),4096,true){AutoFlush=true};
        try
        {
            var line=await reader.ReadLineAsync(token);
            if(string.IsNullOrWhiteSpace(line)){await writer.WriteLineAsync(JsonSerializer.Serialize(RouterResponse.Fail("Empty request."),_json));return;}
            var req=JsonSerializer.Deserialize<RouterRequest>(line,_json) ?? new();
            var response=req.op.ToLowerInvariant() switch
            {
                "ping" => RouterResponse.Ok(new{service="StatefulClanker.Router",version="0.1"}),
                "acquire" => _engine.Acquire(req.preferred,req.sessionId,req.requireTools),
                "release" => _engine.Release(req.lease),
                "heartbeat" => _engine.Heartbeat(req.lease),
                "success" => _engine.Success(req.lease,req.endpoint),
                "failure" => _engine.Failure(req.lease,req.endpoint,req.failureClass,req.message),
                "snapshot" => RouterResponse.Ok(_engine.Snapshot()),
                _ => RouterResponse.Fail("Unknown router operation: "+req.op)
            };
            await writer.WriteLineAsync(JsonSerializer.Serialize(response,_json));
        }
        catch(Exception ex)
        {
            try{await writer.WriteLineAsync(JsonSerializer.Serialize(RouterResponse.Fail(ex.Message),_json));}catch{}
        }
    }
}

public static class RouterPipeClient
{
    static readonly JsonSerializerOptions Json=new(){PropertyNameCaseInsensitive=true};

    public static async Task<RouterResponse> SendAsync(string pipeName,RouterRequest request,int timeoutMs=3000)
    {
        using var pipe=new NamedPipeClientStream(".",pipeName,PipeDirection.InOut,PipeOptions.Asynchronous);
        using var cts=new CancellationTokenSource(timeoutMs);
        await pipe.ConnectAsync(cts.Token);
        using var reader=new StreamReader(pipe,Encoding.UTF8,false,4096,true);
        using var writer=new StreamWriter(pipe,new UTF8Encoding(false),4096,true){AutoFlush=true};
        await writer.WriteLineAsync(JsonSerializer.Serialize(request,Json));
        var line=await reader.ReadLineAsync(cts.Token);
        return string.IsNullOrWhiteSpace(line)?RouterResponse.Fail("Router returned no response."):
            JsonSerializer.Deserialize<RouterResponse>(line,Json) ?? RouterResponse.Fail("Router returned malformed response.");
    }
}

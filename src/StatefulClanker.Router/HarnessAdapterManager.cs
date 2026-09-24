using System.Diagnostics;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace StatefulClanker.Router;

internal sealed record HarnessModel(string Id,string DisplayName,bool Free,bool SupportsTools,long? ContextLength,string Evidence);

internal sealed class ManagedHarnessInstance
{
    public required string Adapter { get; init; }
    public required string Key { get; init; }
    public required string ManagerKey { get; init; }
    public required string ConnectionName { get; init; }
    public required string WorkingDirectory { get; init; }
    public required string BaseUrl { get; init; }
    public required string Username { get; init; }
    public required string Password { get; init; }
    public required Process Process { get; init; }
    public DateTimeOffset LastUsedAt { get; set; }=DateTimeOffset.UtcNow;
    public DateTimeOffset LastDiscoveredAt { get; set; }=DateTimeOffset.MinValue;
    public HashSet<string> EndpointIds { get; }=new(StringComparer.OrdinalIgnoreCase);
}

internal interface IHarnessAdapter
{
    string Kind { get; }
    Task<ManagedHarnessInstance> StartAsync(string workingDirectory,string key,string managerKey,string connectionName,CancellationToken token);
    Task<IReadOnlyList<HarnessModel>> DiscoverAsync(ManagedHarnessInstance instance,CancellationToken token);
    Task<bool> ProbeAsync(ManagedHarnessInstance instance,CancellationToken token);
    Task StopAsync(ManagedHarnessInstance instance,CancellationToken token);
}

internal sealed class OpenCodeHarnessAdapter : IHarnessAdapter
{
    readonly HttpClient _http=new(){Timeout=TimeSpan.FromSeconds(8)};
    public string Kind => "opencode";

    public async Task<ManagedHarnessInstance> StartAsync(string workingDirectory,string key,string managerKey,string connectionName,CancellationToken token)
    {
        var port=FreePort();
        var password=Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
        const string username="opencode";
        var executable=ResolveExecutable();
        var process=Process.Start(NewStartInfo(executable,workingDirectory,port,password,username))
            ?? throw new InvalidOperationException("OpenCode process did not start.");
        var instance=new ManagedHarnessInstance
        {
            Adapter=Kind,Key=key,ManagerKey=managerKey,ConnectionName=connectionName,
            WorkingDirectory=workingDirectory,BaseUrl=$"http://127.0.0.1:{port}",
            Username=username,Password=password,Process=process
        };
        try
        {
            var deadline=DateTimeOffset.UtcNow.AddSeconds(20);
            while(DateTimeOffset.UtcNow<deadline)
            {
                token.ThrowIfCancellationRequested();
                if(process.HasExited) throw new InvalidOperationException($"opencode serve exited during startup with code {process.ExitCode}.");
                if(await ProbeAsync(instance,token)) return instance;
                await Task.Delay(250,token);
            }
            throw new TimeoutException("opencode serve did not become healthy within 20 seconds.");
        }
        catch
        {
            TryKill(process);process.Dispose();throw;
        }
    }

    public async Task<IReadOnlyList<HarnessModel>> DiscoverAsync(ManagedHarnessInstance instance,CancellationToken token)
    {
        using var request=Request(HttpMethod.Get,instance,"/provider");
        using var response=await _http.SendAsync(request,HttpCompletionOption.ResponseContentRead,token);
        response.EnsureSuccessStatusCode();
        using var doc=JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
        if(doc.RootElement.ValueKind!=JsonValueKind.Object ||
           !doc.RootElement.TryGetProperty("all",out var providers) ||
           providers.ValueKind!=JsonValueKind.Array) return Array.Empty<HarnessModel>();

        var output=new List<HarnessModel>();
        foreach(var provider in providers.EnumerateArray())
        {
            if(provider.ValueKind!=JsonValueKind.Object) continue;
            var providerId=String(provider,"id") ?? String(provider,"providerID");
            if(!string.Equals(providerId,"opencode",StringComparison.OrdinalIgnoreCase)) continue;
            if(!provider.TryGetProperty("models",out var models)) continue;
            if(models.ValueKind==JsonValueKind.Object)
            {
                foreach(var property in models.EnumerateObject()) AddModel(output,providerId!,property.Name,property.Value);
            }
            else if(models.ValueKind==JsonValueKind.Array)
            {
                foreach(var model in models.EnumerateArray())
                {
                    var id=String(model,"id") ?? String(model,"modelID");
                    if(!string.IsNullOrWhiteSpace(id)) AddModel(output,providerId!,id!,model);
                }
            }
        }
        return output.GroupBy(x=>x.Id,StringComparer.OrdinalIgnoreCase).Select(x=>x.First())
            .OrderBy(x=>x.DisplayName,StringComparer.OrdinalIgnoreCase).ToList();
    }

    static void AddModel(List<HarnessModel> output,string providerId,string modelId,JsonElement model)
    {
        if(model.ValueKind!=JsonValueKind.Object) return;
        if(model.TryGetProperty("enabled",out var enabled) && enabled.ValueKind==JsonValueKind.False) return;
        if(string.Equals(String(model,"status"),"deprecated",StringComparison.OrdinalIgnoreCase)) return;

        var explicitFree=modelId.EndsWith("-free",StringComparison.OrdinalIgnoreCase);
        var zeroCost=model.TryGetProperty("cost",out var cost) && ZeroCost(cost);
        if(!explicitFree && !zeroCost) return;

        var tools=true;
        if(model.TryGetProperty("capabilities",out var caps) && caps.ValueKind==JsonValueKind.Object &&
           caps.TryGetProperty("tools",out var toolValue) && (toolValue.ValueKind==JsonValueKind.True || toolValue.ValueKind==JsonValueKind.False))
            tools=toolValue.GetBoolean();

        long? context=null;
        if(model.TryGetProperty("limit",out var limit) && limit.ValueKind==JsonValueKind.Object &&
           limit.TryGetProperty("context",out var contextValue) && contextValue.TryGetInt64(out var parsedContext))
            context=parsedContext;

        output.Add(new HarnessModel(
            providerId+"/"+modelId,
            String(model,"name") ?? modelId,
            true,tools,context,
            explicitFree?"OpenCode model id explicitly selects a free route.":"OpenCode live provider catalog reports zero input/output cost."));
    }

    static bool ZeroCost(JsonElement cost)
    {
        if(cost.ValueKind==JsonValueKind.Object) return ZeroCostObject(cost);
        if(cost.ValueKind!=JsonValueKind.Array) return false;
        var any=false;
        foreach(var tier in cost.EnumerateArray())
        {
            if(tier.ValueKind!=JsonValueKind.Object) return false;
            any=true;if(!ZeroCostObject(tier)) return false;
        }
        return any;
    }

    static bool ZeroCostObject(JsonElement cost)
    {
        foreach(var name in new[]{"input","output"})
        {
            if(!cost.TryGetProperty(name,out var value) || value.ValueKind!=JsonValueKind.Number) return false;
            if(!value.TryGetDouble(out var amount) || Math.Abs(amount)>double.Epsilon) return false;
        }
        return true;
    }

    public async Task<bool> ProbeAsync(ManagedHarnessInstance instance,CancellationToken token)
    {
        try
        {
            using var request=Request(HttpMethod.Get,instance,"/global/health");
            using var response=await _http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,token);
            return response.IsSuccessStatusCode;
        }
        catch(OperationCanceledException) when(token.IsCancellationRequested){throw;}
        catch{return false;}
    }

    public async Task StopAsync(ManagedHarnessInstance instance,CancellationToken token)
    {
        try
        {
            using var request=Request(HttpMethod.Post,instance,"/instance/dispose");
            using var response=await _http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,token);
        }
        catch{}
        TryKill(instance.Process);instance.Process.Dispose();
    }

    static HttpRequestMessage Request(HttpMethod method,ManagedHarnessInstance instance,string path)
    {
        var request=new HttpRequestMessage(method,instance.BaseUrl.TrimEnd('/')+path);
        var raw=Convert.ToBase64String(Encoding.UTF8.GetBytes(instance.Username+":"+instance.Password));
        request.Headers.Authorization=new AuthenticationHeaderValue("Basic",raw);
        return request;
    }

    static string? String(JsonElement element,string name) =>
        element.TryGetProperty(name,out var value) && value.ValueKind==JsonValueKind.String ? value.GetString() : null;

    static int FreePort()
    {
        var listener=new TcpListener(System.Net.IPAddress.Loopback,0);listener.Start();
        try{return ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;}finally{listener.Stop();}
    }

    static string ResolveExecutable()
    {
        var configured=Environment.GetEnvironmentVariable("SC_OPENCODE_EXE");
        if(!string.IsNullOrWhiteSpace(configured)) return configured;
        var path=Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach(var root in path.Split(Path.PathSeparator,StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries))
            foreach(var name in OperatingSystem.IsWindows()?new[]{"opencode.exe","opencode.cmd","opencode.bat","opencode"}:new[]{"opencode"})
            {
                try{var candidate=Path.Combine(root,name);if(File.Exists(candidate)) return candidate;}catch{}
            }
        return "opencode";
    }

    static ProcessStartInfo NewStartInfo(string executable,string workingDirectory,int port,string password,string username)
    {
        var psi=new ProcessStartInfo{UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=workingDirectory};
        var ext=Path.GetExtension(executable);
        if(OperatingSystem.IsWindows() && (ext.Equals(".cmd",StringComparison.OrdinalIgnoreCase)||ext.Equals(".bat",StringComparison.OrdinalIgnoreCase)))
        {
            psi.FileName=Environment.GetEnvironmentVariable("COMSPEC") ?? "cmd.exe";
            psi.ArgumentList.Add("/d");psi.ArgumentList.Add("/s");psi.ArgumentList.Add("/c");
            psi.ArgumentList.Add($"\"{executable}\" serve --hostname 127.0.0.1 --port {port}");
        }
        else
        {
            psi.FileName=executable;
            psi.ArgumentList.Add("serve");psi.ArgumentList.Add("--hostname");psi.ArgumentList.Add("127.0.0.1");
            psi.ArgumentList.Add("--port");psi.ArgumentList.Add(port.ToString());
        }
        psi.Environment["OPENCODE_SERVER_PASSWORD"]=password;
        psi.Environment["OPENCODE_SERVER_USERNAME"]=username;
        return psi;
    }

    internal static void TryKill(Process process){try{if(!process.HasExited) process.Kill(entireProcessTree:true);}catch{}}
}

public sealed class HarnessAdapterManager
{
    readonly RouterEngine _engine;
    readonly RouterStore _store;
    readonly Dictionary<string,IHarnessAdapter> _adapters;
    readonly Dictionary<string,ManagedHarnessInstance> _instances=new(StringComparer.OrdinalIgnoreCase);
    readonly SemaphoreSlim _gate=new(1,1);
    static readonly TimeSpan IdleTimeout=TimeSpan.FromMinutes(15);
    static readonly TimeSpan DiscoveryInterval=TimeSpan.FromMinutes(5);

    public HarnessAdapterManager(RouterEngine engine)
    {
        _engine=engine;_store=engine.Store;
        _adapters=new(StringComparer.OrdinalIgnoreCase){["opencode"]=new OpenCodeHarnessAdapter()};
        CleanupStaleRegistrations();
    }

    public async Task<RouterResponse> EnsureAsync(string? adapterName,string? workingDirectory,CancellationToken token=default)
    {
        if(string.IsNullOrWhiteSpace(adapterName)) return RouterResponse.Fail("Harness adapter name is required.");
        if(!_adapters.TryGetValue(adapterName,out var adapter)) return RouterResponse.Fail("Unknown harness adapter: "+adapterName);
        if(string.IsNullOrWhiteSpace(workingDirectory)) return RouterResponse.Fail("Managed harness requires --working-directory.");

        string root;
        try{root=Path.GetFullPath(workingDirectory).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);}
        catch(Exception ex){return RouterResponse.Fail("Invalid harness working directory: "+ex.Message);}
        if(!Directory.Exists(root)) return RouterResponse.Fail("Harness working directory does not exist: "+root);

        await _gate.WaitAsync(token);
        try
        {
            var hash=WorkspaceHash(root);
            var key=adapter.Kind+"|"+root.ToLowerInvariant();
            var managerKey="harness:"+adapter.Kind+":"+hash;
            var connectionName="internal-"+adapter.Kind+"-"+hash;
            ManagedHarnessInstance? instance;
            lock(_instances) _instances.TryGetValue(key,out instance);

            if(instance is not null && instance.Process.HasExited){await StopInstanceAsync(instance,CancellationToken.None);instance=null;}
            if(instance is null)
            {
                try
                {
                    instance=await adapter.StartAsync(root,key,managerKey,connectionName,token);
                    lock(_instances) _instances[key]=instance;
                }
                catch(Exception ex){return RouterResponse.Fail($"Could not start {adapter.Kind} harness: {ex.Message}");}
            }

            instance.LastUsedAt=DateTimeOffset.UtcNow;
            if(instance.LastDiscoveredAt==DateTimeOffset.MinValue ||
               DateTimeOffset.UtcNow-instance.LastDiscoveredAt>=DiscoveryInterval || instance.EndpointIds.Count==0)
            {
                IReadOnlyList<HarnessModel> models;
                try{models=await adapter.DiscoverAsync(instance,token);}
                catch(Exception ex){return RouterResponse.Fail($"{adapter.Kind} harness catalog failed: {ex.Message}");}
                Register(instance,models.Where(x=>x.Free).ToList());
                instance.LastDiscoveredAt=DateTimeOffset.UtcNow;
            }

            _engine.MarkHealthy("connection:"+instance.ConnectionName);
            foreach(var endpoint in instance.EndpointIds) _engine.MarkHealthy("pool:"+endpoint);
            return RouterResponse.Ok(new
            {
                adapter=instance.Adapter,connection=instance.ConnectionName,workingDirectory=instance.WorkingDirectory,
                baseUrl=instance.BaseUrl,processId=instance.Process.Id,eligibleEndpoints=instance.EndpointIds.Count,
                endpoints=instance.EndpointIds.OrderBy(x=>x,StringComparer.OrdinalIgnoreCase).Select(x=>"pool:"+x).ToArray()
            });
        }
        finally{_gate.Release();}
    }

    public async Task RunAsync(CancellationToken token)
    {
        while(!token.IsCancellationRequested)
        {
            try{await Task.Delay(TimeSpan.FromSeconds(20),token);await ReapIdleAsync(token);}
            catch(OperationCanceledException) when(token.IsCancellationRequested){break;}
            catch{}
        }
    }

    async Task ReapIdleAsync(CancellationToken token)
    {
        await _gate.WaitAsync(token);
        try
        {
            ManagedHarnessInstance[] snapshot;lock(_instances) snapshot=_instances.Values.ToArray();
            foreach(var instance in snapshot)
            {
                var leased=instance.EndpointIds.Any(id=>_engine.IsLeased("pool:"+id));
                if(!leased && (instance.Process.HasExited || DateTimeOffset.UtcNow-instance.LastUsedAt>=IdleTimeout))
                    await StopInstanceAsync(instance,CancellationToken.None);
            }
        }
        finally{_gate.Release();}
    }

    public async Task StopAllAsync()
    {
        await _gate.WaitAsync();
        try
        {
            ManagedHarnessInstance[] snapshot;lock(_instances) snapshot=_instances.Values.ToArray();
            foreach(var instance in snapshot) await StopInstanceAsync(instance,CancellationToken.None);
        }
        finally{_gate.Release();}
    }

    public object[] Snapshot()
    {
        lock(_instances) return _instances.Values.Select(x=>(object)new
        {
            adapter=x.Adapter,connection=x.ConnectionName,workingDirectory=x.WorkingDirectory,
            processId=x.Process.Id,baseUrl=x.BaseUrl,lastUsedAt=x.LastUsedAt.ToString("O"),endpointCount=x.EndpointIds.Count
        }).ToArray();
    }

    void Register(ManagedHarnessInstance instance,IReadOnlyList<HarnessModel> models)
    {
        var now=DateTimeOffset.UtcNow.ToString("O");
        var protectedPassword=Protect(instance.Password);
        string? startedAt=null;
        try{startedAt=new DateTimeOffset(instance.Process.StartTime.ToUniversalTime()).ToString("O");}catch{}

        _store.UpdateConnections(doc =>
        {
            doc.connections[instance.ConnectionName]=new ConnectionProfile
            {
                name=instance.ConnectionName,presetId="opencode-harness",protocol="opencode-server",
                baseUrl=instance.BaseUrl,modelsPath="/provider",discoveryKind="harness",authKind="basic",
                username=instance.Username,apiKeyProtected=protectedPassword,transient=true,
                managedBy=instance.ManagerKey,workingDirectory=instance.WorkingDirectory,
                processId=instance.Process.Id,processStartedAt=startedAt
            };
            return 0;
        });

        var desired=models.ToDictionary(m=>EndpointId(instance,m.Id),StringComparer.OrdinalIgnoreCase);
        _store.UpdateEndpoints(doc =>
        {
            foreach(var kv in doc.entries.ToArray())
                if(string.Equals(kv.Value.managedBy,instance.ManagerKey,StringComparison.OrdinalIgnoreCase)&&!desired.ContainsKey(kv.Key))
                    doc.entries.Remove(kv.Key);
            foreach(var model in models)
            {
                var id=EndpointId(instance,model.Id);
                doc.entries[id]=new EndpointEntry
                {
                    id=id,connection=instance.ConnectionName,model=model.Id,displayName="OpenCode · "+model.DisplayName,
                    enabled=true,workhorse=true,free=true,supportsTools=model.SupportsTools,contextLength=model.ContextLength,
                    toolMode="native",leaseCapacity=1,source="managed-harness",
                    rationale="Transient OpenCode harness capacity managed by StatefulClanker Router.",
                    managedBy=instance.ManagerKey,freeClass="confirmed_free",freeEvidence=model.Evidence,
                    lastSeenAt=now,updatedAt=now
                };
            }
            return 0;
        });
        instance.EndpointIds.Clear();foreach(var id in desired.Keys) instance.EndpointIds.Add(id);
    }

    async Task StopInstanceAsync(ManagedHarnessInstance instance,CancellationToken token)
    {
        if(_adapters.TryGetValue(instance.Adapter,out var adapter)) try{await adapter.StopAsync(instance,token);}catch{}
        Unregister(instance);lock(_instances) _instances.Remove(instance.Key);
    }

    void Unregister(ManagedHarnessInstance instance)
    {
        _store.UpdateEndpoints(doc =>
        {
            foreach(var kv in doc.entries.ToArray())
                if(string.Equals(kv.Value.managedBy,instance.ManagerKey,StringComparison.OrdinalIgnoreCase)) doc.entries.Remove(kv.Key);
            return 0;
        });
        _store.UpdateConnections(doc =>
        {
            if(doc.connections.TryGetValue(instance.ConnectionName,out var c)&&c.transient&&
               string.Equals(c.managedBy,instance.ManagerKey,StringComparison.OrdinalIgnoreCase))
                doc.connections.Remove(instance.ConnectionName);
            return 0;
        });
    }

    void CleanupStaleRegistrations()
    {
        var stale=_store.LoadConnections().connections
            .Where(x=>x.Value.transient&&!string.IsNullOrWhiteSpace(x.Value.managedBy)&&
                      x.Value.managedBy.StartsWith("harness:",StringComparison.OrdinalIgnoreCase)).ToArray();
        foreach(var kv in stale) TryKillStale(kv.Value);
        var names=stale.Select(x=>x.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var managers=stale.Select(x=>x.Value.managedBy!).ToHashSet(StringComparer.OrdinalIgnoreCase);
        _store.UpdateEndpoints(doc =>
        {
            foreach(var kv in doc.entries.ToArray())
                if(names.Contains(kv.Value.connection)||(kv.Value.managedBy is not null&&managers.Contains(kv.Value.managedBy)))
                    doc.entries.Remove(kv.Key);
            return 0;
        });
        _store.UpdateConnections(doc =>{foreach(var name in names) doc.connections.Remove(name);return 0;});
    }

    static void TryKillStale(ConnectionProfile profile)
    {
        if(profile.processId is null||profile.processId<=0) return;
        try
        {
            var process=Process.GetProcessById(profile.processId.Value);
            if(!string.IsNullOrWhiteSpace(profile.processStartedAt)&&DateTimeOffset.TryParse(profile.processStartedAt,out var expected))
            {
                var actual=new DateTimeOffset(process.StartTime.ToUniversalTime());
                if(Math.Abs((actual-expected).TotalSeconds)>2){process.Dispose();return;}
            }
            OpenCodeHarnessAdapter.TryKill(process);process.Dispose();
        }
        catch{}
    }

    static string EndpointId(ManagedHarnessInstance instance,string model) =>
        "harness-"+instance.Adapter+":"+WorkspaceHash(instance.WorkingDirectory)+":"+model;

    static string WorkspaceHash(string root) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(root).ToLowerInvariant()))).ToLowerInvariant()[..12];

    static string Protect(string value) =>
        Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(value),null,DataProtectionScope.CurrentUser));
}

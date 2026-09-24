using System.Diagnostics;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace StatefulClanker.Router;

internal sealed record HarnessModel(
    string Id,
    string DisplayName,
    bool Free,
    bool SupportsTools,
    long? ContextLength,
    string Evidence);

internal sealed class ManagedHarnessHost
{
    public required string Adapter { get; init; }
    public required string BaseUrl { get; init; }
    public required string Username { get; init; }
    public required string Password { get; init; }
    public required Process Process { get; init; }
    public DateTimeOffset LastUsedAt { get; set; }=DateTimeOffset.UtcNow;
}

internal sealed class ManagedHarnessRoute
{
    public required string Adapter { get; init; }
    public required string Key { get; init; }
    public required string ManagerKey { get; init; }
    public required string ConnectionName { get; init; }
    public required string WorkingDirectory { get; init; }
    public required ManagedHarnessHost Host { get; init; }
    public DateTimeOffset LastUsedAt { get; set; }=DateTimeOffset.UtcNow;
    public DateTimeOffset LastDiscoveredAt { get; set; }=DateTimeOffset.MinValue;
    public HashSet<string> EndpointIds { get; }=new(StringComparer.OrdinalIgnoreCase);
}

internal interface IHarnessAdapter
{
    string Kind { get; }
    Task<ManagedHarnessHost> StartAsync(CancellationToken token);
    Task<IReadOnlyList<HarnessModel>> DiscoverAsync(ManagedHarnessHost host,string workingDirectory,CancellationToken token);
    Task<bool> ProbeAsync(ManagedHarnessHost host,CancellationToken token);
    Task StopAsync(ManagedHarnessHost host,CancellationToken token);
}

internal sealed class OpenCodeHarnessAdapter : IHarnessAdapter
{
    readonly HttpClient _http=new(){Timeout=TimeSpan.FromSeconds(8)};
    public string Kind => "opencode";

    public async Task<ManagedHarnessHost> StartAsync(CancellationToken token)
    {
        var port=FreePort();
        var password=Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
        const string username="opencode";
        var executable=ResolveExecutable();
        var process=Process.Start(NewStartInfo(executable,port,password,username))
            ?? throw new InvalidOperationException("OpenCode process did not start.");
        var host=new ManagedHarnessHost
        {
            Adapter=Kind,
            BaseUrl=$"http://127.0.0.1:{port}",
            Username=username,
            Password=password,
            Process=process
        };

        try
        {
            var deadline=DateTimeOffset.UtcNow.AddSeconds(25);
            while(DateTimeOffset.UtcNow<deadline)
            {
                token.ThrowIfCancellationRequested();
                if(process.HasExited)
                    throw new InvalidOperationException($"opencode serve exited during startup with code {process.ExitCode}.");
                if(await ProbeAsync(host,token)) return host;
                await Task.Delay(250,token);
            }
            throw new TimeoutException("opencode serve did not become healthy within 25 seconds.");
        }
        catch
        {
            TryKill(process);
            process.Dispose();
            throw;
        }
    }

    public async Task<IReadOnlyList<HarnessModel>> DiscoverAsync(ManagedHarnessHost host,string workingDirectory,CancellationToken token)
    {
        try
        {
            using var request=Request(HttpMethod.Get,host,"/api/model",workingDirectory);
            using var response=await _http.SendAsync(request,HttpCompletionOption.ResponseContentRead,token);
            if(response.IsSuccessStatusCode)
            {
                using var doc=JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
                var models=ParseV2Models(doc.RootElement);
                if(models.Count>0) return models;
            }
        }
        catch(OperationCanceledException) when(token.IsCancellationRequested){throw;}
        catch { }

        // Compatibility path for OpenCode 1.x / legacy server surfaces.
        using var legacyRequest=Request(HttpMethod.Get,host,"/provider",workingDirectory);
        using var legacyResponse=await _http.SendAsync(legacyRequest,HttpCompletionOption.ResponseContentRead,token);
        legacyResponse.EnsureSuccessStatusCode();
        using var legacyDoc=JsonDocument.Parse(await legacyResponse.Content.ReadAsStringAsync(token));
        return ParseLegacyModels(legacyDoc.RootElement);
    }

    static List<HarnessModel> ParseV2Models(JsonElement root)
    {
        JsonElement models;
        if(root.ValueKind==JsonValueKind.Object && root.TryGetProperty("data",out var data)) models=data;
        else models=root;
        if(models.ValueKind!=JsonValueKind.Array) return [];

        var output=new List<HarnessModel>();
        foreach(var model in models.EnumerateArray())
        {
            if(model.ValueKind!=JsonValueKind.Object) continue;
            var providerId=String(model,"providerID") ?? String(model,"providerId");
            if(!string.Equals(providerId,"opencode",StringComparison.OrdinalIgnoreCase)) continue;
            var id=String(model,"id") ?? String(model,"modelID");
            if(string.IsNullOrWhiteSpace(id)) continue;
            AddModel(output,providerId!,id!,model);
        }
        return Deduplicate(output);
    }

    static List<HarnessModel> ParseLegacyModels(JsonElement root)
    {
        if(root.ValueKind!=JsonValueKind.Object ||
           !root.TryGetProperty("all",out var providers) ||
           providers.ValueKind!=JsonValueKind.Array) return [];

        var output=new List<HarnessModel>();
        foreach(var provider in providers.EnumerateArray())
        {
            if(provider.ValueKind!=JsonValueKind.Object) continue;
            var providerId=String(provider,"id") ?? String(provider,"providerID");
            if(!string.Equals(providerId,"opencode",StringComparison.OrdinalIgnoreCase)) continue;
            if(!provider.TryGetProperty("models",out var models)) continue;

            if(models.ValueKind==JsonValueKind.Object)
            {
                foreach(var property in models.EnumerateObject())
                    AddModel(output,providerId!,property.Name,property.Value);
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
        return Deduplicate(output);
    }

    static void AddModel(List<HarnessModel> output,string providerId,string modelId,JsonElement model)
    {
        if(model.ValueKind!=JsonValueKind.Object) return;
        if(model.TryGetProperty("enabled",out var enabled) && enabled.ValueKind==JsonValueKind.False) return;
        if(string.Equals(String(model,"status"),"deprecated",StringComparison.OrdinalIgnoreCase)) return;

        var explicitFree=modelId.EndsWith("-free",StringComparison.OrdinalIgnoreCase);
        var zeroCost=model.TryGetProperty("cost",out var cost) && ZeroCost(cost);
        if(!explicitFree && !zeroCost) return;

        var supportsTools=true;
        if(model.TryGetProperty("capabilities",out var caps) && caps.ValueKind==JsonValueKind.Object &&
           caps.TryGetProperty("tools",out var toolValue) &&
           (toolValue.ValueKind==JsonValueKind.True || toolValue.ValueKind==JsonValueKind.False))
            supportsTools=toolValue.GetBoolean();

        long? context=null;
        if(model.TryGetProperty("limit",out var limit) && limit.ValueKind==JsonValueKind.Object &&
           limit.TryGetProperty("context",out var contextValue) && contextValue.TryGetInt64(out var parsedContext))
            context=parsedContext;

        output.Add(new HarnessModel(
            providerId+"/"+modelId,
            String(model,"name") ?? modelId,
            true,
            supportsTools,
            context,
            explicitFree
                ? "OpenCode model id explicitly selects a free route."
                : "OpenCode live model catalog reports zero input/output cost."));
    }

    static List<HarnessModel> Deduplicate(List<HarnessModel> models) =>
        models.GroupBy(x=>x.Id,StringComparer.OrdinalIgnoreCase)
              .Select(x=>x.First())
              .OrderBy(x=>x.DisplayName,StringComparer.OrdinalIgnoreCase)
              .ToList();

    static bool ZeroCost(JsonElement cost)
    {
        if(cost.ValueKind==JsonValueKind.Object) return ZeroCostObject(cost);
        if(cost.ValueKind!=JsonValueKind.Array) return false;
        var any=false;
        foreach(var tier in cost.EnumerateArray())
        {
            if(tier.ValueKind!=JsonValueKind.Object) return false;
            any=true;
            if(!ZeroCostObject(tier)) return false;
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

    public async Task<bool> ProbeAsync(ManagedHarnessHost host,CancellationToken token)
    {
        foreach(var path in new[]{"/api/health","/global/health"})
        {
            try
            {
                using var request=Request(HttpMethod.Get,host,path,null);
                using var response=await _http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,token);
                if(response.IsSuccessStatusCode) return true;
            }
            catch(OperationCanceledException) when(token.IsCancellationRequested){throw;}
            catch { }
        }
        return false;
    }

    public async Task StopAsync(ManagedHarnessHost host,CancellationToken token)
    {
        try
        {
            using var request=Request(HttpMethod.Post,host,"/instance/dispose",null);
            using var response=await _http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,token);
        }
        catch { }
        TryKill(host.Process);
        host.Process.Dispose();
    }

    static HttpRequestMessage Request(HttpMethod method,ManagedHarnessHost host,string path,string? workingDirectory)
    {
        var request=new HttpRequestMessage(method,host.BaseUrl.TrimEnd('/')+path);
        var raw=Convert.ToBase64String(Encoding.UTF8.GetBytes(host.Username+":"+host.Password));
        request.Headers.Authorization=new AuthenticationHeaderValue("Basic",raw);
        if(!string.IsNullOrWhiteSpace(workingDirectory))
            request.Headers.TryAddWithoutValidation("x-opencode-directory",workingDirectory);
        return request;
    }

    static string? String(JsonElement element,string name) =>
        element.TryGetProperty(name,out var value) && value.ValueKind==JsonValueKind.String ? value.GetString() : null;

    static int FreePort()
    {
        var listener=new TcpListener(System.Net.IPAddress.Loopback,0);
        listener.Start();
        try{return ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;}
        finally{listener.Stop();}
    }

    static string ResolveExecutable()
    {
        var configured=Environment.GetEnvironmentVariable("SC_OPENCODE_EXE");
        if(!string.IsNullOrWhiteSpace(configured)) return configured;

        var path=Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach(var root in path.Split(Path.PathSeparator,StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries))
        {
            foreach(var name in OperatingSystem.IsWindows()
                ? new[]{"opencode.exe","opencode.cmd","opencode.bat","opencode"}
                : new[]{"opencode"})
            {
                try
                {
                    var candidate=Path.Combine(root,name);
                    if(File.Exists(candidate)) return candidate;
                }
                catch { }
            }
        }
        return "opencode";
    }

    static ProcessStartInfo NewStartInfo(string executable,int port,string password,string username)
    {
        var psi=new ProcessStartInfo
        {
            UseShellExecute=false,
            CreateNoWindow=true,
            WorkingDirectory=Path.GetTempPath()
        };
        var ext=Path.GetExtension(executable);
        if(OperatingSystem.IsWindows() &&
           (ext.Equals(".cmd",StringComparison.OrdinalIgnoreCase) || ext.Equals(".bat",StringComparison.OrdinalIgnoreCase)))
        {
            psi.FileName=Environment.GetEnvironmentVariable("COMSPEC") ?? "cmd.exe";
            psi.ArgumentList.Add("/d");
            psi.ArgumentList.Add("/s");
            psi.ArgumentList.Add("/c");
            psi.ArgumentList.Add($"\"{executable}\" serve --hostname 127.0.0.1 --port {port}");
        }
        else
        {
            psi.FileName=executable;
            psi.ArgumentList.Add("serve");
            psi.ArgumentList.Add("--hostname");
            psi.ArgumentList.Add("127.0.0.1");
            psi.ArgumentList.Add("--port");
            psi.ArgumentList.Add(port.ToString());
        }
        psi.Environment["OPENCODE_SERVER_PASSWORD"]=password;
        psi.Environment["OPENCODE_SERVER_USERNAME"]=username;
        return psi;
    }

    internal static void TryKill(Process process)
    {
        try{if(!process.HasExited) process.Kill(entireProcessTree:true);}catch{}
    }
}

public sealed class HarnessAdapterManager
{
    readonly RouterEngine _engine;
    readonly RouterStore _store;
    readonly Dictionary<string,IHarnessAdapter> _adapters;
    readonly Dictionary<string,ManagedHarnessHost> _hosts=new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string,ManagedHarnessRoute> _routes=new(StringComparer.OrdinalIgnoreCase);
    readonly SemaphoreSlim _gate=new(1,1);

    static readonly TimeSpan RouteIdleTimeout=TimeSpan.FromMinutes(15);
    static readonly TimeSpan DiscoveryInterval=TimeSpan.FromMinutes(5);

    public HarnessAdapterManager(RouterEngine engine)
    {
        _engine=engine;
        _store=engine.Store;
        _adapters=new(StringComparer.OrdinalIgnoreCase)
        {
            ["opencode"]=new OpenCodeHarnessAdapter()
        };
        CleanupStaleRegistrations();
    }

    public async Task<RouterResponse> EnsureAsync(string? adapterName,string? workingDirectory,CancellationToken token=default)
    {
        if(string.IsNullOrWhiteSpace(adapterName))
            return RouterResponse.Fail("Harness adapter name is required.");
        if(!_adapters.TryGetValue(adapterName,out var adapter))
            return RouterResponse.Fail("Unknown harness adapter: "+adapterName);
        if(string.IsNullOrWhiteSpace(workingDirectory))
            return RouterResponse.Fail("Managed harness requires --working-directory.");

        string root;
        try
        {
            root=Path.GetFullPath(workingDirectory)
                .TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
        }
        catch(Exception ex)
        {
            return RouterResponse.Fail("Invalid harness working directory: "+ex.Message);
        }
        if(!Directory.Exists(root))
            return RouterResponse.Fail("Harness working directory does not exist: "+root);

        await _gate.WaitAsync(token);
        try
        {
            var host=await EnsureHostAsync(adapter,token);
            if(host is null) return RouterResponse.Fail($"Could not start {adapter.Kind} harness.");

            var key=adapter.Kind+"|"+root.ToLowerInvariant();
            var hash=WorkspaceHash(root);
            var managerKey="harness:"+adapter.Kind+":"+hash;
            var connectionName="internal-"+adapter.Kind+"-"+hash;

            if(!_routes.TryGetValue(key,out var route))
            {
                route=new ManagedHarnessRoute
                {
                    Adapter=adapter.Kind,
                    Key=key,
                    ManagerKey=managerKey,
                    ConnectionName=connectionName,
                    WorkingDirectory=root,
                    Host=host
                };
                _routes[key]=route;
            }

            route.LastUsedAt=DateTimeOffset.UtcNow;
            host.LastUsedAt=route.LastUsedAt;

            if(route.LastDiscoveredAt==DateTimeOffset.MinValue ||
               DateTimeOffset.UtcNow-route.LastDiscoveredAt>=DiscoveryInterval ||
               route.EndpointIds.Count==0)
            {
                IReadOnlyList<HarnessModel> models;
                try
                {
                    models=await adapter.DiscoverAsync(host,root,token);
                }
                catch(Exception ex)
                {
                    return RouterResponse.Fail($"{adapter.Kind} harness catalog failed: {ex.Message}");
                }
                Register(route,models.Where(x=>x.Free).ToList());
                route.LastDiscoveredAt=DateTimeOffset.UtcNow;
            }

            _engine.MarkHealthy("connection:"+route.ConnectionName);
            foreach(var endpoint in route.EndpointIds)
                _engine.MarkHealthy("pool:"+endpoint);

            return RouterResponse.Ok(new
            {
                adapter=route.Adapter,
                connection=route.ConnectionName,
                workingDirectory=route.WorkingDirectory,
                baseUrl=host.BaseUrl,
                processId=host.Process.Id,
                eligibleEndpoints=route.EndpointIds.Count,
                endpoints=route.EndpointIds
                    .OrderBy(x=>x,StringComparer.OrdinalIgnoreCase)
                    .Select(x=>"pool:"+x)
                    .ToArray()
            });
        }
        finally
        {
            _gate.Release();
        }
    }

    async Task<ManagedHarnessHost?> EnsureHostAsync(IHarnessAdapter adapter,CancellationToken token)
    {
        if(_hosts.TryGetValue(adapter.Kind,out var existing))
        {
            if(!existing.Process.HasExited)
            {
                existing.LastUsedAt=DateTimeOffset.UtcNow;
                return existing;
            }

            RemoveRoutesForHost(existing);
            try{existing.Process.Dispose();}catch{}
            _hosts.Remove(adapter.Kind);
        }

        try
        {
            var host=await adapter.StartAsync(token);
            _hosts[adapter.Kind]=host;
            return host;
        }
        catch
        {
            return null;
        }
    }

    public async Task RunAsync(CancellationToken token)
    {
        while(!token.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(20),token);
                await ReapIdleAsync(token);
            }
            catch(OperationCanceledException) when(token.IsCancellationRequested)
            {
                break;
            }
            catch { }
        }
    }

    async Task ReapIdleAsync(CancellationToken token)
    {
        await _gate.WaitAsync(token);
        try
        {
            foreach(var host in _hosts.Values.Where(x=>x.Process.HasExited).ToArray())
            {
                RemoveRoutesForHost(host);
                try{host.Process.Dispose();}catch{}
                _hosts.Remove(host.Adapter);
            }

            foreach(var route in _routes.Values.ToArray())
            {
                var leased=route.EndpointIds.Any(id=>_engine.IsLeased("pool:"+id));
                if(!leased && DateTimeOffset.UtcNow-route.LastUsedAt>=RouteIdleTimeout)
                {
                    Unregister(route);
                    _routes.Remove(route.Key);
                }
            }

            foreach(var host in _hosts.Values.ToArray())
            {
                var hasRoutes=_routes.Values.Any(x=>ReferenceEquals(x.Host,host));
                if(hasRoutes) continue;
                if(_adapters.TryGetValue(host.Adapter,out var adapter))
                {
                    try{await adapter.StopAsync(host,CancellationToken.None);}catch{}
                }
                _hosts.Remove(host.Adapter);
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task StopAllAsync()
    {
        await _gate.WaitAsync();
        try
        {
            foreach(var route in _routes.Values.ToArray())
                Unregister(route);
            _routes.Clear();

            foreach(var host in _hosts.Values.ToArray())
            {
                if(_adapters.TryGetValue(host.Adapter,out var adapter))
                {
                    try{await adapter.StopAsync(host,CancellationToken.None);}catch{}
                }
            }
            _hosts.Clear();
        }
        finally
        {
            _gate.Release();
        }
    }

    public object Snapshot()
    {
        return new
        {
            hosts=_hosts.Values.Select(x=>new
            {
                adapter=x.Adapter,
                processId=x.Process.Id,
                baseUrl=x.BaseUrl,
                lastUsedAt=x.LastUsedAt.ToString("O")
            }).ToArray(),
            routes=_routes.Values.Select(x=>new
            {
                adapter=x.Adapter,
                connection=x.ConnectionName,
                workingDirectory=x.WorkingDirectory,
                lastUsedAt=x.LastUsedAt.ToString("O"),
                endpointCount=x.EndpointIds.Count
            }).ToArray()
        };
    }

    void Register(ManagedHarnessRoute route,IReadOnlyList<HarnessModel> models)
    {
        var now=DateTimeOffset.UtcNow.ToString("O");
        var protectedPassword=Protect(route.Host.Password);
        string? startedAt=null;
        try
        {
            startedAt=new DateTimeOffset(route.Host.Process.StartTime.ToUniversalTime()).ToString("O");
        }
        catch { }

        _store.UpdateConnections(doc =>
        {
            doc.connections[route.ConnectionName]=new ConnectionProfile
            {
                name=route.ConnectionName,
                presetId="opencode-harness",
                protocol="opencode-server",
                baseUrl=route.Host.BaseUrl,
                modelsPath="/api/model",
                discoveryKind="harness",
                authKind="basic",
                username=route.Host.Username,
                apiKeyProtected=protectedPassword,
                transient=true,
                managedBy=route.ManagerKey,
                workingDirectory=route.WorkingDirectory,
                processId=route.Host.Process.Id,
                processStartedAt=startedAt,
                headers=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase)
                {
                    ["x-opencode-directory"]=route.WorkingDirectory
                }
            };
            return 0;
        });

        var desired=models.ToDictionary(m=>EndpointId(route,m.Id),StringComparer.OrdinalIgnoreCase);
        _store.UpdateEndpoints(doc =>
        {
            foreach(var kv in doc.entries.ToArray())
            {
                if(string.Equals(kv.Value.managedBy,route.ManagerKey,StringComparison.OrdinalIgnoreCase) &&
                   !desired.ContainsKey(kv.Key))
                    doc.entries.Remove(kv.Key);
            }

            foreach(var model in models)
            {
                var id=EndpointId(route,model.Id);
                doc.entries[id]=new EndpointEntry
                {
                    id=id,
                    connection=route.ConnectionName,
                    model=model.Id,
                    displayName="OpenCode · "+model.DisplayName,
                    enabled=true,
                    workhorse=true,
                    free=true,
                    supportsTools=model.SupportsTools,
                    contextLength=model.ContextLength,
                    toolMode="native",
                    leaseCapacity=1,
                    source="managed-harness",
                    rationale="Transient workspace route through router-owned OpenCode.",
                    managedBy=route.ManagerKey,
                    freeClass="confirmed_free",
                    freeEvidence=model.Evidence,
                    lastSeenAt=now,
                    updatedAt=now
                };
            }
            return 0;
        });

        route.EndpointIds.Clear();
        foreach(var id in desired.Keys) route.EndpointIds.Add(id);
    }

    void RemoveRoutesForHost(ManagedHarnessHost host)
    {
        foreach(var route in _routes.Values.Where(x=>ReferenceEquals(x.Host,host)).ToArray())
        {
            Unregister(route);
            _routes.Remove(route.Key);
        }
    }

    void Unregister(ManagedHarnessRoute route)
    {
        _store.UpdateEndpoints(doc =>
        {
            foreach(var kv in doc.entries.ToArray())
            {
                if(string.Equals(kv.Value.managedBy,route.ManagerKey,StringComparison.OrdinalIgnoreCase))
                    doc.entries.Remove(kv.Key);
            }
            return 0;
        });

        _store.UpdateConnections(doc =>
        {
            if(doc.connections.TryGetValue(route.ConnectionName,out var connection) &&
               connection.transient &&
               string.Equals(connection.managedBy,route.ManagerKey,StringComparison.OrdinalIgnoreCase))
                doc.connections.Remove(route.ConnectionName);
            return 0;
        });
    }

    void CleanupStaleRegistrations()
    {
        var stale=_store.LoadConnections().connections
            .Where(x=>x.Value.transient &&
                      !string.IsNullOrWhiteSpace(x.Value.managedBy) &&
                      x.Value.managedBy.StartsWith("harness:",StringComparison.OrdinalIgnoreCase))
            .ToArray();

        foreach(var profile in stale.Select(x=>x.Value)
                    .Where(x=>x.processId is not null)
                    .GroupBy(x=>new{x.processId,x.processStartedAt})
                    .Select(x=>x.First()))
            TryKillStale(profile);

        var names=stale.Select(x=>x.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var managers=stale.Select(x=>x.Value.managedBy!).ToHashSet(StringComparer.OrdinalIgnoreCase);

        _store.UpdateEndpoints(doc =>
        {
            foreach(var kv in doc.entries.ToArray())
            {
                if(names.Contains(kv.Value.connection) ||
                   (kv.Value.managedBy is not null && managers.Contains(kv.Value.managedBy)))
                    doc.entries.Remove(kv.Key);
            }
            return 0;
        });

        _store.UpdateConnections(doc =>
        {
            foreach(var name in names) doc.connections.Remove(name);
            return 0;
        });
    }

    static void TryKillStale(ConnectionProfile profile)
    {
        if(profile.processId is null || profile.processId<=0) return;
        try
        {
            var process=Process.GetProcessById(profile.processId.Value);
            if(!string.IsNullOrWhiteSpace(profile.processStartedAt) &&
               DateTimeOffset.TryParse(profile.processStartedAt,out var expected))
            {
                var actual=new DateTimeOffset(process.StartTime.ToUniversalTime());
                if(Math.Abs((actual-expected).TotalSeconds)>2)
                {
                    process.Dispose();
                    return;
                }
            }
            OpenCodeHarnessAdapter.TryKill(process);
            process.Dispose();
        }
        catch { }
    }

    static string EndpointId(ManagedHarnessRoute route,string model) =>
        "harness-"+route.Adapter+":"+WorkspaceHash(route.WorkingDirectory)+":"+model;

    static string WorkspaceHash(string root) =>
        Convert.ToHexString(SHA256.HashData(
            Encoding.UTF8.GetBytes(Path.GetFullPath(root).ToLowerInvariant())))
            .ToLowerInvariant()[..12];

    static string Protect(string value) =>
        Convert.ToBase64String(ProtectedData.Protect(
            Encoding.UTF8.GetBytes(value),null,DataProtectionScope.CurrentUser));
}

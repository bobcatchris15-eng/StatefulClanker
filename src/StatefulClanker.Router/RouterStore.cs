using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace StatefulClanker.Router;

public sealed class RouterStore
{
    static readonly JsonSerializerOptions Json = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    public string Root { get; }
    public string EndpointPath => Path.Combine(Root, "endpoints.json");
    public string ConnectionPath => Path.Combine(Root, "connections.json");
    public string RoutingDir => Path.Combine(Root, "routing");
    public string HealthPath => Path.Combine(RoutingDir, "health.json");
    public string CursorPath => Path.Combine(RoutingDir, "round-robin.json");
    public string LeasePath => Path.Combine(RoutingDir, "leases.json");
    public string CapacityDiscoveryPath => Path.Combine(RoutingDir, "free-capacity.json");

    readonly Mutex _mutex;

    public RouterStore(string? root=null)
    {
        Root = root ?? Environment.GetEnvironmentVariable("SC_ROUTER_ROOT")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StatefulClanker");
        Directory.CreateDirectory(RoutingDir);
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Root))).ToLowerInvariant()[..16];
        _mutex = new Mutex(false, "Local\\StatefulClankerRouterState-" + hash);
    }

    T WithLock<T>(Func<T> action)
    {
        var held=false;
        try
        {
            try { held=_mutex.WaitOne(TimeSpan.FromSeconds(10)); }
            catch (AbandonedMutexException) { held=true; }
            if(!held) throw new TimeoutException("Timed out waiting for router state lock.");
            return action();
        }
        finally { if(held) try{_mutex.ReleaseMutex();}catch{} }
    }

    public EndpointCatalog LoadEndpoints() => WithLock(() => Load<EndpointCatalog>(EndpointPath) ?? new());
    public ConnectionDocument LoadConnections() => WithLock(() => Load<ConnectionDocument>(ConnectionPath) ?? new());
    public RoutingHealthDocument LoadHealth() => WithLock(() => Load<RoutingHealthDocument>(HealthPath) ?? new());
    public RoundRobinDocument LoadCursor() => WithLock(() => Load<RoundRobinDocument>(CursorPath) ?? new());
    public LeaseDocument LoadLeases() => WithLock(() => Load<LeaseDocument>(LeasePath) ?? new());
    public CapacityDiscoveryDocument LoadCapacityDiscovery() => WithLock(() => Load<CapacityDiscoveryDocument>(CapacityDiscoveryPath) ?? new());

    public void SaveEndpoints(EndpointCatalog doc) => WithLock(() => { doc.updatedAt=DateTimeOffset.UtcNow.ToString("O"); Save(EndpointPath,doc); return 0; });
    public void SaveConnections(ConnectionDocument doc) => WithLock(() => { doc.schemaVersion=Math.Max(doc.schemaVersion,3); Save(ConnectionPath,doc); return 0; });
    public void SaveHealth(RoutingHealthDocument doc) => WithLock(() => { Save(HealthPath, doc); return 0; });
    public void SaveCursor(RoundRobinDocument doc) => WithLock(() => { Save(CursorPath, doc); return 0; });
    public void SaveLeases(LeaseDocument doc) => WithLock(() => { doc.updatedAt=DateTimeOffset.UtcNow.ToString("O"); Save(LeasePath,doc); return 0; });
    public void SaveCapacityDiscovery(CapacityDiscoveryDocument doc) => WithLock(() => { doc.updatedAt=DateTimeOffset.UtcNow.ToString("O"); Save(CapacityDiscoveryPath,doc); return 0; });

    public TResult UpdateEndpoints<TResult>(Func<EndpointCatalog,TResult> update) =>
        WithLock(() => { var doc=Load<EndpointCatalog>(EndpointPath) ?? new(); var r=update(doc); doc.updatedAt=DateTimeOffset.UtcNow.ToString("O"); Save(EndpointPath,doc); return r; });

    public TResult UpdateConnections<TResult>(Func<ConnectionDocument,TResult> update) =>
        WithLock(() => { var doc=Load<ConnectionDocument>(ConnectionPath) ?? new(); var r=update(doc); doc.schemaVersion=Math.Max(doc.schemaVersion,3); Save(ConnectionPath,doc); return r; });

    public TResult UpdateHealth<TResult>(Func<RoutingHealthDocument,TResult> update) =>
        WithLock(() => { var doc=Load<RoutingHealthDocument>(HealthPath) ?? new(); var r=update(doc); Save(HealthPath,doc); return r; });

    public TResult UpdateCursor<TResult>(Func<RoundRobinDocument,TResult> update) =>
        WithLock(() => { var doc=Load<RoundRobinDocument>(CursorPath) ?? new(); var r=update(doc); doc.updatedAt=DateTimeOffset.UtcNow.ToString("O"); Save(CursorPath,doc); return r; });

    public TResult UpdateLeases<TResult>(Func<LeaseDocument,TResult> update) =>
        WithLock(() => { var doc=Load<LeaseDocument>(LeasePath) ?? new(); var r=update(doc); doc.updatedAt=DateTimeOffset.UtcNow.ToString("O"); Save(LeasePath,doc); return r; });

    public TResult UpdateCapacityDiscovery<TResult>(Func<CapacityDiscoveryDocument,TResult> update) =>
        WithLock(() => { var doc=Load<CapacityDiscoveryDocument>(CapacityDiscoveryPath) ?? new(); var r=update(doc); doc.updatedAt=DateTimeOffset.UtcNow.ToString("O"); Save(CapacityDiscoveryPath,doc); return r; });

    public string ConnectionFingerprint(ConnectionProfile profile)
    {
        var canonical = JsonSerializer.Serialize(new
        {
            profile.presetId, profile.protocol, profile.baseUrl, profile.modelsPath,
            profile.discoveryKind, profile.authKind, profile.accountId, profile.apiKeyProtected,
            profile.apiKeyEnv, profile.username, profile.transient, profile.managedBy, profile.workingDirectory,
            headers=profile.headers.OrderBy(x=>x.Key,StringComparer.OrdinalIgnoreCase)
        });
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical))).ToLowerInvariant();
    }

    static T? Load<T>(string path)
    {
        if(!File.Exists(path)) return default;
        try { return JsonSerializer.Deserialize<T>(File.ReadAllText(path),Json); }
        catch { return default; }
    }

    static void Save<T>(string path,T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var tmp=path+".tmp-"+Guid.NewGuid().ToString("N");
        File.WriteAllText(tmp,JsonSerializer.Serialize(value,Json),new UTF8Encoding(false));
        File.Move(tmp,path,true);
    }
}

using System.Collections.Concurrent;

namespace StatefulClanker.Router;

public sealed class RouterEngine
{
    readonly RouterStore _store;
    readonly object _leaseLock = new();
    readonly Dictionary<string,LeaseRecord> _leasesByToken = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string,string> _tokenByRoute = new(StringComparer.OrdinalIgnoreCase);

    public RouterEngine(RouterStore store)
    {
        _store=store;
        RestoreLeases();
        ReapExpiredLeases();
    }
    public RouterStore Store => _store;

    public IReadOnlyList<EndpointRoute> Routes()
    {
        var catalog=_store.LoadEndpoints();
        var connections=_store.LoadConnections().connections;
        return catalog.entries
            .Where(kv=>kv.Value.enabled && kv.Value.workhorse)
            .Select(kv =>
            {
                var e=kv.Value;
                var id=string.IsNullOrWhiteSpace(e.id)?kv.Key:e.id;
                connections.TryGetValue(e.connection,out var c);
                var service=ServiceName(c);
                return new EndpointRoute("pool:"+id,id,e,c,service);
            })
            .Where(r=>!string.Equals(r.Endpoint.toolMode,"native",StringComparison.OrdinalIgnoreCase) || r.Endpoint.supportsTools==true)
            .OrderBy(r=>r.RouteName,StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public RouterResponse Acquire(string? preferred,string? sessionId,bool requireTools,int ownerPid=0)
    {
        ReapExpiredLeases();
        var health=_store.LoadHealth();
        var routes=Routes()
            .Where(r=>!requireTools || (r.Endpoint.supportsTools==true && string.Equals(r.Endpoint.toolMode,"native",StringComparison.OrdinalIgnoreCase)))
            .Where(r=>Available(r,health))
            .ToList();

        if(routes.Count==0)
            return RouterResponse.Fail("No healthy eligible endpoint is available.",new { nextRetryAt=NextRetryAt(health) });

        EndpointRoute? selected=null;
        if(!string.IsNullOrWhiteSpace(preferred))
        {
            selected=routes.FirstOrDefault(r=>
                string.Equals(r.RouteName,preferred,StringComparison.OrdinalIgnoreCase) ||
                string.Equals(r.CatalogId,preferred,StringComparison.OrdinalIgnoreCase));
            if(selected is not null && IsLeased(selected.RouteName)) selected=null;
        }

        if(selected is null)
        {
            var cursor=_store.LoadCursor().cursor;
            cursor=((cursor%routes.Count)+routes.Count)%routes.Count;
            for(var offset=0;offset<routes.Count;offset++)
            {
                var candidate=routes[(cursor+offset)%routes.Count];
                if(!IsLeased(candidate.RouteName))
                {
                    selected=candidate;
                    var selectedIndex=(cursor+offset)%routes.Count;
                    _store.UpdateCursor(d=>{d.cursor=(selectedIndex+1)%routes.Count;return 0;});
                    break;
                }
            }
        }

        if(selected is null)
            return RouterResponse.Fail("All healthy eligible endpoints are currently leased.",new { retryAfterSeconds=2 });

        var lease=new LeaseRecord
        {
            route=selected.RouteName,
            catalogId=selected.CatalogId,
            connection=selected.Endpoint.connection,
            model=selected.Endpoint.model,
            sessionId=sessionId,
            ownerPid=ownerPid,
            ownerStartedAt=OwnerStartedAt(ownerPid),
            acquiredAt=DateTimeOffset.UtcNow.ToString("O"),
            expiresAt=DateTimeOffset.UtcNow.AddMinutes(45).ToString("O")
        };

        lock(_leaseLock)
        {
            _leasesByToken[lease.token]=lease;
            _tokenByRoute[lease.route]=lease.token;
            PersistLeasesLocked();
        }

        return RouterResponse.Ok(new
        {
            lease=lease.token,
            endpoint=lease.route,
            catalogId=lease.catalogId,
            connection=lease.connection,
            model=lease.model,
            toolMode=selected.Endpoint.toolMode,
            supportsTools=selected.Endpoint.supportsTools,
            contextLength=selected.Endpoint.contextLength,
            preferredHonored=!string.IsNullOrWhiteSpace(preferred) &&
                (string.Equals(selected.RouteName,preferred,StringComparison.OrdinalIgnoreCase) ||
                 string.Equals(selected.CatalogId,preferred,StringComparison.OrdinalIgnoreCase)),
            expiresAt=lease.expiresAt
        });
    }

    public RouterResponse Release(string? token)
    {
        if(string.IsNullOrWhiteSpace(token)) return RouterResponse.Fail("lease is required.");
        LeaseRecord? lease=null;
        lock(_leaseLock)
        {
            if(_leasesByToken.Remove(token,out lease) && lease is not null)
            {
                _tokenByRoute.Remove(lease.route);
                PersistLeasesLocked();
            }
        }
        return lease is null ? RouterResponse.Fail("Lease was not found.") : RouterResponse.Ok(new { released=lease.route });
    }

    public RouterResponse Heartbeat(string? token)
    {
        if(string.IsNullOrWhiteSpace(token)) return RouterResponse.Fail("lease is required.");
        lock(_leaseLock)
        {
            if(!_leasesByToken.TryGetValue(token,out var lease)) return RouterResponse.Fail("Lease was not found.");
            lease.expiresAt=DateTimeOffset.UtcNow.AddMinutes(45).ToString("O");
            PersistLeasesLocked();
            return RouterResponse.Ok(new { endpoint=lease.route,expiresAt=lease.expiresAt });
        }
    }

    public RouterResponse Success(string? token,string? endpoint=null)
    {
        var route=ResolveRoute(token,endpoint,out var lease);
        if(route is null) return RouterResponse.Fail("A valid lease or endpoint is required.");
        MarkHealthy(route.RouteName);
        MarkHealthy("connection:"+route.Endpoint.connection);
        if(!string.IsNullOrWhiteSpace(route.Service)) MarkHealthy("service:"+route.Service);
        if(lease is not null) Release(lease.token);
        return RouterResponse.Ok(new { endpoint=route.RouteName,state="healthy" });
    }

    public RouterResponse Failure(string? token,string? endpoint,string? failureClass,string? message)
    {
        var route=ResolveRoute(token,endpoint,out var lease);
        if(route is null) return RouterResponse.Fail("A valid lease or endpoint is required.");

        var klass=string.IsNullOrWhiteSpace(failureClass)?FailurePolicy.Classify(message):failureClass!;
        var scope=FailurePolicy.ScopeFor(klass);
        if(scope=="request")
        {
            if(lease is not null) Release(lease.token);
            return RouterResponse.Ok(new { endpoint=route.RouteName,failureClass=klass,scope,healthChanged=false });
        }

        var key=scope=="connection" ? "connection:"+route.Endpoint.connection : route.RouteName;
        var entry=RegisterFailureKey(key,scope,klass,message,route.Connection);

        if(scope=="connection" && (klass=="timeout" || klass=="server_error") && !string.IsNullOrWhiteSpace(route.Service))
            MaybeDegradeService(route.Service!,route.Endpoint.connection,klass,message);

        if(lease is not null) Release(lease.token);
        return RouterResponse.Ok(new
        {
            endpoint=route.RouteName,key,scope,failureClass=klass,
            state=entry.state,retryAfter=entry.retryAfter,nextProbeAt=entry.nextProbeAt,quota=entry.quota
        });
    }

    public object Snapshot()
    {
        ReapExpiredLeases();
        var health=_store.LoadHealth();
        var routes=Routes();
        Dictionary<string,LeaseRecord> leases;
        lock(_leaseLock) leases=_leasesByToken.ToDictionary(x=>x.Key,x=>x.Value,StringComparer.OrdinalIgnoreCase);
        var leaseRoutes=leases.Values.ToDictionary(x=>x.route,x=>x,StringComparer.OrdinalIgnoreCase);
        var eligible=routes.Where(r=>Available(r,health)).ToList();
        var cursor=eligible.Count==0?0:Math.Abs(_store.LoadCursor().cursor%eligible.Count);
        EndpointRoute? next=null;
        for(var i=0;i<eligible.Count;i++)
        {
            var candidate=eligible[(cursor+i)%eligible.Count];
            if(!leaseRoutes.ContainsKey(candidate.RouteName)){next=candidate;break;}
        }

        return new
        {
            schemaVersion=1,
            generatedAt=DateTimeOffset.UtcNow.ToString("O"),
            nextEndpoint=next?.RouteName,
            nextConnection=next?.Endpoint.connection,
            nextModel=next?.Endpoint.model,
            enabledRoutes=routes.Count,
            healthyRoutes=eligible.Count,
            activeLeases=leases.Count,
            nextRetryAt=NextRetryAt(health),
            routes=routes.Select(r=>new
            {
                endpoint=r.RouteName,r.CatalogId,r.Endpoint.connection,r.Endpoint.model,
                r.Endpoint.toolMode,r.Endpoint.supportsTools,r.Endpoint.free,
                available=Available(r,health),
                leased=leaseRoutes.ContainsKey(r.RouteName),
                health=HealthStateFor(r,health)
            }).ToArray(),
            leases=leases.Values.OrderBy(x=>x.route).ToArray()
        };
    }

    public void ReapExpiredLeases()
    {
        var now=DateTimeOffset.UtcNow;
        var changed=false;
        lock(_leaseLock)
        {
            foreach(var kv in _leasesByToken.ToArray())
            {
                var expired=!DateTimeOffset.TryParse(kv.Value.expiresAt,out var at) || at<=now;
                // For process-owned leases, worker identity is authoritative. A long
                // inference may legitimately outlive the nominal TTL; do not double-book
                // that endpoint while the same worker process is still alive. The stored
                // start time also protects against Windows PID reuse after router restart.
                var stale=kv.Value.ownerPid>0
                    ? !ProcessMatches(kv.Value.ownerPid,kv.Value.ownerStartedAt)
                    : expired;
                if(!stale) continue;
                _leasesByToken.Remove(kv.Key);
                _tokenByRoute.Remove(kv.Value.route);
                changed=true;
            }
            if(changed) PersistLeasesLocked();
        }
    }

    void RestoreLeases()
    {
        var persisted=_store.LoadLeases();
        lock(_leaseLock)
        {
            _leasesByToken.Clear();
            _tokenByRoute.Clear();
            foreach(var kv in persisted.leases)
            {
                var lease=kv.Value;
                if(string.IsNullOrWhiteSpace(lease.token)) lease.token=kv.Key;
                if(string.IsNullOrWhiteSpace(lease.route)) continue;
                _leasesByToken[lease.token]=lease;
                _tokenByRoute[lease.route]=lease.token;
            }
        }
    }

    void PersistLeasesLocked()
    {
        var doc=new LeaseDocument
        {
            updatedAt=DateTimeOffset.UtcNow.ToString("O"),
            leases=_leasesByToken.ToDictionary(x=>x.Key,x=>x.Value,StringComparer.OrdinalIgnoreCase)
        };
        _store.SaveLeases(doc);
    }

    static string? OwnerStartedAt(int pid)
    {
        if(pid<=0) return null;
        try
        {
            using var process=System.Diagnostics.Process.GetProcessById(pid);
            return process.StartTime.ToUniversalTime().ToString("O");
        }
        catch { return null; }
    }

    static bool ProcessMatches(int pid,string? expectedStartedAt)
    {
        try
        {
            using var process=System.Diagnostics.Process.GetProcessById(pid);
            if(process.HasExited) return false;
            if(string.IsNullOrWhiteSpace(expectedStartedAt)) return true;
            if(!DateTimeOffset.TryParse(expectedStartedAt,out var expected)) return true;
            var actual=new DateTimeOffset(process.StartTime.ToUniversalTime(),TimeSpan.Zero);
            return Math.Abs((actual-expected).TotalSeconds)<1;
        }
        catch { return false; }
    }

    public void MarkHealthy(string key)
    {
        _store.UpdateHealth(doc =>
        {
            if(!doc.endpoints.TryGetValue(key,out var e)) e=new HealthEntry();
            e.state="healthy";e.reason=null;e.failures=0;e.probeFailures=0;e.retryAfter=null;e.nextProbeAt=null;
            e.lastSuccess=DateTimeOffset.UtcNow.ToString("O");e.message=null;
            doc.endpoints[key]=e;return 0;
        });
    }

    public HealthEntry RegisterFailureKey(string key,string scope,string klass,string? message,ConnectionProfile? connection=null)
    {
        return _store.UpdateHealth(doc =>
        {
            if(!doc.endpoints.TryGetValue(key,out var e)) e=new HealthEntry();
            e.scope=scope;e.reason=klass;e.failures=Math.Max(0,e.failures)+1;e.lastFailure=DateTimeOffset.UtcNow.ToString("O");
            e.message=Bound(message,500);
            var hard=(klass=="auth"||klass=="permission"||klass=="configuration");
            var quota=QuotaIntelligence.ObserveFailure(connection?.presetId,klass,message);
            if(HasQuotaSignal(quota)) e.quota=MergeQuota(e.quota,quota);
            var exactAt=FutureTime(quota.nextAvailableAt);
            var explicitDelay=FailurePolicy.ParseExplicitDelay(message);
            if(hard && explicitDelay is null && exactAt is null)
            {
                e.state="quarantined";e.retryAfter=null;e.nextProbeAt=null;
            }
            else
            {
                var at=exactAt ?? DateTimeOffset.UtcNow.Add(explicitDelay ?? FailurePolicy.Delay(klass,message,e.failures));
                var atText=at.ToUniversalTime().ToString("O");
                e.state="cooldown";e.retryAfter=atText;e.nextProbeAt=atText;
            }
            if(scope=="connection" && connection is not null)
                e.configFingerprint=_store.ConnectionFingerprint(connection);
            doc.endpoints[key]=e;return e;
        });
    }

    public void RecordQuotaObservation(string key,string scope,QuotaObservation observation,ConnectionProfile? connection=null)
    {
        if(!HasQuotaSignal(observation)) return;
        _store.UpdateHealth(doc =>
        {
            if(!doc.endpoints.TryGetValue(key,out var e)) e=new HealthEntry();
            e.scope=scope;
            e.quota=MergeQuota(e.quota,observation);
            e.lastProbe=observation.observedAt;
            if(scope=="connection" && connection is not null)
                e.configFingerprint=_store.ConnectionFingerprint(connection);
            doc.endpoints[key]=e;
            return 0;
        });
    }

    public EndpointRoute? FindRoute(string name)
    {
        return Routes().FirstOrDefault(r=>
            string.Equals(r.RouteName,name,StringComparison.OrdinalIgnoreCase) ||
            string.Equals(r.CatalogId,name,StringComparison.OrdinalIgnoreCase));
    }

    public bool IsLeased(string route)
    {
        lock(_leaseLock) return _tokenByRoute.ContainsKey(route);
    }

    static string? Bound(string? text,int max)
    {
        if(string.IsNullOrWhiteSpace(text)) return null;
        var s=text.Replace("\r"," ").Replace("\n"," ").Trim();
        return s.Length<=max?s:s[..max];
    }

    bool Available(EndpointRoute route,RoutingHealthDocument health)
    {
        return KeyAvailable(route.RouteName,health) &&
               KeyAvailable("connection:"+route.Endpoint.connection,health) &&
               (string.IsNullOrWhiteSpace(route.Service)||KeyAvailable("service:"+route.Service,health));
    }

    static bool KeyAvailable(string key,RoutingHealthDocument health)
    {
        if(!health.endpoints.TryGetValue(key,out var e)) return true;
        return string.Equals(e.state,"healthy",StringComparison.OrdinalIgnoreCase);
    }

    object HealthStateFor(EndpointRoute route,RoutingHealthDocument health)
    {
        var keys=new[]{route.RouteName,"connection:"+route.Endpoint.connection,string.IsNullOrWhiteSpace(route.Service)?null:"service:"+route.Service};
        foreach(var key in keys)
            if(key is not null && health.endpoints.TryGetValue(key,out var e) && !string.Equals(e.state,"healthy",StringComparison.OrdinalIgnoreCase))
                return new { key,e.state,e.reason,e.retryAfter,e.nextProbeAt,e.quota };

        QuotaObservation? quota=null;
        string quotaKey=route.RouteName;
        foreach(var key in keys)
        {
            if(key is null || !health.endpoints.TryGetValue(key,out var e) || e.quota is null) continue;
            quota=e.quota;quotaKey=key;break;
        }
        return new { key=quotaKey,state="healthy",reason=(string?)null,retryAfter=(string?)null,nextProbeAt=(string?)null,quota };
    }

    static bool HasQuotaSignal(QuotaObservation? q) =>
        q is not null && (q.nextAvailableAt is not null || q.resetAt is not null ||
                          q.windowResetAt is not null || q.remaining is not null ||
                          q.limit is not null || q.source!="none" || q.windowSource is not null);

    static QuotaObservation MergeQuota(QuotaObservation? current,QuotaObservation incoming)
    {
        if(current is null) return incoming;

        // Counter/probe observations and deterministic window policies describe
        // different things. Merge them instead of letting a harmless /models
        // probe erase a known inference reset boundary (or vice versa).
        if(incoming.source!="none" || incoming.remaining is not null ||
           incoming.limit is not null || incoming.nextAvailableAt is not null ||
           incoming.resetAt is not null)
        {
            current.status=incoming.status;
            current.observedAt=incoming.observedAt;
            current.nextAvailableAt=incoming.nextAvailableAt;
            current.resetAt=incoming.resetAt;
            current.limiter=incoming.limiter ?? current.limiter;
            current.limit=incoming.limit;
            current.remaining=incoming.remaining;
            current.source=incoming.source;
            current.confidence=incoming.confidence;
            current.evidence=incoming.evidence;
            current.appliesTo=incoming.appliesTo;
        }

        if(incoming.windowResetAt is not null)
        {
            current.windowResetAt=incoming.windowResetAt;
            current.windowCadence=incoming.windowCadence;
            current.windowSource=incoming.windowSource;
            current.windowConfidence=incoming.windowConfidence;
            current.windowEvidence=incoming.windowEvidence;
        }
        return current;
    }

    static DateTimeOffset? FutureTime(string? value)
    {
        if(DateTimeOffset.TryParse(value,out var at) && at>DateTimeOffset.UtcNow) return at;
        return null;
    }

    static string? NextRetryAt(RoutingHealthDocument health)
    {
        var now=DateTimeOffset.UtcNow;
        return health.endpoints.Values
            .SelectMany(e=>new[]{e.nextProbeAt,e.retryAfter})
            .Where(x=>!string.IsNullOrWhiteSpace(x))
            .Select(x=>DateTimeOffset.TryParse(x,out var t)?t:(DateTimeOffset?)null)
            .Where(x=>x is not null && x>now)
            .OrderBy(x=>x)
            .FirstOrDefault()?.ToString("O");
    }

    EndpointRoute? ResolveRoute(string? token,string? endpoint,out LeaseRecord? lease)
    {
        lease=null;
        if(!string.IsNullOrWhiteSpace(token))
        {
            lock(_leaseLock) _leasesByToken.TryGetValue(token,out lease);
            if(lease is not null) return FindRoute(lease.route);
        }
        return string.IsNullOrWhiteSpace(endpoint)?null:FindRoute(endpoint);
    }

    void MaybeDegradeService(string service,string failingConnection,string klass,string? message)
    {
        var health=_store.LoadHealth();
        var connections=_store.LoadConnections().connections;
        var cutoff=DateTimeOffset.UtcNow.AddMinutes(-10);
        var corroborated=false;
        foreach(var kv in connections)
        {
            if(string.Equals(kv.Key,failingConnection,StringComparison.OrdinalIgnoreCase)) continue;
            if(!string.Equals(ServiceName(kv.Value),service,StringComparison.OrdinalIgnoreCase)) continue;
            if(!health.endpoints.TryGetValue("connection:"+kv.Key,out var e)) continue;
            if(e.reason!="timeout" && e.reason!="server_error") continue;
            if(DateTimeOffset.TryParse(e.lastFailure,out var at) && at>=cutoff){corroborated=true;break;}
        }
        if(corroborated) RegisterFailureKey("service:"+service,"service",klass,message);
    }

    public static string? ServiceName(ConnectionProfile? c)
    {
        if(c is null || string.IsNullOrWhiteSpace(c.baseUrl)) return null;
        try { return new Uri(c.baseUrl).Host.ToLowerInvariant(); } catch { return null; }
    }
}

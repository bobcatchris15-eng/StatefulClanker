using System.Collections.Concurrent;

namespace StatefulClanker.Router;

public sealed class RouterEngine
{
    readonly RouterStore _store;
    readonly SignalStore _signals;
    readonly RoutingHealthReducer _healthReducer;
    readonly object _leaseLock = new();
    readonly Dictionary<string,LeaseRecord> _leasesByToken = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string,string> _tokenByRoute = new(StringComparer.OrdinalIgnoreCase);

    public RouterEngine(RouterStore store)
    {
        _store=store;
        _signals=new SignalStore(store.Root);
        _healthReducer=new RoutingHealthReducer(store,_signals);
        CorrectPermissionScopes();
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
            .OrderBy(r=>r.RouteName,StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public RouterResponse Acquire(string? preferred,string? preferredConnection,bool strictPreferred,string? sessionId,bool requireTools,int ownerPid=0,string[]? allowedEndpoints=null,string? requiredToolMode=null,string[]? excludedEndpoints=null)
    {
        ReapExpiredLeases();
        NormalizeExpiredCooldowns();
        var health=_store.LoadHealth();

        var allowSet=(allowedEndpoints??Array.Empty<string>()).Where(x=>!string.IsNullOrWhiteSpace(x)).Select(x=>x.Trim()).ToArray();

        var configuredAll=Routes().ToList();
        var configured=configuredAll;
        if(allowSet.Length>0)
        {
            configured=configuredAll.Where(r=>allowSet.Any(a=>
                string.Equals(a,r.CatalogId,StringComparison.OrdinalIgnoreCase)||
                string.Equals(a,r.RouteName,StringComparison.OrdinalIgnoreCase)||
                string.Equals(a,StripPoolPrefix(r.RouteName),StringComparison.OrdinalIgnoreCase))).ToList();
            if(configured.Count==0)
            {
                EmitRoutingSignal("route_unavailable",null,"request",new(){{"reason","no_allowed_endpoints"},{"configuredEndpoints",configuredAll.Count}},"router","scheduler");
                return RouterResponse.Fail(
                    "No allowed endpoints for this project.",
                    new { reason="no_allowed_endpoints",configuredEndpoints=configuredAll.Count,allowlistApplied=true });
            }
        }

        // Session affinity is advisory. Strict overrides must name an allowed
        // route, matching the same catalog/pool identities used by selection.
        if(strictPreferred && !string.IsNullOrWhiteSpace(preferred) && allowSet.Length>0 &&
           !configured.Any(r=>string.Equals(r.CatalogId,preferred,StringComparison.OrdinalIgnoreCase) ||
                              string.Equals(r.RouteName,preferred,StringComparison.OrdinalIgnoreCase)))
        {
            EmitRoutingSignal("route_unavailable",null,"request",new(){{"reason","preferred_not_allowed"},{"preferred",preferred}},"router","scheduler");
            return RouterResponse.Fail(
                $"Preferred endpoint '{preferred}' is outside the project's allowed endpoints.",
                new { reason="preferred_not_allowed",allowlistApplied=true });
        }

        var excludeSet=(excludedEndpoints??Array.Empty<string>())
            .Where(x=>!string.IsNullOrWhiteSpace(x))
            .Select(x=>x.Trim())
            .ToArray();
        if(excludeSet.Length>0)
        {
            configured=configured.Where(r=>!excludeSet.Any(x=>
                string.Equals(x,r.RouteName,StringComparison.OrdinalIgnoreCase) ||
                string.Equals(x,r.CatalogId,StringComparison.OrdinalIgnoreCase) ||
                string.Equals(x,StripPoolPrefix(r.RouteName),StringComparison.OrdinalIgnoreCase))).ToList();
            if(configured.Count==0)
                return RouterResponse.Fail(
                    "All compatible endpoints have already been attempted for this inference request.",
                    new { reason="all_candidates_attempted",excludedEndpoints=excludeSet });
        }

        var nativeRequired=requireTools || string.Equals(requiredToolMode,"native",StringComparison.OrdinalIgnoreCase);
        var eligible=configured
            .Where(r=>!nativeRequired || (r.Endpoint.supportsTools==true && string.Equals(r.Endpoint.toolMode,"native",StringComparison.OrdinalIgnoreCase)))
            .Where(r=>string.IsNullOrWhiteSpace(preferredConnection) || string.Equals(r.Endpoint.connection,preferredConnection,StringComparison.OrdinalIgnoreCase))
            .ToList();
        var routes=eligible.Where(r=>Available(r,health)).ToList();

        if(routes.Count==0)
        {
            var reason=eligible.Count==0 ? "no_eligible_endpoint" : "all_candidates_unhealthy";
            var error=eligible.Count==0
                ? (string.IsNullOrWhiteSpace(preferredConnection)
                    ? "No enabled endpoint matches the routing requirements."
                    : $"No enabled endpoint matches the routing requirements on connection '{preferredConnection}'.")
                : (string.IsNullOrWhiteSpace(preferredConnection)
                    ? "All eligible endpoints are temporarily unavailable."
                    : $"All eligible endpoints on connection '{preferredConnection}' are temporarily unavailable.");
            EmitRoutingSignal("route_unavailable",null,"request",new(){{"reason",reason},{"connection",preferredConnection},{"requireTools",requireTools},{"eligibleEndpoints",eligible.Count}},"router","scheduler");
            return RouterResponse.Fail(
                error,
                new
                {
                    reason,
                    nextRetryAt=NextRetryAt(eligible,health),
                    connection=preferredConnection,
                    requireTools,
                    requiredToolMode,
                    configuredEndpoints=configured.Count,
                    eligibleEndpoints=eligible.Count,
                    candidates=eligible.Select(r=>RouteDiagnostic(r,health)).ToArray()
                });
        }

        EndpointRoute? selected=null;
        if(!string.IsNullOrWhiteSpace(preferred))
        {
            selected=routes.FirstOrDefault(r=>
                string.Equals(r.RouteName,preferred,StringComparison.OrdinalIgnoreCase) ||
                string.Equals(r.CatalogId,preferred,StringComparison.OrdinalIgnoreCase));
            if(selected is not null && IsAtCapacity(selected)) selected=null;
            if(strictPreferred && selected is null)
            {
                var preferredRoute=eligible.FirstOrDefault(r=>
                    string.Equals(r.RouteName,preferred,StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(r.CatalogId,preferred,StringComparison.OrdinalIgnoreCase));
                EmitRoutingSignal("route_unavailable",preferredRoute,"endpoint",new(){{"reason",preferredRoute is null ? "preferred_not_eligible" : IsAtCapacity(preferredRoute) ? "preferred_at_capacity" : "preferred_unhealthy"},{"preferred",preferred}},"router","scheduler");
                return RouterResponse.Fail(
                    $"Preferred endpoint '{preferred}' is not currently available.",
                    new
                    {
                        reason=preferredRoute is null ? "preferred_not_eligible" : IsAtCapacity(preferredRoute) ? "preferred_at_capacity" : "preferred_unhealthy",
                        nextRetryAt=preferredRoute is null ? null : NextRetryAt(new[]{preferredRoute},health),
                        candidate=preferredRoute is null ? null : RouteDiagnostic(preferredRoute,health)
                    });
            }
        }

        if(selected is null)
        {
            var candidates=routes.Where(r=>!IsAtCapacity(r)).ToList();
            var rotationPool=candidates.Where(r=>r.Endpoint.weight>0).ToList();
            if(rotationPool.Count==0) rotationPool=candidates;
            if(rotationPool.Count>0)
            {
                selected=PickWeighted(rotationPool);
            }
        }

        if(selected is null)
        {
            EmitRoutingSignal("route_unavailable",null,"request",new(){{"reason","all_candidates_at_capacity"},{"candidateCount",routes.Count}},"router","scheduler");
            return RouterResponse.Fail(
                "All healthy eligible endpoints are at lease capacity.",
                new
                {
                    reason="all_candidates_at_capacity",
                    retryAfterSeconds=2,
                    candidates=routes.Select(r=>RouteDiagnostic(r,health)).ToArray()
                });
        }

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
        EmitRoutingSignal("route_acquired",selected,"endpoint",new(){{"connection",lease.connection},{"model",lease.model},{"sessionId",sessionId},{"expiresAt",lease.expiresAt}},"router","scheduler");

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
            weight=selected.Endpoint.weight,
            allowlistApplied=allowSet.Length>0,
            preferredHonored=!string.IsNullOrWhiteSpace(preferred) &&
                (string.Equals(selected.RouteName,preferred,StringComparison.OrdinalIgnoreCase) ||
                 string.Equals(selected.CatalogId,preferred,StringComparison.OrdinalIgnoreCase)),
            connectionHonored=!string.IsNullOrWhiteSpace(preferredConnection) &&
                string.Equals(selected.Endpoint.connection,preferredConnection,StringComparison.OrdinalIgnoreCase),
            expiresAt=lease.expiresAt
        });
    }

    public RouterResponse Negotiate(
        string? preferred,
        string? preferredConnection,
        bool strictPreferred,
        string[]? allowedEndpoints=null)
    {
        ReapExpiredLeases();
        NormalizeExpiredCooldowns();
        var health=_store.LoadHealth();
        var allowSet=(allowedEndpoints??Array.Empty<string>())
            .Where(x=>!string.IsNullOrWhiteSpace(x))
            .Select(x=>x.Trim())
            .ToArray();

        var configured=Routes().ToList();
        if(allowSet.Length>0)
        {
            configured=configured.Where(r=>allowSet.Any(a=>
                string.Equals(a,r.CatalogId,StringComparison.OrdinalIgnoreCase) ||
                string.Equals(a,r.RouteName,StringComparison.OrdinalIgnoreCase) ||
                string.Equals(a,StripPoolPrefix(r.RouteName),StringComparison.OrdinalIgnoreCase))).ToList();
        }
        if(!string.IsNullOrWhiteSpace(preferredConnection))
            configured=configured.Where(r=>string.Equals(
                r.Endpoint.connection,preferredConnection,StringComparison.OrdinalIgnoreCase)).ToList();

        if(configured.Count==0)
            return RouterResponse.Fail("No enabled endpoint matches the routing requirements.",
                new{reason="no_eligible_endpoint",connection=preferredConnection});

        EndpointRoute? preferredRoute=null;
        if(!string.IsNullOrWhiteSpace(preferred))
        {
            preferredRoute=configured.FirstOrDefault(r=>
                string.Equals(r.RouteName,preferred,StringComparison.OrdinalIgnoreCase) ||
                string.Equals(r.CatalogId,preferred,StringComparison.OrdinalIgnoreCase));
            if(strictPreferred)
            {
                if(preferredRoute is null)
                    return RouterResponse.Fail($"Preferred endpoint '{preferred}' is not eligible.",
                        new{reason="preferred_not_eligible"});
                var currentlyAvailable=Available(preferredRoute,health) && !IsAtCapacity(preferredRoute);
                return RouterResponse.Ok(new
                {
                    toolMode=string.Equals(preferredRoute.Endpoint.toolMode,"native",StringComparison.OrdinalIgnoreCase)
                        && preferredRoute.Endpoint.supportsTools==true ? "native" : "text",
                    nativeCandidates=(preferredRoute.Endpoint.supportsTools==true && string.Equals(preferredRoute.Endpoint.toolMode,"native",StringComparison.OrdinalIgnoreCase))?1:0,
                    healthyCandidates=currentlyAvailable?1:0,
                    configuredCandidates=1,
                    currentlyAvailable,
                    nextRetryAt=currentlyAvailable?null:NextRetryAt(new[]{preferredRoute},health),
                    strictPreferred=true
                });
            }
        }

        var healthy=configured.Where(r=>Available(r,health) && !IsAtCapacity(r)).ToList();
        var protocolCandidates=healthy.Count>0?healthy:configured;

        // Preserve soft session affinity when possible, but expose only the
        // compatible tool protocol to the caller, never the chosen endpoint.
        if(preferredRoute is not null && protocolCandidates.Any(r=>string.Equals(r.RouteName,preferredRoute.RouteName,StringComparison.OrdinalIgnoreCase)))
        {
            var preferredNative=preferredRoute.Endpoint.supportsTools==true &&
                string.Equals(preferredRoute.Endpoint.toolMode,"native",StringComparison.OrdinalIgnoreCase);
            if(preferredNative)
            {
                var nativeHealthy=protocolCandidates.Count(r=>r.Endpoint.supportsTools==true &&
                    string.Equals(r.Endpoint.toolMode,"native",StringComparison.OrdinalIgnoreCase));
                if(nativeHealthy>=2 || protocolCandidates.Count==1)
                    return RouterResponse.Ok(new{toolMode="native",nativeCandidates=nativeHealthy,healthyCandidates=healthy.Count,configuredCandidates=configured.Count,currentlyAvailable=(healthy.Count>0),nextRetryAt=healthy.Count>0?null:NextRetryAt(configured,health),strictPreferred=false});
            }
        }

        var nativeCount=protocolCandidates.Count(r=>r.Endpoint.supportsTools==true &&
            string.Equals(r.Endpoint.toolMode,"native",StringComparison.OrdinalIgnoreCase));

        // Text protocol is the wider compatibility class: a native-capable model
        // can still follow the text tool protocol, while a text-only endpoint
        // cannot consume a native tool transcript. Prefer native only when it has
        // redundant coverage, or when it is the sole available class.
        var mode=(nativeCount>=2 || (nativeCount==protocolCandidates.Count && nativeCount>0))?"native":"text";
        return RouterResponse.Ok(new
        {
            toolMode=mode,
            nativeCandidates=nativeCount,
            healthyCandidates=healthy.Count,
            configuredCandidates=configured.Count,
            currentlyAvailable=(healthy.Count>0),
            nextRetryAt=healthy.Count>0?null:NextRetryAt(configured,health),
            strictPreferred=false
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
        EmitRoutingSignal("route_succeeded",route,"endpoint",new(){{"connection",route.Endpoint.connection},{"model",route.Endpoint.model}},"router","health");
        if(lease is not null) Release(lease.token);
        return RouterResponse.Ok(new { endpoint=route.RouteName,state="healthy" });
    }

    public RouterResponse Failure(string? token,string? endpoint,string? failureClass,string? message)
    {
        var route=ResolveRoute(token,endpoint,out var lease);
        if(route is null) return RouterResponse.Fail("A valid lease or endpoint is required.");

        var klass=string.IsNullOrWhiteSpace(failureClass)?FailurePolicy.Classify(message):failureClass!;
        var scope=FailurePolicy.ScopeFor(klass,message);
        if(scope=="request")
        {
            EmitRoutingSignal("route_failed",route,scope,new(){{"failureClass",klass},{"message",Bound(message,500)},{"healthChanged",false}},"router","health");
            if(lease is not null) Release(lease.token);
            return RouterResponse.Ok(new { endpoint=route.RouteName,failureClass=klass,scope,healthChanged=false,failoverAllowed=FailurePolicy.CanFailover(klass) });
        }

        var key=scope=="connection" ? "connection:"+route.Endpoint.connection : route.RouteName;
        var entry=RegisterFailureKey(key,scope,klass,message,route.Connection);
        EmitRoutingSignal("route_failed",route,scope,new(){{"failureClass",klass},{"message",Bound(message,500)},{"healthKey",key},{"healthChanged",true},{"retryAfter",entry.retryAfter}},"router","health");

        if(scope=="connection" && (klass=="timeout" || klass=="server_error") && !string.IsNullOrWhiteSpace(route.Service))
            MaybeDegradeService(route.Service!,route.Endpoint.connection,klass,message);

        if(lease is not null) Release(lease.token);
        return RouterResponse.Ok(new
        {
            endpoint=route.RouteName,key,scope,failureClass=klass,failoverAllowed=FailurePolicy.CanFailover(klass),
            state=entry.state,retryAfter=entry.retryAfter,nextProbeAt=entry.nextProbeAt,quota=entry.quota
        });
    }

    public object Snapshot()
    {
        ReapExpiredLeases();
        NormalizeExpiredCooldowns();
        var health=_store.LoadHealth();
        var capacity=_store.LoadCapacityDiscovery();
        var routes=Routes();
        Dictionary<string,LeaseRecord> leases;
        lock(_leaseLock) leases=_leasesByToken.ToDictionary(x=>x.Key,x=>x.Value,StringComparer.OrdinalIgnoreCase);
        var leaseCounts=leases.Values.GroupBy(x=>x.route,StringComparer.OrdinalIgnoreCase).ToDictionary(x=>x.Key,x=>x.Count(),StringComparer.OrdinalIgnoreCase);
        var eligible=routes.Where(r=>Available(r,health)).ToList();
        var cursor=eligible.Count==0?0:Math.Abs(_store.LoadCursor().cursor%eligible.Count);
        EndpointRoute? next=null;
        for(var i=0;i<eligible.Count;i++)
        {
            var candidate=eligible[(cursor+i)%eligible.Count];
            if(leaseCounts.GetValueOrDefault(candidate.RouteName)<LeaseCapacity(candidate)){next=candidate;break;}
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
            nextRetryAt=NextRetryAt(routes,health),
            freeCapacity=new
            {
                updatedAt=capacity.updatedAt,
                connections=capacity.connections.Count,
                confirmedFree=capacity.connections.Values.Sum(x=>x.confirmedFree),
                workhorseFree=capacity.connections.Values.Sum(x=>x.workhorseFree),
                paid=capacity.connections.Values.Sum(x=>x.paid),
                unknown=capacity.connections.Values.Sum(x=>x.unknown)
            },
            routes=routes.Select(r=>new
            {
                endpoint=r.RouteName,r.CatalogId,r.Endpoint.connection,r.Endpoint.model,
                r.Endpoint.toolMode,r.Endpoint.supportsTools,r.Endpoint.free,r.Endpoint.weight,
                r.Endpoint.managedBy,r.Endpoint.freeClass,r.Endpoint.retiredReason,r.Endpoint.userOverride,
                available=Available(r,health),
                activeLeases=leaseCounts.GetValueOrDefault(r.RouteName),
                leaseCapacity=LeaseCapacity(r),
                leased=leaseCounts.GetValueOrDefault(r.RouteName)>0,
                eligibility=RouteDiagnostic(r,health),
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
        _healthReducer.MarkHealthy(key);
    }

    public HealthEntry RegisterFailureKey(string key,string scope,string klass,string? message,ConnectionProfile? connection=null)
    {
        return _healthReducer.RegisterFailure(key,scope,klass,message,connection);
    }

    public void RecordQuotaObservation(string key,string scope,QuotaObservation observation,ConnectionProfile? connection=null)
    {
        _healthReducer.RecordQuota(key,scope,observation,connection);
    }

    public EndpointRoute? FindRoute(string name)
    {
        return Routes().FirstOrDefault(r=>
            string.Equals(r.RouteName,name,StringComparison.OrdinalIgnoreCase) ||
            string.Equals(r.CatalogId,name,StringComparison.OrdinalIgnoreCase));
    }

    public bool IsLeased(string route)
    {
        lock(_leaseLock) return _leasesByToken.Values.Any(x=>string.Equals(x.route,route,StringComparison.OrdinalIgnoreCase));
    }

    bool IsAtCapacity(EndpointRoute route)
    {
        lock(_leaseLock) return _leasesByToken.Values.Count(x=>string.Equals(x.route,route.RouteName,StringComparison.OrdinalIgnoreCase))>=LeaseCapacity(route);
    }

    static int LeaseCapacity(EndpointRoute route)
    {
        if(route.Endpoint.leaseCapacity is int configured) return Math.Clamp(configured,1,5);
        return IsAutoRoutingModel(route.Endpoint.model)?5:1;
    }

    static bool IsAutoRoutingModel(string? model) =>
        string.Equals(model,"kilo-auto/free",StringComparison.OrdinalIgnoreCase) ||
        string.Equals(model,"openrouter/free",StringComparison.OrdinalIgnoreCase) ||
        string.Equals(model,"openrouter/auto",StringComparison.OrdinalIgnoreCase);

    void EmitRoutingSignal(string kind,EndpointRoute? route,string scope,Dictionary<string,object?> payload,string subjectType,string subjectId)
    {
        try
        {
            var id=route?.RouteName ?? subjectId;
            var signal=SignalEnvelope.Routing(kind,subjectType,id,"router",subjectId,scope,payload);
            if(route is not null)
            {
                signal.source["endpoint"]=route.RouteName;
                signal.source["connection"]=route.Endpoint.connection;
                signal.source["model"]=route.Endpoint.model;
            }
            _signals.Append(signal);
        }
        catch
        {
            // Shadow stage: signal persistence must not alter routing behavior.
        }
    }

    static string? Bound(string? text,int max)
    {
        if(string.IsNullOrWhiteSpace(text)) return null;
        var s=text.Replace("\r"," ").Replace("\n"," ").Trim();
        return s.Length<=max?s:s[..max];
    }

    internal bool TryExpireCooldown(string key,DateTimeOffset now) => _healthReducer.TryExpireCooldown(key,now);

    public void CorrectPermissionScopes() => _healthReducer.NormalizeExpiredCooldowns();

    void NormalizeExpiredCooldowns()
    {
        _healthReducer.NormalizeExpiredCooldowns();
    }

    object RouteDiagnostic(EndpointRoute route,RoutingHealthDocument health)
    {
        var healthState=HealthStateFor(route,health);
        var atCapacity=IsAtCapacity(route);
        return new
        {
            endpoint=route.RouteName,
            route.CatalogId,
            connection=route.Endpoint.connection,
            model=route.Endpoint.model,
            enabled=route.Endpoint.enabled,
            workhorse=route.Endpoint.workhorse,
            toolMode=route.Endpoint.toolMode,
            supportsTools=route.Endpoint.supportsTools,
            weight=route.Endpoint.weight,
            available=Available(route,health),
            atCapacity,
            health=healthState
        };
    }

    static string StripPoolPrefix(string routeName) =>
        routeName.StartsWith("pool:",StringComparison.OrdinalIgnoreCase) ? routeName[5..] : routeName;

    EndpointRoute PickWeighted(IReadOnlyList<EndpointRoute> pool)
    {
        var state=_store.LoadCursor();
        var weights=new Dictionary<string,int>(state.currentWeights??new(StringComparer.OrdinalIgnoreCase),StringComparer.OrdinalIgnoreCase);
        var total=pool.Sum(r=>r.Endpoint.weight>0?r.Endpoint.weight:1);

        EndpointRoute? best=null;
        var bestCurrent=int.MinValue;
        foreach(var r in pool)
        {
            var w=r.Endpoint.weight>0?r.Endpoint.weight:1;
            var cur=weights.TryGetValue(r.RouteName,out var c)?c:0;
            cur+=w;
            weights[r.RouteName]=cur;
            if(cur>bestCurrent)
            {
                bestCurrent=cur;
                best=r;
            }
        }
        var selected=best!;
        weights[selected.RouteName]-=total;

        _store.UpdateCursor(d=>{d.currentWeights=weights;return 0;});
        return selected;
    }

    bool Available(EndpointRoute route,RoutingHealthDocument health)
    {
        if(route.Connection is not null && ProviderProbeCatalog.IsRetired(route.Connection)) return false;
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
        if(route.Connection is not null && ProviderProbeCatalog.IsRetired(route.Connection))
            return new { key="connection:"+route.Endpoint.connection,state="retired",reason="provider_retired",retryAfter=(string?)null,nextProbeAt=(string?)null,quota=(QuotaObservation?)null };
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
                          q.remaining is not null || q.limit is not null || q.source!="none");

    static DateTimeOffset? FutureTime(string? value)
    {
        if(DateTimeOffset.TryParse(value,out var at) && at>DateTimeOffset.UtcNow) return at;
        return null;
    }

    static string? NextRetryAt(IEnumerable<EndpointRoute> routes,RoutingHealthDocument health)
    {
        var now=DateTimeOffset.UtcNow;
        var keys=routes
            .SelectMany(r=>new[]{r.RouteName,"connection:"+r.Endpoint.connection,string.IsNullOrWhiteSpace(r.Service)?null:"service:"+r.Service})
            .Where(k=>!string.IsNullOrWhiteSpace(k))
            .Select(k=>k!)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        return keys
            .Where(k=>health.endpoints.ContainsKey(k))
            .Select(k=>health.endpoints[k])
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

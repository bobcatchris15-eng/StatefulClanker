namespace StatefulClanker.Router;

public sealed class RoutingHealthReducer
{
    readonly RouterStore _store;
    readonly SignalStore _signals;

    public RoutingHealthReducer(RouterStore store,SignalStore signals)
    {
        _store=store;
        _signals=signals;
    }

    public void MarkHealthy(string key,string reason="successful-observation")
    {
        var scope=ScopeFromKey(key);
        Append("health_recovered",key,scope,new()
        {
            ["reason"]=reason,
            ["healthKey"]=key
        });

        _store.UpdateHealth(doc =>
        {
            if(!doc.endpoints.TryGetValue(key,out var e)) e=new HealthEntry();
            e.scope=scope;
            e.state="healthy";
            e.reason=null;
            e.accountPermissionEvidence=null;
            e.failures=0;
            e.probeFailures=0;
            e.retryAfter=null;
            e.nextProbeAt=null;
            e.lastSuccess=DateTimeOffset.UtcNow.ToString("O");
            e.message=null;
            doc.endpoints[key]=e;
            return 0;
        });
    }

    public HealthEntry RegisterFailure(
        string key,
        string scope,
        string failureClass,
        string? message,
        ConnectionProfile? connection=null)
    {
        Append("health_failure_observed",key,scope,new()
        {
            ["healthKey"]=key,
            ["failureClass"]=failureClass,
            ["message"]=Bound(message,500),
            ["connection"]=connection?.name
        });

        return _store.UpdateHealth(doc =>
        {
            if(!doc.endpoints.TryGetValue(key,out var e)) e=new HealthEntry();
            e.scope=scope;
            e.reason=failureClass;
            e.accountPermissionEvidence=failureClass=="permission" && scope=="connection"
                ? FailurePolicy.HasAccountPermissionEvidence(message) : null;
            e.failures=Math.Max(0,e.failures)+1;
            e.lastFailure=DateTimeOffset.UtcNow.ToString("O");
            e.message=Bound(message,500);

            var hard=failureClass is "auth" or "configuration" || (failureClass=="permission" && scope=="connection");
            var quota=QuotaIntelligence.ObserveFailure(connection?.presetId,failureClass,message);
            if(HasQuotaSignal(quota)) e.quota=quota;

            var exactAt=FutureTime(quota.nextAvailableAt);
            var explicitDelay=FailurePolicy.ParseExplicitDelay(message);
            if(hard)
            {
                e.state="quarantined";
                e.retryAfter=null;
                e.nextProbeAt=null;
            }
            else
            {
                var at=exactAt ??
                    DateTimeOffset.UtcNow.Add(explicitDelay ?? FailurePolicy.Delay(failureClass,message,e.failures));
                var atText=at.ToUniversalTime().ToString("O");
                e.state="cooldown";
                e.retryAfter=atText;
                e.nextProbeAt=atText;
            }

            if(scope=="connection" && connection is not null)
                e.configFingerprint=_store.ConnectionFingerprint(connection);
            doc.endpoints[key]=e;
            return e;
        });
    }

    public void RecordQuota(
        string key,
        string scope,
        QuotaObservation observation,
        ConnectionProfile? connection=null)
    {
        if(!HasQuotaSignal(observation)) return;
        Append("quota_observed",key,scope,new()
        {
            ["healthKey"]=key,
            ["quota"]=observation,
            ["connection"]=connection?.name
        });

        _store.UpdateHealth(doc =>
        {
            if(!doc.endpoints.TryGetValue(key,out var e)) e=new HealthEntry();
            e.scope=scope;
            e.quota=observation;
            e.lastProbe=observation.observedAt;
            if(scope=="connection" && connection is not null)
                e.configFingerprint=_store.ConnectionFingerprint(connection);
            doc.endpoints[key]=e;
            return 0;
        });
    }

    public void NormalizeExpiredCooldowns()
    {
        var now=DateTimeOffset.UtcNow;
        var snapshot=_store.LoadHealth();
        foreach(var kv in snapshot.endpoints)
        {
            var e=kv.Value;
            // Legacy permission entries lacked evidence of account-wide failure.
            // Without the original endpoint, let the next real inference establish
            // its own restriction rather than guessing a model or retaining a block.
            if(kv.Key.StartsWith("connection:",StringComparison.OrdinalIgnoreCase) &&
               e.reason=="permission" && e.state!="healthy" &&
               FailurePolicy.ScopeFor("permission",e.message)=="endpoint")
            {
                var recovered=_store.UpdateHealth(doc =>
                {
                    if(!doc.endpoints.TryGetValue(kv.Key,out var current) ||
                       current.reason!="permission" || current.state=="healthy" ||
                       current.accountPermissionEvidence==true ||
                       FailurePolicy.ScopeFor("permission",current.message)!="endpoint") return false;
                    current.state="healthy";
                    current.reason=null;
                    current.failures=0;
                    current.probeFailures=0;
                    current.retryAfter=null;
                    current.nextProbeAt=null;
                    current.message=null;
                    current.accountPermissionEvidence=null;
                    return true;
                });
                if(recovered) Append("health_recovered",kv.Key,"connection",new()
                {
                    ["reason"]="policy-scope-corrected",["healthKey"]=kv.Key
                });
                continue;
            }
            if(!string.Equals(e.state,"cooldown",StringComparison.OrdinalIgnoreCase)) continue;
            if(e.scope=="connection" && (e.reason is "auth" or "configuration" ||
               e.reason=="permission" && (e.accountPermissionEvidence==true ||
               FailurePolicy.HasAccountPermissionEvidence(e.message))))
            {
                _store.UpdateHealth(doc =>
                {
                    if(doc.endpoints.TryGetValue(kv.Key,out var current) && current.state=="cooldown" &&
                       (current.reason is "auth" or "configuration" || current.reason=="permission" &&
                       (current.accountPermissionEvidence==true || FailurePolicy.HasAccountPermissionEvidence(current.message))))
                    {
                        current.state="quarantined";
                        current.retryAfter=null;
                        current.nextProbeAt=null;
                    }
                    return 0;
                });
                continue;
            }
            var raw=e.retryAfter ?? e.nextProbeAt;
            if(!DateTimeOffset.TryParse(raw,out var due) || due>now) continue;
            TryExpireCooldown(kv.Key,now);
        }
    }

    internal bool TryExpireCooldown(string key,DateTimeOffset now)
    {
        var recovered=_store.UpdateHealth(doc =>
        {
            if(!doc.endpoints.TryGetValue(key,out var current) ||
               !string.Equals(current.state,"cooldown",StringComparison.OrdinalIgnoreCase) ||
               !string.Equals(current.scope,ScopeFromKey(key),StringComparison.OrdinalIgnoreCase) ||
               !DateTimeOffset.TryParse(current.retryAfter ?? current.nextProbeAt,out var due) || due>now ||
               current.scope=="connection" && (current.reason is "auth" or "configuration" ||
               current.reason=="permission" && (current.accountPermissionEvidence==true ||
               FailurePolicy.HasAccountPermissionEvidence(current.message)))) return false;
            current.state="healthy";
            current.reason=null;
            current.failures=0;
            current.probeFailures=0;
            current.retryAfter=null;
            current.nextProbeAt=null;
            current.message=null;
            current.accountPermissionEvidence=null;
            return true;
        });
        if(recovered) Append("health_recovered",key,ScopeFromKey(key),new()
        {
            ["reason"]="cooldown-expired",["healthKey"]=key
        });
        return recovered;
    }

    void Append(string kind,string key,string scope,Dictionary<string,object?> payload)
    {
        try
        {
            var signal=SignalEnvelope.Routing(
                kind,"health-key",key,
                "router","health",
                scope,payload);
            signal.source["component"]="routing-health-reducer";
            _signals.Append(signal);
        }
        catch
        {
            // Health machinery must remain available even if diagnostic append fails.
        }
    }

    static string ScopeFromKey(string key) =>
        key.StartsWith("connection:",StringComparison.OrdinalIgnoreCase)?"connection":
        key.StartsWith("service:",StringComparison.OrdinalIgnoreCase)?"service":"endpoint";

    static bool HasQuotaSignal(QuotaObservation q) =>
        q.nextAvailableAt is not null || q.resetAt is not null ||
        q.remaining is not null || q.limit is not null ||
        q.windows.Count>0 || !string.Equals(q.source,"none",StringComparison.OrdinalIgnoreCase);

    static DateTimeOffset? FutureTime(string? text)
    {
        if(!DateTimeOffset.TryParse(text,out var value)) return null;
        return value>DateTimeOffset.UtcNow?value:null;
    }

    static string? Bound(string? text,int max)
    {
        if(string.IsNullOrWhiteSpace(text)) return null;
        var s=text.Replace("\r"," ").Replace("\n"," ").Trim();
        return s.Length<=max?s:s[..max];
    }
}

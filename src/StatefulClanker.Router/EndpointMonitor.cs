using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;

namespace StatefulClanker.Router;

public sealed class EndpointMonitor
{
    sealed record ProbeResult(
        bool Success,
        int StatusCode,
        string FailureClass,
        string Message,
        QuotaObservation Quota,
        ProviderProbePlan Plan);

    readonly RouterEngine _engine;
    readonly RouterStore _store;
    readonly HttpClient _http=new(){Timeout=TimeSpan.FromSeconds(15)};
    readonly Dictionary<string,DateTimeOffset> _nextQuotaProbe=new(StringComparer.OrdinalIgnoreCase);
    DateTimeOffset _nextPolicyRefreshAt=DateTimeOffset.MinValue;
    static readonly TimeSpan HealthyProbeInterval=TimeSpan.FromMinutes(5);
    static readonly TimeSpan PolicyRefreshInterval=TimeSpan.FromMinutes(1);

    public EndpointMonitor(RouterEngine engine)
    {
        _engine=engine;_store=engine.Store;
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("StatefulClanker-Router/0.3");
    }

    public async Task RunAsync(CancellationToken token)
    {
        await Task.WhenAll(
            RunHealthLoopAsync(token),
            RunQuotaLoopAsync(token));
    }

    async Task RunHealthLoopAsync(CancellationToken token)
    {
        while(!token.IsCancellationRequested)
        {
            try { await TickAsync(token); } catch { }
            try { await Task.Delay(TimeSpan.FromSeconds(2),token); }
            catch(OperationCanceledException) { break; }
        }
    }

    async Task RunQuotaLoopAsync(CancellationToken token)
    {
        while(!token.IsCancellationRequested)
        {
            try
            {
                var connections=_store.LoadConnections().connections;
                var now=DateTimeOffset.UtcNow;
                if(now>=_nextPolicyRefreshAt)
                {
                    ApplyProgrammaticWindows(connections,now);
                    _nextPolicyRefreshAt=now.Add(PolicyRefreshInterval);
                }
                await ObserveOneConnectionAsync(connections,now,token);
            }
            catch { }
            try { await Task.Delay(TimeSpan.FromSeconds(2),token); }
            catch(OperationCanceledException) { break; }
        }
    }

    public async Task TickAsync(CancellationToken token=default)
    {
        _engine.ReapExpiredLeases();
        var health=_store.LoadHealth();
        var connections=_store.LoadConnections().connections;
        var now=DateTimeOffset.UtcNow;

        foreach(var kv in health.endpoints.ToArray())
        {
            var key=kv.Key;var entry=kv.Value;
            if(string.Equals(entry.state,"healthy",StringComparison.OrdinalIgnoreCase)) continue;

            if(string.Equals(entry.state,"quarantined",StringComparison.OrdinalIgnoreCase))
            {
                if(!key.StartsWith("connection:",StringComparison.OrdinalIgnoreCase)) continue;
                var name=key["connection:".Length..];
                if(!connections.TryGetValue(name,out var c)) continue;
                var fp=_store.ConnectionFingerprint(c);
                if(!string.Equals(fp,entry.configFingerprint,StringComparison.OrdinalIgnoreCase))
                    _engine.MarkHealthy(key);
                continue;
            }

            var raw=entry.nextProbeAt ?? entry.retryAfter;
            if(DateTimeOffset.TryParse(raw,out var due) && due>now) continue;

            // Endpoint/billing cooldowns are clocks, not invitations to send a
            // sacrificial model request. Once the known/inferred window expires,
            // the route simply becomes eligible for actual work again.
            if(string.Equals(entry.scope,"endpoint",StringComparison.OrdinalIgnoreCase) ||
               entry.reason=="billing_exhausted")
            {
                _engine.MarkHealthy(key);
                continue;
            }

            if(key.StartsWith("connection:",StringComparison.OrdinalIgnoreCase))
            {
                var name=key["connection:".Length..];
                if(connections.TryGetValue(name,out var c))
                    await ProbeConnectionHealthAsync(name,c,token);
                continue;
            }

            if(key.StartsWith("service:",StringComparison.OrdinalIgnoreCase))
            {
                var service=key["service:".Length..];
                var candidate=connections.FirstOrDefault(x=>
                    string.Equals(RouterEngine.ServiceName(x.Value),service,StringComparison.OrdinalIgnoreCase));
                if(!string.IsNullOrWhiteSpace(candidate.Key))
                {
                    var plan=ProviderProbePolicy.For(candidate.Value);
                    var result=await ProbeAsync(candidate.Value,plan,token);
                    RecordQuota(candidate.Key,candidate.Value,result);

                    if(result.Success)
                    {
                        _engine.MarkHealthy(key);
                    }
                    else if(result.FailureClass is "timeout" or "server_error")
                    {
                        _engine.RegisterFailureKey(key,"service",result.FailureClass,result.Message);
                    }
                    else
                    {
                        // A non-inference metadata response proves the service is
                        // reachable. Credential failures apply to the credential;
                        // quota/model/read-bucket failures do not poison inference.
                        _engine.MarkHealthy(key);
                        if(result.FailureClass is "auth" or "permission" or "configuration")
                            _engine.RegisterFailureKey(
                                "connection:"+candidate.Key,
                                "connection",
                                result.FailureClass,
                                result.Message,
                                candidate.Value);
                    }
                }
                else _engine.MarkHealthy(key);
            }
        }
    }

    void ApplyProgrammaticWindows(
        Dictionary<string,ConnectionProfile> connections,
        DateTimeOffset now)
    {
        foreach(var kv in connections)
        {
            var observation=ProviderProbePolicy.ProgrammaticWindow(kv.Value,now);
            if(observation is null) continue;
            _engine.RecordQuotaObservation(
                "connection:"+kv.Key,
                "connection",
                observation,
                kv.Value);
        }
    }

    async Task ObserveOneConnectionAsync(
        Dictionary<string,ConnectionProfile> connections,
        DateTimeOffset now,
        CancellationToken token)
    {
        foreach(var kv in connections.OrderBy(x=>x.Key,StringComparer.OrdinalIgnoreCase))
        {
            if(ProviderProbePolicy.SkipNetworkProbe(kv.Value)) continue;
            if(_nextQuotaProbe.TryGetValue(kv.Key,out var due) && due>now) continue;

            _nextQuotaProbe[kv.Key]=now.Add(HealthyProbeInterval);
            var plan=ProviderProbePolicy.For(kv.Value);
            var result=await ProbeAsync(kv.Value,plan,token);
            RecordQuota(kv.Key,kv.Value,result);

            // A read/account probe may prove credentials are invalid. Its own
            // quota/capacity bucket never disables healthy inference.
            if(!result.Success && result.FailureClass is "auth" or "permission" or "configuration")
                _engine.RegisterFailureKey(
                    "connection:"+kv.Key,
                    "connection",
                    result.FailureClass,
                    result.Message,
                    kv.Value);

            if(result.Quota.nextAvailableAt is not null &&
               DateTimeOffset.TryParse(result.Quota.nextAvailableAt,out var reset) &&
               reset>_nextQuotaProbe[kv.Key])
                _nextQuotaProbe[kv.Key]=reset;

            break;
        }
    }

    async Task ProbeConnectionHealthAsync(
        string name,
        ConnectionProfile profile,
        CancellationToken token)
    {
        var plan=ProviderProbePolicy.For(profile);
        var result=await ProbeAsync(profile,plan,token);
        RecordQuota(name,profile,result);
        var key="connection:"+name;

        if(result.Success)
        {
            _engine.MarkHealthy(key);
            return;
        }

        if(result.FailureClass is "auth" or "permission" or "configuration")
        {
            _engine.RegisterFailureKey(key,"connection",result.FailureClass,result.Message,profile);
            return;
        }

        if(result.FailureClass is "timeout" or "server_error")
        {
            _engine.RegisterFailureKey(key,"connection",result.FailureClass,result.Message,profile);
            return;
        }

        // The metadata/account surface answered. Its own 429, model-list error,
        // or budget response does not prove inference is unavailable.
        _engine.MarkHealthy(key);
    }

    void RecordQuota(
        string connectionName,
        ConnectionProfile profile,
        ProbeResult result)
    {
        var quota=result.Quota;
        quota.appliesTo=result.Plan.AppliesTo;

        if(quota.source!="none")
        {
            var prefix=result.Plan.AppliesTo=="metadata"
                ? "probe:metadata:"
                : "probe:"+result.Plan.Kind+":";
            if(!quota.source.StartsWith("probe:",StringComparison.OrdinalIgnoreCase))
                quota.source=prefix+quota.source;
        }

        if(!string.IsNullOrWhiteSpace(quota.evidence) &&
           !quota.evidence.StartsWith("non-inference probe:",StringComparison.OrdinalIgnoreCase))
            quota.evidence="non-inference probe: "+quota.evidence;

        _engine.RecordQuotaObservation(
            "connection:"+connectionName,
            "connection",
            quota,
            profile);
    }

    async Task<ProbeResult> ProbeAsync(
        ConnectionProfile p,
        ProviderProbePlan plan,
        CancellationToken token)
    {
        try
        {
            using var request=new HttpRequestMessage(HttpMethod.Get,plan.Uri);
            foreach(var h in p.headers) request.Headers.TryAddWithoutValidation(h.Key,h.Value);
            var key=ResolveKey(p);
            if(!string.IsNullOrWhiteSpace(key))
            {
                switch((p.authKind??"bearer").Trim().ToLowerInvariant())
                {
                    case "x-api-key": request.Headers.TryAddWithoutValidation("x-api-key",key); break;
                    case "x-goog-api-key": request.Headers.TryAddWithoutValidation("x-goog-api-key",key); break;
                    case "none": break;
                    default: request.Headers.Authorization=new AuthenticationHeaderValue("Bearer",key); break;
                }
            }

            using var response=await _http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,token);
            var headers=Headers(response);
            var body=(!response.IsSuccessStatusCode || plan.ReadBody)
                ? await ReadBodyBounded(response,token)
                : "";
            var quota=QuotaIntelligence.Observe(
                p.presetId,
                (int)response.StatusCode,
                headers,
                body,
                response.IsSuccessStatusCode);
            quota.appliesTo=plan.AppliesTo;

            if(response.IsSuccessStatusCode)
                return new ProbeResult(
                    true,(int)response.StatusCode,"","",quota,plan);

            var metadata=string.Join(" ",headers.Select(h=>$"{h.Key}: {h.Value}"));
            var text=$"HTTP {(int)response.StatusCode} {response.ReasonPhrase} {metadata} {body}".Trim();
            return new ProbeResult(
                false,
                (int)response.StatusCode,
                FailurePolicy.Classify(text,(int)response.StatusCode),
                text,
                quota,
                plan);
        }
        catch(TaskCanceledException ex) when(!token.IsCancellationRequested)
        {
            var quota=QuotaIntelligence.Observe(p.presetId,null,null,ex.Message,false);
            quota.appliesTo=plan.AppliesTo;
            return new ProbeResult(false,0,"timeout",ex.Message,quota,plan);
        }
        catch(Exception ex)
        {
            var quota=QuotaIntelligence.Observe(p.presetId,null,null,ex.Message,false);
            quota.appliesTo=plan.AppliesTo;
            return new ProbeResult(
                false,0,FailurePolicy.Classify(ex.Message),ex.Message,quota,plan);
        }
    }

    static Dictionary<string,string> Headers(HttpResponseMessage response)
    {
        var result=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        foreach(var h in response.Headers) result[h.Key]=string.Join(",",h.Value);
        foreach(var h in response.Content.Headers) result[h.Key]=string.Join(",",h.Value);
        return result;
    }

    static async Task<string> ReadBodyBounded(
        HttpResponseMessage response,
        CancellationToken token)
    {
        var body=await response.Content.ReadAsStringAsync(token);
        return body.Length<=16384 ? body : body[..16384];
    }

    static string? ResolveKey(ConnectionProfile p)
    {
        if(!string.IsNullOrWhiteSpace(p.apiKeyEnv))
        {
            var env=Environment.GetEnvironmentVariable(p.apiKeyEnv);
            if(!string.IsNullOrWhiteSpace(env)) return env;
        }
        if(string.IsNullOrWhiteSpace(p.apiKeyProtected)) return null;
        try
        {
            var bytes=Convert.FromBase64String(p.apiKeyProtected);
            var clear=ProtectedData.Unprotect(bytes,null,DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(clear);
        }
        catch { return null; }
    }
}

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
        QuotaObservation Quota);

    readonly RouterEngine _engine;
    readonly RouterStore _store;
    readonly HttpClient _http=new(){Timeout=TimeSpan.FromSeconds(15)};
    readonly Dictionary<string,DateTimeOffset> _nextQuotaProbe=new(StringComparer.OrdinalIgnoreCase);
    static readonly TimeSpan HealthyProbeInterval=TimeSpan.FromMinutes(5);

    public EndpointMonitor(RouterEngine engine)
    {
        _engine=engine;_store=engine.Store;
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("StatefulClanker-Router/0.2");
    }

    public async Task RunAsync(CancellationToken token)
    {
        while(!token.IsCancellationRequested)
        {
            try { await TickAsync(token); } catch { }
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

            // Endpoint cooldowns are restored by one real request after the exact
            // provider window (when known) or fallback backoff expires. A synthetic
            // metadata request may have an entirely separate quota and must not burn
            // free inference just to test the bucket.
            if(string.Equals(entry.scope,"endpoint",StringComparison.OrdinalIgnoreCase))
            {
                _engine.MarkHealthy(key);
                continue;
            }

            // Billing windows likewise become eligible at the observed reset time.
            // The next real inference is authoritative.
            if(entry.reason=="billing_exhausted")
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
                    var result=await ProbeAsync(candidate.Value,token);
                    RecordQuota(candidate.Key,candidate.Value,result.Quota);
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
                        // A service probe made through one credential can reveal that
                        // credential/model is bad without proving the provider host is
                        // down.
                        _engine.MarkHealthy(key);
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

        // Independently sample one healthy/non-quarantined connection per tick. This
        // gradually learns provider-reported quota windows without a startup burst.
        await ObserveOneConnectionAsync(connections,now,token);
    }

    async Task ObserveOneConnectionAsync(
        Dictionary<string,ConnectionProfile> connections,
        DateTimeOffset now,
        CancellationToken token)
    {
        foreach(var kv in connections.OrderBy(x=>x.Key,StringComparer.OrdinalIgnoreCase))
        {
            if(SkipPeriodicProbe(kv.Value)) continue;
            if(_nextQuotaProbe.TryGetValue(kv.Key,out var due) && due>now) continue;

            _nextQuotaProbe[kv.Key]=now.Add(HealthyProbeInterval);
            var result=await ProbeAsync(kv.Value,token);
            RecordQuota(kv.Key,kv.Value,result.Quota);

            // A metadata probe is evidence of a broken credential, but its own
            // 429/5xx window is not necessarily the inference window. Record those
            // quota signals without poisoning healthy inference routes.
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

    async Task ProbeConnectionHealthAsync(string name,ConnectionProfile profile,CancellationToken token)
    {
        var result=await ProbeAsync(profile,token);
        RecordQuota(name,profile,result.Quota);
        var key="connection:"+name;
        if(result.Success) _engine.MarkHealthy(key);
        else _engine.RegisterFailureKey(key,"connection",result.FailureClass,result.Message,profile);
    }

    void RecordQuota(string connectionName,ConnectionProfile profile,QuotaObservation quota)
    {
        _engine.RecordQuotaObservation("connection:"+connectionName,"connection",quota,profile);
    }

    async Task<ProbeResult> ProbeAsync(ConnectionProfile p,CancellationToken token)
    {
        try
        {
            var uri=ProbeUri(p);
            using var request=new HttpRequestMessage(HttpMethod.Get,uri);
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
            var readBody=!response.IsSuccessStatusCode ||
                         string.Equals(p.presetId,"openrouter",StringComparison.OrdinalIgnoreCase);
            var body=readBody ? await ReadBodyBounded(response,token) : "";
            var quota=QuotaIntelligence.Observe(
                p.presetId,
                (int)response.StatusCode,
                headers,
                body,
                response.IsSuccessStatusCode);

            if(response.IsSuccessStatusCode)
                return new ProbeResult(true,(int)response.StatusCode,"","",quota);

            var metadata=string.Join(" ",headers.Select(h=>$"{h.Key}: {h.Value}"));
            var text=$"HTTP {(int)response.StatusCode} {response.ReasonPhrase} {metadata} {body}".Trim();
            return new ProbeResult(
                false,
                (int)response.StatusCode,
                FailurePolicy.Classify(text,(int)response.StatusCode),
                text,
                quota);
        }
        catch(TaskCanceledException ex) when(!token.IsCancellationRequested)
        {
            return new ProbeResult(
                false,0,"timeout",ex.Message,
                QuotaIntelligence.Observe(p.presetId,null,null,ex.Message,false));
        }
        catch(Exception ex)
        {
            return new ProbeResult(
                false,0,FailurePolicy.Classify(ex.Message),ex.Message,
                QuotaIntelligence.Observe(p.presetId,null,null,ex.Message,false));
        }
    }

    static Dictionary<string,string> Headers(HttpResponseMessage response)
    {
        var result=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        foreach(var h in response.Headers) result[h.Key]=string.Join(",",h.Value);
        foreach(var h in response.Content.Headers) result[h.Key]=string.Join(",",h.Value);
        return result;
    }

    static async Task<string> ReadBodyBounded(HttpResponseMessage response,CancellationToken token)
    {
        var body=await response.Content.ReadAsStringAsync(token);
        return body.Length<=16384 ? body : body[..16384];
    }

    static Uri ProbeUri(ConnectionProfile p)
    {
        // OpenRouter exposes authenticated key budget/reset metadata without
        // consuming inference. Other providers are sampled through their existing
        // model-list endpoint, harvesting whatever quota headers they return.
        if(string.Equals(p.presetId,"openrouter",StringComparison.OrdinalIgnoreCase))
            return new Uri("https://openrouter.ai/api/v1/key");
        return ModelsUri(p);
    }

    static Uri ModelsUri(ConnectionProfile p)
    {
        var baseUri=p.baseUrl.TrimEnd('/');
        var path=string.IsNullOrWhiteSpace(p.modelsPath)?"/models":p.modelsPath;
        if(Uri.TryCreate(path,UriKind.Absolute,out var absolute)) return absolute;
        return new Uri(baseUri+"/"+path.TrimStart('/'));
    }

    static bool SkipPeriodicProbe(ConnectionProfile p)
    {
        var id=(p.presetId??"").Trim().ToLowerInvariant();
        if(id is "ollama" or "lmstudio" or "vllm") return true;
        if(string.IsNullOrWhiteSpace(p.baseUrl)) return true;
        return false;
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

using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;

namespace StatefulClanker.Router;

public sealed class EndpointMonitor
{
    readonly RouterEngine _engine;
    readonly RouterStore _store;
    readonly HttpClient _http=new(){Timeout=TimeSpan.FromSeconds(15)};

    public EndpointMonitor(RouterEngine engine)
    {
        _engine=engine;_store=engine.Store;
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("StatefulClanker-Router/0.1");
    }

    public async Task RunAsync(CancellationToken token)
    {
        while(!token.IsCancellationRequested)
        {
            try { await TickAsync(token); } catch { }
            try { await Task.Delay(TimeSpan.FromSeconds(2),token); } catch(OperationCanceledException) { break; }
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

            // Endpoint cooldowns represent model/quota windows. When their provider
            // supplied or inferred window expires, admit exactly one real request
            // again; that request is the authoritative quota probe.
            if(string.Equals(entry.scope,"endpoint",StringComparison.OrdinalIgnoreCase))
            {
                _engine.MarkHealthy(key);
                continue;
            }

            // Billing recovery is likewise only knowable from a real inference call.
            if(entry.reason=="billing_exhausted")
            {
                _engine.MarkHealthy(key);
                continue;
            }

            if(key.StartsWith("connection:",StringComparison.OrdinalIgnoreCase))
            {
                var name=key["connection:".Length..];
                if(connections.TryGetValue(name,out var c))
                    await ProbeConnectionAsync(name,c,token);
                continue;
            }

            if(key.StartsWith("service:",StringComparison.OrdinalIgnoreCase))
            {
                var service=key["service:".Length..];
                var candidate=connections.FirstOrDefault(x=>string.Equals(RouterEngine.ServiceName(x.Value),service,StringComparison.OrdinalIgnoreCase));
                if(!string.IsNullOrWhiteSpace(candidate.Key))
                {
                    var result=await ProbeAsync(candidate.Value,token);
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
                        // down. Do not let a 401/403/billing/model error poison every
                        // independent account on the service.
                        _engine.MarkHealthy(key);
                        _engine.RegisterFailureKey("connection:"+candidate.Key,"connection",result.FailureClass,result.Message,candidate.Value);
                    }
                }
                else _engine.MarkHealthy(key);
            }
        }
    }

    async Task ProbeConnectionAsync(string name,ConnectionProfile profile,CancellationToken token)
    {
        var result=await ProbeAsync(profile,token);
        var key="connection:"+name;
        if(result.Success) _engine.MarkHealthy(key);
        else _engine.RegisterFailureKey(key,"connection",result.FailureClass,result.Message,profile);
    }

    async Task<(bool Success,string FailureClass,string Message)> ProbeAsync(ConnectionProfile p,CancellationToken token)
    {
        try
        {
            var uri=ModelsUri(p);
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
            if(response.IsSuccessStatusCode) return (true,"","");

            var body=await response.Content.ReadAsStringAsync(token);
            var metadata=string.Join(" ",response.Headers.Select(h=>$"{h.Key}: {string.Join(",",h.Value)}"));
            var text=$"HTTP {(int)response.StatusCode} {response.ReasonPhrase} {metadata} {body}";
            return (false,FailurePolicy.Classify(text,(int)response.StatusCode),text);
        }
        catch(TaskCanceledException ex) when(!token.IsCancellationRequested)
        {
            return (false,"timeout",ex.Message);
        }
        catch(Exception ex)
        {
            return (false,FailurePolicy.Classify(ex.Message),ex.Message);
        }
    }

    static Uri ModelsUri(ConnectionProfile p)
    {
        var baseUri=p.baseUrl.TrimEnd('/');
        var path=string.IsNullOrWhiteSpace(p.modelsPath)?"/models":p.modelsPath;
        if(Uri.TryCreate(path,UriKind.Absolute,out var absolute)) return absolute;
        return new Uri(baseUri+"/"+path.TrimStart('/'));
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

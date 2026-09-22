using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace StatefulClanker.Router;

public sealed class FreeCapacityManager
{
    readonly RouterEngine _engine;
    readonly RouterStore _store;
    readonly HttpClient _http=new(){Timeout=TimeSpan.FromSeconds(20)};
    readonly Dictionary<string,DateTimeOffset> _nextSync=new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string,bool> _quotaUseful=new(StringComparer.OrdinalIgnoreCase);

    static readonly TimeSpan SuccessInterval=TimeSpan.FromMinutes(20);
    static readonly TimeSpan FailureInterval=TimeSpan.FromMinutes(5);

    public FreeCapacityManager(RouterEngine engine)
    {
        _engine=engine;
        _store=engine.Store;
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("StatefulClanker-FreeCapacity/0.1");
    }

    public async Task RunAsync(CancellationToken token)
    {
        while(!token.IsCancellationRequested)
        {
            try { await TickAsync(token); } catch { }
            try { await Task.Delay(TimeSpan.FromSeconds(2),token); }
            catch(OperationCanceledException){break;}
        }
    }

    public async Task TickAsync(CancellationToken token=default)
    {
        var now=DateTimeOffset.UtcNow;
        var connections=_store.LoadConnections().connections;
        foreach(var kv in connections.OrderBy(x=>x.Key,StringComparer.OrdinalIgnoreCase))
        {
            if(_nextSync.TryGetValue(kv.Key,out var due) && due>now) continue;
            var ok=await SyncConnectionAsync(kv.Key,kv.Value,token);
            var plan=ProviderProbeCatalog.Resolve(kv.Value);
            var interval=FailureInterval;
            if(ok)
            {
                if(plan.Kind==ProviderProbeKind.Models)
                    interval=_quotaUseful.TryGetValue(kv.Key,out var useful) && useful
                        ? plan.UsefulInterval
                        : plan.SilentInterval;
                else
                    interval=SuccessInterval;
            }
            _nextSync[kv.Key]=now.Add(interval);
            break; // one connection per tick; never turn discovery into probe spam
        }
    }

    public async Task<bool> SyncConnectionAsync(string connectionName,ConnectionProfile profile,CancellationToken token=default)
    {
        if(ProviderProbeCatalog.IsRetired(profile))
        {
            RecordFailure(connectionName,"provider retired");
            DisableManagedConnection(connectionName,"provider-retired");
            return false;
        }

        try
        {
            var uri=ModelsUri(profile);
            using var request=new HttpRequestMessage(HttpMethod.Get,uri);
            ApplyHeaders(request,profile);
            using var response=await _http.SendAsync(request,HttpCompletionOption.ResponseContentRead,token);
            var body=await response.Content.ReadAsStringAsync(token);
            var quota=QuotaIntelligence.Observe(
                profile.presetId,
                (int)response.StatusCode,
                Headers(response),
                body,
                response.IsSuccessStatusCode);
            RecordQuota(connectionName,profile,quota);
            _quotaUseful[connectionName]=HasQuotaSignal(quota);
            if(!response.IsSuccessStatusCode)
            {
                RecordFailure(connectionName,$"HTTP {(int)response.StatusCode} {response.ReasonPhrase}");
                return false;
            }

            var models=ParseModels(body,profile);
            if(models.Count==0)
            {
                RecordFailure(connectionName,"catalog returned no discoverable models");
                return false;
            }

            var now=DateTimeOffset.UtcNow;
            var states=models.Select(m=>Classify(profile,m,now)).ToList();
            ApplyLifecycle(connectionName,states,now);
            RecordSuccess(connectionName,states,now);
            return true;
        }
        catch(OperationCanceledException) when(token.IsCancellationRequested){throw;}
        catch(Exception ex)
        {
            RecordFailure(connectionName,ex.Message);
            return false;
        }
    }

    void ApplyLifecycle(string connectionName,List<CapacityModelState> states,DateTimeOffset now)
    {
        var byId=states.ToDictionary(x=>x.model,StringComparer.OrdinalIgnoreCase);
        var eligible=states.Where(x=>IsZeroCostCapacityClass(x.classification) && x.workhorse).ToList();

        _store.UpdateEndpoints(doc =>
        {
            foreach(var model in eligible)
            {
                var key=Id(connectionName,model.model);
                if(doc.entries.TryGetValue(key,out var existing))
                {
                    existing.displayName=model.displayName;
                    existing.free=true;
                    existing.supportsTools=model.supportsTools;
                    existing.contextLength=model.contextLength;
                    existing.lastSeenAt=now.ToString("O");
                    existing.discoveryMisses=0;
                    existing.missingSince=null;

                    if(string.Equals(existing.managedBy,"free-capacity",StringComparison.OrdinalIgnoreCase))
                    {
                        existing.freeClass=model.classification;
                        existing.freeEvidence=model.evidence;
                        existing.retiredReason=null;
                        existing.rationale="Automatically maintained from the configured connection's live zero-cost catalog.";
                        existing.updatedAt=now.ToString("O");
                        existing.toolMode=model.supportsTools==false?"text":"native";
                        existing.enabled=!string.Equals(existing.userOverride,"disabled",StringComparison.OrdinalIgnoreCase);
                        existing.workhorse=true;
                    }
                    doc.entries[key]=existing;
                    continue;
                }

                doc.entries[key]=new EndpointEntry
                {
                    id=key,
                    connection=connectionName,
                    model=model.model,
                    displayName=model.displayName,
                    enabled=true,
                    workhorse=true,
                    free=true,
                    supportsTools=model.supportsTools,
                    contextLength=model.contextLength,
                    toolMode=model.supportsTools==false?"text":"native",
                    source="auto-free-discovery",
                    rationale="Automatically maintained from the configured connection's live zero-cost catalog.",
                    managedBy="free-capacity",
                    freeClass=model.classification,
                    freeEvidence=model.evidence,
                    lastSeenAt=now.ToString("O"),
                    updatedAt=now.ToString("O")
                };
            }

            foreach(var kv in doc.entries.ToArray())
            {
                var e=kv.Value;
                if(!string.Equals(e.connection,connectionName,StringComparison.OrdinalIgnoreCase) ||
                   !string.Equals(e.managedBy,"free-capacity",StringComparison.OrdinalIgnoreCase))
                    continue;

                if(byId.TryGetValue(e.model,out var discovered))
                {
                    e.lastSeenAt=now.ToString("O");
                    e.discoveryMisses=0;
                    e.missingSince=null;
                    e.freeClass=discovered.classification;
                    e.freeEvidence=discovered.evidence;
                    e.supportsTools=discovered.supportsTools;
                    e.contextLength=discovered.contextLength;
                    e.displayName=discovered.displayName;
                    e.free=IsZeroCostCapacityClass(discovered.classification);

                    if(!IsZeroCostCapacityClass(discovered.classification))
                    {
                        e.enabled=false;
                        e.retiredReason=discovered.classification=="paid"?"no-longer-zero-cost":
                            discovered.workhorse?"free-status-unconfirmed":"not-workhorse";
                    }
                    else if(!discovered.workhorse)
                    {
                        e.enabled=false;
                        e.retiredReason="not-workhorse";
                    }
                    else
                    {
                        e.retiredReason=null;
                        e.enabled=!string.Equals(e.userOverride,"disabled",StringComparison.OrdinalIgnoreCase);
                    }
                    e.updatedAt=now.ToString("O");
                    doc.entries[kv.Key]=e;
                    continue;
                }

                e.discoveryMisses=Math.Max(0,e.discoveryMisses)+1;
                e.missingSince ??= now.ToString("O");
                if(e.discoveryMisses>=2)
                {
                    e.enabled=false;
                    e.retiredReason="catalog-missing";
                }
                e.updatedAt=now.ToString("O");
                doc.entries[kv.Key]=e;
            }
            return 0;
        });
    }

    void DisableManagedConnection(string connectionName,string reason)
    {
        _store.UpdateEndpoints(doc =>
        {
            foreach(var kv in doc.entries.ToArray())
            {
                var e=kv.Value;
                if(!string.Equals(e.connection,connectionName,StringComparison.OrdinalIgnoreCase) ||
                   !string.Equals(e.managedBy,"free-capacity",StringComparison.OrdinalIgnoreCase))
                    continue;
                e.enabled=false;e.retiredReason=reason;e.updatedAt=DateTimeOffset.UtcNow.ToString("O");
                doc.entries[kv.Key]=e;
            }
            return 0;
        });
    }

    void RecordSuccess(string connection,List<CapacityModelState> models,DateTimeOffset now)
    {
        _store.UpdateCapacityDiscovery(doc =>
        {
            doc.connections[connection]=new CapacityConnectionState
            {
                lastSyncAt=now.ToString("O"),
                lastSuccessAt=now.ToString("O"),
                lastError=null,
                modelCount=models.Count,
                confirmedFree=models.Count(x=>IsZeroCostCapacityClass(x.classification)),
                paid=models.Count(x=>x.classification=="paid"),
                unknown=models.Count(x=>x.classification=="unknown"),
                workhorseFree=models.Count(x=>IsZeroCostCapacityClass(x.classification)&&x.workhorse),
                models=models.OrderBy(x=>x.displayName,StringComparer.OrdinalIgnoreCase).ToList()
            };
            return 0;
        });
    }

    void RecordFailure(string connection,string error)
    {
        _store.UpdateCapacityDiscovery(doc =>
        {
            if(!doc.connections.TryGetValue(connection,out var state)) state=new CapacityConnectionState();
            state.lastSyncAt=DateTimeOffset.UtcNow.ToString("O");
            state.lastError=Bound(error,500);
            doc.connections[connection]=state;
            return 0;
        });
    }

    static CapacityModelState Classify(ConnectionProfile profile,DiscoveredModel model,DateTimeOffset now)
    {
        var family=ProviderFamily(profile);
        var classification="unknown";
        var evidence="Catalog does not prove zero cost.";

        if(model.ExplicitPaid==true || model.AnyPositivePrice)
        {
            classification="paid";
            evidence=model.ExplicitPaid==true
                ? "Live catalog marks this model paid-only."
                : "Live catalog reports a positive price.";
        }
        else if(model.ExplicitFree==true || model.AllKnownPricesZero)
        {
            classification="confirmed_free";
            evidence=model.ExplicitFree==true
                ? "Live catalog marks this model free."
                : "Live catalog reports zero pricing.";
        }
        else if(IsExplicitFreeId(family,model.Id))
        {
            classification="confirmed_free";
            evidence="Provider-defined model ID explicitly selects a free route.";
        }
        else if(family=="opencode-zen" && IsOpenCodeZenFreeId(model.Id))
        {
            classification="confirmed_free";
            evidence="OpenCode Zen model ID explicitly identifies a promotional free model.";
        }
        else if(family=="nvidia")
        {
            classification="trial_free";
            evidence="Configured NVIDIA hosted NIM catalog uses API Catalog trial/free-endpoint capacity; subject to NVIDIA trial terms.";
        }
        else if(family=="freellmapi")
        {
            classification="confirmed_free";
            evidence="FreeLLMAPI exposes a curated free-provider catalog.";
        }
        else if(family is "ollama" or "lmstudio" or "vllm")
        {
            classification="confirmed_free";
            evidence="Configured local inference endpoint.";
        }

        return new CapacityModelState
        {
            model=model.Id,
            displayName=model.DisplayName,
            classification=classification,
            evidence=evidence,
            workhorse=IsWorkhorse(model),
            supportsTools=model.SupportsTools,
            contextLength=model.ContextLength,
            inputPrice=model.InputPrice,
            outputPrice=model.OutputPrice,
            seenAt=now.ToString("O")
        };
    }

    static bool IsZeroCostCapacityClass(string? classification) =>
        classification is "confirmed_free" or "trial_free";

    static string ProviderFamily(ConnectionProfile profile)
    {
        var id=(profile.presetId??"custom").Trim().ToLowerInvariant();
        if(id!="custom") return id;
        try
        {
            var uri=new Uri(profile.baseUrl);
            var host=uri.Host.ToLowerInvariant();
            var path=uri.AbsolutePath.ToLowerInvariant();
            if(host.EndsWith("opencode.ai"))
                return path.Contains("/zen/go/") ? "opencode-go" : (path.Contains("/zen/") ? "opencode-zen" : id);
            if(host=="gen.pollinations.ai") return "pollinations";
            if(host=="integrate.api.nvidia.com") return "nvidia";
            if(host=="api.kilo.ai") return "kilo";
            if(host.EndsWith("openrouter.ai")) return "openrouter";
        }
        catch { }
        return id;
    }

    static bool IsExplicitFreeId(string? family,string id)
    {
        var s=id.ToLowerInvariant();
        if(s.EndsWith(":free") || s.Contains("/free") || s.Contains("auto:free") || s.StartsWith("free/"))
            return true;
        if(s.EndsWith("-free")) return true;
        if(string.Equals(family,"openrouter",StringComparison.OrdinalIgnoreCase) && s=="openrouter/free")
            return true;
        if(string.Equals(family,"kilo",StringComparison.OrdinalIgnoreCase) && s=="kilo-auto/free")
            return true;
        return false;
    }

    static bool IsOpenCodeZenFreeId(string id)
    {
        var s=id.Trim().ToLowerInvariant();
        // Zen's catalog is intentionally OpenAI-sparse and does not include
        // pricing. Stable "-free" suffixes are safe to automate. Big Pickle is
        // intentionally not hard-coded here because its free promotion can end
        // without its model id changing.
        return s.EndsWith("-free");
    }

    static bool IsWorkhorse(DiscoveredModel model)
    {
        if(model.SupportsTools==false) return false;
        if(model.ContextLength.HasValue && model.ContextLength.Value<16000) return false;
        var id=(model.Id+" "+model.DisplayName).ToLowerInvariant();
        string[] reject={
            "embedding","embed-","nv-embed","rerank","reranker","retrieval",
            "whisper","speech","audio","tts","parakeet",
            "image","flux","stable-diffusion","video","clip","fuyu",
            "moderation","guard","safety","translate","translation"
        };
        return !reject.Any(id.Contains);
    }

    static List<DiscoveredModel> ParseModels(string body,ConnectionProfile profile)
    {
        using var doc=JsonDocument.Parse(body);
        var root=doc.RootElement;
        JsonElement list=default;
        var found=false;
        if(root.ValueKind==JsonValueKind.Array){list=root;found=true;}
        else if(root.ValueKind==JsonValueKind.Object)
        {
            if(root.TryGetProperty("data",out var data)&&data.ValueKind==JsonValueKind.Array){list=data;found=true;}
            else if(root.TryGetProperty("models",out var models)&&models.ValueKind==JsonValueKind.Array){list=models;found=true;}
            else if(root.TryGetProperty("result",out var result))
            {
                if(result.ValueKind==JsonValueKind.Array){list=result;found=true;}
                else if(result.ValueKind==JsonValueKind.Object&&result.TryGetProperty("data",out var nested)&&nested.ValueKind==JsonValueKind.Array){list=nested;found=true;}
            }
        }
        if(!found) return new();

        var output=new List<DiscoveredModel>();
        foreach(var x in list.EnumerateArray())
        {
            if(x.ValueKind!=JsonValueKind.Object) continue;
            var id=Str(x,"id")??Str(x,"name")??Str(x,"model");
            if(string.IsNullOrWhiteSpace(id)) continue;
            if(string.Equals(profile.discoveryKind,"gemini",StringComparison.OrdinalIgnoreCase)&&id.StartsWith("models/",StringComparison.OrdinalIgnoreCase))
                id=id["models/".Length..];

            if(string.Equals(profile.discoveryKind,"gemini",StringComparison.OrdinalIgnoreCase) &&
               x.TryGetProperty("supportedGenerationMethods",out var methods)&&methods.ValueKind==JsonValueKind.Array &&
               !methods.EnumerateArray().Any(v=>v.ValueKind==JsonValueKind.String&&string.Equals(v.GetString(),"generateContent",StringComparison.OrdinalIgnoreCase)))
                continue;

            var m=new DiscoveredModel
            {
                Id=id,
                DisplayName=Str(x,"display_name")??Str(x,"displayName")??Str(x,"title")??Str(x,"name")??id,
                ContextLength=Long(x,"context_length")??Long(x,"max_context_length")??Long(x,"inputTokenLimit"),
                SupportsTools=Bool(x,"supports_tools")??Bool(x,"tools"),
                ExplicitFree=Bool(x,"is_free")??Bool(x,"isFree")??Bool(x,"free"),
                ExplicitPaid=Bool(x,"paid_only")??Bool(x,"isPaid")
            };

            if(m.SupportsTools is null && x.TryGetProperty("capabilities",out var caps))
            {
                if(caps.ValueKind==JsonValueKind.Object)
                    m.SupportsTools=Bool(caps,"function_calling");
                else if(caps.ValueKind==JsonValueKind.Array)
                    m.SupportsTools=caps.EnumerateArray().Any(v=>v.ValueKind==JsonValueKind.String &&
                        (string.Equals(v.GetString(),"tool_calling",StringComparison.OrdinalIgnoreCase) ||
                         string.Equals(v.GetString(),"function_calling",StringComparison.OrdinalIgnoreCase)));
            }
            if(m.SupportsTools is null && x.TryGetProperty("supported_parameters",out var supported)&&supported.ValueKind==JsonValueKind.Array)
                m.SupportsTools=supported.EnumerateArray().Any(v=>v.ValueKind==JsonValueKind.String&&(v.GetString()=="tools"||v.GetString()=="tool_choice"));
            if(string.Equals(profile.discoveryKind,"gemini",StringComparison.OrdinalIgnoreCase)) m.SupportsTools=true;

            ReadPricing(x,m);
            output.Add(m);
        }
        return output;
    }

    static void ReadPricing(JsonElement x,DiscoveredModel m)
    {
        var values=new List<double>();
        if(x.TryGetProperty("pricing",out var pricing)&&pricing.ValueKind==JsonValueKind.Object)
        {
            m.InputPrice=Number(pricing,"input")??Number(pricing,"prompt")??Number(pricing,"promptTextTokens");
            m.OutputPrice=Number(pricing,"output")??Number(pricing,"completion")??Number(pricing,"completionTextTokens");
            foreach(var p in pricing.EnumerateObject())
            {
                if(string.Equals(p.Name,"currency",StringComparison.OrdinalIgnoreCase)) continue;
                if(TryNumber(p.Value,out var n)) values.Add(n);
            }
        }
        m.InputPrice ??= Number(x,"input_price");
        m.OutputPrice ??= Number(x,"output_price");
        if(m.InputPrice is double input && !values.Contains(input)) values.Add(input);
        if(m.OutputPrice is double output && !values.Contains(output)) values.Add(output);
        m.AnyPositivePrice=values.Any(v=>v>0);
        m.AllKnownPricesZero=values.Count>=2 && values.All(v=>Math.Abs(v)<1e-15);
    }

    static bool TryNumber(JsonElement v,out double value)
    {
        if(v.ValueKind==JsonValueKind.Number && v.TryGetDouble(out value)) return true;
        if(v.ValueKind==JsonValueKind.String &&
           double.TryParse(v.GetString(),System.Globalization.NumberStyles.Float,
               System.Globalization.CultureInfo.InvariantCulture,out value)) return true;
        value=0;
        return false;
    }

    void RecordQuota(string connectionName,ConnectionProfile profile,QuotaObservation quota)
    {
        if(quota.source!="none"&&!quota.source.StartsWith("catalog:",StringComparison.OrdinalIgnoreCase))
            quota.source="catalog:"+quota.source;
        if(!string.IsNullOrWhiteSpace(quota.evidence)&&!quota.evidence.StartsWith("catalog refresh:",StringComparison.OrdinalIgnoreCase))
            quota.evidence="catalog refresh: "+quota.evidence;
        _engine.RecordQuotaObservation("connection:"+connectionName,"connection",quota,profile);
    }

    static bool HasQuotaSignal(QuotaObservation q) =>
        q.nextAvailableAt is not null || q.resetAt is not null ||
        q.remaining is not null || q.limit is not null ||
        q.windows.Count>0 || !string.Equals(q.source,"none",StringComparison.OrdinalIgnoreCase);

    static Dictionary<string,string> Headers(HttpResponseMessage response)
    {
        var result=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        foreach(var h in response.Headers) result[h.Key]=string.Join(",",h.Value);
        foreach(var h in response.Content.Headers) result[h.Key]=string.Join(",",h.Value);
        return result;
    }

    static void ApplyHeaders(HttpRequestMessage request,ConnectionProfile p)
    {
        foreach(var h in p.headers) request.Headers.TryAddWithoutValidation(h.Key,h.Value);
        var key=ResolveKey(p);
        if(string.IsNullOrWhiteSpace(key)) return;
        switch((p.authKind??"bearer").Trim().ToLowerInvariant())
        {
            case "x-api-key": request.Headers.TryAddWithoutValidation("x-api-key",key); break;
            case "x-goog-api-key": request.Headers.TryAddWithoutValidation("x-goog-api-key",key); break;
            case "none": break;
            default: request.Headers.Authorization=new AuthenticationHeaderValue("Bearer",key); break;
        }
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
        catch{return null;}
    }

    static Uri ModelsUri(ConnectionProfile p)
    {
        var account=p.accountId?.Trim() ?? "";
        var baseUri=(p.baseUrl ?? "").Replace("{accountId}",account,StringComparison.OrdinalIgnoreCase).TrimEnd('/');
        var path=(string.IsNullOrWhiteSpace(p.modelsPath)?"/models":p.modelsPath)
            .Replace("{accountId}",account,StringComparison.OrdinalIgnoreCase);
        if(Uri.TryCreate(path,UriKind.Absolute,out var absolute)) return absolute;
        return new Uri(baseUri+"/"+path.TrimStart('/'));
    }

    static string Id(string connection,string model)=>connection.Trim()+"::"+model.Trim();
    static string? Str(JsonElement x,string name)=>x.TryGetProperty(name,out var v)&&v.ValueKind==JsonValueKind.String?v.GetString():null;
    static long? Long(JsonElement x,string name)=>x.TryGetProperty(name,out var v)&&v.TryGetInt64(out var n)?n:null;
    static bool? Bool(JsonElement x,string name)=>x.TryGetProperty(name,out var v)?v.ValueKind switch{JsonValueKind.True=>true,JsonValueKind.False=>false,_=>null}:null;
    static double? Number(JsonElement x,string name)
    {
        if(!x.TryGetProperty(name,out var v)) return null;
        if(v.ValueKind==JsonValueKind.Number&&v.TryGetDouble(out var n)) return n;
        if(v.ValueKind==JsonValueKind.String&&double.TryParse(v.GetString(),System.Globalization.NumberStyles.Float,System.Globalization.CultureInfo.InvariantCulture,out n)) return n;
        return null;
    }
    static string Bound(string? text,int max)
    {
        if(string.IsNullOrWhiteSpace(text)) return "";
        var s=text.Replace("\r"," ").Replace("\n"," ").Trim();
        return s.Length<=max?s:s[..max];
    }

    sealed class DiscoveredModel
    {
        public string Id="";
        public string DisplayName="";
        public long? ContextLength;
        public bool? SupportsTools;
        public bool? ExplicitFree;
        public bool? ExplicitPaid;
        public double? InputPrice;
        public double? OutputPrice;
        public bool AnyPositivePrice;
        public bool AllKnownPricesZero;
    }
}

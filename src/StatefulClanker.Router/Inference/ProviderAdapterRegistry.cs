using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace StatefulClanker.Router;

public interface IProviderAdapter
{
    string Id { get; }
    string SourcePath { get; }
    bool CanHandle(ConnectionProfile connection);
    AdapterRequest BuildRequest(ConnectionProfile connection,EndpointEntry endpoint,NormalizedInferenceRequest request,string? apiKey);
    AdapterParseResult ParseSuccess(string body,EndpointEntry endpoint);
}

public sealed class ProviderAdapterRegistry
{
    readonly IProviderAdapter[] _adapters =
    {
        new AnthropicMessagesAdapter(),
        new GeminiNativeAdapter(),
        new OpenAiChatAdapter()
    };

    public IProviderAdapter Resolve(ConnectionProfile connection)
    {
        var adapter=_adapters.FirstOrDefault(x=>x.CanHandle(connection));
        return adapter ?? throw new InvalidOperationException($"No inference adapter handles protocol '{connection.protocol}'.");
    }

    public IReadOnlyList<object> Describe() => _adapters.Select(x=>(object)new
    {
        id=x.Id,
        source=x.SourcePath
    }).ToArray();
}

public static class AdapterJson
{
    public static object ParseArguments(string? json)
    {
        if(string.IsNullOrWhiteSpace(json)) return new Dictionary<string,object?>();
        try{return JsonSerializer.Deserialize<JsonElement>(json);}
        catch{return new Dictionary<string,object?>();}
    }

    public static long Long(JsonElement obj,params string[] names)
    {
        foreach(var name in names)
        {
            if(!obj.TryGetProperty(name,out var value)) continue;
            if(value.ValueKind==JsonValueKind.Number && value.TryGetInt64(out var n)) return n;
        }
        return 0;
    }
}

public static class AdapterHttp
{
    public static HttpRequestMessage JsonRequest(
        HttpMethod method,
        string uri,
        ConnectionProfile connection,
        string? apiKey,
        object body,
        string protocol,
        string toolMode,
        string? sessionKey=null,
        IEnumerable<string>? extraHeaderNames=null)
    {
        var request=new HttpRequestMessage(method,uri);
        foreach(var h in connection.headers)
        {
            if(string.Equals(h.Key,"content-type",StringComparison.OrdinalIgnoreCase)) continue;
            var value=h.Value;
            if(string.Equals(h.Key,"x-opencode-session",StringComparison.OrdinalIgnoreCase) &&
               string.Equals(value,"project",StringComparison.OrdinalIgnoreCase))
                value=string.IsNullOrWhiteSpace(sessionKey)?"statefulclanker-router":sessionKey;
            request.Headers.TryAddWithoutValidation(h.Key,value);
        }

        ApplyConfiguredAuth(request,connection,apiKey);

        var json=JsonSerializer.Serialize(body);
        request.Content=new StringContent(json,new UTF8Encoding(false),"application/json");
        request.Options.Set(RequestEvidenceKey,new SanitizedRequestEvidence
        {
            method=method.Method,
            uri=uri,
            headersPresent=HeaderNames(request,extraHeaderNames),
            headersRedacted=true,
            bodyShape=new SanitizedBodyShape
            {
                topLevelKeys=TopLevelKeys(json),
                protocol=protocol,
                toolMode=toolMode
            }
        });
        return request;
    }

    public static readonly HttpRequestOptionsKey<SanitizedRequestEvidence> RequestEvidenceKey =
        new("StatefulClanker.SanitizedRequestEvidence");

    public static void ApplyConfiguredAuth(HttpRequestMessage request,ConnectionProfile profile,string? apiKey)
    {
        if(string.IsNullOrWhiteSpace(apiKey)) return;
        switch((profile.authKind??"bearer").Trim().ToLowerInvariant())
        {
            case "x-api-key":
                request.Headers.TryAddWithoutValidation("x-api-key",apiKey);
                break;
            case "x-goog-api-key":
                request.Headers.TryAddWithoutValidation("x-goog-api-key",apiKey);
                break;
            case "none":
                break;
            default:
                request.Headers.Authorization=new AuthenticationHeaderValue("Bearer",apiKey);
                break;
        }
    }

    public static SanitizedRequestEvidence Evidence(HttpRequestMessage request)
    {
        if(request.Options.TryGetValue(RequestEvidenceKey,out SanitizedRequestEvidence? evidence) && evidence is not null)
            return evidence;
        return new SanitizedRequestEvidence
        {
            method=request.Method.Method,
            uri=request.RequestUri?.ToString()??"",
            headersPresent=HeaderNames(request),
            headersRedacted=true
        };
    }

    static List<string> HeaderNames(HttpRequestMessage request,IEnumerable<string>? extras=null)
    {
        var names=request.Headers.Select(x=>x.Key)
            .Concat(request.Content?.Headers.Select(x=>x.Key)??Array.Empty<string>())
            .Concat(extras??Array.Empty<string>())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(x=>x,StringComparer.OrdinalIgnoreCase)
            .ToList();
        return names;
    }

    static List<string> TopLevelKeys(string json)
    {
        try
        {
            using var doc=JsonDocument.Parse(json);
            if(doc.RootElement.ValueKind!=JsonValueKind.Object) return new();
            return doc.RootElement.EnumerateObject().Select(x=>x.Name).OrderBy(x=>x,StringComparer.OrdinalIgnoreCase).ToList();
        }
        catch{return new();}
    }
}

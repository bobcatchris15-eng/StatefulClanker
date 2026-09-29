using System.Text.Json;
using System.Text.Json.Serialization;

namespace StatefulClanker.Router;

public sealed class NormalizedInferenceRequest
{
    // prompt/testTools remain as a compact convenience surface for test_endpoint.
    public string prompt { get; set; } = "Reply with exactly: CLANKER_OK";
    public bool testTools { get; set; }
    public List<NormalizedInferenceMessage> messages { get; set; } = new();
    public List<NormalizedToolDefinition> tools { get; set; } = new();
    public string toolMode { get; set; } = "text";
    public int maxOutputTokens { get; set; } = 4096;
    public double? temperature { get; set; }
    public int timeoutSeconds { get; set; } = 300;
    public string? sessionKey { get; set; }
    public int maxRouteAttempts { get; set; } = 6;
    public int maxRouteWaitSeconds { get; set; } = 20;

    public void EnsureDiagnosticConversation()
    {
        if(messages.Count==0)
            messages.Add(new NormalizedInferenceMessage{role="user",content=prompt});
        if(testTools && tools.Count==0)
        {
            tools.Add(new NormalizedToolDefinition
            {
                type="function",
                function=new NormalizedFunctionDefinition
                {
                    name="clanker_probe",
                    description="Harmless endpoint diagnostic tool.",
                    parameters=JsonSerializer.Deserialize<JsonElement>("{\"type\":\"object\",\"properties\":{}}")
                }
            });
        }
        if(testTools) toolMode="native";
    }
}

public sealed class NormalizedInferenceMessage
{
    public string role { get; set; } = "user";
    public string? content { get; set; }
    public List<NormalizedToolCall>? tool_calls { get; set; }
    public string? tool_call_id { get; set; }
}

public sealed class NormalizedToolCall
{
    public string id { get; set; } = "";
    public string type { get; set; } = "function";
    public NormalizedFunctionCall function { get; set; } = new();
    public string? thought_signature { get; set; }
}

public sealed class NormalizedFunctionCall
{
    public string name { get; set; } = "";
    public string arguments { get; set; } = "{}";
}

public sealed class NormalizedToolDefinition
{
    public string type { get; set; } = "function";
    public NormalizedFunctionDefinition function { get; set; } = new();
}

public sealed class NormalizedFunctionDefinition
{
    public string name { get; set; } = "";
    public string description { get; set; } = "";
    public JsonElement parameters { get; set; }
}

public sealed class NormalizedUsage
{
    public string? model { get; set; }
    public long promptTokens { get; set; }
    public long completionTokens { get; set; }
    public long totalTokens { get; set; }
    public bool reported { get; set; }
}

public sealed class RoutingAttemptRecord
{
    public int attempt { get; set; }
    public string endpoint { get; set; } = "";
    public string connection { get; set; } = "";
    public string model { get; set; } = "";
    public string outcome { get; set; } = "";
    public string? failureClass { get; set; }
    public string? scope { get; set; }
    public string? reasonCode { get; set; }
    public double durationSeconds { get; set; }
}

public sealed class NormalizedInferenceResult
{
    public bool ok { get; set; }
    public string endpoint { get; set; } = "";
    public string connection { get; set; } = "";
    public string model { get; set; } = "";
    public string adapterId { get; set; } = "";
    public string adapterSource { get; set; } = "";
    public NormalizedInferenceMessage? assistant { get; set; }
    public NormalizedUsage usage { get; set; } = new();
    public SanitizedRequestEvidence request { get; set; } = new();
    public SanitizedResponseEvidence response { get; set; } = new();
    public InferenceDiagnosis diagnosis { get; set; } = new();
    public bool failoverAllowed { get; set; }
    public bool healthChanged { get; set; }
    public bool routeDeferred { get; set; }
    public bool routeExhausted { get; set; }
    public string? nextRetryAt { get; set; }
    public int routeAttempts { get; set; }
    public List<RoutingAttemptRecord> routeHistory { get; set; } = new();
    public string? signalRef { get; set; }
}

public sealed class SanitizedBodyShape
{
    public List<string> topLevelKeys { get; set; } = new();
    public string protocol { get; set; } = "";
    public string toolMode { get; set; } = "text";
}

public sealed class SanitizedRequestEvidence
{
    public string method { get; set; } = "POST";
    public string uri { get; set; } = "";
    public List<string> headersPresent { get; set; } = new();
    public bool headersRedacted { get; set; } = true;
    public SanitizedBodyShape bodyShape { get; set; } = new();
}

public sealed class SanitizedResponseEvidence
{
    public int? httpStatus { get; set; }
    public Dictionary<string,string> headers { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public string bodyExcerpt { get; set; } = "";
    public string? providerRequestId { get; set; }
    public double durationSeconds { get; set; }
}

public sealed class InferenceDiagnosis
{
    [JsonPropertyName("class")]
    public string failureClass { get; set; } = "none";
    public string scope { get; set; } = "endpoint";
    public bool adapterSuspect { get; set; }
    public bool providerHealthSuspect { get; set; }
    public string reasonCode { get; set; } = "INFERENCE_SUCCEEDED";
    public string? summary { get; set; }
}

public sealed class EndpointTestResult
{
    public bool ok { get; set; }
    public string endpoint { get; set; } = "";
    public string connection { get; set; } = "";
    public string model { get; set; } = "";
    public string adapterId { get; set; } = "";
    public string adapterSource { get; set; } = "";
    public string protocol { get; set; } = "";
    public string connectionConfigFingerprint { get; set; } = "";
    public SanitizedRequestEvidence request { get; set; } = new();
    public SanitizedResponseEvidence response { get; set; } = new();
    public InferenceDiagnosis diagnosis { get; set; } = new();
    public string? signalRef { get; set; }
}

public sealed class AdapterRequest : IDisposable
{
    public HttpRequestMessage message { get; }
    public SanitizedRequestEvidence evidence { get; }

    public AdapterRequest(HttpRequestMessage message, SanitizedRequestEvidence evidence)
    {
        this.message=message;
        this.evidence=evidence;
    }

    public void Dispose() => message.Dispose();
}

public sealed record AdapterParseResult(
    bool Success,
    NormalizedInferenceMessage? Assistant,
    NormalizedUsage Usage,
    string? Error);

using System.Text.Json.Serialization;

namespace StatefulClanker.Router;

public sealed class NormalizedInferenceRequest
{
    public string prompt { get; set; } = "Reply with exactly: CLANKER_OK";
    public int maxOutputTokens { get; set; } = 8;
    public bool testTools { get; set; }
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

public sealed record AdapterParseResult(bool Success,string? Text,string? Error);

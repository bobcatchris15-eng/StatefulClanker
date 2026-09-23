using System.Text.Json.Serialization;

namespace StatefulClanker.Router;

public sealed class EndpointCatalog
{
    public int schemaVersion { get; set; } = 2;
    public string? updatedAt { get; set; }
    public Dictionary<string, EndpointEntry> entries { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class EndpointEntry
{
    public string id { get; set; } = "";
    public string connection { get; set; } = "";
    public string model { get; set; } = "";
    public string displayName { get; set; } = "";
    public bool enabled { get; set; } = true;
    public bool workhorse { get; set; } = true;
    public bool? free { get; set; }
    public bool? supportsTools { get; set; }
    public long? contextLength { get; set; }
    public string toolMode { get; set; } = "native";
    public int? leaseCapacity { get; set; }

    // Lifecycle metadata. Existing/user-managed entries remain untouched unless
    // explicitly adopted by the free-capacity manager.
    public string source { get; set; } = "user";
    public string? rationale { get; set; }
    public string? researchedAt { get; set; }
    public string updatedAt { get; set; } = DateTimeOffset.UtcNow.ToString("O");
    public string? managedBy { get; set; }
    public string? freeClass { get; set; }
    public string? freeEvidence { get; set; }
    public string? lastSeenAt { get; set; }
    public string? missingSince { get; set; }
    public int discoveryMisses { get; set; }
    public string? retiredReason { get; set; }
    public string? userOverride { get; set; }
}

public sealed class ConnectionDocument
{
    public int schemaVersion { get; set; } = 2;
    public Dictionary<string, ConnectionProfile> connections { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class ConnectionProfile
{
    public string name { get; set; } = "";
    public string presetId { get; set; } = "custom";
    public string protocol { get; set; } = "openai-chat";
    public string baseUrl { get; set; } = "";
    public string modelsPath { get; set; } = "/models";
    public string discoveryKind { get; set; } = "openai";
    public string authKind { get; set; } = "bearer";
    public string? accountId { get; set; }
    public string? apiKeyProtected { get; set; }
    public string? apiKeyEnv { get; set; }
    public Dictionary<string,string> headers { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class CapacityDiscoveryDocument
{
    public int schemaVersion { get; set; } = 1;
    public string? updatedAt { get; set; }
    public Dictionary<string, CapacityConnectionState> connections { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class CapacityConnectionState
{
    public string? lastSyncAt { get; set; }
    public string? lastSuccessAt { get; set; }
    public string? lastError { get; set; }
    public int modelCount { get; set; }
    public int confirmedFree { get; set; }
    public int paid { get; set; }
    public int unknown { get; set; }
    public int workhorseFree { get; set; }
    public List<CapacityModelState> models { get; set; } = new();
}

public sealed class CapacityModelState
{
    public string model { get; set; } = "";
    public string displayName { get; set; } = "";
    public string classification { get; set; } = "unknown";
    public string evidence { get; set; } = "";
    public bool workhorse { get; set; }
    public bool? supportsTools { get; set; }
    public long? contextLength { get; set; }
    public double? inputPrice { get; set; }
    public double? outputPrice { get; set; }
    public string seenAt { get; set; } = DateTimeOffset.UtcNow.ToString("O");
}

public sealed class RoutingHealthDocument
{
    public int schemaVersion { get; set; } = 3;
    public Dictionary<string, HealthEntry> endpoints { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class HealthEntry
{
    public string state { get; set; } = "healthy";
    public string scope { get; set; } = "endpoint";
    public string? reason { get; set; }
    public int failures { get; set; }
    public int probeFailures { get; set; }
    public string? lastFailure { get; set; }
    public string? lastSuccess { get; set; }
    public string? lastProbe { get; set; }
    public string? nextProbeAt { get; set; }
    public string? retryAfter { get; set; }
    public string? configFingerprint { get; set; }
    public string? message { get; set; }
    public QuotaObservation? quota { get; set; }
}

public sealed class RoundRobinDocument
{
    public int schemaVersion { get; set; } = 1;
    public int cursor { get; set; }
    public string? updatedAt { get; set; }
}

public sealed record EndpointRoute(string RouteName, string CatalogId, EndpointEntry Endpoint, ConnectionProfile? Connection, string? Service);

public sealed class LeaseDocument
{
    public int schemaVersion { get; set; } = 1;
    public string? updatedAt { get; set; }
    public Dictionary<string, LeaseRecord> leases { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class LeaseRecord
{
    public string token { get; set; } = Guid.NewGuid().ToString("N");
    public string route { get; set; } = "";
    public string catalogId { get; set; } = "";
    public string connection { get; set; } = "";
    public string model { get; set; } = "";
    public string? sessionId { get; set; }
    public int ownerPid { get; set; }
    public string? ownerStartedAt { get; set; }
    public string acquiredAt { get; set; } = DateTimeOffset.UtcNow.ToString("O");
    public string expiresAt { get; set; } = DateTimeOffset.UtcNow.AddMinutes(45).ToString("O");
}

public sealed class RouterRequest
{
    public string op { get; set; } = "";
    public string? preferred { get; set; }
    public string? preferredConnection { get; set; }
    public bool strictPreferred { get; set; }
    public string? sessionId { get; set; }
    public bool requireTools { get; set; }
    public int ownerPid { get; set; }
    public string? lease { get; set; }
    public string? endpoint { get; set; }
    public string? failureClass { get; set; }
    public string? message { get; set; }
}

public sealed class RouterResponse
{
    public bool ok { get; set; }
    public string? error { get; set; }
    public object? data { get; set; }

    public static RouterResponse Ok(object? data=null) => new(){ok=true,data=data};
    public static RouterResponse Fail(string error, object? data=null) => new(){ok=false,error=error,data=data};
}

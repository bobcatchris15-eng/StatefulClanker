namespace StatefulClanker.Planner;

public static class PlannerPhases
{
    public const string Quiescing = "quiescing";
    public const string Planning = "planning";
    public const string Review = "review";
    public const string Handoff = "handoff";
}

public sealed class PlanningBudgetPolicy
{
    public string mode { get; set; } = "parity";
    public double planningToExecutionRatio { get; set; } = 1.0;
    public long? executionEstimateTokens { get; set; }
    public long? planningTargetTokens { get; set; }
}

public sealed class PlannerControl
{
    public int schemaVersion { get; set; } = 1;
    public string sessionId { get; set; } = "";
    public string phase { get; set; } = PlannerPhases.Quiescing;
    public string reason { get; set; } = "";
    public string startedAt { get; set; } = DateTimeOffset.UtcNow.ToString("O");
    public string updatedAt { get; set; } = DateTimeOffset.UtcNow.ToString("O");
    public string? baselinePath { get; set; }
    public string? activeCandidateId { get; set; }
    public string? acceptedHandoffId { get; set; }
    public bool autofillWasPaused { get; set; }
    public PlanningBudgetPolicy budget { get; set; } = new();
}

public sealed class PlannerBaseline
{
    public int schemaVersion { get; set; } = 1;
    public string capturedAt { get; set; } = DateTimeOffset.UtcNow.ToString("O");
    public string projectRoot { get; set; } = "";
    public string? gitHead { get; set; }
    public List<string> dirtyPaths { get; set; } = new();
    public long stateRevision { get; set; }
    public long intentRevision { get; set; }
    public string? intentHash { get; set; }
    public string? activePlanId { get; set; }
    public string taskGraphHash { get; set; } = "";
    public Dictionary<string,int> taskCounts { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class PlannerQuestion
{
    public int schemaVersion { get; set; } = 1;
    public string id { get; set; } = "";
    public string createdAt { get; set; } = DateTimeOffset.UtcNow.ToString("O");
    public string updatedAt { get; set; } = DateTimeOffset.UtcNow.ToString("O");
    public string status { get; set; } = "open";
    public string text { get; set; } = "";
    public string why { get; set; } = "";
    public string impact { get; set; } = "medium";
    public string owner { get; set; } = "human";
    public bool blocking { get; set; } = true;
    public string? answer { get; set; }
}

public sealed class PlannerCandidate
{
    public int schemaVersion { get; set; } = 1;
    public string id { get; set; } = "";
    public string createdAt { get; set; } = DateTimeOffset.UtcNow.ToString("O");
    public string summary { get; set; } = "";
    public string planPath { get; set; } = "";
    public string planSha256 { get; set; } = "";
    public string? intentPath { get; set; }
    public string? intentSha256 { get; set; }
}

public sealed class PlannerHandoff
{
    public int schemaVersion { get; set; } = 1;
    public string id { get; set; } = "";
    public string sessionId { get; set; } = "";
    public string candidateId { get; set; } = "";
    public string acceptedAt { get; set; } = DateTimeOffset.UtcNow.ToString("O");
    public string status { get; set; } = "accepted";
    public string planPath { get; set; } = "";
    public string planSha256 { get; set; } = "";
    public string? intentPath { get; set; }
    public string? intentSha256 { get; set; }
    public string? baselinePath { get; set; }
    public string? appliedPlanId { get; set; }
    public string? releasedAt { get; set; }
}

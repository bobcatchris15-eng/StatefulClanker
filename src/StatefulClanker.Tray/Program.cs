using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace StatefulClanker.Tray;

static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        using var mutex = new Mutex(true, "Local\\StatefulClanker.WindowsHost", out var first);
        if (!first) return;
        Application.Run(new MainForm());
    }
}

sealed class ProjectEntry
{
    public string Name { get; set; } = "";
    public string Path { get; set; } = "";
}

sealed class AppSettings
{
    public List<ProjectEntry> Projects { get; set; } = new();
    public string? ActiveProjectPath { get; set; }
    public int HttpPort { get; set; } = 7337;
    public string? McpToken { get; set; }

    // Cockpit geometry is operator state, not project state. Keep splitter positions
    // here so every major pane is actually draggable without snapping back on restart.
    public int LeftRailWidth { get; set; } = 235;
    public int LeftProjectHeight { get; set; } = 330;
    public int LeftTargetPoolHeight { get; set; } = 180;
    public int RightRailWidth { get; set; } = 265;
    public int OverviewInfoHeight { get; set; } = 285;
    public int OverviewStatusWidth { get; set; } = 255;
    public int OverviewProviderWidth { get; set; } = 315;
    public int ActivityTelemetryHeight { get; set; } = 300;
}

static class AppStore
{
    public static readonly string Root = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StatefulClanker");
    public static readonly string SettingsPath = System.IO.Path.Combine(Root, "app.json");
    public static readonly string ActiveProjectPointer = System.IO.Path.Combine(Root, "active-project.txt");
    public static readonly string McpDetailsPath = System.IO.Path.Combine(Root, "mcp-http.json");
    static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };

    public static AppSettings Load()
    {
        Directory.CreateDirectory(Root);
        AppSettings settings = new();
        try { if (File.Exists(SettingsPath)) settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath), JsonOptions) ?? new(); }
        catch { }
        if (string.IsNullOrWhiteSpace(settings.McpToken))
        {
            try
            {
                if (File.Exists(McpDetailsPath))
                {
                    var d = JsonSerializer.Deserialize<McpDetails>(File.ReadAllText(McpDetailsPath), JsonOptions);
                    if (!string.IsNullOrWhiteSpace(d?.token)) settings.McpToken = d.token;
                }
            }
            catch { }
            if (string.IsNullOrWhiteSpace(settings.McpToken))
            {
                settings.McpToken = Guid.NewGuid().ToString("N");
            }
            Save(settings);
        }
        return settings;
    }

    public static void Save(AppSettings settings)
    {
        Directory.CreateDirectory(Root);
        File.WriteAllText(SettingsPath, JsonSerializer.Serialize(settings, JsonOptions), new UTF8Encoding(false));
    }

    public static void SetActiveProject(string? path)
    {
        Directory.CreateDirectory(Root);
        if (string.IsNullOrWhiteSpace(path)) { try { File.Delete(ActiveProjectPointer); } catch { } return; }
        File.WriteAllText(ActiveProjectPointer, path, new UTF8Encoding(false));
    }
}

static class Runtime
{
    public static string FindRoot()
    {
        DirectoryInfo? current = new(AppContext.BaseDirectory);
        for (var i = 0; i < 8 && current is not null; i++, current = current.Parent)
        {
            if (File.Exists(System.IO.Path.Combine(current.FullName, "StatefulClanker.ps1")) &&
                File.Exists(System.IO.Path.Combine(current.FullName, "mcp", "StatefulClanker.McpHttp.ps1"))) return current.FullName;
        }
        return AppContext.BaseDirectory;
    }

    public static string FindPowerShell()
    {
        var fixedPath = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
        if (File.Exists(fixedPath)) return fixedPath;
        if (CommandExists("pwsh.exe")) return "pwsh.exe";
        return "powershell.exe";
    }

    public static bool CommandExists(string command)
    {
        if (string.IsNullOrWhiteSpace(command)) return false;
        if (command.Contains('\\') || command.Contains('/')) return File.Exists(command);
        try
        {
            using var p = Process.Start(new ProcessStartInfo("where.exe")
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
                ArgumentList = { command }
            });
            p?.WaitForExit(1500);
            return p?.ExitCode == 0;
        }
        catch { return false; }
    }

    public static (int code, string stdout, string stderr) Run(string file, string workingDir, params string[] args)
    {
        try
        {
            var psi = new ProcessStartInfo(file) { WorkingDirectory = workingDir, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var arg in args) psi.ArgumentList.Add(arg);
            using var p = Process.Start(psi);
            if (p is null) return (-1, "", "Could not start process.");
            var stdout = p.StandardOutput.ReadToEnd();
            var stderr = p.StandardError.ReadToEnd();
            p.WaitForExit();
            return (p.ExitCode, stdout, stderr);
        }
        catch (Exception ex) { return (-1, "", ex.Message); }
    }

    public static (int code, string stdout, string stderr) RunPowerShell(string root, params string[] args)
    {
        var all = new List<string> { "-NoProfile", "-NonInteractive" }; all.AddRange(args);
        return Run(FindPowerShell(), root, all.ToArray());
    }
}

sealed class McpDetails
{
    public string? url { get; set; }
    public string? token { get; set; }
    public int pid { get; set; }
}

sealed class McpHost : IDisposable
{
    readonly string _root;
    Process? _owned;
    public int Port { get; }
    public string? Token { get; }
    public McpHost(string root, int port, string? token = null) { _root = root; Port = port; Token = token; }

    public McpDetails? Details()
    {
        try
        {
            if (!File.Exists(AppStore.McpDetailsPath)) return null;
            var d = JsonSerializer.Deserialize<McpDetails>(File.ReadAllText(AppStore.McpDetailsPath));
            if (d is null || d.pid <= 0 || string.IsNullOrWhiteSpace(d.url)) return null;
            using var _ = Process.GetProcessById(d.pid);
            return d;
        }
        catch { return null; }
    }

    public void EnsureStarted()
    {
        if (_owned is { HasExited: false } || Details() is not null) return;
        var script = System.IO.Path.Combine(_root, "mcp", "StatefulClanker.McpHttp.ps1");
        if (!File.Exists(script)) return;
        var psi = new ProcessStartInfo(Runtime.FindPowerShell()) { WorkingDirectory = _root, UseShellExecute = false, CreateNoWindow = true };
        var args = new List<string> { "-NoProfile", "-NonInteractive", "-File", script, "-Port", Port.ToString() };
        if (!string.IsNullOrWhiteSpace(Token)) { args.AddRange(new[] { "-Token", Token }); }
        foreach (var arg in args) psi.ArgumentList.Add(arg);
        try { _owned = Process.Start(psi); } catch { _owned = null; }
    }

    public void Dispose()
    {
        try { if (_owned is { HasExited: false }) _owned.Kill(entireProcessTree: true); } catch { }
        _owned?.Dispose();
    }
}

sealed class AutofillHost : IDisposable
{
    readonly string _root;
    Process? _owned;
    string? _project;
    public AutofillHost(string root) { _root = root; }

    public static string StateDir(string project) => System.IO.Path.Combine(project, ".statefulclanker", "autofill");
    public static string StatusPath(string project) => System.IO.Path.Combine(StateDir(project), "supervisor.json");
    public static string StopPath(string project) => System.IO.Path.Combine(StateDir(project), "stop.request");
    public static string PausePath(string project) => System.IO.Path.Combine(StateDir(project), "pause.request");
    public static string TriggerPath(string project) => System.IO.Path.Combine(StateDir(project), "trigger.request");

    public static bool Enabled(string project)
    {
        try
        {
            var path = System.IO.Path.Combine(project, ".statefulclanker", "config.json");
            if (!File.Exists(path)) return false;
            using var d = JsonDocument.Parse(File.ReadAllText(path));
            return !d.RootElement.TryGetProperty("autofillEnabled", out var enabled) || enabled.ValueKind != JsonValueKind.False;
        }
        catch { return false; }
    }

    public static bool IsProcessAlive(int pid)
    {
        if (pid <= 0) return false;
        try { using var proc = Process.GetProcessById(pid); return !proc.HasExited; }
        catch { return false; }
    }

    static bool ExistingAlive(string project)
    {
        try
        {
            var path = StatusPath(project); if (!File.Exists(path)) return false;
            using var d = JsonDocument.Parse(File.ReadAllText(path)); if (!d.RootElement.TryGetProperty("pid", out var p)) return false;
            return IsProcessAlive(p.GetInt32());
        }
        catch { return false; }
    }

    public static void RequestStop(string? project)
    {
        if (string.IsNullOrWhiteSpace(project)) return;
        try { Directory.CreateDirectory(StateDir(project)); File.WriteAllText(StopPath(project), DateTimeOffset.UtcNow.ToString("O"), new UTF8Encoding(false)); } catch { }
    }

    public static void RequestPause(string? project)
    {
        if (string.IsNullOrWhiteSpace(project)) return;
        try { Directory.CreateDirectory(StateDir(project)); File.WriteAllText(PausePath(project), DateTimeOffset.UtcNow.ToString("O"), new UTF8Encoding(false)); } catch { }
    }

    public static void RequestResume(string? project)
    {
        if (string.IsNullOrWhiteSpace(project)) return;
        try
        {
            var p = PausePath(project);
            if (File.Exists(p)) File.Delete(p);
            RequestTrigger(project);
        }
        catch { }
    }

    public static void RequestTrigger(string? project)
    {
        if (string.IsNullOrWhiteSpace(project)) return;
        try { Directory.CreateDirectory(StateDir(project)); File.WriteAllText(TriggerPath(project), DateTimeOffset.UtcNow.ToString("O"), new UTF8Encoding(false)); } catch { }
    }

    public void EnsureStarted(string? project)
    {
        if (string.IsNullOrWhiteSpace(project) || !Directory.Exists(project)) { if (_project is not null) RequestStop(_project); _project = null; return; }
        if (!string.Equals(_project, project, StringComparison.OrdinalIgnoreCase) && _project is not null) RequestStop(_project);
        _project = project;
        if (!Enabled(project)) { RequestStop(project); return; }
        if (_owned is { HasExited: false } || ExistingAlive(project)) return;
        var harness = System.IO.Path.Combine(_root, "StatefulClanker.ps1"); if (!File.Exists(harness)) return;
        try
        {
            var psi = new ProcessStartInfo(Runtime.FindPowerShell()) { WorkingDirectory = project, UseShellExecute = false, CreateNoWindow = true };
            foreach (var arg in new[] { "-NoProfile", "-NonInteractive", "-File", harness, "autofill", "run" }) psi.ArgumentList.Add(arg);
            _owned = Process.Start(psi);
        }
        catch { _owned = null; }
    }

    public void Dispose()
    {
        RequestStop(_project);
        _owned?.Dispose();
    }
}

sealed class AutofillSnapshot
{
    public bool Enabled = true;
    public bool Running;
    public string State = "stopped";
    public bool Paused;
    public int Pid;
    public int ActiveWorkers;
    public int MaxConcurrent = 3;
    public int ReadyCount;
    public int RetryCount;
    public int Slots = 3;
    public string? BlockReason;
}

sealed class ActiveAgentInfo
{
    public string AgentId = "";
    public string TaskId = "";
    public string Type = "Worker";
    public string Endpoint = "";
    public string Model = "";
}

sealed class TaskBoardEntry
{
    public string Id = "";
    public string Title = "";
    public string Status = "";
    public string CreatedAt = "";
    public string? BlockReason;
    public int AttemptCount;
    public string? LatestRunId;
    public string? LatestCritiqueId;
    public string? LatestValidationId;
    public string? LatestProposalId;
    public string? Role;
    public string? Size;
    public string? Provider;
    public List<string> DependsOn = new();
}

sealed class ProjectMetrics
{
    public int ActiveAgents, Sessions, Commits, Validators, CompleteTasks, TotalTasks;
    public List<TaskBoardEntry> TaskBoard = new();
    public long UsageReports, PromptTokens, CompletionTokens, TotalTokens;
    public Dictionary<string,long> ModelTokens = new(StringComparer.OrdinalIgnoreCase);
    public string IntentRevision = "—", Goal = "", Activity = "", Telemetry = "";
    public Dictionary<string, int> ActiveTypes = new(StringComparer.OrdinalIgnoreCase);
    public string ActiveTypesSummary = "";
    public List<ActiveAgentInfo> ActiveAgentList = new();
}

sealed class IntegrationStatus
{
    public string id { get; set; } = "";
    public string name { get; set; } = "";
    public bool installed { get; set; }
    public bool registered { get; set; }
    public bool verified { get; set; }
    public string note { get; set; } = "";
}

sealed class McpServerStatus
{
    public string name { get; set; } = "";
    public string harness { get; set; } = "";
    public bool verified { get; set; }
    public string transport { get; set; } = "";
    public bool probeOk { get; set; }
    public int toolCount { get; set; }
    public string? probeError { get; set; }
    public bool imported { get; set; }
}

sealed class ProviderStatus
{
    public string Name = "", Backend = "", Target = "", Roles = "";
    public bool Disabled;
    public int Priority = 100;
}

sealed class UiSnapshot
{
    public McpDetails? Mcp;
    public ProjectMetrics Project = new();
    public AutofillSnapshot Autofill = new();
    public EndpointQueuePreview NextEndpoint = new();
    public List<IntegrationStatus> Integrations = new();
    public List<ProviderStatus> Providers = new();
    public bool HasProject;
}

static class Inspector
{
    static IEnumerable<string> JsonFiles(string dir) => Directory.Exists(dir) ? Directory.EnumerateFiles(dir, "*.json") : Array.Empty<string>();

    public static ProjectMetrics Project(string project)
    {
        var m = new ProjectMetrics(); var state = System.IO.Path.Combine(project, ".statefulclanker"); if (!Directory.Exists(state)) return m;
        var active = JsonFiles(System.IO.Path.Combine(state, "telemetry", "active")).ToArray(); m.ActiveAgents = active.Length;
        foreach (var file in active) {
            try {
                using var d = JsonDocument.Parse(File.ReadAllText(file));
                var r = d.RootElement;
                AddModels(m, r);

                var type = "Worker";
                string? tidStr = null;
                if (r.TryGetProperty("taskId", out var tidProp) && tidProp.ValueKind == JsonValueKind.String) tidStr = tidProp.GetString();
                // Ordinary task completion uses the validator stage only. Project-level
                // reviews may still run both critic and validator; their pseudo-task id is
                // prefixed "review-" (New-SCId 'review' in ProjectReview.ps1). Only that
                // project-level critic gets the distinct red "Project Critic" lamp.
                var isProjectReview = !string.IsNullOrEmpty(tidStr) && tidStr.StartsWith("review-", StringComparison.OrdinalIgnoreCase);
                if (r.TryGetProperty("stage", out var st) && st.ValueKind == JsonValueKind.String)
                {
                    var s = st.GetString()?.ToLowerInvariant();
                    if (s == "critic" && isProjectReview) type = "Project Critic";
                    else if (s == "critic" || s == "validator") type = "Validator";
                    else if (s == "research" || s == "researcher") type = "Researcher";
                    else if (r.TryGetProperty("role", out var ro) && ro.ValueKind == JsonValueKind.String && ro.GetString()?.ToLowerInvariant() == "researcher")
                        type = "Researcher";
                }
                m.ActiveTypes[type] = m.ActiveTypes.TryGetValue(type, out var cur) ? cur + 1 : 1;
                var info = new ActiveAgentInfo { AgentId = System.IO.Path.GetFileNameWithoutExtension(file) };
                info.TaskId = tidStr ?? "";
                if (r.TryGetProperty("agentId", out var aid) && aid.ValueKind == JsonValueKind.String) info.AgentId = aid.GetString() ?? info.AgentId;
                if (r.TryGetProperty("endpoint", out var ep) && ep.ValueKind == JsonValueKind.String) info.Endpoint = ep.GetString() ?? "";
                if (r.TryGetProperty("model", out var md) && md.ValueKind == JsonValueKind.String) info.Model = md.GetString() ?? "";
                info.Type = type;
                m.ActiveAgentList.Add(info);
            } catch { }
        }
        if (m.ActiveTypes.Count > 0)
        {
            m.ActiveTypesSummary = string.Join(", ", m.ActiveTypes.Select(kv => kv.Value == 1 ? kv.Key : $"{kv.Value} {kv.Key}s"));
        }
        var runs = JsonFiles(System.IO.Path.Combine(state, "telemetry", "runs")).ToArray(); m.Sessions = runs.Length;
        foreach (var file in runs)
        {
            try { using var d = JsonDocument.Parse(File.ReadAllText(file)); var r=d.RootElement; if (r.TryGetProperty("stage", out var s) && (s.GetString() == "critic" || s.GetString() == "validator")) m.Validators++; AddUsage(m,r); } catch { }
        }
        foreach (var file in JsonFiles(System.IO.Path.Combine(state, "tasks")))
        {
            m.TotalTasks++;
            try
            {
                using var d = JsonDocument.Parse(File.ReadAllText(file));
                var root = d.RootElement;
                var status = root.TryGetProperty("status", out var s) ? (s.GetString() ?? "") : "";
                if (status == "complete") m.CompleteTasks++;
                var id = root.TryGetProperty("id", out var idProp) && idProp.ValueKind == JsonValueKind.String ? (idProp.GetString() ?? "") : "";
                if (string.IsNullOrEmpty(id)) id = System.IO.Path.GetFileNameWithoutExtension(file);
                var title = root.TryGetProperty("title", out var titleProp) && titleProp.ValueKind == JsonValueKind.String ? (titleProp.GetString() ?? "") : "";
                var createdAt = root.TryGetProperty("createdAt", out var caProp) && caProp.ValueKind == JsonValueKind.String ? (caProp.GetString() ?? "") : "";
                var blockReason = root.TryGetProperty("blockReason", out var brProp) && brProp.ValueKind == JsonValueKind.String ? brProp.GetString() : null;
                var attemptCount = root.TryGetProperty("attemptCount", out var acProp) && acProp.TryGetInt32(out var ac) ? ac : 0;
                var latestRunId = root.TryGetProperty("latestRunId", out var lriProp) && lriProp.ValueKind == JsonValueKind.String ? lriProp.GetString() : null;
                var latestCritiqueId = root.TryGetProperty("latestCritiqueId", out var lciProp) && lciProp.ValueKind == JsonValueKind.String ? lciProp.GetString() : null;
                var latestValidationId = root.TryGetProperty("latestValidationId", out var lviProp) && lviProp.ValueKind == JsonValueKind.String ? lviProp.GetString() : null;
                var latestProposalId = root.TryGetProperty("latestProposalId", out var lpiProp) && lpiProp.ValueKind == JsonValueKind.String ? lpiProp.GetString() : null;
                var role = root.TryGetProperty("role", out var roleProp) && roleProp.ValueKind == JsonValueKind.String ? roleProp.GetString() : null;
                var size = root.TryGetProperty("size", out var sizeProp) && sizeProp.ValueKind == JsonValueKind.String ? sizeProp.GetString() : null;
                var provider = root.TryGetProperty("provider", out var provProp) && provProp.ValueKind == JsonValueKind.String ? provProp.GetString() : null;
                var dependsOn = new List<string>();
                if (root.TryGetProperty("dependsOn", out var depProp) && depProp.ValueKind == JsonValueKind.Array)
                {
                    foreach (var el in depProp.EnumerateArray())
                    {
                        if (el.ValueKind == JsonValueKind.String && el.GetString() is { } dep && !string.IsNullOrWhiteSpace(dep))
                            dependsOn.Add(dep);
                    }
                }
                m.TaskBoard.Add(new TaskBoardEntry
                {
                    Id = id,
                    Title = string.IsNullOrEmpty(title) ? id : title,
                    Status = status,
                    CreatedAt = createdAt,
                    BlockReason = blockReason,
                    AttemptCount = attemptCount,
                    LatestRunId = latestRunId,
                    LatestCritiqueId = latestCritiqueId,
                    LatestValidationId = latestValidationId,
                    LatestProposalId = latestProposalId,
                    Role = role,
                    Size = size,
                    Provider = provider,
                    DependsOn = dependsOn
                });
            }
            catch { }
        }
        m.TaskBoard = m.TaskBoard.OrderBy(t => t.CreatedAt, StringComparer.Ordinal).ToList();
        try { m.Goal = JsonNode.Parse(File.ReadAllText(System.IO.Path.Combine(state, "state.json")))?["goal"]?.GetValue<string>() ?? ""; } catch { }
        try { m.IntentRevision = JsonNode.Parse(File.ReadAllText(System.IO.Path.Combine(state, "intent", "contract.json")))?["revision"]?.ToString() ?? "—"; } catch { }
        m.Commits = CommitCount(project);
        m.Activity = Activity(System.IO.Path.Combine(state, "events.jsonl"));
        m.Telemetry = Telemetry(state, active, runs);
        return m;
    }

    static string Telemetry(string state, string[] active, string[] runs)
    {
        var sb = new StringBuilder();
        sb.AppendLine("ACTIVE WORKERS / REVIEWERS");
        sb.AppendLine("──────────────────────────");

        if (active.Length == 0)
        {
            sb.AppendLine("No active agent processes.");
        }
        else
        {
            foreach (var file in active.OrderBy(x => x, StringComparer.OrdinalIgnoreCase))
            {
                try
                {
                    using var d = JsonDocument.Parse(File.ReadAllText(file));
                    var r = d.RootElement;
                    var id = r.TryGetProperty("agentId", out var aid) ? aid.GetString() : Path.GetFileNameWithoutExtension(file);
                    var task = r.TryGetProperty("taskId", out var tid) ? tid.GetString() : "";
                    var stage = r.TryGetProperty("stage", out var st) ? st.GetString() : "worker";
                    var provider = r.TryGetProperty("provider", out var pv) ? pv.GetString() : "";
                    var started = r.TryGetProperty("startedAt", out var sa) ? sa.GetString() : "";
                    var clock = DateTimeOffset.TryParse(started, out var dto) ? dto.ToLocalTime().ToString("HH:mm:ss") : started;
                    sb.AppendLine($"{clock,-9} {stage,-10} {task,-18} {provider,-12} {id}");
                }
                catch { }
            }
        }

        sb.AppendLine();
        sb.AppendLine("RECENT WORKER TELEMETRY");
        sb.AppendLine("───────────────────────");

        var recent = runs
            .Select(x => new FileInfo(x))
            .OrderByDescending(x => x.LastWriteTimeUtc)
            .Take(40)
            .ToArray();

        if (recent.Length == 0)
        {
            sb.AppendLine("No completed worker telemetry recorded.");
        }
        else
        {
            foreach (var fi in recent)
            {
                try
                {
                    using var d = JsonDocument.Parse(File.ReadAllText(fi.FullName));
                    var x = d.RootElement;
                    var task = x.TryGetProperty("taskId", out var tid) ? tid.GetString() : "";
                    var stage = x.TryGetProperty("stage", out var st) ? st.GetString() : "worker";
                    var provider = x.TryGetProperty("provider", out var pv) ? pv.GetString() : "";
                    var verdict = x.TryGetProperty("verdict", out var vv) && vv.ValueKind == JsonValueKind.String ? vv.GetString() : "";
                    var exit = x.TryGetProperty("exitCode", out var ec) && ec.TryGetInt32(out var eci) ? eci.ToString() : "—";
                    var secs = x.TryGetProperty("durationSeconds", out var ds) && ds.TryGetDouble(out var dsv) ? $"{dsv:0.0}s" : "";
                    var ended = x.TryGetProperty("endedAt", out var ea) ? ea.GetString() : "";
                    var clock = DateTimeOffset.TryParse(ended, out var dto) ? dto.ToLocalTime().ToString("MM-dd HH:mm:ss") : ended;
                    var outcome = string.IsNullOrWhiteSpace(verdict) ? $"exit {exit}" : verdict;
                    sb.AppendLine($"{clock,-15} {stage,-10} {task,-18} {provider,-12} {outcome,-8} {secs,8}");
                }
                catch { }
            }
        }

        var faults = System.IO.Path.Combine(state, "telemetry", "context-faults.jsonl");
        if (File.Exists(faults))
        {
            var lines = File.ReadLines(faults).Where(x => !string.IsNullOrWhiteSpace(x)).TakeLast(20).ToArray();
            if (lines.Length > 0)
            {
                sb.AppendLine();
                sb.AppendLine("RECENT CONTEXT FAULTS");
                sb.AppendLine("─────────────────────");
                foreach (var line in lines.Reverse())
                {
                    try
                    {
                        using var d = JsonDocument.Parse(line);
                        var x = d.RootElement;
                        var task = x.TryGetProperty("taskId", out var tid) ? tid.GetString() : "";
                        var req = x.TryGetProperty("request", out var rq) ? rq.GetString() : "";
                        var ts = x.TryGetProperty("ts", out var tp) ? tp.GetString() : "";
                        var clock = DateTimeOffset.TryParse(ts, out var dto) ? dto.ToLocalTime().ToString("MM-dd HH:mm:ss") : ts;
                        sb.AppendLine($"{clock}  {task}  {req}");
                    }
                    catch { }
                }
            }
        }

        return sb.ToString();
    }

    public static AutofillSnapshot Autofill(string project)
    {
        var snap = new AutofillSnapshot();
        var state = System.IO.Path.Combine(project, ".statefulclanker");
        if (!Directory.Exists(state)) return snap;

        var cfgPath = System.IO.Path.Combine(state, "config.json");
        if (File.Exists(cfgPath))
        {
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(cfgPath));
                var root = doc.RootElement;
                if (root.TryGetProperty("autofillEnabled", out var aeb) && aeb.ValueKind == JsonValueKind.False)
                    snap.Enabled = false;
                if (root.TryGetProperty("maxConcurrent", out var mc) && mc.TryGetInt32(out var parsedMc))
                    snap.MaxConcurrent = Math.Max(1, Math.Min(16, parsedMc));
            }
            catch { }
        }

        var statusPath = AutofillHost.StatusPath(project);
        if (File.Exists(statusPath))
        {
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(statusPath));
                var root = doc.RootElement;
                if (root.TryGetProperty("pid", out var pv) && pv.TryGetInt32(out var pid))
                {
                    snap.Pid = pid;
                    snap.Running = AutofillHost.IsProcessAlive(pid);
                }
                if (root.TryGetProperty("state", out var sv) && sv.ValueKind == JsonValueKind.String)
                    snap.State = sv.GetString() ?? (snap.Running ? "running" : "stopped");
                else
                    snap.State = snap.Running ? "running" : "stopped";

                if (root.TryGetProperty("paused", out var pzb))
                    snap.Paused = pzb.ValueKind == JsonValueKind.True;
                if (root.TryGetProperty("activeWorkers", out var aw) && aw.TryGetInt32(out var awVal))
                    snap.ActiveWorkers = awVal;
                else if (root.TryGetProperty("ownedActive", out var oa) && oa.TryGetInt32(out var oaVal))
                    snap.ActiveWorkers = oaVal;
                else if (root.TryGetProperty("activeTasks", out var at) && at.ValueKind == JsonValueKind.Array)
                    snap.ActiveWorkers = at.GetArrayLength();

                if (root.TryGetProperty("maxConcurrent", out var mcv) && mcv.TryGetInt32(out var mcvVal))
                    snap.MaxConcurrent = mcvVal;
                if (root.TryGetProperty("readyCount", out var rc) && rc.TryGetInt32(out var rcVal))
                    snap.ReadyCount = rcVal;
                if (root.TryGetProperty("retryCount", out var rtc) && rtc.TryGetInt32(out var rtcVal))
                    snap.RetryCount = rtcVal;
                if (root.TryGetProperty("slots", out var sl) && sl.TryGetInt32(out var slVal))
                    snap.Slots = slVal;
                if (root.TryGetProperty("blockReason", out var br) && br.ValueKind == JsonValueKind.String)
                    snap.BlockReason = br.GetString();
            }
            catch { }
        }
        else
        {
            snap.Running = false;
            snap.State = "stopped";
        }

        if (File.Exists(AutofillHost.PausePath(project)))
            snap.Paused = true;

        if (!snap.Running)
        {
            snap.State = "stopped";
            snap.ActiveWorkers = 0;
            snap.Slots = snap.MaxConcurrent;
        }

        return snap;
    }

    static long Number(JsonElement r,string name) => r.TryGetProperty(name,out var n) && n.ValueKind==JsonValueKind.Number && n.TryGetInt64(out var v) ? v : 0;
    static void PutModel(ProjectMetrics m,string? model,long tokens=0) { if(string.IsNullOrWhiteSpace(model)) return; m.ModelTokens[model]=m.ModelTokens.TryGetValue(model,out var old)?old+tokens:tokens; }
    static void AddModels(ProjectMetrics m,JsonElement r)
    {
        if(r.TryGetProperty("actualModels",out var actual) && actual.ValueKind==JsonValueKind.Array){foreach(var x in actual.EnumerateArray()) if(x.ValueKind==JsonValueKind.String) PutModel(m,x.GetString());return;}
        if(r.TryGetProperty("model",out var model) && model.ValueKind==JsonValueKind.String) PutModel(m,model.GetString());
    }
    static void AddUsage(ProjectMetrics m,JsonElement r)
    {
        m.UsageReports+=Number(r,"usageReports");m.PromptTokens+=Number(r,"promptTokens");m.CompletionTokens+=Number(r,"completionTokens");m.TotalTokens+=Number(r,"totalTokens");
        if(r.TryGetProperty("modelUsage",out var usage) && usage.ValueKind==JsonValueKind.Array){foreach(var row in usage.EnumerateArray()){var model=row.TryGetProperty("model",out var x)&&x.ValueKind==JsonValueKind.String?x.GetString():null;PutModel(m,model,Number(row,"totalTokens"));}return;}
        AddModels(m,r);
    }

    static int CommitCount(string project)
    {
        var r = Runtime.Run("git", project, "log", "--all", "--author=statefulclanker@localhost", "--format=%H");
        if (r.code != 0) return 0;
        return r.stdout.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries).Length;
    }

    static string Activity(string path)
    {
        if (!File.Exists(path)) return "No activity recorded.";
        var sb = new StringBuilder();
        try
        {
            foreach (var line in File.ReadLines(path).Where(x => !string.IsNullOrWhiteSpace(x)).TakeLast(100).Reverse())
            {
                try
                {
                    using var d = JsonDocument.Parse(line); var r = d.RootElement;
                    var ts = r.TryGetProperty("ts", out var t) ? t.GetString() : ""; var type = r.TryGetProperty("type", out var ty) ? ty.GetString() : "event"; var msg = r.TryGetProperty("message", out var mm) ? mm.GetString() : "";
                    var clock = DateTimeOffset.TryParse(ts, out var dto) ? dto.ToLocalTime().ToString("MM-dd HH:mm:ss") : ts;
                    sb.Append(clock).Append("  ").Append(type); if (!string.IsNullOrWhiteSpace(msg)) sb.Append("  ").Append(msg); sb.AppendLine();
                }
                catch { }
            }
        }
        catch { }
        return sb.Length == 0 ? "No activity recorded." : sb.ToString();
    }

    public static (string summary, string details) GetTaskDiagnostics(string project, TaskBoardEntry task)
    {
        var state = System.IO.Path.Combine(project, ".statefulclanker");
        var sb = new StringBuilder();
        string summary = task.BlockReason ?? (!string.IsNullOrEmpty(task.Status) ? $"Status: {task.Status}" : "No failure reason recorded.");

        sb.AppendLine($"TASK ID:         {task.Id}");
        sb.AppendLine($"TITLE:           {task.Title}");
        sb.AppendLine($"STATUS:          {task.Status.ToUpperInvariant()}");
        if (task.AttemptCount > 0) sb.AppendLine($"ATTEMPTS:        {task.AttemptCount}");
        if (!string.IsNullOrEmpty(task.Role)) sb.AppendLine($"ROLE:            {task.Role}");
        if (!string.IsNullOrEmpty(task.Size)) sb.AppendLine($"SIZE:            {task.Size}");
        if (!string.IsNullOrEmpty(task.Provider)) sb.AppendLine($"PROVIDER:        {task.Provider}");
        if (task.DependsOn.Count > 0) sb.AppendLine($"DEPENDS ON:      {string.Join(", ", task.DependsOn)}");

        if (!string.IsNullOrWhiteSpace(task.BlockReason))
        {
            sb.AppendLine();
            sb.AppendLine("================================================================================");
            sb.AppendLine("PRIMARY FAILURE / BLOCK REASON:");
            sb.AppendLine($"  {task.BlockReason}");
            sb.AppendLine("================================================================================");
        }

        // 1. Critic Review Receipt / Diagnostics
        if (!string.IsNullOrWhiteSpace(task.LatestCritiqueId))
        {
            var jsonPath = System.IO.Path.Combine(state, "critiques", $"{task.LatestCritiqueId}.json");
            var stdoutPath = System.IO.Path.Combine(state, "critiques", $"{task.LatestCritiqueId}.stdout.txt");
            sb.AppendLine();
            sb.AppendLine($"[CRITIC REVIEW RECEIPT: {task.LatestCritiqueId}]");
            if (File.Exists(jsonPath))
            {
                try
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(jsonPath));
                    var root = doc.RootElement;
                    if (root.TryGetProperty("verdict", out var v)) sb.AppendLine($"Verdict:    {v.GetString()}");
                    if (root.TryGetProperty("provider", out var p)) sb.AppendLine($"Provider:   {p.GetString()}");
                    if (root.TryGetProperty("exitCode", out var ec)) sb.AppendLine($"Exit Code:  {ec.GetInt32()}");
                    if (root.TryGetProperty("gateReasons", out var gr) && gr.ValueKind == JsonValueKind.Array)
                    {
                        sb.AppendLine("Gate Violations:");
                        foreach (var g in gr.EnumerateArray()) sb.AppendLine($"  - {g.GetString()}");
                    }
                    if (root.TryGetProperty("feedback", out var fb) && !string.IsNullOrWhiteSpace(fb.GetString()))
                    {
                        sb.AppendLine($"Critic Feedback:\n{fb.GetString()?.Trim()}");
                    }
                    if (root.TryGetProperty("error", out var err) && !string.IsNullOrWhiteSpace(err.GetString()))
                    {
                        sb.AppendLine($"Critic Error:\n{err.GetString()?.Trim()}");
                    }
                    if (root.TryGetProperty("stderr", out var se) && !string.IsNullOrWhiteSpace(se.GetString()))
                    {
                        sb.AppendLine($"Critic Stderr:\n{se.GetString()?.Trim()}");
                    }
                }
                catch { }
            }
            if (File.Exists(stdoutPath))
            {
                try
                {
                    var stdout = File.ReadAllText(stdoutPath).Trim();
                    if (!string.IsNullOrWhiteSpace(stdout)) sb.AppendLine($"Critique Output Log:\n{stdout}");
                }
                catch { }
            }
        }

        // 2. Validation Receipt / Diagnostics
        if (!string.IsNullOrWhiteSpace(task.LatestValidationId))
        {
            var jsonPath = System.IO.Path.Combine(state, "validations", $"{task.LatestValidationId}.json");
            var stdoutPath = System.IO.Path.Combine(state, "validations", $"{task.LatestValidationId}.stdout.txt");
            sb.AppendLine();
            sb.AppendLine($"[VALIDATION RECEIPT: {task.LatestValidationId}]");
            if (File.Exists(jsonPath))
            {
                try
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(jsonPath));
                    var root = doc.RootElement;
                    if (root.TryGetProperty("verdict", out var v)) sb.AppendLine($"Verdict:    {v.GetString()}");
                    if (root.TryGetProperty("feedback", out var fb) && !string.IsNullOrWhiteSpace(fb.GetString()))
                        sb.AppendLine($"Validation Feedback:\n{fb.GetString()?.Trim()}");
                    if (root.TryGetProperty("error", out var err) && !string.IsNullOrWhiteSpace(err.GetString()))
                        sb.AppendLine($"Validation Error:\n{err.GetString()?.Trim()}");
                }
                catch { }
            }
            if (File.Exists(stdoutPath))
            {
                try
                {
                    var stdout = File.ReadAllText(stdoutPath).Trim();
                    if (!string.IsNullOrWhiteSpace(stdout)) sb.AppendLine($"Validation Output Log:\n{stdout}");
                }
                catch { }
            }
        }

        // 3. Worker Run stderr / stdout / exit code
        if (!string.IsNullOrWhiteSpace(task.LatestRunId))
        {
            var jsonPath = System.IO.Path.Combine(state, "runs", $"{task.LatestRunId}.json");
            var stderrPath = System.IO.Path.Combine(state, "runs", $"{task.LatestRunId}.stderr.txt");
            var stdoutPath = System.IO.Path.Combine(state, "runs", $"{task.LatestRunId}.stdout.txt");
            sb.AppendLine();
            sb.AppendLine($"[WORKER RUN EXECUTION: {task.LatestRunId}]");
            if (File.Exists(jsonPath))
            {
                try
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(jsonPath));
                    var root = doc.RootElement;
                    if (root.TryGetProperty("exitCode", out var ec)) sb.AppendLine($"Exit Code:  {ec.GetInt32()}");
                    if (root.TryGetProperty("provider", out var p)) sb.AppendLine($"Provider:   {p.GetString()}");
                    if (root.TryGetProperty("startedAt", out var sa)) sb.AppendLine($"Started:    {sa.GetString()}");
                    if (root.TryGetProperty("finishedAt", out var fa)) sb.AppendLine($"Finished:   {fa.GetString()}");
                    if (root.TryGetProperty("durationSeconds", out var ds)) sb.AppendLine($"Duration:   {ds.GetDouble():F1}s");
                }
                catch { }
            }
            if (File.Exists(stderrPath))
            {
                try
                {
                    var stderr = File.ReadAllText(stderrPath).Trim();
                    if (!string.IsNullOrWhiteSpace(stderr)) sb.AppendLine($"Worker Standard Error:\n{stderr}");
                }
                catch { }
            }
            if (File.Exists(stdoutPath))
            {
                try
                {
                    var stdout = File.ReadAllText(stdoutPath).Trim();
                    if (!string.IsNullOrWhiteSpace(stdout))
                    {
                        var preview = stdout.Length > 2000 ? stdout.Substring(0, 2000) + "\n... [truncated]" : stdout;
                        sb.AppendLine($"Worker Standard Output:\n{preview}");
                    }
                }
                catch { }
            }
        }

        // 4. Proposal info
        if (!string.IsNullOrWhiteSpace(task.LatestProposalId))
        {
            var jsonPath = System.IO.Path.Combine(state, "proposals", $"{task.LatestProposalId}.json");
            if (File.Exists(jsonPath))
            {
                try
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(jsonPath));
                    var root = doc.RootElement;
                    sb.AppendLine();
                    sb.AppendLine($"[COMPLETION PROPOSAL: {task.LatestProposalId}]");
                    if (root.TryGetProperty("status", out var ps)) sb.AppendLine($"Proposal Status: {ps.GetString()}");
                    if (root.TryGetProperty("rejectionReasons", out var rr) && rr.ValueKind == JsonValueKind.Array)
                    {
                        sb.AppendLine("Rejection Reasons:");
                        foreach (var r in rr.EnumerateArray()) sb.AppendLine($"  - {r.GetString()}");
                    }
                }
                catch { }
            }
        }

        // 5. Recent events for this task
        var eventsPath = System.IO.Path.Combine(state, "events.jsonl");
        if (File.Exists(eventsPath))
        {
            try
            {
                var matching = new List<string>();
                foreach (var line in File.ReadLines(eventsPath).Where(x => !string.IsNullOrWhiteSpace(x)).TakeLast(250))
                {
                    if (line.Contains($"\"{task.Id}\"") || line.Contains(task.Id))
                    {
                        try
                        {
                            using var doc = JsonDocument.Parse(line);
                            var root = doc.RootElement;
                            var ts = root.TryGetProperty("ts", out var tp) ? tp.GetString() : "";
                            var type = root.TryGetProperty("type", out var typ) ? typ.GetString() : "";
                            var msg = root.TryGetProperty("message", out var mp) ? mp.GetString() : "";
                            var clock = DateTimeOffset.TryParse(ts, out var dto) ? dto.ToLocalTime().ToString("MM-dd HH:mm:ss") : ts;
                            matching.Add($"{clock}  [{type}] {msg}");
                        }
                        catch { }
                    }
                }
                if (matching.Count > 0)
                {
                    sb.AppendLine();
                    sb.AppendLine("[RECENT TASK EVENTS]");
                    foreach (var ev in matching.TakeLast(10)) sb.AppendLine($"  {ev}");
                }
            }
            catch { }
        }

        return (summary, sb.ToString());
    }
}

static class Theme
{
    public static readonly Color Back = Color.FromArgb(23, 29, 38), Surface = Color.FromArgb(30, 40, 52), Surface2 = Color.FromArgb(36, 47, 60), Border = Color.FromArgb(43, 55, 68), Separator = Color.FromArgb(16, 21, 28), Text = Color.FromArgb(232, 239, 245), Muted = Color.FromArgb(135, 153, 171), Accent = Color.FromArgb(85, 198, 232), Good = Color.FromArgb(73, 217, 145), Warn = Color.FromArgb(255, 174, 74), Error = Color.FromArgb(255, 85, 85);
    public static void Apply(Control root)
    {
        root.BackColor = Back;
        root.ForeColor = Text;
        NativeUiTheme.Attach(root);

        if (root is Form form)
        {
            form.Font = new Font("Segoe UI", 9f);
        }

        foreach (Control c in root.Controls)
        {
            if (c is Button b)
            {
                // UseVisualStyleBackColor defaults to true, which lets the OS theme
                // engine paint its own (light/system-accent) chrome on top of/instead
                // of FlatAppearance on Windows 11 -- that's the bright white/grey
                // border that survives every other dark-theme setting here. Flat +
                // this false is what actually hands the whole button to FlatAppearance.
                b.UseVisualStyleBackColor = false;
                b.FlatStyle = FlatStyle.Flat;
                b.FlatAppearance.BorderColor = Surface2;
                b.FlatAppearance.BorderSize = 0;
                b.FlatAppearance.MouseOverBackColor = Color.FromArgb(42, 55, 69);
                b.FlatAppearance.MouseDownBackColor = Color.FromArgb(31, 43, 55);
                b.BackColor = Surface2;
                b.ForeColor = Text;
                if (b.Padding == Padding.Empty) b.Padding = new Padding(6, 0, 6, 0);
                b.UseCompatibleTextRendering = false;
            }
            else if (c is TextBox tb)
            {
                tb.BackColor = Surface;
                tb.ForeColor = Text;
                if (!tb.Multiline) tb.BorderStyle = BorderStyle.None;
            }
            else if (c is ComboBox cb)
            {
                cb.BackColor = Surface;
                cb.ForeColor = Text;
                cb.FlatStyle = FlatStyle.Flat;
            }
            else if (c is NumericUpDown nud)
            {
                nud.BackColor = Surface;
                nud.ForeColor = Text;
                nud.BorderStyle = BorderStyle.None;
            }
            else if (c is TreeView tv)
            {
                tv.BackColor = Surface;
                tv.ForeColor = Text;
                tv.BorderStyle = BorderStyle.None;
            }
            else if (c is TabControl tabs)
            {
                tabs.BackColor = Back;
                tabs.ForeColor = Text;
            }
            else if (c is DataGridView dg)
            {
                dg.BackgroundColor = Surface;
                dg.GridColor = Border;
                dg.BorderStyle = BorderStyle.None;
                dg.CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal;
                dg.DefaultCellStyle.BackColor = Surface;
                dg.DefaultCellStyle.ForeColor = Text;
                dg.DefaultCellStyle.SelectionBackColor = Surface2;
                dg.DefaultCellStyle.SelectionForeColor = Text;
                dg.ColumnHeadersBorderStyle = DataGridViewHeaderBorderStyle.None;
                dg.ColumnHeadersDefaultCellStyle.BackColor = Surface2;
                dg.ColumnHeadersDefaultCellStyle.ForeColor = Text;
                dg.EnableHeadersVisualStyles = false;
                dg.DefaultCellStyle.WrapMode = DataGridViewTriState.True;
                dg.ColumnHeadersDefaultCellStyle.WrapMode = DataGridViewTriState.True;
                dg.AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.AllCells;
                dg.RowTemplate.MinimumHeight = 24;
                dg.DefaultCellStyle.Padding = new Padding(4, 2, 4, 2);
            }
            else if (c is CheckBox chk)
            {
                chk.ForeColor = Text;
                chk.BackColor = Color.Transparent;
                chk.FlatStyle = FlatStyle.Flat;
                chk.FlatAppearance.BorderColor = Border;
            }
            Apply(c);
        }
    }

    // Cards are separated by tone and whitespace, not bevels or luminous outlines.
    // The old etched highlight read as a thick bright bar on several Windows themes.
    public static System.Drawing.Drawing2D.GraphicsPath RoundedRect(Rectangle r, int radius)
    {
        var path = new System.Drawing.Drawing2D.GraphicsPath();
        var d = radius * 2;
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    public static void PaintCard(Graphics g, Rectangle bounds, Color fill, int radius = 7)
    {
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        var r = new Rectangle(bounds.X, bounds.Y, bounds.Width - 1, bounds.Height - 1);
        using var path = RoundedRect(r, radius);
        using var fillBrush = new SolidBrush(fill);
        g.FillPath(fillBrush, path);
    }
}

// A flat-modern rounded card, replacing plain rectangular Panels for the boxes
// that group related controls (worker status, provider summary, etc).
class CardPanel : Panel
{
    public int Radius { get; set; } = 7;
    public Color Fill { get; set; } = Theme.Surface;

    public CardPanel()
    {
        DoubleBuffered = true;
        BackColor = Theme.Back;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Theme.PaintCard(e.Graphics, new Rectangle(0, 0, Width, Height), Fill, Radius);
        base.OnPaint(e);
    }
}

sealed class QuietSplitContainer : SplitContainer
{
    public int ResetDistance { get; set; } = 240;
    public int? ResetPanel2Width { get; set; }
    public event EventHandler? SplitterReset;

    private int? _pendingPanel2MinSize;

    public QuietSplitContainer(Orientation orientation)
    {
        Dock = DockStyle.Fill;
        Orientation = orientation;
        BorderStyle = BorderStyle.None;
        SplitterWidth = 2;
        BackColor = Theme.Back;
        Panel1.BackColor = Theme.Back;
        Panel2.BackColor = Theme.Back;
        TabStop = false;
    }

    int Extent => this.Orientation == System.Windows.Forms.Orientation.Vertical ? ClientSize.Width : ClientSize.Height;

    public int Panel2MinSizePending
    {
        set => _pendingPanel2MinSize = value;
    }

    public void RestoreDistance(int desired)
    {
        var max = Extent - Panel2MinSize - SplitterWidth;
        if (max < Panel1MinSize) return;
        SplitterDistance = Math.Clamp(desired, Panel1MinSize, max);
    }

    public void RestorePanel2Width(int desired)
        => RestoreDistance(Extent - Math.Max(Panel2MinSize, desired) - SplitterWidth);

    bool IsSplitter(Point point)
    {
        var axis = this.Orientation == System.Windows.Forms.Orientation.Vertical ? point.X : point.Y;
        return axis >= SplitterDistance - 3 && axis <= SplitterDistance + SplitterWidth + 3;
    }

    protected override void OnCreateControl()
    {
        base.OnCreateControl();
        if (_pendingPanel2MinSize.HasValue && base.Panel2MinSize != _pendingPanel2MinSize.Value)
        {
            base.Panel2MinSize = _pendingPanel2MinSize.Value;
            _pendingPanel2MinSize = null;
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        using var brush = new SolidBrush(Theme.Separator);
        e.Graphics.FillRectangle(brush, SplitterRectangle);
    }

    protected override void OnMouseDoubleClick(MouseEventArgs e)
    {
        base.OnMouseDoubleClick(e);
        if (!IsSplitter(e.Location)) return;
        if (ResetPanel2Width.HasValue) RestorePanel2Width(ResetPanel2Width.Value);
        else RestoreDistance(ResetDistance);
        SplitterReset?.Invoke(this, EventArgs.Empty);
    }
}

sealed class AgentBlinkenBank : Control
{
    public readonly string? AgentId;
    public string TaskId { get; set; } = "";
    public string AgentType { get; set; } = "Standby";
    public string Endpoint { get; set; } = "";
    public string Model { get; set; } = "";
    public bool IsActive { get; set; }

    const int Rows = 4;
    const int Cols = 10;
    const int TotalLamps = Rows * Cols;
    readonly bool[] _lamps = new bool[TotalLamps];
    readonly int[] _lampColors = new int[TotalLamps];
    readonly Random _rng = new();
    int _sweepStep;

    static readonly Color[] LampPalette = new[]
    {
        Color.FromArgb(65, 235, 95),   // Vivid Green
        Color.FromArgb(255, 175, 35),  // Warm Amber
        Color.FromArgb(255, 65, 65),   // Crimson Red
        Color.FromArgb(50, 215, 255),  // Bright Cyan
        Color.FromArgb(255, 235, 60),  // Vivid Yellow
        Color.FromArgb(220, 85, 255),  // Electric Violet
        Color.FromArgb(255, 110, 180), // Hot Pink
        Color.FromArgb(120, 180, 255)  // Ice Blue
    };

    public AgentBlinkenBank(string? agentId, string? taskId, string agentType)
    {
        AgentId = agentId;
        TaskId = taskId ?? "";
        AgentType = agentType;
        IsActive = !string.Equals(agentType, "standby", StringComparison.OrdinalIgnoreCase);
        DoubleBuffered = true;
        Size = new Size(225, 84);
        Margin = new Padding(4);

        for (var i = 0; i < TotalLamps; i++)
        {
            _lampColors[i] = _rng.Next(LampPalette.Length);
        }
    }

    public void Step()
    {
        if (!IsActive)
        {
            Array.Clear(_lamps, 0, _lamps.Length);
            Invalidate();
            return;
        }
        _sweepStep = (_sweepStep + 1) % 32;
        for (var i = 0; i < TotalLamps; i++)
        {
            var col = i % Cols;
            var sweepHit = (col == (_sweepStep % Cols));
            if (_rng.NextDouble() < 0.65)
            {
                _lamps[i] = sweepHit ? (_rng.NextDouble() < 0.85) : (_rng.NextDouble() < 0.38);
                // Each lamp changes color dynamically as it operates
                if (_rng.NextDouble() < 0.22)
                {
                    _lampColors[i] = (_lampColors[i] + _rng.Next(1, LampPalette.Length)) % LampPalette.Length;
                }
            }
        }
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.Clear(Parent?.BackColor ?? Color.FromArgb(10, 14, 18));
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;

        var r = new Rectangle(0, 0, Width - 1, Height - 1);

        Color borderColor, headerColor;
        switch (AgentType.ToLowerInvariant())
        {
            case "project critic":
                borderColor = IsActive ? Color.FromArgb(240, 60, 60) : Color.FromArgb(48, 58, 68);
                headerColor = Color.FromArgb(255, 95, 95);
                break;
            case "validator":
                borderColor = IsActive ? Color.FromArgb(245, 210, 45) : Color.FromArgb(48, 58, 68);
                headerColor = Color.FromArgb(255, 220, 70);
                break;
            case "researcher":
                borderColor = IsActive ? Color.FromArgb(50, 215, 255) : Color.FromArgb(48, 58, 68);
                headerColor = Color.FromArgb(70, 215, 255);
                break;
            case "worker":
                borderColor = IsActive ? Color.FromArgb(60, 225, 95) : Color.FromArgb(48, 58, 68);
                headerColor = Color.FromArgb(85, 225, 115);
                break;
            default:
                borderColor = Color.FromArgb(45, 55, 65);
                headerColor = Color.FromArgb(90, 105, 120);
                break;
        }

        using var panelBrush = new SolidBrush(Color.FromArgb(18, 24, 30));
        using var edgePen = new Pen(borderColor, IsActive ? 1.5f : 1.0f);
        using var innerPen = new Pen(Color.FromArgb(28, 36, 44));

        using (var cardPath = Theme.RoundedRect(r, 6))
        {
            g.FillPath(panelBrush, cardPath);
            g.DrawPath(edgePen, cardPath);
        }
        if (IsActive)
        {
            using var glowPen = new Pen(Color.FromArgb(65, borderColor));
            using var glowPath = Theme.RoundedRect(new Rectangle(r.X + 1, r.Y + 1, r.Width - 2, r.Height - 2), 5);
            g.DrawPath(glowPen, glowPath);
        }

        using var screwBrush = new SolidBrush(Color.FromArgb(70, 82, 94));
        g.FillEllipse(screwBrush, r.Left + 2, r.Top + 2, 3, 3);
        g.FillEllipse(screwBrush, r.Right - 5, r.Top + 2, 3, 3);
        g.FillEllipse(screwBrush, r.Left + 2, r.Bottom - 5, 3, 3);
        g.FillEllipse(screwBrush, r.Right - 5, r.Bottom - 5, 3, 3);

        var labelText = string.IsNullOrEmpty(TaskId) ? AgentType.ToUpperInvariant() : $"{AgentType.ToUpperInvariant()}: {TaskId}";
        using var font = new Font("Cascadia Mono", 7.5f, FontStyle.Bold);
        using var subFont = new Font("Cascadia Mono", 6.6f);
        using var textBrush = new SolidBrush(headerColor);
        using var subBrush = new SolidBrush(Color.FromArgb(115, 132, 145));
        g.DrawString(labelText, font, textBrush, 8, 3);
        var route = string.IsNullOrWhiteSpace(Endpoint) ? (string.IsNullOrWhiteSpace(Model) ? "UNASSIGNED ENDPOINT" : Model) :
            (string.IsNullOrWhiteSpace(Model) ? Endpoint : $"{Endpoint} / {Model}");
        g.DrawString(route, subFont, subBrush, 8, 14);

        var padX = 8;
        var padY = 29;
        var drawW = r.Width - padX * 2;
        var drawH = r.Height - padY - 4;
        if (drawW <= 0 || drawH <= 0) return;

        var ledW = Math.Max(4, (drawW - (Cols - 1) * 3) / Cols);
        var ledH = Math.Max(4, (drawH - (Rows - 1) * 3) / Rows);
        var spacingX = (drawW - ledW * Cols) / Math.Max(1, Cols - 1) + ledW;
        var spacingY = (drawH - ledH * Rows) / Math.Max(1, Rows - 1) + ledH;

        for (var row = 0; row < Rows; row++)
        {
            for (var col = 0; col < Cols; col++)
            {
                var idx = row * Cols + col;
                var x = r.X + padX + col * spacingX;
                var y = r.Y + padY + row * spacingY;
                var on = IsActive && _lamps[idx];
                var baseColor = LampPalette[_lampColors[idx]];
                var litColor = baseColor;
                var unlitColor = Color.FromArgb(Math.Max(12, baseColor.R / 7), Math.Max(14, baseColor.G / 7), Math.Max(16, baseColor.B / 7));
                var c = on ? litColor : unlitColor;
                var d = Math.Min(ledW, ledH);
                var cx = x + ledW / 2f - d / 2f;
                var cy = y + ledH / 2f - d / 2f;

                if (on)
                {
                    using (var glow = new SolidBrush(Color.FromArgb(90, c)))
                        g.FillEllipse(glow, cx - d * 0.35f, cy - d * 0.35f, d * 1.7f, d * 1.7f);
                }
                using (var b = new SolidBrush(c))
                    g.FillEllipse(b, cx, cy, d, d);

                if (on)
                {
                    using var hot = new SolidBrush(Color.FromArgb(190, 255, 255, 255));
                    g.FillEllipse(hot, cx + d * 0.2f, cy + d * 0.15f, Math.Max(1, d * 0.35f), Math.Max(1, d * 0.35f));
                }
                else
                {
                    g.DrawEllipse(innerPen, cx, cy, d, d);
                }
            }
        }
    }
}

sealed class BlinkenRack : Panel
{
    readonly FlowLayoutPanel _flow = new()
    {
        Dock = DockStyle.Fill,
        AutoScroll = true,
        WrapContents = true,
        BackColor = Color.FromArgb(10, 14, 18),
        Padding = new Padding(2)
    };
    readonly System.Windows.Forms.Timer _pulse = new() { Interval = 110 };
    readonly List<AgentBlinkenBank> _banks = new();
    readonly AgentBlinkenBank _standbyBank = new(null, null, "Standby");

    public BlinkenRack()
    {
        Dock = DockStyle.Fill;
        BackColor = Color.FromArgb(10, 14, 18);
        Controls.Add(_flow);
        _flow.Controls.Add(_standbyBank);
        _pulse.Tick += (_, _) =>
        {
            foreach (var b in _banks) b.Step();
        };
        _pulse.Start();
    }

    public void SyncAgents(List<ActiveAgentInfo> agents)
    {
        _flow.SuspendLayout();
        try
        {
            var activeIds = new HashSet<string>(agents.Select(a => a.AgentId), StringComparer.OrdinalIgnoreCase);

            for (var i = _banks.Count - 1; i >= 0; i--)
            {
                var b = _banks[i];
                if (!activeIds.Contains(b.AgentId ?? ""))
                {
                    b.IsActive = false;
                    _flow.Controls.Remove(b);
                    _banks.RemoveAt(i);
                    b.Dispose();
                }
            }

            foreach (var a in agents)
            {
                var existing = _banks.FirstOrDefault(b => string.Equals(b.AgentId, a.AgentId, StringComparison.OrdinalIgnoreCase));
                if (existing is not null)
                {
                    existing.TaskId = a.TaskId;
                    existing.AgentType = a.Type;
                    existing.Endpoint = a.Endpoint;
                    existing.Model = a.Model;
                    existing.IsActive = true;
                }
                else
                {
                    var newBank = new AgentBlinkenBank(a.AgentId, a.TaskId, a.Type) { Endpoint = a.Endpoint, Model = a.Model };
                    _banks.Add(newBank);
                    _flow.Controls.Add(newBank);
                }
            }

            if (!_flow.Controls.Contains(_standbyBank))
            {
                _flow.Controls.Add(_standbyBank);
            }
            _flow.Controls.SetChildIndex(_standbyBank, _flow.Controls.Count - 1);
            _standbyBank.IsActive = false;
        }
        finally
        {
            _flow.ResumeLayout();
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _pulse.Dispose();
            foreach (var b in _banks) b.Dispose();
            _standbyBank.Dispose();
        }
        base.Dispose(disposing);
    }
}

// TASK BOARD
//
// The blinkenlights above show currently RUNNING processes. This shows every
// task's lifecycle status at a glance, mainframe-panel style: one small round
// lamp per task, colored by status, next to its title.
sealed class LedIndicator : Control
{
    public Color OnColor { get; set; } = Color.FromArgb(48, 58, 68);

    public LedIndicator()
    {
        DoubleBuffered = true;
        Dock = DockStyle.Fill;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;

        var d = Math.Max(4, Math.Min(Width, Height) - 8);
        var rect = new Rectangle((Width - d) / 2, (Height - d) / 2, d, d);

        using (var glow = new SolidBrush(Color.FromArgb(70, OnColor)))
            g.FillEllipse(glow, rect.X - 2, rect.Y - 2, rect.Width + 4, rect.Height + 4);
        using (var body = new SolidBrush(OnColor))
            g.FillEllipse(body, rect);
        using (var highlight = new SolidBrush(Color.FromArgb(150, 255, 255, 255)))
            g.FillEllipse(highlight, rect.X + rect.Width / 4, rect.Y + rect.Height / 5, Math.Max(1, rect.Width / 3), Math.Max(1, rect.Height / 3));
        using var ring = new Pen(Color.FromArgb(10, 14, 18), 1.2f);
        g.DrawEllipse(ring, rect);
    }
}

sealed class PromptDialog : Form
{
    readonly TextBox _input = new() { Dock = DockStyle.Top, Font = new Font("Cascadia Mono", 9f) };
    public string Value => _input.Text.Trim();

    public PromptDialog(string title, string prompt, string defaultValue = "")
    {
        Text = title;
        Width = 480;
        Height = 180;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterParent;
        MaximizeBox = false;
        MinimizeBox = false;

        var panel = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Padding = new Padding(14) };
        panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var lbl = new Label { Text = prompt, Dock = DockStyle.Fill, Font = new Font("Segoe UI", 9f) };
        _input.Text = defaultValue;

        var btnBar = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft, WrapContents = false };
        var btnCancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Width = 85, Height = 28 };
        var btnOk = new Button { Text = "OK", DialogResult = DialogResult.OK, Width = 85, Height = 28 };
        btnBar.Controls.AddRange(new Control[] { btnCancel, btnOk });

        panel.Controls.Add(lbl, 0, 0);
        panel.Controls.Add(_input, 0, 1);
        panel.Controls.Add(btnBar, 0, 2);
        Controls.Add(panel);
        AcceptButton = btnOk;
        CancelButton = btnCancel;
        Theme.Apply(this);
    }

    public static string? Prompt(Form parent, string title, string prompt, string defaultValue = "")
    {
        using var dlg = new PromptDialog(title, prompt, defaultValue);
        return dlg.ShowDialog(parent) == DialogResult.OK ? dlg.Value : null;
    }
}

sealed class TaskDetailDialog : Form
{
    readonly string _root;
    readonly string _projectPath;
    readonly TaskBoardEntry _task;
    readonly List<string> _providers;
    readonly Action _onChanged;

    readonly Label _headerStatus = new() { AutoSize = true, Font = new Font("Cascadia Mono", 10.5f, FontStyle.Bold), Margin = new Padding(0, 2, 8, 0) };
    readonly Label _taskId = new() { AutoSize = true, Font = new Font("Cascadia Mono", 12f, FontStyle.Bold), ForeColor = Theme.Accent, Margin = new Padding(0, 0, 8, 0) };
    readonly Label _taskTitle = new() { Dock = DockStyle.Top, Font = new Font("Segoe UI", 9.5f), AutoEllipsis = true, Margin = new Padding(0, 4, 0, 4) };
    readonly Label _meta = new() { Dock = DockStyle.Top, Font = new Font("Cascadia Mono", 8.5f), ForeColor = Theme.Muted, Margin = new Padding(0, 0, 0, 6) };
    readonly TextBox _diagText = new() { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, Font = new Font("Cascadia Mono", 8.5f) };
    readonly ComboBox _cboProviders = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 160, Margin = new Padding(0, 4, 6, 0), Font = new Font("Segoe UI", 9f) };
    readonly Button _btnRetry = new() { Text = "🔄 Retry Task", Width = 115, Height = 32, Margin = new Padding(0, 4, 6, 0) };
    readonly Button _btnOverride = new() { Text = "⚡ Override & Complete", Width = 175, Height = 32, Margin = new Padding(0, 4, 6, 0) };
    readonly Button _btnRetryProvider = new() { Text = "Retry with Provider", Width = 150, Height = 32, Margin = new Padding(0, 4, 6, 0) };
    readonly Button _btnBlock = new() { Text = "🚫 Block Task", Width = 110, Height = 32, Margin = new Padding(0, 4, 6, 0) };
    readonly Button _btnCopy = new() { Text = "📋 Copy Report", Width = 120, Height = 32, Margin = new Padding(0, 4, 6, 0) };
    readonly Button _btnClose = new() { Text = "Close", Width = 80, Height = 32, Margin = new Padding(0, 4, 0, 0) };
    readonly Label _statusMsg = new() { AutoSize = true, ForeColor = Theme.Accent, Font = new Font("Cascadia Mono", 8.5f, FontStyle.Bold), Margin = new Padding(4, 10, 4, 0) };
    readonly List<Button> _actionButtons = new();

    public TaskDetailDialog(Form parent, string root, string projectPath, TaskBoardEntry task, List<string> providers, Action onChanged)
    {
        _root = root;
        _projectPath = projectPath;
        _task = task;
        _providers = providers;
        _onChanged = onChanged;

        Text = $"Task Diagnostics: {task.Id}";
        Width = 840;
        Height = 640;
        MinimumSize = new Size(680, 500);
        StartPosition = FormStartPosition.CenterParent;

        _actionButtons.AddRange(new[] { _btnRetry, _btnOverride, _btnRetryProvider, _btnBlock });

        BuildUi();
        LoadDiagnostics();
        Theme.Apply(this);
    }

    void BuildUi()
    {
        var main = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4, Padding = new Padding(12) };
        main.RowStyles.Add(new RowStyle(SizeType.Absolute, 72));
        main.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));
        main.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        main.RowStyles.Add(new RowStyle(SizeType.Absolute, 82));

        // Header
        var header = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Surface, Padding = new Padding(8, 6, 8, 6) };
        var topRow = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 26, WrapContents = false };
        var (statusColor, statusLabel) = StatusVisual(_task.Status);
        _headerStatus.Text = $"[{statusLabel}]";
        _headerStatus.ForeColor = statusColor;
        _taskId.Text = _task.Id;
        topRow.Controls.Add(_headerStatus);
        topRow.Controls.Add(_taskId);

        _taskTitle.Text = _task.Title;
        var metaList = new List<string>();
        if (_task.AttemptCount > 0) metaList.Add($"Attempts: {_task.AttemptCount}");
        if (!string.IsNullOrEmpty(_task.Role)) metaList.Add($"Role: {_task.Role}");
        if (!string.IsNullOrEmpty(_task.Size)) metaList.Add($"Size: {_task.Size}");
        if (!string.IsNullOrEmpty(_task.Provider)) metaList.Add($"Provider: {_task.Provider}");
        if (_task.DependsOn.Count > 0) metaList.Add($"DependsOn: [{string.Join(", ", _task.DependsOn)}]");
        _meta.Text = metaList.Count > 0 ? string.Join("  |  ", metaList) : "No special constraints";

        header.Controls.Add(_meta);
        header.Controls.Add(_taskTitle);
        header.Controls.Add(topRow);
        main.Controls.Add(header, 0, 0);

        // Section label
        var isFailure = _task.Status is "failed" or "needs_rework";
        var isBlocked = _task.Status is "blocked" or "stale";
        var sectionColor = isFailure ? Theme.Error : (isBlocked ? Theme.Warn : Theme.Accent);
        var secLabel = new Label
        {
            Text = isFailure ? "⚠ FAILURE DIAGNOSTICS & LOG OUTPUT" : (isBlocked ? "⚠ BLOCKER & REASON DETAILS" : "TASK DETAILS & EXECUTION HISTORY"),
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.BottomLeft,
            Font = new Font("Segoe UI Semibold", 8.5f, FontStyle.Bold),
            ForeColor = sectionColor
        };
        main.Controls.Add(secLabel, 0, 1);

        // Diag text
        main.Controls.Add(_diagText, 0, 2);

        // Action panel
        var actionPanel = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1 };
        actionPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        actionPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));

        var bar1 = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
        _btnRetry.Click += async (_, _) => await RunActionAsync("Retrying task...", () => {
            var harness = System.IO.Path.Combine(_root, "StatefulClanker.ps1");
            return Runtime.RunPowerShell(_projectPath, "-File", harness, "task", "retry", "-TaskId", _task.Id);
        });

        _btnOverride.Click += async (_, _) => {
            if (MessageBox.Show(this, $"Override validation and manually mark task '{_task.Id}' as COMPLETE?\n\nThis records human authority and immediately unblocks dependent downstream tasks.", "Manual Completion Override", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
                return;
            await RunActionAsync("Overriding validation and marking complete...", () => {
                var harness = System.IO.Path.Combine(_root, "StatefulClanker.ps1");
                return Runtime.RunPowerShell(_projectPath, "-File", harness, "complete", "-TaskId", _task.Id);
            });
        };

        _btnBlock.Click += async (_, _) => {
            var reason = PromptDialog.Prompt(this, "Block Task", $"Enter reason for blocking task '{_task.Id}':", _task.BlockReason ?? "Blocked by operator");
            if (string.IsNullOrWhiteSpace(reason)) return;
            await RunActionAsync("Blocking task...", () => {
                var harness = System.IO.Path.Combine(_root, "StatefulClanker.ps1");
                return Runtime.RunPowerShell(_projectPath, "-File", harness, "block", "-TaskId", _task.Id, "-Reason", reason);
            });
        };

        _btnCopy.Click += (_, _) => {
            Clipboard.SetText(_diagText.Text);
            _statusMsg.Text = "Copied full diagnostics report to clipboard!";
            _statusMsg.ForeColor = Theme.Good;
        };

        _btnClose.Click += (_, _) => Close();

        bar1.Controls.AddRange(new Control[] { _btnRetry, _btnOverride, _btnBlock, _btnCopy, _btnClose });
        actionPanel.Controls.Add(bar1, 0, 0);

        var bar2 = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
        _cboProviders.Items.Clear();
        foreach (var p in _providers) _cboProviders.Items.Add(p);
        if (!string.IsNullOrEmpty(_task.Provider) && _providers.Contains(_task.Provider))
            _cboProviders.SelectedItem = _task.Provider;
        else if (_cboProviders.Items.Count > 0)
            _cboProviders.SelectedIndex = 0;

        _btnRetryProvider.Click += async (_, _) => {
            var selectedProv = _cboProviders.SelectedItem?.ToString();
            if (string.IsNullOrWhiteSpace(selectedProv)) return;
            await RunActionAsync($"Setting provider to '{selectedProv}' and retrying...", () => {
                var harness = System.IO.Path.Combine(_root, "StatefulClanker.ps1");
                Runtime.RunPowerShell(_projectPath, "-File", harness, "task", "set", "-TaskId", _task.Id, "-Provider", selectedProv);
                return Runtime.RunPowerShell(_projectPath, "-File", harness, "task", "retry", "-TaskId", _task.Id);
            });
        };

        var provLbl = new Label { Text = "Override Provider:", AutoSize = true, Margin = new Padding(0, 10, 4, 0), ForeColor = Theme.Muted };
        bar2.Controls.AddRange(new Control[] { provLbl, _cboProviders, _btnRetryProvider, _statusMsg });
        actionPanel.Controls.Add(bar2, 0, 1);

        main.Controls.Add(actionPanel, 0, 3);
        Controls.Add(main);
    }

    void LoadDiagnostics()
    {
        var (_, details) = Inspector.GetTaskDiagnostics(_projectPath, _task);
        _diagText.Text = details;
        _diagText.SelectionStart = 0;
        _diagText.SelectionLength = 0;
    }

    async Task RunActionAsync(string busyText, Func<(int code, string stdout, string stderr)> action)
    {
        _statusMsg.Text = busyText;
        _statusMsg.ForeColor = Theme.Accent;
        foreach (var btn in _actionButtons) btn.Enabled = false;
        try
        {
            var result = await Task.Run(action);
            if (result.code == 0)
            {
                _statusMsg.Text = "Command completed successfully.";
                _statusMsg.ForeColor = Theme.Good;
                _onChanged();
                await Task.Delay(400);
                if (!IsDisposed) Close();
            }
            else
            {
                _statusMsg.Text = "Failed: " + (string.IsNullOrWhiteSpace(result.stderr) ? result.stdout : result.stderr).Trim();
                _statusMsg.ForeColor = Theme.Error;
                foreach (var btn in _actionButtons) btn.Enabled = true;
            }
        }
        catch (Exception ex)
        {
            _statusMsg.Text = "Error: " + ex.Message;
            _statusMsg.ForeColor = Theme.Error;
            foreach (var btn in _actionButtons) btn.Enabled = true;
        }
    }

    static (Color, string) StatusVisual(string status) => status switch
    {
        "complete" => (Color.FromArgb(65, 235, 95), "DONE"),
        "running" => (Color.FromArgb(70, 150, 255), "RUNNING"),
        "reviewing" => (Color.FromArgb(255, 220, 70), "CRITIC"),
        "validating" => (Color.FromArgb(255, 220, 70), "VALIDATOR"),
        "needs_rework" => (Color.FromArgb(240, 60, 60), "REJECTED"),
        "failed" => (Color.FromArgb(240, 60, 60), "FAILED"),
        "stale" => (Color.FromArgb(255, 140, 50), "STALE"),
        "blocked" => (Color.FromArgb(180, 70, 70), "BLOCKED"),
        "ready" => (Color.FromArgb(80, 170, 220), "READY"),
        "pending" => (Color.FromArgb(75, 90, 105), "PENDING"),
        "" => (Color.FromArgb(48, 58, 68), "—"),
        _ => (Color.FromArgb(48, 58, 68), status.ToUpperInvariant())
    };
}

sealed class TaskBoardRow : TableLayoutPanel
{
    public readonly LedIndicator Led = new();
    readonly Label _title = new() { Dock = DockStyle.Fill, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft, ForeColor = Theme.Text, Font = new Font("Cascadia Mono", 8.75f), Margin = new Padding(2, 0, 4, 0) };
    readonly Label _status = new() { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleRight, Font = new Font("Cascadia Mono", 8f, FontStyle.Bold), Margin = new Padding(0, 0, 8, 0) };
    readonly ToolTip _tooltip = new() { InitialDelay = 200, ReshowDelay = 100, AutoPopDelay = 12000 };
    TaskBoardEntry? _entry;
    Color _defaultBg = Color.FromArgb(14, 19, 25);
    Color _hoverBg = Color.FromArgb(28, 38, 50);

    public event Action<TaskBoardEntry>? InspectRequested;
    public event Action<TaskBoardEntry>? RetryRequested;
    public event Action<TaskBoardEntry>? CompleteRequested;
    public event Action<TaskBoardEntry>? BlockRequested;

    public TaskBoardRow()
    {
        Dock = DockStyle.Top;
        Height = 26;
        ColumnCount = 3;
        RowCount = 1;
        BackColor = _defaultBg;
        Margin = new Padding(0, 0, 0, 1);
        Cursor = Cursors.Hand;
        ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 26));
        ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 92));
        Controls.Add(Led, 0, 0);
        Controls.Add(_title, 1, 0);
        Controls.Add(_status, 2, 0);

        var menu = new ContextMenuStrip();
        menu.Items.Add("🔍 View Failure Reason & Diagnostics...", null, (_, _) => { if (_entry != null) InspectRequested?.Invoke(_entry); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("🔄 Retry Task (Reset to Ready)", null, (_, _) => { if (_entry != null) RetryRequested?.Invoke(_entry); });
        menu.Items.Add("⚡ Override & Mark Complete", null, (_, _) => { if (_entry != null) CompleteRequested?.Invoke(_entry); });
        menu.Items.Add("🚫 Block Task...", null, (_, _) => { if (_entry != null) BlockRequested?.Invoke(_entry); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("📋 Copy Task ID", null, (_, _) => { if (_entry != null) Clipboard.SetText(_entry.Id); });
        menu.Items.Add("📋 Copy Failure Reason", null, (_, _) => { if (_entry != null && !string.IsNullOrEmpty(_entry.BlockReason)) Clipboard.SetText(_entry.BlockReason); });

        ContextMenuStrip = menu;
        Led.ContextMenuStrip = menu;
        _title.ContextMenuStrip = menu;
        _status.ContextMenuStrip = menu;

        foreach (Control c in new Control[] { this, Led, _title, _status })
        {
            c.Cursor = Cursors.Hand;
            c.MouseEnter += (_, _) => { BackColor = _hoverBg; };
            c.MouseLeave += (_, _) => { BackColor = _defaultBg; };
            c.MouseClick += (s, e) =>
            {
                if (e.Button == MouseButtons.Left && _entry != null)
                {
                    InspectRequested?.Invoke(_entry);
                }
            };
            c.DoubleClick += (_, _) =>
            {
                if (_entry != null) InspectRequested?.Invoke(_entry);
            };
        }
    }

    public void SetTask(TaskBoardEntry t)
    {
        _entry = t;
        _title.Text = string.IsNullOrEmpty(t.Title) ? t.Id : t.Title;
        var (color, label) = StatusVisual(t.Status);
        Led.OnColor = color;
        _status.Text = label;
        _status.ForeColor = color;

        if (t.Status is "failed" or "needs_rework")
            _defaultBg = Color.FromArgb(38, 16, 20);
        else if (t.Status == "blocked")
            _defaultBg = Color.FromArgb(28, 20, 22);
        else if (t.Status == "stale")
            _defaultBg = Color.FromArgb(32, 24, 16);
        else
            _defaultBg = Color.FromArgb(14, 19, 25);

        _hoverBg = Color.FromArgb(Math.Min(255, _defaultBg.R + 22), Math.Min(255, _defaultBg.G + 22), Math.Min(255, _defaultBg.B + 28));
        BackColor = _defaultBg;

        var tip = $"[{t.Id}] {t.Title}\nStatus: {label}" + (t.AttemptCount > 0 ? $" (Attempt #{t.AttemptCount})" : "");
        if (!string.IsNullOrWhiteSpace(t.BlockReason)) tip += $"\nReason: {t.BlockReason}";
        tip += "\n\n(Click to inspect failure & override options)";

        _tooltip.SetToolTip(this, tip);
        _tooltip.SetToolTip(_title, tip);
        _tooltip.SetToolTip(_status, tip);
        _tooltip.SetToolTip(Led, tip);

        Led.Invalidate();
    }

    static (Color, string) StatusVisual(string status) => status switch
    {
        "complete" => (Color.FromArgb(65, 235, 95), "DONE"),
        "running" => (Color.FromArgb(70, 150, 255), "RUNNING"),
        "reviewing" => (Color.FromArgb(255, 220, 70), "CRITIC"),
        "validating" => (Color.FromArgb(255, 220, 70), "VALIDATOR"),
        "needs_rework" => (Color.FromArgb(240, 60, 60), "REJECTED"),
        "failed" => (Color.FromArgb(240, 60, 60), "FAILED"),
        "stale" => (Color.FromArgb(255, 140, 50), "STALE"),
        "blocked" => (Color.FromArgb(180, 70, 70), "BLOCKED"),
        "ready" => (Color.FromArgb(80, 170, 220), "READY"),
        "pending" => (Color.FromArgb(75, 90, 105), "PENDING"),
        "" => (Color.FromArgb(48, 58, 68), "—"),
        _ => (Color.FromArgb(48, 58, 68), status.ToUpperInvariant())
    };
}

sealed class TaskBoardPanel : Panel
{
    readonly TableLayoutPanel _list = new() { Dock = DockStyle.Top, ColumnCount = 1, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
    readonly Label _empty = new() { Dock = DockStyle.Top, Height = 24, Text = "No tasks yet.", ForeColor = Theme.Muted, Font = new Font("Cascadia Mono", 8.75f), TextAlign = ContentAlignment.MiddleLeft, Margin = new Padding(4, 4, 0, 0) };

    public event Action<TaskBoardEntry>? InspectRequested;
    public event Action<TaskBoardEntry>? RetryRequested;
    public event Action<TaskBoardEntry>? CompleteRequested;
    public event Action<TaskBoardEntry>? BlockRequested;

    public TaskBoardPanel()
    {
        Dock = DockStyle.Fill;
        AutoScroll = true;
        BackColor = Color.FromArgb(10, 14, 18);
        Padding = new Padding(2);
        Controls.Add(_empty);
        Controls.Add(_list);
    }

    public void SetTasks(IReadOnlyList<TaskBoardEntry> tasks)
    {
        _list.SuspendLayout();
        try
        {
            while (_list.Controls.Count < tasks.Count)
            {
                var row = new TaskBoardRow();
                row.InspectRequested += t => InspectRequested?.Invoke(t);
                row.RetryRequested += t => RetryRequested?.Invoke(t);
                row.CompleteRequested += t => CompleteRequested?.Invoke(t);
                row.BlockRequested += t => BlockRequested?.Invoke(t);

                _list.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));
                _list.RowCount = _list.Controls.Count + 1;
                _list.Controls.Add(row, 0, _list.Controls.Count);
            }
            while (_list.Controls.Count > tasks.Count)
            {
                var last = _list.Controls[_list.Controls.Count - 1];
                _list.Controls.Remove(last);
                last.Dispose();
                if (_list.RowStyles.Count > 0) _list.RowStyles.RemoveAt(_list.RowStyles.Count - 1);
            }
            for (var i = 0; i < tasks.Count; i++)
            {
                ((TaskBoardRow)_list.Controls[i]).SetTask(tasks[i]);
            }
            _empty.Visible = tasks.Count == 0;
        }
        finally
        {
            _list.ResumeLayout();
        }
    }
}

sealed class MainForm : Form
{
    readonly string _root = Runtime.FindRoot();
    readonly AppSettings _settings = AppStore.Load();
    readonly TreeView _projects = new();
    readonly TabControl _tabs = new();
    readonly Label _header = new(), _mcpState = new(), _intent = new(), _goal = new();
    readonly Label[] _metrics = Enumerable.Range(0, 5).Select(_ => new Label()).ToArray();
    readonly TextBox _usage = new(), _allActivity = new(), _workerTelemetry = new(), _endpoint = new(), _stdio = new(), _integrationNote = new();
    readonly DataGridView _overviewTargets = new();
    readonly Label _overviewTargetSummary = new();
    readonly BlinkenRack _blinkenRack = new();
    readonly TaskBoardPanel _taskBoard = new();
    readonly RecentActivityPanel _recentActivity = new();
    readonly OverviewReadoutPanel _overviewReadout = new();
    readonly EmbeddedTerminalPanel _terminal = new();
    readonly DataGridView _integrations = new(), _providers = new(), _mcpImport = new();
    readonly Button _btnMcpDiscover = Btn("Discover", 100);
    readonly Label _autofillStatus = new();
    readonly Button _btnAutofillToggle = Btn("Start Autofill", 115);
    readonly Button _btnAutofillPause = Btn("Pause", 80);
    readonly Button _btnAutofillTrigger = Btn("Trigger Now", 95);
    readonly NumericUpDown _numMaxConcurrent = new() { Minimum = 1, Maximum = 16, Value = 3, Width = 55, Margin = new Padding(0, 4, 8, 0), Font = new Font("Segoe UI", 9) };
    bool _updatingAutofillUi;
    readonly System.Windows.Forms.Timer _timer = new() { Interval = 3000 };
    readonly System.Windows.Forms.Timer _layoutSaveTimer = new() { Interval = 450 };
    string? _eventCursorTs = DateTimeOffset.UtcNow.ToString("o");
    static readonly HashSet<string> EscalatedEventTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "run.failed", "critic.error", "validator.error", "project.hold.set", "project.review.failed",
        "state.proposal_rejected", "task.plan_repair_required", "autofill.stalled"
    };
    int _refreshing;
    int _mcpDiscoveryRunning;
    readonly McpHost _mcp;
    readonly AutofillHost _autofill;
    readonly NotifyIcon _notify;
    bool _reallyExit;

    public MainForm()
    {
        Text = "StatefulClanker"; Width = 1160; Height = 740; MinimumSize = new Size(920, 590); StartPosition = FormStartPosition.CenterScreen;
        try { using var s = typeof(MainForm).Assembly.GetManifestResourceStream("StatefulClanker.ico"); if (s is not null) Icon = new Icon(s); } catch { }
        _mcp = new McpHost(_root, _settings.HttpPort, _settings.McpToken); _mcp.EnsureStarted(); _autofill = new AutofillHost(_root);
        var menu = new ContextMenuStrip(); menu.Items.Add("Open StatefulClanker", null, (_, _) => ShowFromTray()); menu.Items.Add("Exit", null, (_, _) => { _reallyExit = true; Close(); });
        _notify = new NotifyIcon { Text = "StatefulClanker", Icon = Icon ?? SystemIcons.Application, Visible = true, ContextMenuStrip = menu }; _notify.DoubleClick += (_, _) => ShowFromTray();
        BuildUi(); RestoreProjects(); Theme.Apply(this); _ = RefreshAllAsync();
        _layoutSaveTimer.Tick += (_, _) => { _layoutSaveTimer.Stop(); AppStore.Save(_settings); };
        _timer.Tick += async (_, _) => { await RefreshAllAsync(); EscalateNewEvents(); }; _timer.Start(); Resize += (_, _) => { if (WindowState == FormWindowState.Minimized) Hide(); }; FormClosing += HandleFormClosing;
    }

    // Surface failures and holds in the active terminal. QueueNotice displays a
    // toast and flushes the notice into the PTY at the next input boundary.
    void EscalateNewEvents()
    {
        if (!_terminal.HasActiveSession) return;
        var project = _settings.ActiveProjectPath;
        if (string.IsNullOrWhiteSpace(project) || !Directory.Exists(project)) return;
        var eventsPath = System.IO.Path.Combine(project, ".statefulclanker", "events.jsonl");
        foreach (var (ts, type, message) in ReadNewEvents(eventsPath, ref _eventCursorTs))
        {
            var text = string.IsNullOrWhiteSpace(message) ? type : $"{type}: {message}";
            _terminal.QueueNotice($"# [StatefulClanker] {text}");
        }
    }

    static List<(string ts, string type, string message)> ReadNewEvents(string path, ref string? cursorTs)
    {
        var results = new List<(string ts, string type, string message)>();
        if (!File.Exists(path)) return results;
        string? newCursor = cursorTs;
        foreach (var line in File.ReadLines(path))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            try
            {
                using var d = JsonDocument.Parse(line);
                var r = d.RootElement;
                var ts = r.TryGetProperty("ts", out var t) ? t.GetString() : null;
                var type = r.TryGetProperty("type", out var ty) ? ty.GetString() : null;
                if (string.IsNullOrEmpty(ts) || string.IsNullOrEmpty(type)) continue;
                if (cursorTs is not null && string.CompareOrdinal(ts, cursorTs) <= 0) continue;
                if (!EscalatedEventTypes.Contains(type)) { if (newCursor is null || string.CompareOrdinal(ts, newCursor) > 0) newCursor = ts; continue; }
                var message = r.TryGetProperty("message", out var mm) ? mm.GetString() ?? "" : "";
                results.Add((ts, type, message));
                if (newCursor is null || string.CompareOrdinal(ts, newCursor) > 0) newCursor = ts;
            }
            catch { }
        }
        cursorTs = newCursor;
        return results;
    }

    static Button Btn(string text, int width = 145) => new() { Text = text, Width = width, Height = 32, Margin = new Padding(0, 4, 8, 0) };
    static Label Section(string text) => new() { Text = text, Dock = DockStyle.Fill, TextAlign = ContentAlignment.BottomLeft, Font = new Font("Segoe UI Semibold", 8, FontStyle.Bold), ForeColor = Theme.Muted, AutoEllipsis = true, Padding = new Padding(1, 0, 1, 3) };
    TabPage Page(string name) => new(name) { Padding = new Padding(12), BackColor = Theme.Back, ForeColor = Theme.Text };

    void QueueLayoutSave()
    {
        _layoutSaveTimer.Stop();
        _layoutSaveTimer.Start();
    }

    void TrackSplitter(QuietSplitContainer split, Action capture)
    {
        split.SplitterMoved += (_, _) => { capture(); QueueLayoutSave(); };
        split.SplitterReset += (_, _) => { capture(); QueueLayoutSave(); };
    }

    void RestoreSplitterWhenShown(Action restore)
    {
        Shown += (_, _) => BeginInvoke(new Action(restore));
    }

    void BuildUi()
    {
        var shell = new QuietSplitContainer(Orientation.Vertical)
        {
            Panel1MinSize = 160,
            Panel2MinSizePending = 540,
            ResetDistance = 235
        };
        var workspace = new QuietSplitContainer(Orientation.Vertical)
        {
            Panel1MinSize = 430,
            Panel2MinSizePending = 180,
            ResetPanel2Width = 265
        };
        Controls.Add(shell);
        shell.Panel2.Controls.Add(workspace);

        var leftRoot = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, Padding = new Padding(12), Margin = new Padding(0), BackColor = Theme.Back };
        leftRoot.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        leftRoot.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        leftRoot.Controls.Add(new Label { Text = "STATEFULCLANKER", Dock = DockStyle.Fill, Font = new Font("Segoe UI Semibold", 12, FontStyle.Bold), ForeColor = Theme.Accent, TextAlign = ContentAlignment.MiddleLeft }, 0, 0);

        var leftBody = new QuietSplitContainer(Orientation.Horizontal)
        {
            Panel1MinSize = 145,
            Panel2MinSizePending = 90,
            ResetDistance = 330
        };
        var projectPanel = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 4, ColumnCount = 1, Margin = new Padding(0), BackColor = Theme.Back };
        projectPanel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        projectPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        projectPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        projectPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        _projects.Dock = DockStyle.Fill; _projects.HideSelection = false; _projects.BorderStyle = BorderStyle.None; _projects.ShowLines = false; _projects.ShowPlusMinus = false; _projects.FullRowSelect = true; _projects.ItemHeight = 28;
        _projects.AfterSelect += (_, _) => SelectProject(); projectPanel.Controls.Add(_projects, 0, 0);
        var add = Btn("+ Add / open project", 210); add.Dock = DockStyle.Fill; add.Click += (_, _) => AddProject(); projectPanel.Controls.Add(add, 0, 1);
        var remove = Btn("Remove from list", 210); remove.Dock = DockStyle.Fill; remove.Click += (_, _) => RemoveProject(); projectPanel.Controls.Add(remove, 0, 2);
        var explorer = Btn("Open in Explorer", 210); explorer.Dock = DockStyle.Fill; explorer.Click += (_, _) => OpenExplorer(); projectPanel.Controls.Add(explorer, 0, 3);
        leftBody.Panel1.Controls.Add(projectPanel);

        var leftTargetSplit = new QuietSplitContainer(Orientation.Horizontal)
        {
            Panel1MinSize = 110,
            Panel2MinSizePending = 80,
            ResetDistance = 180
        };
        var targetPanel = BuildTargetPoolPanel();
        leftTargetSplit.Panel1.Controls.Add(targetPanel);

        var recentPanel = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, Margin = new Padding(0), Padding = new Padding(0, 4, 0, 0), BackColor = Theme.Back };
        recentPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 30));
        recentPanel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        recentPanel.Controls.Add(Section("RECENT ACTIVITY"), 0, 0);
        _recentActivity.OpenActivityRequested += () => _tabs.SelectedIndex = 1;
        recentPanel.Controls.Add(_recentActivity, 0, 1);
        leftTargetSplit.Panel2.Controls.Add(recentPanel);
        leftBody.Panel2.Controls.Add(leftTargetSplit);
        leftRoot.Controls.Add(leftBody, 0, 1);
        shell.Panel1.Controls.Add(leftRoot);

        var center = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, Padding = new Padding(14), Margin = new Padding(0), BackColor = Theme.Back };
        center.RowStyles.Add(new RowStyle(SizeType.Absolute, 52));
        center.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var top = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1 };
        top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        top.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 210));
        _header.Dock = DockStyle.Fill; _header.Font = new Font("Segoe UI Semibold", 15, FontStyle.Bold); _header.TextAlign = ContentAlignment.MiddleLeft;
        _mcpState.Dock = DockStyle.Fill; _mcpState.TextAlign = ContentAlignment.MiddleCenter; _mcpState.Font = new Font("Cascadia Mono", 8.5f, FontStyle.Bold);
        top.Controls.Add(_header, 0, 0); top.Controls.Add(_mcpState, 1, 0); center.Controls.Add(top, 0, 0);

        _tabs.Dock = DockStyle.Fill;
        _tabs.Appearance = TabAppearance.FlatButtons;
        _tabs.ItemSize = new Size(118, 30);
        _tabs.SizeMode = TabSizeMode.Fixed;
        _tabs.DrawMode = TabDrawMode.OwnerDrawFixed;
        _tabs.Padding = new Point(14, 6);
        _tabs.DrawItem += (s, e) =>
        {
            var g = e.Graphics;
            var tab = _tabs.TabPages[e.Index];
            var selected = e.Index == _tabs.SelectedIndex;
            var bounds = e.Bounds;
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using var back = new SolidBrush(selected ? Theme.Surface2 : Theme.Back);
            g.FillRectangle(back, bounds);
            using var text = new SolidBrush(selected ? Theme.Text : Theme.Muted);
            using var font = new Font("Segoe UI Semibold", 9f, selected ? FontStyle.Bold : FontStyle.Regular);
            using var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString(tab.Text, font, text, bounds, sf);
            if (selected)
            {
                using var accent = new SolidBrush(Theme.Accent);
                g.FillRectangle(accent, bounds.X + 8, bounds.Bottom - 1, bounds.Width - 16, 1);
            }
        };
        _tabs.TabPages.Add(BuildOverview());
        _tabs.TabPages.Add(BuildActivity());
        _tabs.TabPages.Add(BuildIntegrations());
        _tabs.TabPages.Add(BuildMcpImport());
        center.Controls.Add(_tabs, 0, 1);
        workspace.Panel1.Controls.Add(center);

        var taskRail = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, Padding = new Padding(12), Margin = new Padding(0), BackColor = Theme.Back };
        taskRail.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        taskRail.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        _metrics[0].Dock = DockStyle.Fill; _metrics[0].Margin = new Padding(0); _metrics[0].TextAlign = ContentAlignment.MiddleLeft;
        _metrics[0].Font = new Font("Cascadia Mono", 10, FontStyle.Bold); _metrics[0].Text = "TASK STATE";
        taskRail.Controls.Add(_metrics[0], 0, 0);
        _taskBoard.Dock = DockStyle.Fill; _taskBoard.Margin = new Padding(0);
        _taskBoard.InspectRequested += task => ShowTaskDetails(task);
        _taskBoard.RetryRequested += task => RetryTask(task);
        _taskBoard.CompleteRequested += task => OverrideCompleteTask(task);
        _taskBoard.BlockRequested += task => BlockTask(task);
        taskRail.Controls.Add(_taskBoard, 0, 1);
        workspace.Panel2.Controls.Add(taskRail);

        TrackSplitter(shell, () => _settings.LeftRailWidth = shell.SplitterDistance);
        TrackSplitter(leftBody, () => _settings.LeftProjectHeight = leftBody.SplitterDistance);
        TrackSplitter(leftTargetSplit, () => _settings.LeftTargetPoolHeight = leftTargetSplit.SplitterDistance);
        TrackSplitter(workspace, () => _settings.RightRailWidth = Math.Max(workspace.Panel2MinSize, workspace.Width - workspace.SplitterDistance - workspace.SplitterWidth));
        RestoreSplitterWhenShown(() =>
        {
            shell.RestoreDistance(_settings.LeftRailWidth);
            leftBody.RestoreDistance(_settings.LeftProjectHeight);
            leftTargetSplit.RestoreDistance(_settings.LeftTargetPoolHeight);
            workspace.RestorePanel2Width(_settings.RightRailWidth);
        });
    }

    TabPage BuildOverview()
    {
        var p = Page("Overview");

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            RowCount = 3,
            ColumnCount = 1,
            Margin = new Padding(0),
            Padding = new Padding(8),
            BackColor = Theme.Back
        };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 98));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        _overviewReadout.Margin = new Padding(0,0,0,6);
        root.Controls.Add(_overviewReadout,0,0);

        var controls = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            WrapContents = false,
            AutoScroll = false,
            Margin = new Padding(0),
            Padding = new Padding(0,2,0,2),
            BackColor = Theme.Back
        };
        _btnAutofillToggle.Click += (_, _) => ToggleAutofill();
        _btnAutofillPause.Click += (_, _) => ToggleAutofillPause();
        _btnAutofillTrigger.Click += (_, _) => TriggerAutofill();
        _numMaxConcurrent.ValueChanged += (_, _) => OnMaxConcurrentChanged();
        _btnAutofillToggle.Width=102;_btnAutofillPause.Width=72;_btnAutofillTrigger.Width=88;
        var maxLbl = new Label { Text = "WORKER CAP", AutoSize = true, Margin = new Padding(8,9,5,0), ForeColor = Theme.Muted, Font = new Font("Cascadia Mono",7.5f,FontStyle.Bold) };
        _numMaxConcurrent.Margin = new Padding(0,4,0,0);
        controls.Controls.AddRange(new Control[] { _btnAutofillToggle,_btnAutofillPause,_btnAutofillTrigger,maxLbl,_numMaxConcurrent });
        root.Controls.Add(controls,0,1);

        var stars = new QuietSplitContainer(Orientation.Horizontal)
        {
            Panel1MinSize = 145,
            Panel2MinSizePending = 220,
            ResetDistance = 205
        };

        var blinkenFrame = new Panel { Dock=DockStyle.Fill, BackColor=Color.FromArgb(9,13,16), Padding=new Padding(5), Margin=new Padding(0) };
        var blinkenLayout = new TableLayoutPanel { Dock=DockStyle.Fill, RowCount=2, ColumnCount=1, Margin=new Padding(0), BackColor=Color.FromArgb(9,13,16) };
        blinkenLayout.RowStyles.Add(new RowStyle(SizeType.Absolute,22));
        blinkenLayout.RowStyles.Add(new RowStyle(SizeType.Percent,100));
        blinkenLayout.Controls.Add(new Label
        {
            Text="BLINKENLIGHTS // ACTIVE WORKER ENDPOINTS",
            Dock=DockStyle.Fill,
            ForeColor=Theme.Accent,
            Font=new Font("Cascadia Mono",7.5f,FontStyle.Bold),
            TextAlign=ContentAlignment.MiddleLeft,
            Padding=new Padding(4,0,0,0)
        },0,0);
        _blinkenRack.Dock=DockStyle.Fill;
        blinkenLayout.Controls.Add(_blinkenRack,0,1);
        blinkenFrame.Controls.Add(blinkenLayout);
        stars.Panel1.Controls.Add(blinkenFrame);

        _terminal.Dock = DockStyle.Fill;
        stars.Panel2.Controls.Add(_terminal);
        root.Controls.Add(stars,0,2);
        p.Controls.Add(root);

        TrackSplitter(stars, () => _settings.OverviewInfoHeight = stars.SplitterDistance);
        RestoreSplitterWhenShown(() => stars.RestoreDistance(Math.Max(145,_settings.OverviewInfoHeight)));
        return p;
    }

    Control BuildTargetPoolPanel()
    {
        var card = new CardPanel { Dock = DockStyle.Fill, Padding = new Padding(8), Margin = new Padding(0, 0, 0, 4) };
        var rows = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1 };
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 22)); rows.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        _overviewTargetSummary.Dock = DockStyle.Fill; _overviewTargetSummary.Font = new Font("Segoe UI Semibold", 8f, FontStyle.Bold); _overviewTargetSummary.ForeColor = Theme.Muted; _overviewTargetSummary.Text = "TARGET POOL";
        _overviewTargets.Dock = DockStyle.Fill; _overviewTargets.AllowUserToAddRows = false; _overviewTargets.RowHeadersVisible = false; _overviewTargets.SelectionMode = DataGridViewSelectionMode.FullRowSelect; _overviewTargets.MultiSelect = false; _overviewTargets.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill; _overviewTargets.BackgroundColor = Theme.Surface; _overviewTargets.BorderStyle = BorderStyle.None;
        _overviewTargets.Columns.Add(new DataGridViewCheckBoxColumn { Name = "enabled", HeaderText = "On", Width = 42, AutoSizeMode = DataGridViewAutoSizeColumnMode.None });
        _overviewTargets.Columns.Add("connection", "Connection"); _overviewTargets.Columns.Add("model", "Model");
        foreach (DataGridViewColumn column in _overviewTargets.Columns) if (column.Name != "enabled") column.ReadOnly = true;
        _overviewTargets.CurrentCellDirtyStateChanged += (_, _) => { if (_overviewTargets.IsCurrentCellDirty && _overviewTargets.CurrentCell?.ColumnIndex == 0) _overviewTargets.CommitEdit(DataGridViewDataErrorContexts.Commit); };
        _overviewTargets.CellValueChanged += (_, e) => { if (e.RowIndex >= 0 && e.ColumnIndex == 0 && _overviewTargets.Rows[e.RowIndex].Tag is TargetPoolEntry target) ToggleOverviewTarget(target, Convert.ToBoolean(_overviewTargets.Rows[e.RowIndex].Cells[0].Value)); };
        rows.Controls.Add(_overviewTargetSummary, 0, 0); rows.Controls.Add(_overviewTargets, 0, 1); card.Controls.Add(rows);
        return card;
    }

    TabPage BuildActivity()
    {
        var p = Page("Activity & Telemetry");
        var split = new QuietSplitContainer(Orientation.Horizontal)
        {
            Panel1MinSize = 110,
            Panel2MinSizePending = 110,
            ResetDistance = 300
        };

        var telemetryPane = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, Margin = new Padding(0), BackColor = Theme.Back };
        telemetryPane.RowStyles.Add(new RowStyle(SizeType.Absolute, 30));
        telemetryPane.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        telemetryPane.Controls.Add(Section("WORKER TELEMETRY / CONTEXT FAULTS"), 0, 0);
        _workerTelemetry.Dock = DockStyle.Fill; _workerTelemetry.Multiline = true; _workerTelemetry.ReadOnly = true; _workerTelemetry.ScrollBars = ScrollBars.Both; _workerTelemetry.WordWrap = false; _workerTelemetry.BorderStyle = BorderStyle.None; _workerTelemetry.Font = new Font("Cascadia Mono", 8.5f);
        telemetryPane.Controls.Add(_workerTelemetry, 0, 1);

        var activityPane = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1, Margin = new Padding(0), BackColor = Theme.Back };
        activityPane.RowStyles.Add(new RowStyle(SizeType.Absolute, 30));
        activityPane.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        activityPane.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        activityPane.Controls.Add(Section("DURABLE RECENT ACTIVITY"), 0, 0);
        _allActivity.Dock = DockStyle.Fill; _allActivity.Multiline = true; _allActivity.ReadOnly = true; _allActivity.ScrollBars = ScrollBars.Both; _allActivity.WordWrap = false; _allActivity.BorderStyle = BorderStyle.None; _allActivity.Font = new Font("Cascadia Mono", 8.5f);
        activityPane.Controls.Add(_allActivity, 0, 1);
        activityPane.Controls.Add(new Label { Dock = DockStyle.Fill, Text = "Click a task in the right rail for its run / critique / validation receipts and operator actions.", ForeColor = Theme.Muted, Font = new Font("Segoe UI", 8.25f), TextAlign = ContentAlignment.MiddleLeft }, 0, 2);

        split.Panel1.Controls.Add(telemetryPane);
        split.Panel2.Controls.Add(activityPane);
        p.Controls.Add(split);
        TrackSplitter(split, () => _settings.ActivityTelemetryHeight = split.SplitterDistance);
        RestoreSplitterWhenShown(() => split.RestoreDistance(_settings.ActivityTelemetryHeight));
        return p;
    }

    TabPage BuildIntegrations()
    {
        var p = Page("Integrations"); var rows = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 7, ColumnCount = 1 }; rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 28)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 50)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 28)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 50)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 44)); rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 28)); rows.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        rows.Controls.Add(Section("RESIDENT STREAMABLE MCP"), 0, 0); _endpoint.Dock = DockStyle.Fill; _endpoint.ReadOnly = true; _endpoint.Font = new Font("Cascadia Mono", 9); rows.Controls.Add(_endpoint, 0, 1);
        rows.Controls.Add(Section("STDIO BRIDGE"), 0, 2); _stdio.Dock = DockStyle.Fill; _stdio.ReadOnly = true; _stdio.Font = new Font("Cascadia Mono", 9); rows.Controls.Add(_stdio, 0, 3);
        var bar = new FlowLayoutPanel { Dock = DockStyle.Fill }; var copyEndpoint = Btn("Copy endpoint"); copyEndpoint.Click += (_, _) => Copy(_endpoint.Text); var copyToken = Btn("Copy token"); copyToken.Click += (_, _) => Copy(_mcp.Details()?.token ?? ""); var register = Btn("Register selected"); register.Click += (_, _) => RegisterSelected(); var remove = Btn("Remove selected"); remove.Click += (_, _) => UnregisterSelected(); bar.Controls.AddRange(new Control[] { copyEndpoint, copyToken, register, remove }); rows.Controls.Add(bar, 0, 4);
        rows.Controls.Add(Section("CLIENT INTEGRATIONS"), 0, 5); _integrations.Dock = DockStyle.Fill; _integrations.ReadOnly = true; _integrations.AllowUserToAddRows = false; _integrations.RowHeadersVisible = false; _integrations.SelectionMode = DataGridViewSelectionMode.FullRowSelect; _integrations.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill; _integrations.Columns.Add("client", "Client"); _integrations.Columns.Add("installed", "Installed"); _integrations.Columns.Add("registered", "Registered"); _integrations.Columns.Add("verified", "Path verified"); _integrations.Columns.Add("note", "Note"); rows.Controls.Add(_integrations, 0, 6);
        p.Controls.Add(rows); return p;
    }

    TabPage BuildMcpImport()
    {
        var p = Page("MCP Import"); var rows = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1 };
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        rows.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var bar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
        _btnMcpDiscover.Click += async (_, _) => await DiscoverMcpServersAsync();
        var refresh = Btn("Refresh", 85); refresh.Click += (_, _) => LoadMcpImportFromCache();
        bar.Controls.AddRange(new Control[] { _btnMcpDiscover, refresh });
        rows.Controls.Add(bar, 0, 0);

        rows.Controls.Add(Section("MCP SERVERS DISCOVERED IN OTHER HARNESSES"), 0, 1);

        _mcpImport.Dock = DockStyle.Fill; _mcpImport.AllowUserToAddRows = false; _mcpImport.RowHeadersVisible = false; _mcpImport.SelectionMode = DataGridViewSelectionMode.FullRowSelect; _mcpImport.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
        _mcpImport.Columns.Add("name", "Server name");
        _mcpImport.Columns.Add("harness", "Harness");
        _mcpImport.Columns.Add("verified", "Path verified");
        _mcpImport.Columns.Add("probe", "Probe result");
        _mcpImport.Columns.Add(new DataGridViewCheckBoxColumn { Name = "imported", HeaderText = "Imported", Width = 70, AutoSizeMode = DataGridViewAutoSizeColumnMode.None });
        foreach (DataGridViewColumn c in _mcpImport.Columns) if (c.Name != "imported") c.ReadOnly = true;
        _mcpImport.CellValueChanged += (s, e) => {
            if (e.RowIndex >= 0 && _mcpImport.Columns[e.ColumnIndex].Name == "imported") ToggleMcpImport(e.RowIndex, (bool)_mcpImport.Rows[e.RowIndex].Cells["imported"].Value);
        };
        _mcpImport.CurrentCellDirtyStateChanged += (s, e) => {
            if (_mcpImport.IsCurrentCellDirty && _mcpImport.Columns[_mcpImport.CurrentCell.ColumnIndex].Name == "imported") _mcpImport.CommitEdit(DataGridViewDataErrorContexts.Commit);
        };
        rows.Controls.Add(_mcpImport, 0, 2);

        p.Controls.Add(rows);
        p.HandleCreated += (_, _) => LoadMcpImportFromCache();
        return p;
    }

    TabPage BuildProviders()
    {
        var p = Page("Providers"); var rows = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 4, ColumnCount = 1 };
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        rows.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        rows.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var bar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
        var test = Btn("Test Provider", 105); test.Click += (_, _) => TestSelectedProvider();
        var open = Btn("Open config", 100); open.Click += (_, _) => OpenConfig();
        var refresh = Btn("Refresh", 85); refresh.Click += async (_, _) => await RefreshAllAsync();
        bar.Controls.AddRange(new Control[] { test, open, refresh });

        var roleBar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
        var roleLbl = new Label { Text = "Routing role:", AutoSize = true, Margin = new Padding(4, 10, 4, 0), ForeColor = Theme.Muted };
        var setDefault = Btn("Set Default", 95); setDefault.Click += (_, _) => SetProviderRole("defaultProvider");
        var setCritic = Btn("Set Critic", 90); setCritic.Click += (_, _) => SetProviderRole("criticProvider");
        var setValidator = Btn("Set Validator", 105); setValidator.Click += (_, _) => SetProviderRole("validatorProvider");
        var sizeLbl = new Label { Text = "Task size:", AutoSize = true, Margin = new Padding(12, 10, 4, 0), ForeColor = Theme.Muted };
        var setTiny = Btn("Set Tiny", 80); setTiny.Click += (_, _) => SetProviderRole("tiny");
        var setSmall = Btn("Set Small", 85); setSmall.Click += (_, _) => SetProviderRole("small");
        var setMed = Btn("Set Medium", 95); setMed.Click += (_, _) => SetProviderRole("medium");
        var setLrg = Btn("Set Large", 85); setLrg.Click += (_, _) => SetProviderRole("large");
        var clearRoles = Btn("Clear Roles", 95); clearRoles.Click += (_, _) => ClearProviderRoles();
        roleBar.Controls.AddRange(new Control[] { roleLbl, setDefault, setCritic, setValidator, sizeLbl, setTiny, setSmall, setMed, setLrg, clearRoles });

        rows.Controls.Add(bar, 0, 0);
        rows.Controls.Add(roleBar, 0, 1);
        rows.Controls.Add(Section("WORKER BACKEND STATUS, PRIORITY, AND ROUTING"), 0, 2);

        _providers.Dock = DockStyle.Fill; _providers.ReadOnly = false; _providers.AllowUserToAddRows = false; _providers.RowHeadersVisible = false; _providers.SelectionMode = DataGridViewSelectionMode.FullRowSelect; _providers.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
        _providers.Columns.Add(new DataGridViewCheckBoxColumn { Name = "enabled", HeaderText = "Enabled", Width = 60, AutoSizeMode = DataGridViewAutoSizeColumnMode.None });
        _providers.Columns.Add("name", "Provider");
        _providers.Columns.Add("backend", "Backend");
        _providers.Columns.Add("target", "Target");
        _providers.Columns.Add("roles", "Routing / roles");
        foreach(DataGridViewColumn c in _providers.Columns) if (c.Name != "enabled") c.ReadOnly = true;
        _providers.AllowDrop = true;
        Rectangle dragBox = Rectangle.Empty; int dragIndex = -1;
        _providers.MouseDown += (s, e) => {
            var hit = _providers.HitTest(e.X, e.Y);
            dragIndex = hit.RowIndex;
            if (dragIndex >= 0 && hit.ColumnIndex != 0) {
                var dragSize = SystemInformation.DragSize;
                dragBox = new Rectangle(new Point(e.X - (dragSize.Width / 2), e.Y - (dragSize.Height / 2)), dragSize);
            } else dragBox = Rectangle.Empty;
        };
        _providers.MouseMove += (s, e) => {
            if ((e.Button & MouseButtons.Left) == MouseButtons.Left) {
                if (dragBox != Rectangle.Empty && !dragBox.Contains(e.X, e.Y)) {
                    _providers.DoDragDrop(_providers.Rows[dragIndex], DragDropEffects.Move);
                }
            }
        };
        _providers.DragEnter += (s, e) => e.Effect = DragDropEffects.Move;
        _providers.DragDrop += (s, e) => {
            var cp = _providers.PointToClient(new Point(e.X, e.Y));
            var hit = _providers.HitTest(cp.X, cp.Y);
            if (hit.RowIndex >= 0 && dragIndex >= 0 && hit.RowIndex != dragIndex) {
                ReorderProviderConfig(dragIndex, hit.RowIndex);
            }
        };
        _providers.CellValueChanged += (s, e) => {
            if (e.RowIndex >= 0 && e.ColumnIndex == 0) {
                ToggleProviderConfig(e.RowIndex, (bool)_providers.Rows[e.RowIndex].Cells[0].Value);
            }
        };
        _providers.CurrentCellDirtyStateChanged += (s, e) => {
            if (_providers.IsCurrentCellDirty && _providers.CurrentCell.ColumnIndex == 0) {
                _providers.CommitEdit(DataGridViewDataErrorContexts.Commit);
            }
        };

        var menu = new ContextMenuStrip();
        menu.Items.Add("Set as Default Provider", null, (_, _) => SetProviderRole("defaultProvider"));
        menu.Items.Add("Set as Critic Provider", null, (_, _) => SetProviderRole("criticProvider"));
        menu.Items.Add("Set as Validator Provider", null, (_, _) => SetProviderRole("validatorProvider"));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Set for Tiny Tasks", null, (_, _) => SetProviderRole("tiny"));
        menu.Items.Add("Set for Small Tasks", null, (_, _) => SetProviderRole("small"));
        menu.Items.Add("Set for Medium Tasks", null, (_, _) => SetProviderRole("medium"));
        menu.Items.Add("Set for Large Tasks", null, (_, _) => SetProviderRole("large"));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Clear Roles & Sizes for Provider", null, (_, _) => ClearProviderRoles());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Test Provider", null, (_, _) => TestSelectedProvider());

        _providers.ContextMenuStrip = menu;
        _providers.CellMouseDown += (s, e) =>
        {
            if (e.Button == MouseButtons.Right && e.RowIndex >= 0)
            {
                _providers.ClearSelection();
                _providers.Rows[e.RowIndex].Selected = true;
            }
        };

        rows.Controls.Add(_providers, 0, 3);
        p.Controls.Add(rows);
        return p;
    }

    ProviderStatus? SelectedProvider => _providers.SelectedRows.Count > 0 ? _providers.SelectedRows[0].Tag as ProviderStatus : null;

    void ToggleProviderConfig(int rowIndex, bool enabled)
    {
        var path = _settings.ActiveProjectPath;
        if (string.IsNullOrWhiteSpace(path)) return;
        var cfg = System.IO.Path.Combine(path, ".statefulclanker", "config.json");
        if (!File.Exists(cfg)) return;
        try {
            var node = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(cfg)) as System.Text.Json.Nodes.JsonObject;
            if (node == null || !node.TryGetPropertyValue("providers", out var providersNode) || providersNode is not System.Text.Json.Nodes.JsonObject providers) return;
            var providerName = _providers.Rows[rowIndex].Cells["name"].Value?.ToString();
            if (providerName != null && providers.TryGetPropertyValue(providerName, out var providerNode) && providerNode is System.Text.Json.Nodes.JsonObject pObj) {
                pObj["disabled"] = !enabled;
                File.WriteAllText(cfg, node.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
                _ = RefreshAllAsync();
            }
        } catch { }
    }

    void ReorderProviderConfig(int fromIndex, int toIndex)
    {
        var path = _settings.ActiveProjectPath;
        if (string.IsNullOrWhiteSpace(path)) return;
        var cfg = System.IO.Path.Combine(path, ".statefulclanker", "config.json");
        if (!File.Exists(cfg)) return;
        try {
            var node = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(cfg)) as System.Text.Json.Nodes.JsonObject;
            if (node == null || !node.TryGetPropertyValue("providers", out var providersNode) || providersNode is not System.Text.Json.Nodes.JsonObject providers) return;
            var list = new System.Collections.Generic.List<string>();
            foreach (DataGridViewRow row in _providers.Rows) list.Add(row.Cells["name"].Value.ToString()!);
            var item = list[fromIndex];
            list.RemoveAt(fromIndex);
            list.Insert(toIndex, item);
            for (int i = 0; i < list.Count; i++) {
                if (providers.TryGetPropertyValue(list[i], out var providerNode) && providerNode is System.Text.Json.Nodes.JsonObject pObj) {
                    pObj["priority"] = (i + 1) * 10;
                }
            }
            File.WriteAllText(cfg, node.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
            _ = RefreshAllAsync();
        } catch { }
    }
    void SetProviderRole(string roleOrSize)
    {
        var p = SelectedProvider;
        var path = _settings.ActiveProjectPath;
        if (p is null || string.IsNullOrWhiteSpace(path)) return;
        var cfgPath = System.IO.Path.Combine(path, ".statefulclanker", "config.json");
        if (!File.Exists(cfgPath)) return;
        try
        {
            var node = JsonNode.Parse(File.ReadAllText(cfgPath));
            if (node is null) return;

            if (roleOrSize is "tiny" or "small" or "medium" or "large")
            {
                if (node["providerBySize"] is not JsonObject bySize)
                {
                    bySize = new JsonObject();
                    node["providerBySize"] = bySize;
                }
                bySize[roleOrSize] = p.Name;
            }
            else
            {
                node[roleOrSize] = p.Name;
            }

            File.WriteAllText(cfgPath, node.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            _ = RefreshAllAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Failed to update config: " + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    void ClearProviderRoles()
    {
        var p = SelectedProvider;
        var path = _settings.ActiveProjectPath;
        if (p is null || string.IsNullOrWhiteSpace(path)) return;
        var cfgPath = System.IO.Path.Combine(path, ".statefulclanker", "config.json");
        if (!File.Exists(cfgPath)) return;
        try
        {
            var node = JsonNode.Parse(File.ReadAllText(cfgPath));
            if (node is null) return;

            if (node["defaultProvider"]?.ToString() == p.Name) node.AsObject().Remove("defaultProvider");
            if (node["criticProvider"]?.ToString() == p.Name) node.AsObject().Remove("criticProvider");
            if (node["validatorProvider"]?.ToString() == p.Name) node.AsObject().Remove("validatorProvider");

            if (node["providerBySize"] is JsonObject bySize)
            {
                foreach (var size in new[] { "tiny", "small", "medium", "large" })
                {
                    if (bySize[size]?.ToString() == p.Name)
                    {
                        bySize.Remove(size);
                    }
                }
            }

            File.WriteAllText(cfgPath, node.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            _ = RefreshAllAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Failed to clear provider roles: " + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    void TestSelectedProvider()
    {
        var p = SelectedProvider;
        var path = _settings.ActiveProjectPath;
        if (p is null || string.IsNullOrWhiteSpace(path)) return;
        var harness = System.IO.Path.Combine(_root, "mcp", "StatefulClanker.McpCore.ps1");
        var command = $". '{harness.Replace("'", "''")}'; Test-McpProvider '{path.Replace("'", "''")}' @{{ name='{p.Name.Replace("'", "''")}' }} | ConvertTo-Json -Depth 5 -Compress";
        var r = Runtime.RunPowerShell(_root, "-Command", command);
        if (!string.IsNullOrWhiteSpace(r.stdout))
        {
            try
            {
                using var doc = JsonDocument.Parse(r.stdout);
                var elem = doc.RootElement;
                var usable = elem.TryGetProperty("usable", out var uv) && uv.GetBoolean();
                var diag = elem.TryGetProperty("diagnosis", out var dv) ? dv.GetString() : "";
                var icon = usable ? MessageBoxIcon.Information : MessageBoxIcon.Warning;
                MessageBox.Show(this, $"Provider: {p.Name}\nUsable: {usable}\n\nDiagnosis:\n{diag}", "Provider Test Result", MessageBoxButtons.OK, icon);
                return;
            }
            catch { }
        }
        MessageBox.Show(this, (r.stdout + "\n" + r.stderr).Trim(), "Provider Test Output", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    void RestoreProjects()
    {
        _projects.Nodes.Clear(); TreeNode? active = null;
        foreach (var entry in _settings.Projects.OrderBy(x => x.Name, StringComparer.OrdinalIgnoreCase))
        {
            var node = new TreeNode(Directory.Exists(entry.Path) ? entry.Name : entry.Name + "  [missing]") { Tag = entry, ToolTipText = entry.Path }; _projects.Nodes.Add(node); if (SamePath(entry.Path, _settings.ActiveProjectPath)) active = node;
        }
        if (active is not null && Directory.Exists(((ProjectEntry)active.Tag!).Path)) { _projects.SelectedNode = active; active.EnsureVisible(); }
        else SetActiveProject(null);
    }

    static bool SamePath(string a, string? b)
    {
        if (b is null) return false; try { return string.Equals(System.IO.Path.GetFullPath(a).TrimEnd('\\'), System.IO.Path.GetFullPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase); } catch { return false; }
    }

    ProjectEntry? SelectedProject => _projects.SelectedNode?.Tag as ProjectEntry;
    void SelectProject() { var p = SelectedProject; SetActiveProject(p is not null && Directory.Exists(p.Path) ? p.Path : null); }

    void SetActiveProject(string? path)
    {
        _settings.ActiveProjectPath = path;
        AppStore.Save(_settings);
        AppStore.SetActiveProject(path);
        _header.Text = path is null ? "No active project" : (SelectedProject?.Name ?? new DirectoryInfo(path).Name);
        Text = path is null ? "StatefulClanker" : $"StatefulClanker — {_header.Text}";
        _terminal.SetProject(path);
        _ = RefreshAllAsync();
    }

    void AddProject()
    {
        using var picker = new FolderBrowserDialog { Description = "Select the project StatefulClanker should manage", UseDescriptionForTitle = true }; if (picker.ShowDialog(this) != DialogResult.OK) return; var path = System.IO.Path.GetFullPath(picker.SelectedPath);
        if (!File.Exists(System.IO.Path.Combine(path, ".statefulclanker", "state.json")))
        {
            if (MessageBox.Show(this, "Initialize StatefulClanker state in this folder?", "Initialize project", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            var script = System.IO.Path.Combine(_root, "StatefulClanker.ps1"); var r = Runtime.RunPowerShell(path, "-File", script, "init"); if (r.code != 0) { MessageBox.Show(this, (r.stdout + Environment.NewLine + r.stderr).Trim(), "Initialization failed", MessageBoxButtons.OK, MessageBoxIcon.Error); return; }
        }
        if (_settings.Projects.All(x => !SamePath(x.Path, path))) _settings.Projects.Add(new ProjectEntry { Name = new DirectoryInfo(path).Name, Path = path }); AppStore.Save(_settings); RestoreProjects();
        foreach (TreeNode node in _projects.Nodes) if (node.Tag is ProjectEntry e && SamePath(e.Path, path)) { _projects.SelectedNode = node; break; }
    }

    void RemoveProject()
    {
        var p = SelectedProject; if (p is null) return; if (MessageBox.Show(this, $"Remove '{p.Name}' from the local list? No project files are deleted.", "Remove project", MessageBoxButtons.YesNo) != DialogResult.Yes) return;
        var active = SamePath(p.Path, _settings.ActiveProjectPath); _settings.Projects.RemoveAll(x => SamePath(x.Path, p.Path)); if (active) _settings.ActiveProjectPath = null; AppStore.Save(_settings); RestoreProjects();
    }

    void OpenExplorer() { var path = _settings.ActiveProjectPath; if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) return; try { Process.Start(new ProcessStartInfo("explorer.exe") { UseShellExecute = true, ArgumentList = { path } }); } catch { } }

    async Task RefreshAllAsync()
    {
        if (Interlocked.Exchange(ref _refreshing, 1) != 0) return;
        var projectPath = _settings.ActiveProjectPath;
        try
        {
            var snapshot = await Task.Run(() => BuildSnapshot(projectPath));
            if (IsDisposed || Disposing) return;
            ApplySnapshot(snapshot);
        }
        catch { }
        finally { Interlocked.Exchange(ref _refreshing, 0); }
    }

    UiSnapshot BuildSnapshot(string? projectPath)
    {
        _mcp.EnsureStarted(); _autofill.EnsureStarted(projectPath);
        var snapshot = new UiSnapshot { Mcp = _mcp.Details(), HasProject = !string.IsNullOrWhiteSpace(projectPath) && Directory.Exists(projectPath), NextEndpoint = RoutingQueueInspector.Snapshot() };
        if (snapshot.HasProject)
        {
            snapshot.Project = Inspector.Project(projectPath!);
            snapshot.Autofill = Inspector.Autofill(projectPath!);
            snapshot.Providers = ReadProviderStatus(projectPath!);
        }
        snapshot.Integrations = ReadIntegrationStatus();
        return snapshot;
    }

    void ApplySnapshot(UiSnapshot snapshot)
    {
        var d = snapshot.Mcp;
        _mcpState.Text = d is null ? "MCP  STOPPED" : "MCP  RUNNING";
        _mcpState.ForeColor = d is null ? Theme.Warn : Theme.Good; _mcpState.BackColor = Theme.Surface;
        _endpoint.Text = d?.url ?? $"http://127.0.0.1:{_settings.HttpPort}/mcp (starting...)";
        var stdioScript = System.IO.Path.Combine(_root, "mcp", "StatefulClanker.Mcp.ps1");
        _stdio.Text = $"{Runtime.FindPowerShell()} -NoProfile -File \"{stdioScript}\"";
        if (snapshot.HasProject)
        {
            SetMetrics(snapshot.Project);
            SetAutofillUi(snapshot.Autofill, snapshot.Project, true);
            _allActivity.Text = snapshot.Project.Activity;
            _workerTelemetry.Text = snapshot.Project.Telemetry;
            _recentActivity.SetActivity(snapshot.Project.Activity);
            _overviewReadout.SetState(snapshot.Project, snapshot.Autofill, d is not null, true, snapshot.NextEndpoint);
            PopulateOverviewTargets();
        }
        else
        {
            SetMetrics(new());
            SetAutofillUi(snapshot.Autofill, new(), false);
            _allActivity.Text = "Select a project at left. StatefulClanker does not silently substitute a default project.";
            _workerTelemetry.Text = "Select a project to inspect worker telemetry.";
            _recentActivity.SetActivity("");
            _overviewReadout.SetState(new(), snapshot.Autofill, d is not null, false, snapshot.NextEndpoint);
            PopulateOverviewTargets();
        }
        ApiConnectionsUiBootstrap.RefreshProjectMarkers();
        _integrations.SuspendLayout();
        try
        {
            _integrations.Rows.Clear();
            foreach (var item in snapshot.Integrations) { var i = _integrations.Rows.Add(item.name, item.installed ? "yes" : "no", item.registered ? "yes" : "no", item.verified ? "yes" : "no", item.note); _integrations.Rows[i].Tag = item; }
        }
        finally { _integrations.ResumeLayout(); }
        _providers.SuspendLayout();
        try
        {
            _providers.Rows.Clear();
            foreach (var item in snapshot.Providers) {
                var i = _providers.Rows.Add(!item.Disabled, item.Name, item.Backend, item.Target, item.Roles);
                _providers.Rows[i].Tag = item;
                if (item.Disabled)
                {
                    _providers.Rows[i].DefaultCellStyle.ForeColor = Theme.Muted;
                }
            }
        }
        finally { _providers.ResumeLayout(); }
    }

    void PopulateOverviewTargets()
    {
        var targets = TargetPoolStore.LoadActive().entries.Values.OrderBy(x => x.connection, StringComparer.OrdinalIgnoreCase).ThenBy(x => x.model, StringComparer.OrdinalIgnoreCase).ToList();
        _overviewTargets.SuspendLayout();
        try
        {
            _overviewTargets.Rows.Clear();
            foreach (var target in targets)
            {
                var row = _overviewTargets.Rows.Add(target.enabled, target.connection, target.displayName == target.model ? target.model : $"{target.displayName} ({target.model})");
                _overviewTargets.Rows[row].Tag = target;
                if (!target.enabled) _overviewTargets.Rows[row].DefaultCellStyle.ForeColor = Theme.Muted;
            }
            _overviewTargetSummary.Text = targets.Count == 0 ? "ACTIVE PROJECT TARGETS — none selected" : $"ACTIVE PROJECT TARGETS — {targets.Count(x => x.enabled)} enabled of {targets.Count}";
        }
        finally { _overviewTargets.ResumeLayout(); }
    }

    void ToggleOverviewTarget(TargetPoolEntry target, bool enabled)
    {
        var pool = TargetPoolStore.LoadActive();
        var id = TargetPoolStore.Id(target.connection, target.model);
        if (!pool.entries.TryGetValue(id, out var current)) return;
        current.enabled = enabled; current.updatedAt = DateTimeOffset.UtcNow.ToString("O"); pool.entries[id] = current;
        try { TargetPoolStore.SaveActive(pool); PopulateOverviewTargets(); ApiConnectionsUiBootstrap.RefreshProjectMarkers(); }
        catch (Exception ex) { MessageBox.Show(this, "Failed to update target: " + ex.Message, "Target update failed", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    void SetAutofillUi(AutofillSnapshot a, ProjectMetrics m, bool hasProject)
    {
        _updatingAutofillUi = true;
        try
        {
            if (!hasProject)
            {
                _btnAutofillToggle.Enabled = false;
                _btnAutofillPause.Enabled = false;
                _btnAutofillTrigger.Enabled = false;
                _numMaxConcurrent.Enabled = false;
                _autofillStatus.Text = "No project selected";
                _autofillStatus.ForeColor = Theme.Muted;
                return;
            }

            _btnAutofillToggle.Enabled = true;
            _btnAutofillToggle.Text = a.Enabled && a.Running ? "Stop Autofill" : "Start Autofill";
            _btnAutofillPause.Enabled = a.Running;
            _btnAutofillPause.Text = a.Paused ? "Resume" : "Pause";
            _btnAutofillTrigger.Enabled = a.Running && !a.Paused;
            _numMaxConcurrent.Enabled = true;
            if (_numMaxConcurrent.Value != a.MaxConcurrent && a.MaxConcurrent >= 1 && a.MaxConcurrent <= 16)
            {
                _numMaxConcurrent.Value = a.MaxConcurrent;
            }

            var stateStr = a.Paused ? "PAUSED" : (a.Running ? "RUNNING" : "STOPPED");
            var activeCount = Math.Max(a.ActiveWorkers, m.ActiveAgents);
            var freeSlots = Math.Max(0, a.MaxConcurrent - activeCount);
            var activePart = activeCount == 0
                ? $"Slots: 0/{a.MaxConcurrent} active ({freeSlots} free)"
                : (string.IsNullOrEmpty(m.ActiveTypesSummary)
                    ? $"Slots: {activeCount}/{a.MaxConcurrent} active ({freeSlots} free)"
                    : $"Slots: {activeCount}/{a.MaxConcurrent} active [{m.ActiveTypesSummary}] ({freeSlots} free)");

            var queuePart = a.RetryCount > 0
                ? $"Queue: {a.ReadyCount} ready, {a.RetryCount} retry"
                : $"Queue: {a.ReadyCount} ready";

            var statusText = $"Status: {stateStr}  |  {activePart}  |  {queuePart}";
            if (!string.IsNullOrWhiteSpace(a.BlockReason)) statusText += $"  [{a.BlockReason}]";
            _autofillStatus.Text = statusText;
            _autofillStatus.ForeColor = a.Paused ? Theme.Warn : (a.Running ? Theme.Good : Theme.Muted);
        }
        finally
        {
            _updatingAutofillUi = false;
        }
    }

    void ToggleAutofill()
    {
        var path = _settings.ActiveProjectPath;
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) return;
        var cfgPath = System.IO.Path.Combine(path, ".statefulclanker", "config.json");
        try
        {
            var enabled = AutofillHost.Enabled(path);
            var newEnabled = !enabled;
            if (File.Exists(cfgPath))
            {
                var node = JsonNode.Parse(File.ReadAllText(cfgPath));
                if (node is not null)
                {
                    node["autofillEnabled"] = newEnabled;
                    File.WriteAllText(cfgPath, node.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
                }
            }
            if (newEnabled)
            {
                var stopFile = AutofillHost.StopPath(path);
                if (File.Exists(stopFile)) try { File.Delete(stopFile); } catch { }
                _autofill.EnsureStarted(path);
            }
            else
            {
                AutofillHost.RequestStop(path);
            }
            _ = RefreshAllAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Failed to toggle autofill: " + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    void ToggleAutofillPause()
    {
        var path = _settings.ActiveProjectPath;
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) return;
        try
        {
            var pauseFile = AutofillHost.PausePath(path);
            if (File.Exists(pauseFile))
            {
                AutofillHost.RequestResume(path);
            }
            else
            {
                AutofillHost.RequestPause(path);
            }
            _ = RefreshAllAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Failed to change pause state: " + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    void TriggerAutofill()
    {
        var path = _settings.ActiveProjectPath;
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) return;
        try
        {
            AutofillHost.RequestTrigger(path);
            _ = RefreshAllAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Failed to trigger autofill: " + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    void OnMaxConcurrentChanged()
    {
        if (_updatingAutofillUi) return;
        var path = _settings.ActiveProjectPath;
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) return;
        var cfgPath = System.IO.Path.Combine(path, ".statefulclanker", "config.json");
        try
        {
            int val = (int)_numMaxConcurrent.Value;
            if (File.Exists(cfgPath))
            {
                var node = JsonNode.Parse(File.ReadAllText(cfgPath));
                if (node is not null)
                {
                    node["maxConcurrent"] = val;
                    File.WriteAllText(cfgPath, node.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
                }
            }
            AutofillHost.RequestTrigger(path);
            _ = RefreshAllAsync();
        }
        catch { }
    }

    static string TokenText(long value) => value >= 1_000_000 ? $"{value / 1_000_000d:0.00}M" : value >= 1_000 ? $"{value / 1_000d:0.0}K" : value.ToString("N0");
    static string UsageText(ProjectMetrics m)
    {
        var sb = new StringBuilder();
        sb.Append("TOTAL ").Append(TokenText(m.TotalTokens)).Append("   INPUT ").Append(TokenText(m.PromptTokens)).Append("   OUTPUT ").Append(TokenText(m.CompletionTokens));
        if (m.UsageReports == 0) sb.Append("   [provider token telemetry unavailable]");
        foreach (var row in m.ModelTokens.OrderByDescending(x => x.Value).ThenBy(x => x.Key, StringComparer.OrdinalIgnoreCase))
            sb.AppendLine().Append(row.Key).Append("   ").Append(row.Value > 0 ? TokenText(row.Value) + " tokens" : "usage not reported");
        return m.ModelTokens.Count == 0 ? sb.AppendLine().Append("No model telemetry recorded yet.").ToString() : sb.ToString();
    }

    void SetMetrics(ProjectMetrics m)
    {
        var agentText = m.ActiveAgents == 0
            ? "ACTIVE AGENTS: 0"
            : (string.IsNullOrEmpty(m.ActiveTypesSummary) ? $"ACTIVE AGENTS: {m.ActiveAgents}" : $"ACTIVE AGENTS: {m.ActiveAgents} ({m.ActiveTypesSummary})");
        _metrics[0].Text = agentText;
        _metrics[1].Text = $"WORKER SESSIONS: {m.Sessions}";
        _metrics[2].Text = $"COMMITS: {m.Commits}";
        _metrics[3].Text = $"VALIDATOR RUNS: {m.Validators}";
        _metrics[4].Text = $"TASKS COMPLETE: {m.CompleteTasks}/{m.TotalTasks}";
        _intent.Text = $"INTENT REVISION  {m.IntentRevision}";
        _goal.Text = string.IsNullOrWhiteSpace(m.Goal) ? "No project goal recorded." : m.Goal;
        _usage.Text = UsageText(m);
        _blinkenRack.SyncAgents(m.ActiveAgentList);
        _taskBoard.SetTasks(m.TaskBoard);
    }

    List<IntegrationStatus> ReadIntegrationStatus()
    {
        var module = System.IO.Path.Combine(_root, "lib", "StatefulClanker.Integrations.ps1"); var escaped = module.Replace("'", "''");
        var command = $". '{escaped}'; @(Get-SCIntegrationTargets | ForEach-Object {{ [pscustomobject]@{{ id=$_.id; name=$_.name; installed=[bool](Test-SCIntegrationInstalled $_); registered=[bool](Test-SCIntegrationRegistered $_); verified=[bool]$_.verified; note=$_.note }} }}) | ConvertTo-Json -Depth 6 -Compress";
        var r = Runtime.RunPowerShell(_root, "-Command", command); if (r.code != 0 || string.IsNullOrWhiteSpace(r.stdout)) return new();
        try { return JsonSerializer.Deserialize<List<IntegrationStatus>>(r.stdout, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new(); } catch { return new(); }
    }

    IntegrationStatus? SelectedIntegration => _integrations.SelectedRows.Count > 0 ? _integrations.SelectedRows[0].Tag as IntegrationStatus : null;

    void RegisterSelected()
    {
        var s = SelectedIntegration; if (s is null) return; if (!s.verified) { MessageBox.Show(this, "This integration's config path is not verified. Use its MCP settings and the stdio command shown above instead of allowing StatefulClanker to write a guessed path.", "Manual registration", MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
        InvokeIntegrationMutation(s.id, true);
    }

    void UnregisterSelected() { var s = SelectedIntegration; if (s is null || !s.verified) return; InvokeIntegrationMutation(s.id, false); }

    void InvokeIntegrationMutation(string id, bool register)
    {
        var module = System.IO.Path.Combine(_root, "lib", "StatefulClanker.Integrations.ps1").Replace("'", "''"); var safeId = id.Replace("'", "''");
        var action = register ? "Register-SCIntegration $t $null (Get-SCInstallRoot) | ConvertTo-Json -Depth 6 -Compress" : "Unregister-SCIntegration $t | ConvertTo-Json -Compress";
        var cmd = $". '{module}'; $t=@(Get-SCIntegrationTargets | Where-Object {{ $_.id -eq '{safeId}' }})[0]; if($null -eq $t){{throw 'Integration not found'}}; {action}";
        var r = Runtime.RunPowerShell(_root, "-Command", cmd); if (r.code != 0) MessageBox.Show(this, (r.stdout + Environment.NewLine + r.stderr).Trim(), "Integration update failed", MessageBoxButtons.OK, MessageBoxIcon.Error); _ = RefreshAllAsync();
    }

    List<McpServerStatus> ReadMcpDiscoveryCache()
    {
        var module = System.IO.Path.Combine(_root, "lib", "StatefulClanker.McpDiscovery.ps1"); var escaped = module.Replace("'", "''");
        var command = $". '{escaped}'; $c=Get-SCMcpDiscoveryCache; if($null -eq $c -or -not $c.PSObject.Properties['servers']){{'[]'}}else{{@($c.servers) | ConvertTo-Json -Depth 6 -Compress}}";
        var r = Runtime.RunPowerShell(_root, "-Command", command); if (r.code != 0 || string.IsNullOrWhiteSpace(r.stdout)) return new();
        try { return JsonSerializer.Deserialize<List<McpServerStatus>>(r.stdout, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new(); } catch { return new(); }
    }

    List<McpServerStatus> RunMcpDiscoveryScan()
    {
        var module = System.IO.Path.Combine(_root, "lib", "StatefulClanker.McpDiscovery.ps1"); var escaped = module.Replace("'", "''");
        var command = $". '{escaped}'; @(Invoke-SCMcpDiscoveryScan) | ConvertTo-Json -Depth 6 -Compress";
        var r = Runtime.RunPowerShell(_root, "-Command", command); if (r.code != 0 || string.IsNullOrWhiteSpace(r.stdout)) return new();
        try { return JsonSerializer.Deserialize<List<McpServerStatus>>(r.stdout, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new(); } catch { return new(); }
    }

    void PopulateMcpImportGrid(List<McpServerStatus> servers)
    {
        _mcpImport.SuspendLayout();
        try
        {
            _mcpImport.Rows.Clear();
            foreach (var item in servers)
            {
                var probe = item.probeOk ? $"ok ({item.toolCount} tools)" : (item.probeError ?? "failed");
                var i = _mcpImport.Rows.Add(item.name, item.harness, item.verified ? "yes" : "no", probe, item.imported);
                _mcpImport.Rows[i].Tag = item;
            }
        }
        finally { _mcpImport.ResumeLayout(); }
    }

    void LoadMcpImportFromCache() => PopulateMcpImportGrid(ReadMcpDiscoveryCache());

    async Task DiscoverMcpServersAsync()
    {
        if (Interlocked.Exchange(ref _mcpDiscoveryRunning, 1) != 0) return;
        _btnMcpDiscover.Enabled = false; _btnMcpDiscover.Text = "Discovering...";
        try
        {
            var servers = await Task.Run(() => RunMcpDiscoveryScan());
            if (IsDisposed || Disposing) return;
            PopulateMcpImportGrid(servers);
        }
        catch (Exception ex) { MessageBox.Show(this, ex.Message, "MCP discovery failed", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        finally { _btnMcpDiscover.Enabled = true; _btnMcpDiscover.Text = "Discover"; Interlocked.Exchange(ref _mcpDiscoveryRunning, 0); }
    }

    void ToggleMcpImport(int rowIndex, bool import)
    {
        var tag = _mcpImport.Rows[rowIndex].Tag as McpServerStatus; if (tag is null) return;
        var module = System.IO.Path.Combine(_root, "lib", "StatefulClanker.McpDiscovery.ps1").Replace("'", "''"); var safeName = tag.name.Replace("'", "''");
        var action = import ? $"Import-SCDiscoveredMcpServer '{safeName}' | ConvertTo-Json -Depth 6 -Compress" : $"Remove-SCImportedMcpServer '{safeName}' | ConvertTo-Json -Depth 6 -Compress";
        var cmd = $". '{module}'; {action}";
        var r = Runtime.RunPowerShell(_root, "-Command", cmd);
        if (r.code != 0) MessageBox.Show(this, (r.stdout + Environment.NewLine + r.stderr).Trim(), "MCP import update failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
        LoadMcpImportFromCache();
    }

    List<ProviderStatus> ReadProviderStatus(string path)
    {
        var result = new List<ProviderStatus>(); var cfg = System.IO.Path.Combine(path, ".statefulclanker", "config.json"); if (!File.Exists(cfg)) return result;
        try
        {
            using var d = JsonDocument.Parse(File.ReadAllText(cfg)); var root = d.RootElement; var def = root.TryGetProperty("defaultProvider", out var dv) ? dv.GetString() : null; var critic = root.TryGetProperty("criticProvider", out var cv) ? cv.GetString() : null; var validator = root.TryGetProperty("validatorProvider", out var vv) ? vv.GetString() : null; var routes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (root.TryGetProperty("providerBySize", out var map) && map.ValueKind == JsonValueKind.Object) foreach (var x in map.EnumerateObject()) if (x.Value.ValueKind == JsonValueKind.String) routes[x.Name] = x.Value.GetString() ?? "";
            if (!root.TryGetProperty("providers", out var providers) || providers.ValueKind != JsonValueKind.Object) return result;
            int defaultPri = 1;
            foreach (var p in providers.EnumerateObject())
            {
                var type = p.Value.TryGetProperty("type", out var tv) && tv.ValueKind == JsonValueKind.String ? tv.GetString() ?? "cli" : "cli";
                var cmd = p.Value.TryGetProperty("command", out var c) ? c.GetString() ?? "" : "";
                var connection = p.Value.TryGetProperty("connection", out var cn) ? cn.GetString() ?? "" : "";
                var target = type.Equals("api", StringComparison.OrdinalIgnoreCase) ? connection : cmd;
                var disabled = p.Value.TryGetProperty("disabled", out var disV) && disV.ValueKind == JsonValueKind.True;
                var pri = p.Value.TryGetProperty("priority", out var pv) && pv.TryGetInt32(out var parsedPri) ? parsedPri : (p.Name == def ? 0 : defaultPri * 10);
                defaultPri++;
                var status = disabled ? "disabled" : (type.Equals("api", StringComparison.OrdinalIgnoreCase) ? (string.IsNullOrWhiteSpace(connection) ? "missing" : "api") : (Runtime.CommandExists(cmd) ? "cli" : "missing"));
                var tags = new List<string>();
                if (p.Name == def) tags.Add("default");
                if (p.Name == critic) tags.Add("critic");
                if (p.Name == validator) tags.Add("validator");
                foreach (var route in routes.Where(x => x.Value == p.Name)) tags.Add(route.Key);
                result.Add(new ProviderStatus { Name = p.Name, Backend = status, Target = target, Roles = string.Join(", ", tags), Disabled = disabled, Priority = pri });
            }
            result = result.OrderBy(x => x.Priority).ThenBy(x => x.Name, StringComparer.OrdinalIgnoreCase).ToList();
        }
        catch { }
        return result;
    }

    void OpenConfig() { var path = _settings.ActiveProjectPath; if (string.IsNullOrWhiteSpace(path)) return; var cfg = System.IO.Path.Combine(path, ".statefulclanker", "config.json"); if (File.Exists(cfg)) try { Process.Start(new ProcessStartInfo("notepad.exe") { UseShellExecute = true, ArgumentList = { cfg } }); } catch { } }
    static void Copy(string text) { if (!string.IsNullOrWhiteSpace(text)) Clipboard.SetText(text); }
    void ShowFromTray() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    void HandleFormClosing(object? sender, FormClosingEventArgs e)
    {
        _layoutSaveTimer.Stop();
        AppStore.Save(_settings);
        if (!_reallyExit) { e.Cancel = true; Hide(); return; }
        _timer.Stop();
        _terminal.StopSession();
        _autofill.Dispose();
        _mcp.Dispose();
        _notify.Visible = false;
        _notify.Dispose();
    }

    void ShowTaskDetails(TaskBoardEntry task)
    {
        var path = _settings.ActiveProjectPath;
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) return;
        var providers = ReadProviderStatus(path).Where(p => !p.Disabled).Select(p => p.Name).ToList();
        using var dlg = new TaskDetailDialog(this, _root, path, task, providers, () => _ = RefreshAllAsync());
        dlg.ShowDialog(this);
    }

    void RetryTask(TaskBoardEntry task, string? provider = null)
    {
        var path = _settings.ActiveProjectPath;
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) return;
        var harness = System.IO.Path.Combine(_root, "StatefulClanker.ps1");
        Task.Run(() =>
        {
            if (!string.IsNullOrWhiteSpace(provider))
            {
                Runtime.RunPowerShell(path, "-File", harness, "task", "set", "-TaskId", task.Id, "-Provider", provider);
            }
            var r = Runtime.RunPowerShell(path, "-File", harness, "task", "retry", "-TaskId", task.Id);
            if (r.code != 0)
            {
                BeginInvoke(() => MessageBox.Show(this, (string.IsNullOrWhiteSpace(r.stderr) ? r.stdout : r.stderr).Trim(), "Task Retry Failed", MessageBoxButtons.OK, MessageBoxIcon.Error));
            }
            _ = RefreshAllAsync();
        });
    }

    void OverrideCompleteTask(TaskBoardEntry task)
    {
        var path = _settings.ActiveProjectPath;
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) return;
        if (MessageBox.Show(this, $"Override validation and manually mark task '{task.Id}' as COMPLETE?\n\nThis records human authority and immediately unblocks dependent downstream tasks.", "Manual Completion Override", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
            return;

        var harness = System.IO.Path.Combine(_root, "StatefulClanker.ps1");
        Task.Run(() =>
        {
            var r = Runtime.RunPowerShell(path, "-File", harness, "complete", "-TaskId", task.Id);
            if (r.code != 0)
            {
                BeginInvoke(() => MessageBox.Show(this, (string.IsNullOrWhiteSpace(r.stderr) ? r.stdout : r.stderr).Trim(), "Task Complete Failed", MessageBoxButtons.OK, MessageBoxIcon.Error));
            }
            _ = RefreshAllAsync();
        });
    }

    void BlockTask(TaskBoardEntry task)
    {
        var path = _settings.ActiveProjectPath;
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) return;
        var reason = PromptDialog.Prompt(this, "Block Task", $"Enter reason for blocking task '{task.Id}':", task.BlockReason ?? "Blocked by operator");
        if (string.IsNullOrWhiteSpace(reason)) return;

        var harness = System.IO.Path.Combine(_root, "StatefulClanker.ps1");
        Task.Run(() =>
        {
            var r = Runtime.RunPowerShell(path, "-File", harness, "block", "-TaskId", task.Id, "-Reason", reason);
            if (r.code != 0)
            {
                BeginInvoke(() => MessageBox.Show(this, (string.IsNullOrWhiteSpace(r.stderr) ? r.stdout : r.stderr).Trim(), "Block Task Failed", MessageBoxButtons.OK, MessageBoxIcon.Error));
            }
            _ = RefreshAllAsync();
        });
    }
}

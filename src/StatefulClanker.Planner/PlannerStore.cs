using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace StatefulClanker.Planner;

public sealed class PlannerStore
{
    static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    readonly string _root;
    readonly string _stateRoot;
    readonly string _planningRoot;
    readonly string _activePath;

    public PlannerStore(string projectRoot)
    {
        _root = Path.GetFullPath(projectRoot);
        _stateRoot = Path.Combine(_root, ".statefulclanker");
        _planningRoot = Path.Combine(_stateRoot, "planning");
        _activePath = Path.Combine(_planningRoot, "active.json");
    }

    public object Status() => WithLock<object>(() =>
    {
        EnsureProject();
        var active = ReadJson<PlannerControl>(_activePath);
        if (active is null)
            return new { active = false, projectRoot = _root };

        return new
        {
            active = true,
            projectRoot = _root,
            control = active,
            busyTaskIds = BusyTaskIds(),
            openQuestions = Questions(active.sessionId).Count(q => q.status == "open")
        };
    });

    public PlannerControl Begin(string reason, long? executionEstimateTokens) => WithLock(() =>
    {
        EnsureProject();
        if (File.Exists(_activePath))
            throw new InvalidOperationException("A planning session is already active.");

        Directory.CreateDirectory(_planningRoot);
        var pausePath = Path.Combine(_stateRoot, "autofill", "pause.request");
        var wasPaused = File.Exists(pausePath);

        var sessionId = NewId("planning");
        var control = new PlannerControl
        {
            sessionId = sessionId,
            phase = PlannerPhases.Quiescing,
            reason = reason ?? "",
            autofillWasPaused = wasPaused,
            budget = new PlanningBudgetPolicy
            {
                executionEstimateTokens = executionEstimateTokens,
                planningTargetTokens = executionEstimateTokens,
                planningToExecutionRatio = 1.0
            }
        };

        // Barrier first. Everything after this point is allowed to discover
        // outstanding work, but no new implementation dispatch should begin.
        WriteJson(_activePath, control);
        Directory.CreateDirectory(SessionDir(sessionId));
        WriteJson(SessionPath(sessionId), control);

        if (!wasPaused)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(pausePath)!);
            File.WriteAllText(pausePath, DateTimeOffset.UtcNow.ToString("O"), new UTF8Encoding(false));
        }

        return control;
    });

    public object Settle() => WithLock<object>(() =>
    {
        EnsureProject();
        var control = RequireActive();
        if (control.phase != PlannerPhases.Quiescing)
            throw new InvalidOperationException($"Planning session is '{control.phase}', not quiescing.");

        var busy = BusyTaskIds();
        if (busy.Count > 0)
            return new { settled = false, phase = control.phase, busyTaskIds = busy };

        var baseline = CaptureBaseline();
        var baselinePath = Path.Combine(SessionDir(control.sessionId), "baseline.json");
        WriteJson(baselinePath, baseline);

        control.phase = PlannerPhases.Planning;
        control.baselinePath = RelativeToState(baselinePath);
        Touch(control);
        SaveControl(control);

        return new { settled = true, phase = control.phase, baseline = control.baselinePath };
    });

    public PlannerQuestion AddQuestion(string text, string why, string impact, string owner, bool blocking)
        => WithLock(() =>
    {
        var control = RequireActive();
        RequirePlanningPhase(control);
        if (string.IsNullOrWhiteSpace(text))
            throw new ArgumentException("Question text is required.");

        var question = new PlannerQuestion
        {
            id = NewId("q"),
            text = text.Trim(),
            why = why?.Trim() ?? "",
            impact = string.IsNullOrWhiteSpace(impact) ? "medium" : impact.Trim().ToLowerInvariant(),
            owner = string.IsNullOrWhiteSpace(owner) ? "human" : owner.Trim().ToLowerInvariant(),
            blocking = blocking
        };

        var dir = Path.Combine(SessionDir(control.sessionId), "questions");
        Directory.CreateDirectory(dir);
        WriteJson(Path.Combine(dir, question.id + ".json"), question);
        return question;
    });

    public PlannerQuestion AnswerQuestion(string questionId, string answer) => WithLock(() =>
    {
        var control = RequireActive();
        RequirePlanningPhase(control);
        var path = Path.Combine(SessionDir(control.sessionId), "questions", questionId + ".json");
        var question = ReadJson<PlannerQuestion>(path)
            ?? throw new InvalidOperationException("Unknown planning question: " + questionId);

        question.answer = answer ?? "";
        question.status = "answered";
        question.updatedAt = DateTimeOffset.UtcNow.ToString("O");
        WriteJson(path, question);
        return question;
    });

    public List<PlannerQuestion> Questions(string? sessionId = null)
    {
        var id = sessionId ?? RequireActive().sessionId;
        var dir = Path.Combine(SessionDir(id), "questions");
        if (!Directory.Exists(dir))
            return new List<PlannerQuestion>();

        return Directory.GetFiles(dir, "*.json")
            .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
            .Select(ReadJson<PlannerQuestion>)
            .Where(x => x is not null)
            .Cast<PlannerQuestion>()
            .ToList();
    }

    public PlannerCandidate AddCandidate(string planFile, string? intentFile, string summary) => WithLock(() =>
    {
        var control = RequireActive();
        RequirePlanningPhase(control);

        if (!File.Exists(planFile))
            throw new FileNotFoundException("Plan file not found.", planFile);
        if (!string.IsNullOrWhiteSpace(intentFile) && !File.Exists(intentFile))
            throw new FileNotFoundException("Intent file not found.", intentFile);

        var candidate = new PlannerCandidate
        {
            id = NewId("candidate"),
            summary = summary ?? ""
        };

        var dir = Path.Combine(SessionDir(control.sessionId), "candidates", candidate.id);
        Directory.CreateDirectory(dir);

        var extension = Path.GetExtension(planFile);
        var planDest = Path.Combine(dir, "plan" + (string.IsNullOrWhiteSpace(extension) ? ".json" : extension));
        File.Copy(Path.GetFullPath(planFile), planDest, true);
        candidate.planPath = RelativeToState(planDest);
        candidate.planSha256 = FileHash(planDest);

        if (!string.IsNullOrWhiteSpace(intentFile))
        {
            var intentDest = Path.Combine(dir, "intent.json");
            File.Copy(Path.GetFullPath(intentFile), intentDest, true);
            candidate.intentPath = RelativeToState(intentDest);
            candidate.intentSha256 = FileHash(intentDest);
        }

        WriteJson(Path.Combine(dir, "candidate.json"), candidate);

        control.activeCandidateId = candidate.id;
        control.phase = PlannerPhases.Review;
        Touch(control);
        SaveControl(control);
        return candidate;
    });

    public PlannerHandoff AcceptCandidate(string candidateId) => WithLock(() =>
    {
        var control = RequireActive();
        if (control.phase is not (PlannerPhases.Review or PlannerPhases.Planning))
            throw new InvalidOperationException($"Cannot accept a candidate while phase is '{control.phase}'.");

        var blocking = Questions(control.sessionId)
            .Where(q => q.status == "open" && q.blocking)
            .ToList();
        if (blocking.Count > 0)
            throw new InvalidOperationException(
                $"Cannot accept planning output with {blocking.Count} open blocking question(s).");

        var candidateDir = Path.Combine(SessionDir(control.sessionId), "candidates", candidateId);
        var candidate = ReadJson<PlannerCandidate>(Path.Combine(candidateDir, "candidate.json"))
            ?? throw new InvalidOperationException("Unknown candidate: " + candidateId);

        var handoff = new PlannerHandoff
        {
            id = NewId("handoff"),
            sessionId = control.sessionId,
            candidateId = candidate.id,
            planPath = candidate.planPath,
            planSha256 = candidate.planSha256,
            intentPath = candidate.intentPath,
            intentSha256 = candidate.intentSha256,
            baselinePath = control.baselinePath
        };

        var handoffDir = Path.Combine(SessionDir(control.sessionId), "handoffs");
        Directory.CreateDirectory(handoffDir);
        WriteJson(Path.Combine(handoffDir, handoff.id + ".json"), handoff);

        control.acceptedHandoffId = handoff.id;
        control.activeCandidateId = candidate.id;
        control.phase = PlannerPhases.Handoff;
        Touch(control);
        SaveControl(control);
        return handoff;
    });

    public PlannerHandoff Release(string handoffId, string appliedPlanId) => WithLock(() =>
    {
        var control = RequireActive();
        if (control.phase != PlannerPhases.Handoff)
            throw new InvalidOperationException(
                $"Cannot release planning barrier while phase is '{control.phase}'.");

        var handoffPath = Path.Combine(
            SessionDir(control.sessionId), "handoffs", handoffId + ".json");
        var handoff = ReadJson<PlannerHandoff>(handoffPath)
            ?? throw new InvalidOperationException("Unknown handoff: " + handoffId);

        if (!string.Equals(control.acceptedHandoffId, handoff.id, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException(
                "Handoff is not the accepted handoff for this session.");

        var state = ReadElement(Path.Combine(_stateRoot, "state.json"));
        var activePlanId = TryString(state, "activePlanId");
        if (string.IsNullOrWhiteSpace(appliedPlanId) ||
            !string.Equals(activePlanId, appliedPlanId, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException(
                $"Applied plan verification failed. state.activePlanId='{activePlanId ?? "<null>"}'.");

        handoff.status = "applied";
        handoff.appliedPlanId = appliedPlanId;
        handoff.releasedAt = DateTimeOffset.UtcNow.ToString("O");
        WriteJson(handoffPath, handoff);

        ArchiveAndClear(control, "completed");
        return handoff;
    });

    public object Cancel(string reason) => WithLock(() =>
    {
        var control = RequireActive();
        ArchiveAndClear(control, "cancelled", reason);
        return new { cancelled = true, sessionId = control.sessionId, reason };
    });

    void ArchiveAndClear(PlannerControl control, string result, string? note = null)
    {
        WriteJson(Path.Combine(SessionDir(control.sessionId), "closed.json"), new
        {
            schemaVersion = 1,
            sessionId = control.sessionId,
            result,
            note,
            closedAt = DateTimeOffset.UtcNow.ToString("O"),
            control
        });

        if (File.Exists(_activePath))
            File.Delete(_activePath);

        if (!control.autofillWasPaused)
        {
            var pausePath = Path.Combine(_stateRoot, "autofill", "pause.request");
            if (File.Exists(pausePath))
                File.Delete(pausePath);

            var triggerPath = Path.Combine(_stateRoot, "autofill", "trigger.request");
            Directory.CreateDirectory(Path.GetDirectoryName(triggerPath)!);
            File.WriteAllText(
                triggerPath,
                DateTimeOffset.UtcNow.ToString("O"),
                new UTF8Encoding(false));
        }
    }

    PlannerBaseline CaptureBaseline()
    {
        var state = ReadElement(Path.Combine(_stateRoot, "state.json"));
        var taskDir = Path.Combine(_stateRoot, "tasks");
        var taskFiles = Directory.Exists(taskDir)
            ? Directory.GetFiles(taskDir, "*.json")
                .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
                .ToArray()
            : Array.Empty<string>();

        var counts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in taskFiles)
        {
            var task = ReadElement(file);
            var status = TryString(task, "status") ?? "unknown";
            counts[status] = counts.TryGetValue(status, out var count) ? count + 1 : 1;
        }

        var intentPath = Path.Combine(_stateRoot, "intent", "contract.json");
        return new PlannerBaseline
        {
            projectRoot = _root,
            gitHead = Git("rev-parse", "HEAD"),
            dirtyPaths = GitLines("status", "--porcelain")
                .Select(ParseDirtyPath)
                .Where(x => !string.IsNullOrWhiteSpace(x))
                .ToList(),
            stateRevision = TryLong(state, "revision"),
            intentRevision = TryLong(state, "intentRevision"),
            intentHash = File.Exists(intentPath) ? FileHash(intentPath) : null,
            activePlanId = TryString(state, "activePlanId"),
            taskGraphHash = HashFiles(taskFiles),
            taskCounts = counts
        };
    }

    List<string> BusyTaskIds()
    {
        var taskDir = Path.Combine(_stateRoot, "tasks");
        if (!Directory.Exists(taskDir))
            return new List<string>();

        var busy = new List<string>();
        foreach (var path in Directory.GetFiles(taskDir, "*.json"))
        {
            var task = ReadElement(path);
            var status = TryString(task, "status");
            if (status is "running" or "reviewing" or "validating")
                busy.Add(TryString(task, "id") ?? Path.GetFileNameWithoutExtension(path));
        }

        return busy.OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
    }

    void RequirePlanningPhase(PlannerControl control)
    {
        if (control.phase is not (PlannerPhases.Planning or PlannerPhases.Review))
            throw new InvalidOperationException(
                $"Planning data may not be edited while phase is '{control.phase}'.");
    }

    PlannerControl RequireActive()
    {
        EnsureProject();
        return ReadJson<PlannerControl>(_activePath)
            ?? throw new InvalidOperationException("No active planning session.");
    }

    void SaveControl(PlannerControl control)
    {
        WriteJson(_activePath, control);
        WriteJson(SessionPath(control.sessionId), control);
    }

    static void Touch(PlannerControl control)
        => control.updatedAt = DateTimeOffset.UtcNow.ToString("O");

    string SessionDir(string id)
        => Path.Combine(_planningRoot, "sessions", id);

    string SessionPath(string id)
        => Path.Combine(SessionDir(id), "session.json");

    string RelativeToState(string path)
    {
        var relative = Path.GetRelativePath(_stateRoot, path).Replace('\', '/');
        return ".statefulclanker/" + relative;
    }

    void EnsureProject()
    {
        if (!File.Exists(Path.Combine(_stateRoot, "state.json")))
            throw new InvalidOperationException(
                $"'{_root}' is not an initialized StatefulClanker project.");
    }

    T WithLock<T>(Func<T> body)
    {
        var name = "Local\\StatefulClankerPlanner-" +
                   ShortHash(_stateRoot.ToLowerInvariant());
        using var mutex = new Mutex(false, name);
        var held = false;
        try
        {
            try
            {
                held = mutex.WaitOne(TimeSpan.FromSeconds(30));
            }
            catch (AbandonedMutexException)
            {
                held = true;
            }

            if (!held)
                throw new TimeoutException("Timed out waiting for planning-state lock.");

            return body();
        }
        finally
        {
            if (held)
            {
                try { mutex.ReleaseMutex(); }
                catch { }
            }
        }
    }

    string? Git(params string[] args)
    {
        var lines = GitLines(args);
        return lines.Count == 0 ? null : lines[0].Trim();
    }

    List<string> GitLines(params string[] args)
    {
        try
        {
            var psi = new ProcessStartInfo("git")
            {
                WorkingDirectory = _root,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            psi.ArgumentList.Add("-C");
            psi.ArgumentList.Add(_root);
            foreach (var arg in args)
                psi.ArgumentList.Add(arg);

            using var process = Process.Start(psi);
            if (process is null)
                return new List<string>();

            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(5000);
            if (process.ExitCode != 0)
                return new List<string>();

            return output.Split(
                new[] { "\r\n", "\n" },
                StringSplitOptions.RemoveEmptyEntries).ToList();
        }
        catch
        {
            return new List<string>();
        }
    }

    static string ParseDirtyPath(string line)
    {
        if (line.Length <= 3)
            return line.Trim();

        var path = line[3..].Trim().Trim('"');
        var arrow = path.LastIndexOf(" -> ", StringComparison.Ordinal);
        return arrow >= 0
            ? path[(arrow + 4)..].Trim().Trim('"')
            : path;
    }

    static string HashFiles(IEnumerable<string> files)
    {
        using var sha = SHA256.Create();
        foreach (var file in files)
        {
            var name = Encoding.UTF8.GetBytes(
                Path.GetFileName(file).ToLowerInvariant() + "\n");
            sha.TransformBlock(name, 0, name.Length, null, 0);

            var bytes = File.ReadAllBytes(file);
            sha.TransformBlock(bytes, 0, bytes.Length, null, 0);
        }

        sha.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
        return Convert.ToHexString(sha.Hash!).ToLowerInvariant();
    }

    static string FileHash(string path)
        => Convert.ToHexString(
            SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();

    static string ShortHash(string value)
        => Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(value)))
            .ToLowerInvariant()[..24];

    static string NewId(string prefix)
    {
        var suffix = Guid.NewGuid().ToString("N")[..8];
        return $"{prefix}-{DateTimeOffset.UtcNow:yyyyMMddHHmmss}-{suffix}";
    }

    static JsonElement ReadElement(string path)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        return doc.RootElement.Clone();
    }

    static string? TryString(JsonElement element, string property)
    {
        if (element.ValueKind == JsonValueKind.Object &&
            element.TryGetProperty(property, out var value) &&
            value.ValueKind != JsonValueKind.Null)
            return value.ValueKind == JsonValueKind.String
                ? value.GetString()
                : value.ToString();

        return null;
    }

    static long TryLong(JsonElement element, string property)
    {
        if (element.ValueKind == JsonValueKind.Object &&
            element.TryGetProperty(property, out var value))
        {
            if (value.TryGetInt64(out var parsed))
                return parsed;
            if (long.TryParse(value.ToString(), out parsed))
                return parsed;
        }

        return 0;
    }

    static T? ReadJson<T>(string path) where T : class
    {
        if (!File.Exists(path))
            return null;

        var raw = File.ReadAllText(path);
        if (string.IsNullOrWhiteSpace(raw))
            return null;

        return JsonSerializer.Deserialize<T>(raw, Json);
    }

    static void WriteJson<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + "." + Environment.ProcessId + "." +
                   Guid.NewGuid().ToString("N") + ".tmp";
        File.WriteAllText(
            temp,
            JsonSerializer.Serialize(value, Json),
            new UTF8Encoding(false));
        File.Move(temp, path, true);
    }
}

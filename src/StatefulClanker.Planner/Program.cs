using System.Text.Json;

namespace StatefulClanker.Planner;

internal static class Program
{
    static readonly JsonSerializerOptions Json = new() { WriteIndented = false };

    static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0) return Usage();
            var command = args[0].ToLowerInvariant();
            var opts = Parse(args.Skip(1).ToArray());
            var root = Get(opts, "project") ?? Directory.GetCurrentDirectory();
            var store = new PlannerStore(root);

            object result = command switch
            {
                "status" => store.Status(),
                "begin" => store.Begin(Get(opts, "reason") ?? "", GetLong(opts, "execution-token-estimate")),
                "settle" => store.Settle(),
                "ask" => store.AddQuestion(
                    Require(opts, "text"),
                    Get(opts, "why") ?? "",
                    Get(opts, "impact") ?? "medium",
                    Get(opts, "owner") ?? "human",
                    GetBool(opts, "blocking", true),
                    GetStringList(opts, "affected-refs-json"),
                    GetStringList(opts, "alternatives-json"),
                    GetStringList(opts, "evidence-json")),
                "answer" => store.AnswerQuestion(
                    Require(opts, "question"),
                    Require(opts, "text"),
                    Get(opts, "source")),
                "questions" => store.Questions(),
                "candidate" => store.AddCandidate(
                    Require(opts, "plan"),
                    Get(opts, "intent"),
                    Get(opts, "directives"),
                    Get(opts, "goal"),
                    Get(opts, "summary") ?? ""),
                "accept" => store.AcceptCandidate(Require(opts, "candidate")),
                "release" => store.Release(Require(opts, "handoff"), Require(opts, "applied-plan-id")),
                "cancel" => store.Cancel(Get(opts, "reason") ?? ""),
                _ => throw new ArgumentException("Unknown planner command: " + command)
            };

            Console.WriteLine(JsonSerializer.Serialize(new { ok = true, data = result }, Json));
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine(JsonSerializer.Serialize(new { ok = false, error = ex.Message }, Json));
            return 1;
        }
    }

    static int Usage()
    {
        Console.Error.WriteLine("StatefulClanker.Planner <status|begin|settle|ask|answer|questions|candidate|accept|release|cancel> [options]");
        Console.Error.WriteLine("  --project <path>                    StatefulClanker project root");
        Console.Error.WriteLine("  begin --reason <text> [--execution-token-estimate <n>]");
        Console.Error.WriteLine("  settle");
        Console.Error.WriteLine("  ask --text <q> [--why <text>] [--impact low|medium|high] [--owner human|system] [--blocking true|false]");
        Console.Error.WriteLine("      [--affected-refs-json <json-array>] [--alternatives-json <json-array>] [--evidence-json <json-array>]");
        Console.Error.WriteLine("  answer --question <id> --text <answer> [--source human|evidence|planner|system]");
        Console.Error.WriteLine("  candidate --plan <file> [--intent <file>] [--directives <file>] [--goal <text>] [--summary <text>]");
        Console.Error.WriteLine("  accept --candidate <id>");
        Console.Error.WriteLine("  release --handoff <id> --applied-plan-id <plan-id>");
        return 2;
    }

    static Dictionary<string,string?> Parse(string[] args)
    {
        var map = new Dictionary<string,string?>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < args.Length; i++)
        {
            if (!args[i].StartsWith("--", StringComparison.Ordinal)) continue;
            var key = args[i][2..];
            var value = i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal)
                ? args[++i]
                : "true";
            map[key] = value;
        }
        return map;
    }

    static string? Get(Dictionary<string,string?> map, string key)
        => map.TryGetValue(key, out var value) ? value : null;

    static string Require(Dictionary<string,string?> map, string key)
        => Get(map, key) is { Length: > 0 } value
            ? value
            : throw new ArgumentException("--" + key + " is required.");

    static bool GetBool(Dictionary<string,string?> map, string key, bool fallback)
        => bool.TryParse(Get(map, key), out var value) ? value : fallback;

    static List<string> GetStringList(Dictionary<string,string?> map, string key)
    {
        var raw = Get(map, key);
        if (string.IsNullOrWhiteSpace(raw)) return new List<string>();
        try
        {
            return JsonSerializer.Deserialize<List<string>>(raw, Json)
                ?.Where(x => !string.IsNullOrWhiteSpace(x))
                .ToList() ?? new List<string>();
        }
        catch (JsonException ex)
        {
            throw new ArgumentException($"--{key} must be a JSON array of strings.", ex);
        }
    }

    static long? GetLong(Dictionary<string,string?> map, string key)
        => long.TryParse(Get(map, key), out var value) ? value : null;
}

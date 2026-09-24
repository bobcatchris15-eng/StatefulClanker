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
                    GetBool(opts, "blocking", true)),
                "answer" => store.AnswerQuestion(Require(opts, "question"), Require(opts, "text")),
                "questions" => store.Questions(),
                "candidate" => store.AddCandidate(
                    Require(opts, "plan"),
                    Get(opts, "intent"),
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
        Console.Error.WriteLine("  answer --question <id> --text <answer>");
        Console.Error.WriteLine("  candidate --plan <file> [--intent <file>] [--summary <text>]");
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

    static long? GetLong(Dictionary<string,string?> map, string key)
        => long.TryParse(Get(map, key), out var value) ? value : null;
}

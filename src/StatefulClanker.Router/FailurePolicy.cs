using System.Globalization;
using System.Text.RegularExpressions;

namespace StatefulClanker.Router;

public static partial class FailurePolicy
{
    [GeneratedRegex(@"(?i)\b(?:http\s*)?429\b|too many requests|rate.?limit|quota exceeded")]
    private static partial Regex RateRx();
    [GeneratedRegex(@"(?i)\b401\b|invalid api key|unauthorized|invalid.*token")]
    private static partial Regex AuthRx();
    [GeneratedRegex(@"(?i)\b403\b|forbidden|permission denied")]
    private static partial Regex PermissionRx();
    [GeneratedRegex(@"(?i)\b402\b|billing|insufficient credits?|payment required|budget exhausted")]
    private static partial Regex BillingRx();
    [GeneratedRegex(@"(?i)timed?\s*out|timeout|connection reset|network is unreachable|dns")]
    private static partial Regex TimeoutRx();
    [GeneratedRegex(@"(?i)\b5\d\d\b|service unavailable|bad gateway|gateway timeout|server error")]
    private static partial Regex ServerRx();
    [GeneratedRegex(@"(?i)model.*(?:not found|unavailable|does not exist)|\b404\b")]
    private static partial Regex ModelRx();
    [GeneratedRegex(@"(?i)capacity|overloaded|no capacity")]
    private static partial Regex CapacityRx();

    public static string Classify(string? text,int? status=null)
    {
        var t=text ?? "";
        if(status==429 || RateRx().IsMatch(t)) return "rate_limited";
        if(status==401 || AuthRx().IsMatch(t)) return "auth";
        if(status==403 || PermissionRx().IsMatch(t)) return "permission";
        if(status==402 || BillingRx().IsMatch(t)) return "billing_exhausted";
        if(status==404 || ModelRx().IsMatch(t)) return "model_unavailable";
        if(status is >=500 and <=599 || ServerRx().IsMatch(t)) return "server_error";
        if(TimeoutRx().IsMatch(t)) return "timeout";
        if(CapacityRx().IsMatch(t)) return "capacity";
        return "request_error";
    }

    public static string ScopeFor(string failureClass) => failureClass switch
    {
        "auth" or "permission" or "configuration" or "billing_exhausted" or "timeout" or "server_error" => "connection",
        "rate_limited" or "capacity" or "model_unavailable" or "malformed_response" or "empty_response" or "protocol_error" => "endpoint",
        _ => "request"
    };

    public static TimeSpan Delay(string failureClass,string? text,int failures=1)
    {
        var explicitDelay=ParseExplicitDelay(text);
        if(explicitDelay is not null) return explicitDelay.Value;

        return failureClass switch
        {
            "rate_limited" => TimeSpan.FromSeconds(Math.Min(3600, failures<=1 ? 60 : failures==2 ? 300 : failures==3 ? 900 : 3600)),
            "billing_exhausted" => TimeSpan.FromMinutes(Math.Min(360, 30*Math.Max(1,failures))),
            "server_error" or "timeout" => TimeSpan.FromSeconds(Math.Min(1800, failures<=1 ? 300 : 300*Math.Pow(2,Math.Min(3,failures-1)))),
            "capacity" or "model_unavailable" => TimeSpan.FromMinutes(Math.Min(60,5*Math.Max(1,failures))),
            _ => TimeSpan.FromMinutes(5)
        };
    }

    public static TimeSpan? ParseExplicitDelay(string? text)
    {
        if(string.IsNullOrWhiteSpace(text)) return null;
        foreach(var pattern in new[]
        {
            @"(?i)retry-after\s*[:=]\s*(\d+(?:\.\d+)?)",
            @"(?i)retry_after_seconds[""']?\s*[:=]\s*(\d+(?:\.\d+)?)",
            @"(?i)retryDelay[""']?\s*[:=]\s*[""']?(\d+(?:\.\d+)?)s?",
            @"(?i)x-ratelimit-reset-after\s*[:=]\s*(\d+(?:\.\d+)?)"
        })
        {
            var m=Regex.Match(text,pattern);
            if(m.Success && double.TryParse(m.Groups[1].Value,NumberStyles.Float,CultureInfo.InvariantCulture,out var s))
                return TimeSpan.FromSeconds(Math.Max(1,Math.Ceiling(s)));
        }

        var epoch=Regex.Match(text,@"(?i)x-ratelimit-reset\s*[:=]\s*(\d{10,})");
        if(epoch.Success && long.TryParse(epoch.Groups[1].Value,out var unix))
        {
            var delta=DateTimeOffset.FromUnixTimeSeconds(unix)-DateTimeOffset.UtcNow;
            return delta>TimeSpan.Zero ? delta : TimeSpan.FromSeconds(1);
        }
        return null;
    }
}

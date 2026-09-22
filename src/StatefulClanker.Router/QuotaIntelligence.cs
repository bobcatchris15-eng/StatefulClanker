using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace StatefulClanker.Router;

public sealed class QuotaWindow
{
    public string kind { get; set; } = "";
    public string? unit { get; set; }
    public double? limit { get; set; }
    public double? remaining { get; set; }
    public string? resetAt { get; set; }
    public string source { get; set; } = "none";
    public string confidence { get; set; } = "unknown";
    public string? evidence { get; set; }
    public List<QuotaWindow> windows { get; set; } = new();
}

public sealed class QuotaObservation
{
    public string status { get; set; } = "unknown";
    public string observedAt { get; set; } = DateTimeOffset.UtcNow.ToString("O");
    public string? nextAvailableAt { get; set; }
    public string? resetAt { get; set; }
    public string? limiter { get; set; }
    public double? limit { get; set; }
    public double? remaining { get; set; }
    public string source { get; set; } = "none";
    public string confidence { get; set; } = "unknown";
    public string? evidence { get; set; }
}

public static partial class QuotaIntelligence
{
    [GeneratedRegex(@"(?i)(?:retry[-_ ]?after|try again(?: in)?|retry in)\D{0,20}(\d+(?:\.\d+)?)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)")]
    private static partial Regex RetryTextRx();
    [GeneratedRegex(@"(?i)(?:retryDelay|retry_delay|retry_after_seconds|retry_after)[""']?\s*[:=]\s*[""']?(\d+(?:\.\d+)?)\s*([a-z]+)?")]
    private static partial Regex RetryJsonRx();
    [GeneratedRegex(@"(?i)(?:regain access|available again|resumes?|reset(?:s)?)(?:\s+on|\s+at|\s*[:=])\s*[""']?([0-9]{4}-[0-9]{2}-[0-9]{2}[^""'\r\n,}]*)")]
    private static partial Regex AbsoluteTextRx();
    [GeneratedRegex(@"(?i)(?:x-)?ratelimit(?:-reset|-reset-after)?\s*[:=]\s*(\d{10,})")]
    private static partial Regex EpochRx();
    [GeneratedRegex(@"(?i)(\d+(?:\.\d+)?)(ms|d|h|m|s)")]
    private static partial Regex DurationPartRx();

    public static QuotaObservation Observe(
        string? providerId,
        int? statusCode,
        IReadOnlyDictionary<string,string>? headers,
        string? body,
        bool success)
    {
        var now=DateTimeOffset.UtcNow;
        var h=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        if(headers is not null)
            foreach(var kv in headers) h[kv.Key]=kv.Value;
        var text=body ?? "";
        var q=new QuotaObservation
        {
            observedAt=now.ToString("O"),
            status=statusCode==429 ? "exhausted" : (success ? "available" : "unknown")
        };

        // Preserve independent request and token buckets. Providers such as
        // Groq expose both simultaneously with different reset windows.
        var requestRemaining=FirstNumber(h,
            "anthropic-ratelimit-requests-remaining",
            "x-ratelimit-remaining-requests",
            "ratelimit-remaining",
            "x-ratelimit-remaining");
        var requestLimit=FirstNumber(h,
            "anthropic-ratelimit-requests-limit",
            "x-ratelimit-limit-requests",
            "ratelimit-limit",
            "x-ratelimit-limit");
        var tokenRemaining=FirstNumber(h,
            "anthropic-ratelimit-tokens-remaining",
            "anthropic-ratelimit-input-tokens-remaining",
            "anthropic-ratelimit-output-tokens-remaining",
            "x-ratelimit-remaining-tokens");
        var tokenLimit=FirstNumber(h,
            "anthropic-ratelimit-tokens-limit",
            "anthropic-ratelimit-input-tokens-limit",
            "anthropic-ratelimit-output-tokens-limit",
            "x-ratelimit-limit-tokens");

        var requestWindow=AddWindow(q,"requests",null,requestLimit,requestRemaining,"headers","reported",
            requestRemaining is not null || requestLimit is not null ? $"requests remaining={requestRemaining}; limit={requestLimit}" : null);
        var tokenWindow=AddWindow(q,"tokens",null,tokenLimit,tokenRemaining,"headers","reported",
            tokenRemaining is not null || tokenLimit is not null ? $"tokens remaining={tokenRemaining}; limit={tokenLimit}" : null);

        // Back-compat summary: requests are the first scheduling gate, then tokens.
        q.remaining=requestRemaining ?? tokenRemaining;
        q.limit=requestRemaining is not null || requestLimit is not null ? requestLimit : tokenLimit;
        q.limiter=requestRemaining is not null || requestLimit is not null ? "requests" :
            (tokenRemaining is not null || tokenLimit is not null ? "tokens" : null);
        if(requestRemaining is <= 0 || tokenRemaining is <= 0) q.status="exhausted";

        // Retry-After is the strongest generic signal and may be seconds or an
        // HTTP date.
        if(TryRetryAfter(h,out var retryAt,out var retryEvidence))
            SetTime(q,retryAt,"retry-after","reported",retryEvidence,true);

        // Cloudflare's current REST format: RateLimit: "default";r=50;t=30
        if(h.TryGetValue("ratelimit",out var rateLimit))
        {
            var rem=Regex.Match(rateLimit,@"(?i)(?:^|;)\s*r\s*=\s*(\d+(?:\.\d+)?)");
            if(rem.Success && double.TryParse(rem.Groups[1].Value,NumberStyles.Float,CultureInfo.InvariantCulture,out var r))
            {
                q.remaining=r;q.limiter ??="requests";
                var w=AddWindow(q,"requests",null,null,r,"ratelimit","reported",rateLimit);
                if(r<=0) q.status="exhausted";
            }
            var reset=Regex.Match(rateLimit,@"(?i)(?:^|;)\s*t\s*=\s*(\d+(?:\.\d+)?)");
            if(reset.Success && double.TryParse(reset.Groups[1].Value,NumberStyles.Float,CultureInfo.InvariantCulture,out var seconds))
            {
                var at=now.AddSeconds(Math.Max(0,seconds));
                SetTime(q,at,"ratelimit:t","reported",rateLimit,q.remaining is <=0 || statusCode==429);
                SetWindowReset(q,"requests",at,"ratelimit:t","reported",rateLimit);
            }
        }

        // Standard / provider reset headers. Groq returns compact durations
        // (2m59.56s); Anthropic returns RFC3339; GitHub commonly returns epoch.
        foreach(var item in new[]
        {
            (name:"anthropic-ratelimit-requests-reset",kind:"requests"),
            (name:"anthropic-ratelimit-tokens-reset",kind:"tokens"),
            (name:"anthropic-ratelimit-input-tokens-reset",kind:"input_tokens"),
            (name:"anthropic-ratelimit-output-tokens-reset",kind:"output_tokens"),
            (name:"x-ratelimit-reset-requests",kind:"requests"),
            (name:"x-ratelimit-reset-tokens",kind:"tokens"),
            (name:"ratelimit-reset",kind:q.limiter ?? "requests"),
            (name:"x-ratelimit-reset",kind:q.limiter ?? "requests")
        })
        {
            if(!h.TryGetValue(item.name,out var raw) || string.IsNullOrWhiteSpace(raw)) continue;
            if(TryResetValue(raw,now,out var resetAt))
            {
                var active=WindowExhausted(q,item.kind) || statusCode==429;
                SetTime(q,resetAt,item.name,"reported",$"{item.name}: {raw}",active);
                SetWindowReset(q,item.kind,resetAt,item.name,"reported",$"{item.name}: {raw}");
            }
        }

        // Google RetryInfo and many OpenAI-compatible gateways expose a retry
        // duration in JSON/text even when no useful headers survive the client.
        if(TryTextDelay(text,now,out var textAt,out var textEvidence))
            SetTime(q,textAt,"body-retry","reported",textEvidence,true);

        // Anthropic spend-cap errors and a few gateways report an absolute
        // "regain access on ..." timestamp in the body.
        var abs=AbsoluteTextRx().Match(text);
        if(abs.Success && DateTimeOffset.TryParse(
            abs.Groups[1].Value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal|DateTimeStyles.AllowWhiteSpaces,
            out var absolute))
            SetTime(q,absolute.ToUniversalTime(),"body-reset","reported",abs.Value,true);

        // OpenRouter's /api/v1/key endpoint reports spend-limit remaining and
        // reset cadence. It is not the free-model request counter, but it is
        // still useful because a zero key budget makes the connection unusable.
        if(string.Equals(providerId,"openrouter",StringComparison.OrdinalIgnoreCase))
            ApplyOpenRouterKeyBody(q,text,now);

        // Gemini requests-per-day reset at midnight Pacific. Use this only when
        // the error itself identifies a daily limiter and Google supplied no
        // explicit RetryInfo.
        if(string.Equals(providerId,"gemini",StringComparison.OrdinalIgnoreCase) &&
           statusCode==429 && q.nextAvailableAt is null &&
           Regex.IsMatch(text,@"(?i)requests?\s+per\s+day|\bRPD\b|perday|per_day"))
        {
            var next=NextPacificMidnight(now);
            SetTime(q,next,"gemini-rpd","inferred","Gemini daily quota; midnight Pacific reset",true);
        }

        // Published fixed windows are useful telemetry even while healthy. They
        // describe when the provider's daily bucket rolls over; they do not by
        // themselves imply exhaustion.
        if(string.Equals(providerId,"gemini",StringComparison.OrdinalIgnoreCase))
        {
            var reset=NextPacificMidnight(now);
            AddWindow(q,"requests_per_day",null,null,null,"provider-rule","derived",
                "Gemini RPD resets at midnight Pacific",reset);
            if(q.resetAt is null) q.resetAt=reset.ToString("O");
        }
        if(string.Equals(providerId,"cloudflare",StringComparison.OrdinalIgnoreCase))
        {
            var reset=new DateTimeOffset(now.UtcDateTime.Date.AddDays(1),TimeSpan.Zero);
            AddWindow(q,"free_allocation","neurons/day",10000,null,"provider-rule","derived",
                "Workers AI free allocation resets at 00:00 UTC",reset);
            if(q.resetAt is null) q.resetAt=reset.ToString("O");
        }

        if(q.nextAvailableAt is not null && DateTimeOffset.TryParse(q.nextAvailableAt,out var n) && n<=now)
            q.nextAvailableAt=null;
        if(q.resetAt is not null && DateTimeOffset.TryParse(q.resetAt,out var rAt) && rAt<=now)
            q.resetAt=null;

        if(q.remaining is > 0 && statusCode!=429) q.status="available";
        if(q.remaining is <= 0) q.status="exhausted";
        if(q.source=="none" && (q.remaining is not null || q.limit is not null))
        {
            q.source="headers";
            q.confidence="reported";
            q.evidence=Bound($"remaining={q.remaining}; limit={q.limit}",180);
        }
        return q;
    }

    public static QuotaObservation ObserveFailure(string? providerId,string failureClass,string? text)
    {
        var status=failureClass=="rate_limited" ? 429 : (int?)null;
        return Observe(providerId,status,ParseHeaderText(text),text,false);
    }

    public static Dictionary<string,string> ParseHeaderText(string? text)
    {
        var result=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        if(string.IsNullOrWhiteSpace(text)) return result;
        foreach(var name in new[]
        {
            "Retry-After","RateLimit","RateLimit-Policy","RateLimit-Remaining","RateLimit-Reset",
            "X-RateLimit-Limit","X-RateLimit-Remaining","X-RateLimit-Reset",
            "X-RateLimit-Limit-Requests","X-RateLimit-Remaining-Requests","X-RateLimit-Reset-Requests",
            "X-RateLimit-Limit-Tokens","X-RateLimit-Remaining-Tokens","X-RateLimit-Reset-Tokens",
            "Anthropic-RateLimit-Requests-Limit","Anthropic-RateLimit-Requests-Remaining","Anthropic-RateLimit-Requests-Reset",
            "Anthropic-RateLimit-Tokens-Limit","Anthropic-RateLimit-Tokens-Remaining","Anthropic-RateLimit-Tokens-Reset",
            "Anthropic-RateLimit-Input-Tokens-Limit","Anthropic-RateLimit-Input-Tokens-Remaining","Anthropic-RateLimit-Input-Tokens-Reset",
            "Anthropic-RateLimit-Output-Tokens-Limit","Anthropic-RateLimit-Output-Tokens-Remaining","Anthropic-RateLimit-Output-Tokens-Reset"
        })
        {
            var m=Regex.Match(text,$@"(?im)(?:^|\r?\n)\s*{Regex.Escape(name)}\s*:\s*([^\r\n]+)");
            if(!m.Success)
                m=Regex.Match(text,$@"(?i)(?:^|;\s*){Regex.Escape(name)}\s*:\s*([^;\r\n]+)");
            if(m.Success) result[name]=m.Groups[1].Value.Trim();
        }
        return result;
    }

    static void ApplyOpenRouterKeyBody(QuotaObservation q,string text,DateTimeOffset now)
    {
        if(string.IsNullOrWhiteSpace(text)) return;
        try
        {
            using var doc=JsonDocument.Parse(text);
            var root=doc.RootElement;
            if(root.TryGetProperty("data",out var data)) root=data;
            if(root.TryGetProperty("limit_remaining",out var rem) && rem.ValueKind==JsonValueKind.Number && rem.TryGetDouble(out var remaining))
            {
                q.remaining=remaining;q.limiter="budget";
                var budgetWindow=AddWindow(q,"budget",null,null,remaining,"openrouter-key","reported",
                    $"OpenRouter key budget remaining={remaining}");
                if(root.TryGetProperty("limit",out var lim) && lim.ValueKind==JsonValueKind.Number && lim.TryGetDouble(out var limit)) q.limit=limit;
                q.status=remaining<=0 ? "exhausted" : "available";
                q.source="openrouter-key";
                q.confidence="reported";
                q.evidence=Bound($"OpenRouter key budget remaining={remaining}",180);
                if(remaining<=0 && root.TryGetProperty("limit_reset",out var reset) && reset.ValueKind==JsonValueKind.String)
                {
                    var cadence=reset.GetString()?.ToLowerInvariant();
                    var next=cadence switch
                    {
                        "daily" => new DateTimeOffset(now.UtcDateTime.Date.AddDays(1),TimeSpan.Zero),
                        "weekly" => NextUtcWeek(now),
                        "monthly" => new DateTimeOffset(new DateTime(now.Year,now.Month,1,0,0,0,DateTimeKind.Utc).AddMonths(1)),
                        _ => (DateTimeOffset?)null
                    };
                    if(next is not null)
                    {
                        SetTime(q,next.Value,"openrouter-key-reset","derived",cadence ?? "",true);
                        SetWindowReset(q,"budget",next.Value,"openrouter-key-reset","derived",cadence ?? "");
                    }
                }
            }
        }
        catch { }
    }

    static bool TryRetryAfter(Dictionary<string,string> h,out DateTimeOffset at,out string evidence)
    {
        at=default;evidence="";
        if(!h.TryGetValue("retry-after",out var raw) || string.IsNullOrWhiteSpace(raw)) return false;
        var now=DateTimeOffset.UtcNow;
        if(double.TryParse(raw,NumberStyles.Float,CultureInfo.InvariantCulture,out var seconds))
        {
            at=now.AddSeconds(Math.Max(1,seconds));evidence="Retry-After: "+raw;return true;
        }
        if(DateTimeOffset.TryParse(raw,CultureInfo.InvariantCulture,DateTimeStyles.AssumeUniversal,out at))
        {
            evidence="Retry-After: "+raw;return true;
        }
        return false;
    }

    static bool TryResetValue(string raw,DateTimeOffset now,out DateTimeOffset at)
    {
        at=default;
        raw=raw.Trim();
        if(long.TryParse(raw,NumberStyles.Integer,CultureInfo.InvariantCulture,out var integer) && integer>=1_000_000_000)
        {
            try { at=DateTimeOffset.FromUnixTimeSeconds(integer);return true; } catch { }
        }
        if(DateTimeOffset.TryParse(raw,CultureInfo.InvariantCulture,DateTimeStyles.AssumeUniversal,out at)) return true;
        if(TryDuration(raw,out var span)){at=now.Add(span);return true;}
        if(double.TryParse(raw,NumberStyles.Float,CultureInfo.InvariantCulture,out var seconds))
        {
            at=now.AddSeconds(Math.Max(0,seconds));return true;
        }
        return false;
    }

    static bool TryDuration(string raw,out TimeSpan span)
    {
        span=TimeSpan.Zero;
        var matches=DurationPartRx().Matches(raw.Trim());
        if(matches.Count==0) return false;
        double seconds=0;
        foreach(Match m in matches)
        {
            if(!double.TryParse(m.Groups[1].Value,NumberStyles.Float,CultureInfo.InvariantCulture,out var value)) continue;
            seconds += m.Groups[2].Value.ToLowerInvariant() switch
            {
                "d" => value*86400,
                "h" => value*3600,
                "m" => value*60,
                "ms" => value/1000,
                _ => value
            };
        }
        span=TimeSpan.FromSeconds(Math.Max(0,seconds));
        return true;
    }

    static bool TryTextDelay(string text,DateTimeOffset now,out DateTimeOffset at,out string evidence)
    {
        at=default;evidence="";
        if(string.IsNullOrWhiteSpace(text)) return false;
        var m=RetryJsonRx().Match(text);
        if(m.Success && double.TryParse(m.Groups[1].Value,NumberStyles.Float,CultureInfo.InvariantCulture,out var n))
        {
            var unit=m.Groups[2].Success?m.Groups[2].Value:"s";
            var seconds=UnitSeconds(n,unit);
            at=now.AddSeconds(Math.Max(1,seconds));evidence=Bound(m.Value,180)!;return true;
        }
        m=RetryTextRx().Match(text);
        if(m.Success && double.TryParse(m.Groups[1].Value,NumberStyles.Float,CultureInfo.InvariantCulture,out n))
        {
            at=now.AddSeconds(Math.Max(1,UnitSeconds(n,m.Groups[2].Value)));evidence=Bound(m.Value,180)!;return true;
        }
        var epoch=EpochRx().Match(text);
        if(epoch.Success && long.TryParse(epoch.Groups[1].Value,out var unix))
        {
            try { at=DateTimeOffset.FromUnixTimeSeconds(unix);evidence=Bound(epoch.Value,180)!;return true; } catch { }
        }
        return false;
    }

    static double UnitSeconds(double value,string unit)
    {
        var u=unit.Trim().ToLowerInvariant();
        if(u.StartsWith("h")) return value*3600;
        if(u.StartsWith("m") && u!="ms") return value*60;
        if(u=="ms") return value/1000;
        return value;
    }

    static QuotaWindow? AddWindow(
        QuotaObservation q,string kind,string? unit,double? limit,double? remaining,
        string source,string confidence,string? evidence,DateTimeOffset? resetAt=null)
    {
        if(limit is null && remaining is null && resetAt is null) return null;
        var existing=q.windows.FirstOrDefault(x=>string.Equals(x.kind,kind,StringComparison.OrdinalIgnoreCase));
        if(existing is null)
        {
            existing=new QuotaWindow{kind=kind};
            q.windows.Add(existing);
        }
        if(unit is not null) existing.unit=unit;
        if(limit is not null) existing.limit=limit;
        if(remaining is not null) existing.remaining=remaining;
        if(resetAt is not null && resetAt>DateTimeOffset.UtcNow) existing.resetAt=resetAt.Value.ToUniversalTime().ToString("O");
        if(ConfidenceRank(confidence)>=ConfidenceRank(existing.confidence))
        {
            existing.source=source;existing.confidence=confidence;existing.evidence=Bound(evidence,240);
        }
        return existing;
    }

    static void SetWindowReset(
        QuotaObservation q,string kind,DateTimeOffset at,string source,string confidence,string evidence)
    {
        if(at<=DateTimeOffset.UtcNow) return;
        AddWindow(q,kind,null,null,null,source,confidence,evidence,at);
    }

    static bool WindowExhausted(QuotaObservation q,string kind)
    {
        var w=q.windows.FirstOrDefault(x=>string.Equals(x.kind,kind,StringComparison.OrdinalIgnoreCase));
        return w?.remaining is <=0;
    }

    static double? FirstNumber(Dictionary<string,string> h,params string[] names)
    {
        foreach(var name in names)
            if(h.TryGetValue(name,out var raw) && double.TryParse(raw,NumberStyles.Float,CultureInfo.InvariantCulture,out var n))
                return n;
        return null;
    }

    static void SetTime(QuotaObservation q,DateTimeOffset at,string source,string confidence,string evidence,bool nextAvailable)
    {
        if(at<=DateTimeOffset.UtcNow) return;
        if(q.resetAt is null || !DateTimeOffset.TryParse(q.resetAt,out var existingReset) || at<existingReset)
            q.resetAt=at.ToUniversalTime().ToString("O");
        if(nextAvailable && (q.nextAvailableAt is null || !DateTimeOffset.TryParse(q.nextAvailableAt,out var existing) || at<existing))
            q.nextAvailableAt=at.ToUniversalTime().ToString("O");
        // Prefer stronger evidence over inferred/derived observations.
        var rank=ConfidenceRank(confidence);
        if(rank>ConfidenceRank(q.confidence))
        {
            q.source=source;q.confidence=confidence;q.evidence=Bound(evidence,240);
        }
    }

    static int ConfidenceRank(string? confidence) => confidence switch
    {
        "reported" => 3,
        "derived" => 2,
        "inferred" => 1,
        _ => 0
    };

    static DateTimeOffset NextUtcWeek(DateTimeOffset now)
    {
        var days=((int)DayOfWeek.Monday-(int)now.UtcDateTime.DayOfWeek+7)%7;
        if(days==0) days=7;
        return new DateTimeOffset(now.UtcDateTime.Date.AddDays(days),TimeSpan.Zero);
    }

    static DateTimeOffset NextPacificMidnight(DateTimeOffset now)
    {
        TimeZoneInfo tz;
        try { tz=TimeZoneInfo.FindSystemTimeZoneById("America/Los_Angeles"); }
        catch { tz=TimeZoneInfo.FindSystemTimeZoneById("Pacific Standard Time"); }
        var local=TimeZoneInfo.ConvertTime(now,tz);
        var nextLocal=DateTime.SpecifyKind(local.Date.AddDays(1),DateTimeKind.Unspecified);
        return new DateTimeOffset(nextLocal,tz.GetUtcOffset(nextLocal)).ToUniversalTime();
    }

    static string? Bound(string? value,int max)
    {
        if(string.IsNullOrWhiteSpace(value)) return null;
        var s=value.Replace("\r"," ").Replace("\n"," ").Trim();
        return s.Length<=max?s:s[..max];
    }
}

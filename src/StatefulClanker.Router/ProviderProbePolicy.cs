namespace StatefulClanker.Router;

public sealed record ProviderProbePlan(
    Uri Uri,
    string Kind,
    string AppliesTo,
    bool ReadBody);

public static class ProviderProbePolicy
{
    public static ProviderProbePlan For(ConnectionProfile profile)
    {
        var id=(profile.presetId??"custom").Trim().ToLowerInvariant();

        // OpenRouter exposes current-key/account budget metadata with the same
        // inference credential and no generation request.
        if(id=="openrouter")
            return new ProviderProbePlan(
                new Uri("https://openrouter.ai/api/v1/key"),
                "account-metadata",
                "account-budget",
                true);

        // Every other built-in provider already has a harmless discovery/read
        // endpoint. Its rate-limit headers prove that read surface only unless
        // provider documentation explicitly says otherwise.
        return new ProviderProbePlan(
            ModelsUri(profile),
            "model-catalog",
            "metadata",
            false);
    }

    public static QuotaObservation? ProgrammaticWindow(
        ConnectionProfile profile,
        DateTimeOffset now)
    {
        var id=(profile.presetId??"custom").Trim().ToLowerInvariant();
        switch(id)
        {
            case "cloudflare":
                return new QuotaObservation
                {
                    status="available",
                    observedAt=now.ToString("O"),
                    windowResetAt=NextUtcMidnight(now).ToString("O"),
                    windowCadence="daily",
                    limiter="free-allocation",
                    appliesTo="inference-policy",
                    source="none",
                    confidence="unknown",
                    windowSource="policy:cloudflare-free-allocation",
                    windowConfidence="documented",
                    windowEvidence="Workers AI free allocation resets daily at 00:00 UTC."
                };

            case "gemini":
                return new QuotaObservation
                {
                    status="available",
                    observedAt=now.ToString("O"),
                    windowResetAt=NextPacificMidnight(now).ToString("O"),
                    windowCadence="daily",
                    limiter="RPD",
                    appliesTo="inference-policy",
                    source="none",
                    confidence="unknown",
                    windowSource="policy:gemini-rpd",
                    windowConfidence="documented",
                    windowEvidence="Gemini requests-per-day quota resets at midnight Pacific."
                };

            default:
                return null;
        }
    }

    public static bool SkipNetworkProbe(ConnectionProfile profile)
    {
        var id=(profile.presetId??"").Trim().ToLowerInvariant();
        return id is "ollama" or "lmstudio" or "vllm" ||
               string.IsNullOrWhiteSpace(profile.baseUrl);
    }

    static Uri ModelsUri(ConnectionProfile p)
    {
        var baseUri=p.baseUrl.TrimEnd('/');
        var path=string.IsNullOrWhiteSpace(p.modelsPath)?"/models":p.modelsPath;
        if(Uri.TryCreate(path,UriKind.Absolute,out var absolute)) return absolute;
        return new Uri(baseUri+"/"+path.TrimStart('/'));
    }

    static DateTimeOffset NextUtcMidnight(DateTimeOffset now) =>
        new(now.UtcDateTime.Date.AddDays(1),TimeSpan.Zero);

    static DateTimeOffset NextPacificMidnight(DateTimeOffset now)
    {
        TimeZoneInfo tz;
        try { tz=TimeZoneInfo.FindSystemTimeZoneById("America/Los_Angeles"); }
        catch { tz=TimeZoneInfo.FindSystemTimeZoneById("Pacific Standard Time"); }
        var local=TimeZoneInfo.ConvertTime(now,tz);
        var nextLocal=DateTime.SpecifyKind(local.Date.AddDays(1),DateTimeKind.Unspecified);
        return new DateTimeOffset(nextLocal,tz.GetUtcOffset(nextLocal)).ToUniversalTime();
    }
}

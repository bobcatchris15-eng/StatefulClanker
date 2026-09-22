namespace StatefulClanker.Router;

public enum ProviderProbeKind
{
    Models,
    DedicatedQuota,
    HealthOnly,
    Disabled
}

public sealed record ProviderProbePlan(
    string ProviderId,
    ProviderProbeKind Kind,
    HttpMethod Method,
    Uri? Uri,
    bool ReadSuccessBody,
    bool ApplyConnectionAuth,
    TimeSpan UsefulInterval,
    TimeSpan SilentInterval,
    string Strategy,
    string? Note = null)
{
    public bool Enabled => Kind != ProviderProbeKind.Disabled && Uri is not null;
}

public static class ProviderProbeCatalog
{
    static readonly TimeSpan Useful = TimeSpan.FromMinutes(5);
    static readonly TimeSpan Silent = TimeSpan.FromMinutes(30);

    public static ProviderProbePlan Resolve(ConnectionProfile profile)
    {
        var id=(profile.presetId ?? "custom").Trim().ToLowerInvariant();

        if(id is "ollama" or "lmstudio" or "vllm")
            return Disabled(id,"Local/self-hosted provider; periodic quota probing is unnecessary.");

        if(id=="github-models")
            return Disabled(id,"GitHub Models was retired on 2026-07-30.");

        if(id=="openrouter")
        {
            var baseUri=BaseUri(profile);
            return new ProviderProbePlan(
                id,ProviderProbeKind.DedicatedQuota,HttpMethod.Get,
                Append(baseUri,"key"),true,true,
                TimeSpan.FromMinutes(2),TimeSpan.FromMinutes(10),
                "openrouter-key",
                "Authenticated key metadata exposes budget and reset cadence without inference.");
        }

        if(id=="cohere")
        {
            var authority=ModelsAuthority(profile) ?? new Uri("https://api.cohere.com/");
            return new ProviderProbePlan(
                id,ProviderProbeKind.HealthOnly,HttpMethod.Post,
                new Uri(authority,"v1/check-api-key"),true,true,
                TimeSpan.FromMinutes(15),TimeSpan.FromMinutes(30),
                "cohere-key-check",
                "Dedicated key-validity endpoint; quota telemetry is harvested if headers are present.");
        }

        // These providers currently expose useful quota/reset headers on ordinary
        // API/control-plane responses. Keep the models/catalog request cheap and
        // harvest the response metadata instead of spending inference.
        var telemetryPreferred=id is
            "groq" or "cerebras" or "anthropic" or "gemini" or "cloudflare" or
            "openrouter" or "kilo";

        var models=ModelsUri(profile);
        return new ProviderProbePlan(
            id,ProviderProbeKind.Models,HttpMethod.Get,models,false,true,
            telemetryPreferred ? Useful : TimeSpan.FromMinutes(10),
            telemetryPreferred ? Silent : TimeSpan.FromMinutes(45),
            "models",
            telemetryPreferred
                ? "Catalog/control-plane request; harvest rate-limit and reset metadata when returned."
                : "Generic authenticated model/catalog health probe; back off when quota-silent.");
    }

    public static bool IsRetired(ConnectionProfile profile) =>
        string.Equals(profile.presetId,"github-models",StringComparison.OrdinalIgnoreCase);

    static ProviderProbePlan Disabled(string id,string reason) =>
        new(id,ProviderProbeKind.Disabled,HttpMethod.Get,null,false,false,
            TimeSpan.FromHours(1),TimeSpan.FromHours(6),"disabled",reason);

    static Uri BaseUri(ConnectionProfile profile)
    {
        if(!Uri.TryCreate(profile.baseUrl.TrimEnd('/')+"/",UriKind.Absolute,out var uri))
            throw new InvalidOperationException("Connection base URL is invalid.");
        return uri;
    }

    static Uri? ModelsAuthority(ConnectionProfile profile)
    {
        if(!string.IsNullOrWhiteSpace(profile.modelsPath) &&
           Uri.TryCreate(profile.modelsPath,UriKind.Absolute,out var absolute))
            return new Uri(absolute.GetLeftPart(UriPartial.Authority)+"/");

        try { return new Uri(BaseUri(profile).GetLeftPart(UriPartial.Authority)+"/"); }
        catch { return null; }
    }

    static Uri ModelsUri(ConnectionProfile profile)
    {
        var baseUri=profile.baseUrl.TrimEnd('/');
        var path=string.IsNullOrWhiteSpace(profile.modelsPath)?"/models":profile.modelsPath;
        if(Uri.TryCreate(path,UriKind.Absolute,out var absolute)) return absolute;
        return new Uri(baseUri+"/"+path.TrimStart('/'));
    }

    static Uri Append(Uri baseUri,string segment)
    {
        var text=baseUri.ToString().TrimEnd('/')+"/"+segment.TrimStart('/');
        return new Uri(text);
    }
}

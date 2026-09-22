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

        if(id=="pollinations")
        {
            var authority=ModelsAuthority(profile) ?? new Uri("https://gen.pollinations.ai/");
            return new ProviderProbePlan(
                id,ProviderProbeKind.DedicatedQuota,HttpMethod.Get,
                new Uri(authority,"account/key"),true,true,
                TimeSpan.FromMinutes(5),TimeSpan.FromMinutes(20),
                "pollinations-key",
                "Authenticated key metadata exposes pollen budget, expiry and rate-limit state without generation.");
        }

        var models=ModelsUri(profile);
        return id switch
        {
            "groq" => ModelsPlan(id,models,"groq-models-headers",
                "Groq documents RPD/TPM remaining and reset headers on API responses; harvest them without inference."),
            "cerebras" => ModelsPlan(id,models,"cerebras-models-headers",
                "Cerebras documents request/day and token/minute remaining/reset headers on API responses."),
            "anthropic" => ModelsPlan(id,models,"anthropic-models-headers",
                "Harvest Anthropic rate-limit metadata from its authenticated control plane when present."),
            "gemini" => ModelsPlan(id,models,"gemini-models-rules",
                "Model-list health plus published midnight-Pacific daily reset rules; explicit RetryInfo remains authoritative."),
            "cloudflare" => ModelsPlan(id,models,"cloudflare-models-rules",
                "Workers AI model catalog plus published 00:00 UTC daily free-allocation reset."),
            "kilo" => ModelsPlan(id,models,"kilo-models-rules",
                "Public model catalog plus published 200 free-model requests/hour/IP policy."),
            "nvidia" => ModelsPlan(id,models,"nvidia-nim-models",
                "Hosted NIM model catalog; configured API Catalog capacity is treated separately as trial/free-endpoint capacity."),
            "opencode-zen" => ModelsPlan(id,models,"opencode-zen-models",
                "Sparse Zen catalog; free routes are identified conservatively from explicit free model IDs."),
            "mistral" => ModelsPlan(id,models,"mistral-models",
                "Ordinary API keys can validate/list models; richer usage/rate-limit Admin APIs require a separate Admin API key."),
            "huggingface" => ModelsPlan(id,models,"huggingface-models",
                "Inference Providers catalog health; billing/credit detail is primarily exposed in account billing settings."),
            "vercel" => ModelsPlan(id,models,"vercel-models",
                "AI Gateway model catalog health. Budget/spend inspection is exposed through Vercel account tooling rather than the gateway key endpoint."),
            _ => new ProviderProbePlan(
                id,ProviderProbeKind.Models,HttpMethod.Get,models,false,true,
                TimeSpan.FromMinutes(10),TimeSpan.FromMinutes(45),
                "models",
                "Generic authenticated model/catalog health probe; back off when quota-silent.")
        };
    }

    static ProviderProbePlan ModelsPlan(string id,Uri uri,string strategy,string note) =>
        new(id,ProviderProbeKind.Models,HttpMethod.Get,uri,false,true,
            Useful,Silent,strategy,note);

    public static bool IsRetired(ConnectionProfile profile) =>
        string.Equals(profile.presetId,"github-models",StringComparison.OrdinalIgnoreCase);

    static ProviderProbePlan Disabled(string id,string reason) =>
        new(id,ProviderProbeKind.Disabled,HttpMethod.Get,null,false,false,
            TimeSpan.FromHours(1),TimeSpan.FromHours(6),"disabled",reason);

    static Uri BaseUri(ConnectionProfile profile)
    {
        var expanded=Expand(profile,profile.baseUrl).TrimEnd('/')+"/";
        if(!Uri.TryCreate(expanded,UriKind.Absolute,out var uri))
            throw new InvalidOperationException("Connection base URL is invalid.");
        return uri;
    }

    static Uri? ModelsAuthority(ConnectionProfile profile)
    {
        var modelsPath=Expand(profile,profile.modelsPath);
        if(!string.IsNullOrWhiteSpace(modelsPath) &&
           Uri.TryCreate(modelsPath,UriKind.Absolute,out var absolute))
            return new Uri(absolute.GetLeftPart(UriPartial.Authority)+"/");

        try { return new Uri(BaseUri(profile).GetLeftPart(UriPartial.Authority)+"/"); }
        catch { return null; }
    }

    static Uri ModelsUri(ConnectionProfile profile)
    {
        var baseUri=Expand(profile,profile.baseUrl).TrimEnd('/');
        var path=Expand(profile,string.IsNullOrWhiteSpace(profile.modelsPath)?"/models":profile.modelsPath);
        if(Uri.TryCreate(path,UriKind.Absolute,out var absolute)) return absolute;
        return new Uri(baseUri+"/"+path.TrimStart('/'));
    }

    static string Expand(ConnectionProfile profile,string? value) =>
        (value ?? "").Replace("{accountId}",profile.accountId?.Trim() ?? "",StringComparison.OrdinalIgnoreCase);

    static Uri Append(Uri baseUri,string segment)
    {
        var text=baseUri.ToString().TrimEnd('/')+"/"+segment.TrimStart('/');
        return new Uri(text);
    }
}

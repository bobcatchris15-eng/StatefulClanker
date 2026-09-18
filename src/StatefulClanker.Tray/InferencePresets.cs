namespace StatefulClanker.Tray;

sealed record InferencePreset(
    string Id,
    string DisplayName,
    string BaseUrlTemplate,
    string ModelsPathTemplate,
    string DiscoveryKind,
    bool RequiresAccountId,
    bool RequiresApiKey,
    string FreeLabel,
    string KeyPlaceholder,
    string SetupUrl,
    string Instructions,
    // Wire protocol this connection speaks. "openai-chat" (default) covers every
    // OpenAI-compatible gateway below. "anthropic-messages" is Anthropic's native
    // Messages API -- different auth header, different request/response shape --
    // the PowerShell worker runtime (lib/StatefulClanker.WorkerRuntime.ps1)
    // translates this project's canonical OpenAI-shaped message history to/from
    // it automatically, so nothing above the connection layer needs to know.
    string Protocol = "openai-chat",
    // Headers a connection using this preset should start with (e.g. Anthropic's
    // required anthropic-version), seeded into the Headers field on preset select.
    string DefaultHeaders = "");

static class InferencePresets
{
    public static readonly InferencePreset[] All =
    {
        new("openrouter","OpenRouter","https://openrouter.ai/api/v1","/models","openai",false,true,
            "Ongoing free-model pool","sk-or-v1-...","https://openrouter.ai/settings/keys",
            "Create an OpenRouter account, open Settings > Keys, create a key, and paste it here. OpenRouter publishes free model variants and the openrouter/free router; model availability changes, so StatefulClanker discovers the live catalog instead of shipping a fixed list."),
        new("anthropic","Anthropic","https://api.anthropic.com","/v1/models","openai",false,true,
            "No ongoing free tier; pay-as-you-go (new accounts may get limited trial credit)","sk-ant-...","https://console.anthropic.com/settings/keys",
            "Create an Anthropic account, open Console > API Keys, create a key, and paste it here. This preset uses Anthropic's native Messages API (x-api-key authentication and the anthropic-version header, not OpenAI-style Bearer tokens) -- StatefulClanker translates the worker/critic/validator tool-calling loop to and from Anthropic's wire format automatically, so it's used exactly like any other endpoint once saved.",
            "anthropic-messages","anthropic-version: 2023-06-01"),
        new("groq","GroqCloud","https://api.groq.com/openai/v1","/models","openai",false,true,
            "Free rate-limited developer access","gsk_...","https://console.groq.com/keys",
            "Create a GroqCloud account, create an API key in the Groq console, and paste it here. The free developer limits vary by model and are returned/enforced by Groq."),
        new("gemini","Google Gemini API / AI Studio","https://generativelanguage.googleapis.com/v1beta/openai","/models","openai",false,true,
            "Gemini API free tier","AIza...","https://aistudio.google.com/apikey",
            "Open Google AI Studio, create a Gemini API key, and paste it here. StatefulClanker uses Google's OpenAI-compatible endpoint and discovers the models enabled for that key."),
        new("cloudflare","Cloudflare Workers AI","https://api.cloudflare.com/client/v4/accounts/{accountId}/ai/v1","https://api.cloudflare.com/client/v4/accounts/{accountId}/ai/models/search?format=openrouter&per_page=1000","cloudflare",true,true,
            "10,000 neurons/day free allocation","Cloudflare API token","https://dash.cloudflare.com/",
            "In the Cloudflare dashboard open Workers AI > Use REST API. Copy the Account ID and create a Workers AI API token with Workers AI Read/Edit permission. Enter both below. The free allocation resets daily."),
        new("mistral","Mistral La Plateforme","https://api.mistral.ai/v1","/models","openai",false,true,
            "Free mode included usage; Labs models may be $0","MISTRAL_API_KEY","https://console.mistral.ai/api-keys",
            "Create a Mistral account, enable Free mode, create an API key, and paste it here. Current included usage is account-specific; Labs models marked free by Mistral can also be selected."),
        new("huggingface","Hugging Face Inference Providers","https://router.huggingface.co/v1","/models","openai",false,true,
            "Small monthly free inference credit","hf_...","https://huggingface.co/settings/tokens",
            "Create a fine-grained Hugging Face token with permission to make calls to Inference Providers. Free accounts currently receive a small monthly inference credit. The catalog may route one model through several underlying providers."),
        new("nvidia","NVIDIA NIM / build.nvidia.com","https://integrate.api.nvidia.com/v1","/models","openai",false,true,
            "Free developer-program prototype endpoints","nvapi-...","https://build.nvidia.com/",
            "Join the free NVIDIA Developer Program, open a model on build.nvidia.com, choose Prototype / API, and generate an API key. Free endpoint availability is intended for development and experimentation."),
        new("cohere","Cohere","https://api.cohere.ai/compatibility/v1","https://api.cohere.com/v1/models?page_size=1000&endpoint=chat","cohere",false,true,
            "Free evaluation key: 1,000 calls/month","Cohere API key","https://dashboard.cohere.com/api-keys",
            "Create a Cohere trial/evaluation API key and paste it here. Evaluation keys are free but limited and are not intended as production capacity. StatefulClanker uses Cohere's OpenAI Compatibility API for chat and the native model catalog for discovery."),
        new("kilo","Kilo AI Gateway","https://api.kilo.ai/api/gateway","/models","openai",false,false,
            "Free models; anonymous access up to 200 requests/hour/IP","","https://kilo.ai/docs/gateway",
            "No key is required for Kilo's free models. Select the preset and Test & discover immediately. You may optionally add a Kilo API key for account-backed access. Choose models tagged :free or kilo-auto/free; free requests are rate-limited by IP and some upstreams may log prompts."),
        new("vercel","Vercel AI Gateway","https://ai-gateway.vercel.sh/v1","/models","openai",false,true,
            "$5/month included gateway credit while on the free tier","Vercel AI Gateway key","https://vercel.com/ai-gateway",
            "Create a Vercel account and an AI Gateway API key, then paste it here. Vercel currently includes $5/month of AI Gateway credit on the free tier; purchasing gateway credits moves the account to paid-tier billing and ends that monthly free credit."),
        new("cerebras","Cerebras Inference","https://api.cerebras.ai/v1","/models","openai",false,true,
            "$5 free trial credit (not ongoing free tier)","csk-...","https://cloud.cerebras.ai/",
            "Create a Cerebras Inference account and API key. Cerebras currently advertises $5 of free trial credit; StatefulClanker labels this as trial rather than ongoing free inference."),
        new("ollama","Ollama (local)","http://127.0.0.1:11434/v1","/models","openai",false,false,
            "Free local inference","","https://ollama.com/",
            "Install Ollama and pull at least one model. Leave the API key blank. StatefulClanker connects to the local OpenAI-compatible endpoint and discovers installed models."),
        new("lmstudio","LM Studio (local)","http://127.0.0.1:1234/v1","/models","openai",false,false,
            "Free local inference","","https://lmstudio.ai/",
            "Install LM Studio, download a model, and start the Local Server with its OpenAI-compatible API enabled. Leave the API key blank."),
        new("vllm","vLLM (local / LAN)","http://127.0.0.1:8000/v1","/models","openai",false,false,
            "Free self-hosted inference","","https://docs.vllm.ai/",
            "Start vLLM's OpenAI-compatible server and enter its reachable base URL. If you configured API-key authentication, provide that key; otherwise leave it blank."),
        new("custom","Custom OpenAI-compatible","https://","/models","openai",false,false,
            "Depends on service","","",
            "Enter an OpenAI-compatible base URL. StatefulClanker will authenticate if a key is supplied, call the model-list endpoint, and only save the connection after a successful discovery.")
    };

    public static InferencePreset Get(string? id) =>
        All.FirstOrDefault(x => string.Equals(x.Id,id,StringComparison.OrdinalIgnoreCase)) ?? All[^1];

    public static string Expand(string template,string? accountId) =>
        template.Replace("{accountId}", accountId?.Trim() ?? "", StringComparison.OrdinalIgnoreCase);
}

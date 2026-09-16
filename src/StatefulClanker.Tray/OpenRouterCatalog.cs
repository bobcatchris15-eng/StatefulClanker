namespace StatefulClanker.Tray;

sealed record OpenRouterFreeModel(string ConnectionId, string ModelId, string DisplayName, string ToolMode);

// Snapshot verified against OpenRouter /api/v1/models on 2026-09-16. Pricing and availability are external and may change.
static class OpenRouterFreeModels
{
    public const string BaseUrl = "https://openrouter.ai/api/v1";
    public static readonly OpenRouterFreeModel[] All =
    {
        new("or-north-mini-code", "cohere/north-mini-code:free", "Cohere North Mini Code", "native"),
        new("or-dots3-note", "dots-studio/dots-3-note-preview:free", "Dots3-Note Preview", "native"),
        new("or-free-router", "openrouter/free", "OpenRouter Free Models Router", "native"),
        new("or-gemma4-26b", "google/gemma-4-26b-a4b-it:free", "Gemma 4 26B A4B", "native"),
        new("or-gemma4-31b", "google/gemma-4-31b-it:free", "Gemma 4 31B", "native"),
        new("or-ling-flash-fin", "inclusionai/ling-3.0-flash-fin:free", "Ling 3.0 Flash Fin", "native"),
        new("or-ling-flash-sante", "inclusionai/ling-3.0-flash-sante:free", "Ling 3.0 Flash Sante", "native"),
        new("or-ling-flash-vl", "inclusionai/ling-3.0-flash-vl:free", "Ling 3.0 Flash VL", "native"),
        new("or-lfm25-26b", "liquid/lfm-2.5-2.6b:free", "LFM2.5 2.6B", "native"),
        new("or-nex-n25-mini", "nex-agi/nex-n2.5-mini:free", "Nex-N2.5 Mini", "native"),
        new("or-nex-n25-pro", "nex-agi/nex-n2.5-pro:free", "Nex-N2.5 Pro", "native"),
        new("or-nemotron3-nano-omni", "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free", "Nemotron 3 Nano Omni", "native"),
        new("or-nemotron3-super", "nvidia/nemotron-3-super-120b-a12b:free", "Nemotron 3 Super", "native"),
        new("or-nemotron3-ultra", "nvidia/nemotron-3-ultra-550b-a55b:free", "Nemotron 3 Ultra", "native"),
        new("or-nemotron35-lightning", "nvidia/nemotron-3.5-lightning:free", "Nemotron 3.5 Lightning", "native"),
        new("or-laguna-s21", "poolside/laguna-s-2.1:free", "Poolside Laguna S 2.1", "native"),
        new("or-laguna-xs21", "poolside/laguna-xs-2.1:free", "Poolside Laguna XS 2.1", "native"),
        new("or-inkling", "thinkingmachines/inkling:free", "Thinking Machines Inkling", "native"),
        new("or-inkling-small", "thinkingmachines/inkling-small:free", "Thinking Machines Inkling Small", "native"),
        new("or-union-alpha", "stealth/union-alpha", "Union Alpha", "native"),
        new("or-glm52", "z-ai/glm-5.2:free", "GLM 5.2", "text"),
    };
}

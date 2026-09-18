# Direct inference, connections, endpoints, and routing

StatefulClanker separates machine access from project routing.

## Connections

A **Connection** is machine-local access to an inference service. It stores the service adapter, base URL, authentication, extra headers, health, and the last discovered model catalog in:

```text
%LOCALAPPDATA%\StatefulClanker\connections.json
```

Secrets are DPAPI-encrypted for the current Windows user or referenced by environment variable. Projects never copy API keys.

The Windows **Connections** page provides presets for OpenRouter, GroqCloud, Gemini / AI Studio, Cloudflare Workers AI, Mistral, Hugging Face Inference Providers, NVIDIA NIM, Cerebras, Ollama, LM Studio, vLLM, and arbitrary OpenAI-compatible services.

Adding or editing a connection is validation-first:

1. choose a service preset;
2. follow the displayed provider-specific setup instructions;
3. enter the account/key details;
4. select **Test & discover**;
5. StatefulClanker authenticates against the API and retrieves its live model catalog;
6. Save is enabled only after successful discovery.

The discovered catalog is cached only as convenience metadata. **Test & refresh** re-queries the service. This replaces the former hardcoded OpenRouter free-model snapshot.

## Endpoints

An **Endpoint** is one executable inference target available to the active project:

- API: one machine Connection + one discovered model;
- CLI: one configured local command/harness.

Multiple endpoints may expose the same model through different connections. This is intentional: quota, rate limits, latency, credentials, and health belong to the route actually used.

The **Connections** page can select one or many discovered models and add them to the active project. Project configuration continues to use the existing `providers` object for on-disk compatibility, but those entries are treated and displayed as endpoints:

```json
{
  "providers": {
    "gemini-or-primary": {
      "type": "api",
      "connection": "openrouter-primary",
      "model": "google/example-model",
      "toolMode": "native",
      "priority": 10
    },
    "gemini-or-backup": {
      "type": "api",
      "connection": "openrouter-backup",
      "model": "google/example-model",
      "toolMode": "native",
      "priority": 20
    },
    "codex": {
      "type": "cli",
      "command": "codex",
      "mode": "stdin",
      "priority": 30
    }
  }
}
```

## Endpoints & Routing

The old **Providers** page is now **Endpoints & Routing**. It owns project-specific enable/disable state, priority, health, and preferred routes for:

- default work;
- critic review;
- validator review;
- tiny, small, medium, and large tasks.

Existing keys such as `defaultProvider`, `criticProvider`, `validatorProvider`, and `providerBySize` remain valid for compatibility. Their values now mean **preferred first endpoint**, not “this endpoint or fail.”

An explicit operator `-Provider <name>` override remains strict and does not silently select another endpoint.

## Failover and cooldowns

Ordinary routed work builds an eligible candidate list. The preferred endpoint is tried first. For API endpoints, StatefulClanker next prefers another configured connection exposing the **same model** before changing models, then continues through project endpoint priority.

Failures are normalized into routing classes including:

- `rate_limited`;
- `capacity`;
- `timeout`;
- `server_error`;
- `auth`;
- `model_unavailable`;
- `context_too_large`;
- `bad_request`;
- `unknown`.

Rate limits, capacity errors, transport failures, server failures, and temporarily unavailable models can fail over to another eligible endpoint. Bad requests and context-size failures are not sprayed across every service.

Endpoint and shared-connection health is durable at:

```text
.statefulclanker\routing\health.json
```

A rate limit on one credentialed service connection cools that connection rather than repeatedly hammering every model attached to it. Server-provided retry timing is used when recognizable; otherwise StatefulClanker applies bounded cooldowns.

A successful request clears the endpoint's circuit state. Expired cooldowns naturally become eligible again.

If all eligible routes are unavailable, the task is blocked as an **inference-routing/infrastructure condition** rather than being misclassified as implementation rework. Critic and validator outages follow the same rule.

## Direct API worker harness

API endpoints use StatefulClanker's bounded inner coding/tool loop above the same Current Human Directives, reconciled Intent, task graph, freshness, critic/validator, and event machinery used by CLI endpoints.

The implemented transport is OpenAI-compatible `/chat/completions`. The effective API request combines:

- machine Connection transport/authentication;
- project Endpoint model/tool-mode overrides.

This lets one machine connection safely expose many project models without duplicating credentials.

Built-in worker capabilities include file read/search/write/replace, bounded PowerShell execution, git diff, read-only Intent inspection, and finish. External MCP capabilities remain governed by the existing worker capability policy.

## Free-source presets

The preset catalog intentionally distinguishes ongoing free allocations from trials.

As of 2026-09-18 the packaged presets include free or limited-free options such as OpenRouter's free-model pool, GroqCloud free developer limits, the Gemini API free tier, Cloudflare Workers AI's daily free allocation, Mistral Free mode/Labs models, Hugging Face's small monthly inference credit, NVIDIA's developer prototype endpoints, plus entirely local Ollama/LM Studio/vLLM.

Cerebras is packaged for convenience but labeled as **trial credit**, not an ongoing free tier. Free allocations and model catalogs are external policy and can change; live connection/model discovery is therefore authoritative over documentation snapshots.

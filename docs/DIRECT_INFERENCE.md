# Direct inference, connections, endpoints, and routing

StatefulClanker separates machine access from project routing.

## Connections

A **Connection** is machine-local access to an inference service. It stores the service adapter, base URL, authentication, extra headers, health, and the last discovered model catalog in:

```text
%LOCALAPPDATA%\StatefulClanker\connections.json
```

Secrets are DPAPI-encrypted for the current Windows user or referenced by environment variable. Projects never copy API keys.

The Windows **Connections** page provides presets for OpenRouter, GroqCloud, Gemini / AI Studio, Cloudflare Workers AI, Mistral, Hugging Face Inference Providers, NVIDIA NIM, Cohere, Kilo AI Gateway, Vercel AI Gateway, Cerebras, Ollama, LM Studio, vLLM, and arbitrary OpenAI-compatible services.

Adding or editing a connection is validation-first:

1. choose a service preset;
2. follow the displayed provider-specific setup instructions;
3. enter the account/key details;
4. select **Test & discover**;
5. StatefulClanker authenticates against the API and retrieves its live model catalog;
6. Save is enabled only after successful discovery.

The discovered catalog is cached only as convenience metadata. **Test & refresh** re-queries the service. This replaces the former hardcoded OpenRouter free-model snapshot.

## Project target pool

Connections are machine-local credentials/transports plus their last discovered live model catalogs. The project does **not** copy credentials or every discovered model into project configuration.

Instead, the active project owns a small workhorse table at:

```text
.statefulclanker\routing\target-pool.json
```

Each target row names a machine connection + discovered model and records operational metadata such as tool support, context length, current free/local status, source, rationale, and the date Clanker last researched it. The Connections page can toggle individual discovered models into this table or conservatively seed likely free/local workhorses.

The table is also exposed to the conversational Clanker through `connection_catalog`, `target_pool_list`, `target_pool_upsert`, and `target_pool_remove`. Credentials and custom auth headers are never returned by those tools.

## Automatic routing

Normal worker, critic, and validator calls all draw from the same enabled target pool. There are no permanent model roles and no task-size pins. Healthy rows are selected with a durable pseudo-round-robin cursor so parallel dispatch naturally spreads work across the available pool instead of repeatedly picking the first model.

An explicit operator `-Provider <name>` override remains strict as a debugging/diagnostic escape hatch. It is not normal plan metadata.

Projects created before the target-pool design can still run: if the target pool is empty, enabled legacy `providers` entries are treated as a compatibility fallback. Their old default/critic/validator/size/priority fields do not influence normal automatic selection.

## Failover and health

Route health remains durable under:

```text
.statefulclanker\routing\health.json
```

Endpoint/model health and shared connection health are separate. A connection-scoped failure can remove every child model on that credential/service from eligibility without rediscovering the same 429 on each model. Model-specific capacity/unavailability can cool only that target.

Free inference is expected to be flaky. Routing failures are infrastructure telemetry and should preferentially rotate to another healthy target rather than changing task semantics.

**Route Doctor** probes failed health domains rather than every child endpoint. It honors provider Retry-After/reset timing when available. Without an explicit reset, account/rate-limit failures probe conservatively at roughly 30m -> 1h -> 2h -> 4h -> 6h, while transport/server failures start at 5m -> 15m -> 30m -> 1h -> 2h. Auth failures are quarantined much longer and are cleared immediately when the stored connection configuration/credential fingerprint changes. An expired cooldown is not enough to return a route to production: a successful tiny probe must recover the circuit first.

Failures inherit downward: an endpoint/model circuit suppresses one target row; a connection/account circuit suppresses every model using that connection; and corroborated transport/server failures on two independent connections to the same service can suppress that service until recovery. Account-level 429s do not automatically poison an independent credential for the same service.

## Direct API worker harness

API endpoints use StatefulClanker's bounded inner coding/tool loop above the same Current Human Directives, reconciled Intent, task graph, freshness, critic/validator, and event machinery used by CLI endpoints.

The implemented transport is OpenAI-compatible `/chat/completions`. The effective API request combines:

- machine Connection transport/authentication;
- the selected project target-pool model/tool-mode row.

This lets one machine connection safely expose many target-pool models without duplicating credentials.

Built-in worker capabilities include file read/search/write/replace, bounded PowerShell execution, git diff, read-only Intent inspection, and finish. External MCP capabilities remain governed by the existing worker capability policy.

## Free-source presets

The preset catalog intentionally distinguishes ongoing free allocations from trials.

As of 2026-09-18 the packaged presets include free or limited-free options such as OpenRouter's free-model pool, GroqCloud free developer limits, the Gemini API free tier, Cloudflare Workers AI's daily free allocation, Mistral Free mode/Labs models, Hugging Face's small monthly inference credit, Cohere evaluation keys, Kilo's anonymous/free-model gateway, Vercel AI Gateway's monthly included credit, NVIDIA's developer prototype endpoints, plus entirely local Ollama/LM Studio/vLLM.

Cerebras is packaged for convenience but labeled as **trial credit**, not an ongoing free tier. Free allocations and model catalogs are external policy and can change; live connection/model discovery is therefore authoritative over documentation snapshots.

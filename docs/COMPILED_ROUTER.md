# Compiled Router and Endpoint Monitor

StatefulClanker's routing authority is moving out of per-dispatch PowerShell state and into a small machine-wide .NET service.

## Responsibility boundary

`StatefulClanker.Router` owns scarce inference capacity:

- the machine endpoint catalog and connection metadata,
- health state at endpoint, connection, and service scope,
- health-aware round-robin ordering,
- one active lease per exact provider/model endpoint,
- durable lease recovery across router restarts,
- dead-worker lease reclamation,
- cooldown and quarantine state,
- rate/reset parsing,
- connection configuration fingerprints,
- active recovery monitoring,
- preferred worker-session route affinity with safe migration,
- and the live routing snapshot used by the Overview page.

The router also owns inference protocol execution through its provider adapters. PowerShell owns worker tools and durable transcript/session semantics and submits normalized inference requests to the router.

Successful inference responses are read completely before adapter parsing. Only diagnostic excerpts are bounded (4,096 characters); truncating the parsing input would corrupt valid large content or tool arguments. A genuinely malformed response is a request-scoped adapter diagnosis and does not by itself quarantine a provider.

Worker-session endpoint pins are advisory preferences. When a remembered endpoint is no longer permitted or eligible, routing may select another compatible endpoint inside the current project allowlist. Explicit operator endpoint overrides remain strict and fail if excluded; connection constraints remain enforced. Missing or empty project allowlists impose no additional endpoint restriction, and a singleton allowlist is handled as an array.

Worker sessions retain their persisted tool protocol when resumed. Text mode executes authorized tools through JSON commands and can run on native-capable models too. Native transcripts require native-tool endpoints; if none is available, routing defers rather than changing the transcript protocol. A catalog entry with `supportsTools: false` therefore does not exclude it from text-mode workers.

OpenAI-compatible requests omit absent optional tool fields instead of emitting null. Actual assistant tool calls and tool-result identifiers remain present, and nullable assistant content is preserved.

Endpoint diagnostics allow the provider's 45-second response budget plus IPC overhead. Daemon startup retries apply only before a pipe connection is established; a failure after connection is returned to the caller without replaying the submitted request. `ping` also contacts the daemon and is not a stateless executable check.

MCP may itself be hosted by Windows PowerShell, but harness child processes require PowerShell 7 or newer. The MCP bridge resolves a supported `pwsh` executable instead of inheriting a Windows PowerShell 5.1 host.

## Machine state

By default the router uses:

```
%LOCALAPPDATA%\StatefulClanker
```

and shares the existing:

- `endpoints.json`
- `connections.json`
- `routing/health.json`
- `routing/round-robin.json`

It adds:

- `routing/leases.json`

`SC_ROUTER_ROOT` may override the root for testing.

Router state and pipe identities normalize absolute paths, separators, trailing separators, and Windows case aliases. The default machine root retains its existing pipe identity. Clients using a custom root should be updated together and their daemons restarted when adopting this normalization.

## Endpoint identity and concurrency

An endpoint is one exact **connection + model** pair.

The router issues at most one active lease for an endpoint. Multiple models under the same provider credential may run concurrently if each model is represented as its own enabled endpoint and the provider supports that behavior.

Leases include the owning worker PID and worker process start time. They are persisted before the route is returned to a worker.

A router restart therefore does not make an in-flight endpoint look free. The restarted daemon restores the lease. Conversely, if the owning worker process dies, the monitor reclaims the lease without waiting for a long timeout.

For process-owned leases, worker identity is authoritative even if a nominal lease TTL elapses during unusually long inference. Process start time prevents a reused Windows PID from validating a stale lease.

## Health scope

Failures intentionally poison the smallest justified scope:

| Failure | Scope | Behavior |
| --- | --- | --- |
| HTTP 429 / rate limit / quota window | endpoint | Cool only that provider/model endpoint. Sibling models stay eligible. |
| capacity / model unavailable | endpoint | Retire the affected model temporarily. |
| auth / permission / configuration | connection | Quarantine every endpoint using that credential/config until configuration changes. |
| billing exhausted | connection | Cool the credential and periodically allow a real request to test recovery. |
| timeout / server error | connection initially | Back off the connection. Independent corroborating connection failures may degrade the provider service. |
| request/session incompatibility / malformed inference response | request | Do not poison endpoint health. |

A service-wide outage requires corroborating evidence. A 401, billing failure, model error, or other credential-specific failure from a service probe is **not** treated as evidence that every independent account on that provider is down.

## Monitoring and recovery

The daemon monitor:

- reclaims dead-worker leases,
- clears hard connection quarantine when its configuration fingerprint changes,
- re-admits endpoint quota/capacity cooldowns when their known/inferred window expires,
- probes due connection/service failures through their models endpoint when an active probe is meaningful,
- and keeps the machine routing snapshot current.

For rate limits and billing windows, the first real inference after re-admission remains the authoritative probe. This avoids spending scarce free quota on synthetic health requests.

## Quota intelligence

The monitor also runs a separate, low-rate quota-observation loop. It samples at most one due connection at a time, independently of lease recovery and routing-health work. Probe cadence is adaptive: providers that return useful quota telemetry stay relatively warm, while quota-silent control planes are backed off substantially. A slow or offline metadata endpoint therefore cannot stall worker lease cleanup or route recovery.

The sampler prefers requests that do not consume inference and resolves them through a provider probe catalog:

- OpenRouter uses authenticated `/api/v1/key` metadata for key budget/reset cadence.
- Cohere uses its dedicated `POST /v1/check-api-key` endpoint for credential health.
- Groq, Cerebras, Anthropic, Gemini, Cloudflare, Kilo and most compatible services use their model/catalog endpoint and harvest quota/reset headers when present.
- Gemini and Cloudflare also contribute documented deterministic daily reset rules even when the control-plane response does not report a counter.
- Kilo contributes its published free-model request limit as rule telemetry without pretending a rolling-window reset timestamp is known.
- Mistral uses the ordinary model catalog with the normal inference key; richer Admin API usage/rate-limit endpoints require a separate Admin API key and therefore are not silently queried with the workhorse credential.
- Local Ollama, LM Studio and vLLM connections are not periodically quota-probed.
- Providers known to be retired are excluded from routing rather than tested by inference.

Provider feedback is normalized into a `QuotaObservation` stored in `routing/health.json`. One observation may contain multiple simultaneous `QuotaWindow` records, so request/day, token/minute, account-budget, and provider-allocation limits are not collapsed into one misleading counter.

The normalized state includes:

- availability/exhaustion status,
- observed time,
- independent quota windows with their own units, remaining/limit values, and reset times,
- a backward-compatible summary limiter,
- next actionable inference time,
- evidence source,
- and confidence (`reported`, `derived`, or `inferred`).

The generic parser understands common provider forms including `Retry-After`, standard `RateLimit` fields, `X-RateLimit-*`, Anthropic request/token reset headers, epoch and RFC3339 timestamps, compact durations such as `2m59.56s`, and retry hints embedded in JSON error bodies.

Actual inference failures are authoritative for scheduling. If an inference 429 reports an exact retry/reset time, that time replaces generic exponential backoff for the affected endpoint. `Retry-After` is treated as the strongest first instruction when several equally authoritative timers are supplied.

Background metadata probes are deliberately weaker. Their observations are tagged `probe:...` and are shown that way in the **Quota / reset** column of **Endpoints & Routing**. A model-list endpoint may have a different bucket from inference, so a probe-reported zero balance or metadata 429 does not by itself disable an otherwise healthy inference endpoint. Authentication, permission, or configuration failures discovered by a probe may quarantine the connection because those are credential facts rather than quota guesses.

The endpoint table prefers endpoint-specific inference observations and falls back to connection-level probe telemetry. Examples are `7/30 · reset 14:32:10`, `exhausted · reset 00:00:00`, or `probe 7/30 · reset 14:32:10`.

## IPC

The local service uses a machine-root-specific named pipe and newline-delimited JSON requests.

Current operations:

- `ping`
- `snapshot`
- `acquire`
- `heartbeat`
- `release`
- `success`
- `failure`

The first PowerShell router client call starts the daemon automatically if it is not already running.

## Routing authority and explicit compatibility backends

The compiled router is the sole authority for automatic endpoint selection, leases, health, cooldowns, and round-robin state. If it cannot be contacted or started, automatic dispatch fails visibly; it does not switch to a second routing implementation.

Project-local CLI providers remain available only when explicitly requested as compatibility/debug backends. They do not participate in automatic endpoint routing and are never an automatic fallback.

`STATEFULCLANKER_DISABLE_COMPILED_ROUTER=1` disables automatic compiled routing for diagnosis; it does not enable a legacy router.

## Packaging

### Inference validation and tool output recovery

Shell diagnostics can use `infer --request-file request.json`. Tool definitions use the normalized shape `{ "type": "function", "function": { "name": "read_file", "parameters": { "type": "object", "properties": { "path": { "type": "string" } } } } }`. Flat definitions are rejected before IPC with `INVALID_INFERENCE_REQUEST`; malformed files receive the same structured diagnosis. Text-mode clients may omit tools or send `tools: null` for compatibility.

Corrupt saved tool calls receive `CORRUPT_INPUT_TOOL_CALL` with class `corrupt_input` before any route acquisition or provider request. They are never retried or attributed to an endpoint. Repair or replace that session before retrying it.

Malformed provider tool calls retain the `INVALID_TOOL_ARGUMENTS` reason code but use class `provider_tool_output_invalid` and endpoint scope. The router rejects the entire invalid response without executing, repairing, or persisting its tool calls. It permits one same-endpoint retry within the shared timeout and existing three-HTTP-attempt cap, then may fail over within the caller's allowed routes and route-attempt limit. Exact endpoints and strict pins never migrate.

Each observed malformed tool response increments the endpoint's `toolOutputFailures` and `consecutiveToolOutputFailures`, records `lastToolOutputFailure`, and applies a temporary cooldown of 60, 120, 240, 480, then at most 900 seconds. A successful inference clears the streak but retains cumulative history. Metadata probes do not clear the streak. Both `health.json` and route snapshots expose these counters; snapshot `quality` remains visible when an endpoint is healthy again. Usage and response evidence remain attached to every HTTP attempt, including failed retries.

Build and test updates outside the live installation. A new client executable can still contact an old daemon because the named pipe is keyed by machine state root, not executable path; isolated tests must use a temporary `SC_ROUTER_ROOT`.

For deployment, pause dispatch across affected projects and wait for active inference and worker leases to drain. Back up the router and changed harness/MCP files, stop the idle daemon, replace files, and verify the new daemon PID and artifact hash. Restart MCP and any harness process that already loaded changed PowerShell functions. Embedded Pi can recreate a stopped MCP child on its next tool call without discarding its persisted conversation. Preserve existing project holds and pause state; deployment is not permission to resume tasks. Keep the old file bundle for rollback.

The Windows installer publishes `StatefulClanker.Router.exe` as a self-contained win-x64 binary under:

```
{app}\router\
```

The tray references the router IPC types and asks the live daemon for the Overview's **Next Endpoint In Queue** readout. If the service is not active, the UI falls back to the previous file-based predictor.

## Automatic free-capacity lifecycle

The router treats the user's configured connections as the complete trust boundary. It does not discover or add new providers on its own.

A background free-capacity manager refreshes the live model catalog for configured connections and automatically maintains only endpoints whose zero-cost status can be positively established. Auto-managed endpoints carry lifecycle metadata in `endpoints.json` and discovery inventory is persisted in `routing/free-capacity.json`.

Safety rules:

- positive live pricing immediately retires an auto-managed endpoint,
- unknown cost never enters the automatic free pool,
- two consecutive successful catalog misses retire a disappeared model,
- a reappearing confirmed-free model returns automatically,
- manually-created endpoints are never deleted or rewritten by the manager,
- disabling/removing an auto-managed endpoint becomes a persistent operator suppression,
- obvious embedding, reranking, speech, media, safety and other specialist models are excluded from the workhorse pool.

Current high-confidence automatic sources include live zero-price/`isFree` metadata, explicit free route identifiers such as `:free`, `-free` and `auto:free`, curated free gateways, and local inference. NVIDIA hosted NIM/API Catalog entries are tracked separately as `trial_free` capacity because NVIDIA describes those hosted endpoints as trial/evaluation capacity.

Sparse or account-dependent catalogs remain conservative. For example, OpenCode Zen can safely contribute explicit `-free` model IDs, while OpenCode GO subscription models are not treated as $0. Gemini and Cloudflare catalogs are not blanket-classified free merely because those providers offer a free tier; existing manually selected endpoints remain untouched and continue to benefit from quota/health monitoring.

Pollinations uses its rich public text-model catalog for pricing/capabilities and its authenticated `/account/key` endpoint for pollen-budget telemetry without generation. It will automatically contribute models only if the live catalog actually proves zero price.

## Direction

This service is the home for quota-aware routing intelligence. The current implementation actively probes provider control planes, learns reported reset windows and remaining counters, retains simultaneous quota buckets, and applies documented provider reset rules without changing task semantics or provider execution code. Future work can add optional secondary credentials for admin-only usage APIs, historical throughput/error scoring, and richer prediction while keeping reported facts distinct from inferred availability.

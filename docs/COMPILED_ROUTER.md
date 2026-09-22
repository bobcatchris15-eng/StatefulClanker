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

It does **not** own inference protocol execution yet. Existing PowerShell provider adapters still issue the actual model request and maintain worker transcript/session semantics. PowerShell asks the compiled router for a lease, invokes the selected provider, then reports success or failure back to the router.

This deliberately creates a strangler boundary: routing can move to compiled code without rewriting every already-working provider adapter at once.

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
| capacity / model unavailable / malformed protocol reply | endpoint | Retire the affected model temporarily. |
| auth / permission / configuration | connection | Quarantine every endpoint using that credential/config until configuration changes. |
| billing exhausted | connection | Cool the credential until the known/provider-policy window expires; do not send a synthetic inference probe. |
| timeout / server error | connection initially | Back off the connection. Independent corroborating connection failures may degrade the provider service. |
| request/session incompatibility | request | Do not poison endpoint health. |

A service-wide outage requires corroborating evidence. A 401, billing failure, model error, or other credential-specific failure from a service probe is **not** treated as evidence that every independent account on that provider is down.

## Monitoring and recovery

The daemon monitor:

- reclaims dead-worker leases,
- clears hard connection quarantine when its configuration fingerprint changes,
- re-admits endpoint quota/capacity cooldowns when their known/inferred window expires,
- probes due connection/service failures only through non-inference read/account endpoints,
- advances documented quota windows locally without network traffic,
- and keeps the machine routing snapshot current.

**Monitoring never spends inference.** A route whose quota window expires simply becomes eligible for the next piece of real work. That real request may confirm the bucket reopened, but the router never manufactures a prompt solely to test it. The legacy PowerShell Route Doctor follows the same rule and uses GET-only metadata/account probing.

## Quota intelligence

The monitor also runs a separate, low-rate quota-observation loop. It samples at most one due connection at a time (normally no more than once every five minutes per connection), independently of lease recovery and routing-health work. A slow or offline metadata endpoint therefore cannot stall worker lease cleanup or route recovery.

The sampler uses only requests that do not consume inference:

- the connection's model/catalog endpoint by default,
- provider-specific account/limit metadata when a useful endpoint is known (for example OpenRouter's authenticated key metadata),
- and no periodic probe for local Ollama, LM Studio, or vLLM connections.

Provider feedback and deterministic provider policy are normalized into a `QuotaObservation` stored in `routing/health.json`:

- availability/exhaustion status,
- observed time,
- remaining and limit values when reported,
- limiter type when identifiable,
- observed reset time,
- next actionable inference time,
- deterministic window reset/cadence when documented,
- evidence source,
- applicability (`inference`, `metadata`, or `account-budget`),
- and confidence (`reported`, `derived`, `inferred`, or documented policy metadata).

The generic parser understands common provider forms including `Retry-After`, standard `RateLimit` fields, `X-RateLimit-*`, Anthropic request/token reset headers, epoch and RFC3339 timestamps, compact durations such as `2m59.56s`, and retry hints embedded in JSON error bodies.

Actual inference failures are authoritative for scheduling. If an inference 429 reports an exact retry/reset time, that time replaces generic exponential backoff for the affected endpoint. `Retry-After` is treated as the strongest first instruction when several equally authoritative timers are supplied.

Documented fixed windows are advanced programmatically. Current built-in policies include:

- **Cloudflare Workers AI**: the 10,000-Neuron free allocation resets daily at **00:00 UTC**.
- **Gemini API**: requests-per-day quotas reset at **midnight Pacific**.
- **OpenRouter**: the current-key metadata endpoint provides account budget/limit/reset information without model inference; its configured daily/weekly/monthly key-limit cadence is tracked separately from free-model request throttling.

These clocks are recalculated locally. They do not require periodic model calls, and they are kept separate from metadata-endpoint rate limits.

Background metadata probes are deliberately weaker. Their observations are tagged `probe:...` and are shown that way in the **Quota / reset** column of **Endpoints & Routing**. A model-list endpoint may have a different bucket from inference, so a probe-reported zero balance or metadata 429 does not by itself disable an otherwise healthy inference endpoint. Authentication, permission, or configuration failures discovered by a probe may quarantine the connection because those are credential facts rather than quota guesses.

The endpoint table prefers endpoint-specific inference observations and falls back to connection-level probe telemetry. Examples are `7/30 · reset 14:32:10`, `exhausted · reset 00:00:00`, `metadata 7/30 · reset 14:32:10`, or `window 00:00:00`. Metadata/account counters and inference-window clocks are intentionally labeled separately.

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

## Compatibility and fallback

Normal automatic dispatch uses the compiled router when its executable is available.

Explicit operator/provider overrides remain on the existing strict PowerShell route path.

If the compiled router cannot be contacted or started, dispatch records a `routing.compiled_router_fallback` event and uses the legacy PowerShell router for that call. This keeps source checkouts and recovery paths usable while the migration is in progress.

Set:

```
STATEFULCLANKER_DISABLE_COMPILED_ROUTER=1
```

to force legacy routing for diagnosis.

## Packaging

The Windows installer publishes `StatefulClanker.Router.exe` as a self-contained win-x64 binary under:

```
{app}\router\
```

The tray references the router IPC types and asks the live daemon for the Overview's **Next Endpoint In Queue** readout. If the service is not active, the UI falls back to the previous file-based predictor.

## Direction

This service is the home for quota-aware routing intelligence. The current implementation learns provider-reported reset windows and remaining counters without changing task semantics or provider execution code. Future work can add provider-specific budget endpoints, historical throughput/error scoring, and richer prediction while keeping reported facts distinct from inferred availability.

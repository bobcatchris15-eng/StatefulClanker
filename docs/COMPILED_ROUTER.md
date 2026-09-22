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
| billing exhausted | connection | Cool the credential and periodically allow a real request to test recovery. |
| timeout / server error | connection initially | Back off the connection. Independent corroborating connection failures may degrade the provider service. |
| request/session incompatibility | request | Do not poison endpoint health. |

A service-wide outage requires corroborating evidence. A 401, billing failure, model error, or other credential-specific failure from a service probe is **not** treated as evidence that every independent account on that provider is down.

## Monitoring and recovery

The daemon monitor:

- reclaims dead-worker leases,
- clears hard connection quarantine when its configuration fingerprint changes,
- re-admits endpoint quota/capacity cooldowns when their known/inferred window expires,
- probes due connection/service failures through their models endpoint when an active probe is meaningful,
- and keeps the machine routing snapshot current.

For rate limits and billing windows, the first real inference after re-admission remains the authoritative probe. This avoids spending scarce free quota on synthetic health requests.

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

This service is the intended home for future quota-aware routing intelligence. Provider-specific reset semantics, free-quota budgets, historical throughput/error scoring, and richer endpoint monitoring can be added here without changing task semantics or provider execution code.

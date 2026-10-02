# StatefulClanker router integration for isolated model research

Status: read-only source mapping, 2026-10-01. No router command, endpoint probe, or inference request was run for this note. Provider/model discovery is owned by the parent research task; this document does not nominate or test a target.

## Structural path and bounded conclusion

The existing router has a concrete exact-endpoint completion entrypoint and its provider credentials remain in the current-user machine store:

```text
router.exe infer --endpoint pool:<endpoint-id> --request-file <research-request.json>
        │
        ├─ Program.ParseRequest reads a <= 4 MiB NormalizedInferenceRequest
        ├─ Program.SendWithDaemonAsync sends the RouterRequest over the machine-root named pipe
        ├─ RouterPipeServer handles op="infer"
        ├─ InferenceGateway.InferAsync sees endpoint != null → InferExactAsync
        ├─ RouterEngine.FindRoute resolves pool:<endpoint-id> to one enabled workhorse catalog row
        ├─ ProviderAdapterRegistry selects OpenAI Chat, Anthropic Messages, or Gemini Native
        ├─ ConnectionCredentialResolver resolves the configured key from environment or current-user DPAPI
        └─ adapter builds the provider request; HttpClient sends it
```

The explicit endpoint bypasses route acquisition, round-robin, and migration to another model. It is therefore pinned at the *route* level. It is not a single-HTTP-attempt API: `InferExactAsync` calls the ordinary `ExecuteAsync` with diagnostic mode off, which can issue as many as three provider HTTP attempts on the same endpoint after an output-budget exhaustion or invalid tool response. The result returns per-attempt diagnosis, usage, token cap, and a sanitized response excerpt, but not the complete HTTP request/response body for each retry. Thus the current CLI route is useful for bounded exploratory calls where same-endpoint retry is acceptable; it does not meet a controlled-pilot requirement of exactly one recorded provider attempt with complete raw transport evidence.

For a controlled campaign requiring one attempt per slot, use a research-only wrapper around the router's public adapter types instead of changing the live router. It can load the chosen `ConnectionProfile` and `EndpointEntry`, resolve DPAPI in memory, call the selected adapter's `BuildRequest` and `ParseSuccess`, and write exact request/response bytes into the research run directory. The wrapper must make exactly one `HttpClient.SendAsync`, disable redirects, never retry or select a second route, redact secrets from logs, and record HTTP/parse failures as consumed attempts. This reuses the configured connection and matching protocol implementation without altering machine health state. This note maps that option; it does not implement or launch it.

## Machine data, isolation, and credentials

By default, the router reads machine-wide configuration from:

```text
%LOCALAPPDATA%\StatefulClanker\connections.json
%LOCALAPPDATA%\StatefulClanker\endpoints.json
```

`RouterStore` accepts `SC_ROUTER_ROOT` as an override. Its endpoint rows map an ID to a connection ID and model ID; the router exposes eligible rows as `pool:<id>`. `RouterEngine.Routes()` includes only rows with `enabled=true` and `workhorse=true`. The root also contains routing health, round-robin, leases, and free-capacity state.

An explicit `--endpoint 'pool:<id>'` is strict about which catalog row executes: it bypasses the automatic target-pool allowlist/selection loop and never migrates to another route. The selected endpoint ID and model ID must therefore be verified against the parent's current free-target evidence before dispatch. The nullable `free` flag and lifecycle fields in `endpoints.json` are useful metadata but are not, alone, proof of current provider pricing or quota.

Keep the research run artifacts under a distinct folder such as:

```text
research\external-cognition\router\runs\<run-id>\
```

For a live-router call, leave `SC_ROUTER_ROOT` unset so the already configured current-user machine root and its connections are used. Do not copy `connections.json`, API keys, protected values, or custom auth headers into the research folder. `apiKeyProtected` is DPAPI data scoped to the current Windows user; `ConnectionCredentialResolver` unprotects it in process memory. The resolver also supports an environment-variable reference. Do not print either credential or serialize the resolved key into a request artifact. A separate router root has no live connection profiles by default; setting it does not give it access to machine credentials and starting a daemon for it would create another router instance.

The exact CLI request also affects live router state: a successful exact request marks the endpoint healthy, while transport/provider failures may update endpoint/connection health and append routing signals. It bypasses a lease, but the router's normal background daemon can still maintain leases, health, and capacity. For no production-state changes, use the research-only direct-adapter wrapper described above with read-only access to the selected non-secret endpoint/connection metadata, while resolving the DPAPI key only from the live machine file and never copying it. Keep any required profile in memory, omit auth headers and secrets from receipts, and write artifacts only under the research run folder. That wrapper should not instantiate `RouterEngine`, call `RouterStore` mutation methods, or start the daemon.

## Finding and pinning the executable

`lib/StatefulClanker.RouterClient.ps1` defines executable discovery. If `STATEFULCLANKER_ROUTER_EXE` names an existing file, that exact path wins. Otherwise it checks these locations relative to `StatefulClankerHome` (the repository/install root):

```text
router\StatefulClanker.Router.exe
install\router-publish\StatefulClanker.Router.exe
src\StatefulClanker.Router\bin\Release\net8.0-windows\win-x64\publish\StatefulClanker.Router.exe
src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe
```

The installer publishes the self-contained executable under `{app}\router\`. For reproducibility, resolve the path once, write that full path and its SHA-256 into the run manifest, and invoke that pinned executable directly. Do not infer the current route from `snapshot` for a live research selection: the parent discovery step should choose an explicit endpoint ID. Also, `snapshot` and `ping` are CLI operations that can contact or start the daemon, so do not use them as a “harmless check” when the constraint is to avoid starting a resident router.

`Program.SendWithDaemonAsync` automatically launches a daemon when the named pipe is unavailable. It has a mutex guard, but callers cannot use its normal CLI fallback as a guarantee that no process will be started. To reuse only an already-running daemon, the operator must first establish that the correct machine-root pipe is already present; then perform the pinned call. Never invoke `infer` for this reuse path if no daemon was confirmed running. A direct-adapter research wrapper avoids this autostart behavior entirely.

## Exact CLI contract (exploration only)

The CLI accepts a `RouterRequest` operation and parses inference JSON into `NormalizedInferenceRequest`. The request file must be UTF-8 JSON and at most 4 MiB. A minimal text-mode request is:

```json
{
  "messages": [
    {"role": "user", "content": "<one bounded research prompt>"}
  ],
  "tools": [],
  "toolMode": "text",
  "maxOutputTokens": 256,
  "temperature": 0,
  "timeoutSeconds": 120,
  "maxRouteAttempts": 1,
  "maxRouteWaitSeconds": 0
}
```

All fields are defined in `src/StatefulClanker.Router/Inference/InferenceModels.cs`. `messages` supports `system`, `developer`, `user`, `assistant`, and `tool`; the request validator checks roles and tool schemas. The OpenAI-compatible adapter sends `model`, `messages`, `max_tokens`, and `stream=false`, adding temperature only when present. A provider adapter may translate the same normalized request into its own native wire schema. The adapter clamps output tokens to 1–131072. The router clamps `timeoutSeconds` to 15–1800 seconds. `maxRouteAttempts` and `maxRouteWaitSeconds` control the automatic multi-route loop and do not disable same-endpoint retries in exact mode.

PowerShell invocation shape (do not paste a real prompt or request into a shared transcript if it contains sensitive study content):

```powershell
$router = '<full path pinned from executable discovery>'
$requestFile = '<absolute path to run directory>\request.json'
& $router infer --endpoint 'pool:<chosen-endpoint-id>' --request-file $requestFile
```

The required `--endpoint` is passed as `RouterRequest.endpoint`; `InferAsync` delegates it to `InferExactAsync`. `pool:<id>` is the snapshot/catalog route identity. The catalog ID without `pool:` is also accepted by `FindRoute`, but prefer the displayed `pool:<id>` form to make pinning explicit. No `--preferred`/`--strict-preferred` option is needed for this exact operation, and `allowedEndpoints` is not applied by `InferExactAsync`; the `--endpoint` identity is the pin.

The CLI prints one JSON `RouterResponse`. On a successful transport, `data` is a `NormalizedInferenceResult` containing `endpoint`, `connection`, `model`, `assistant`, `usage`, `diagnosis`, `routeAttempts`, and `inferenceAttempts`. `inferenceAttempts` lists actual same-endpoint HTTP tries with their output-token budget, normalized usage, diagnosis, and sanitized response evidence. The latest response evidence contains only allowlisted headers, provider request ID, status, duration, and a flattened excerpt capped at 4096 characters. It is not a full raw transcript. The request evidence intentionally contains URI, present-header names, protocol/tool mode and body-key names while redacting header values and message content.

## Attempt recording and retry/failover policy

For controlled research, make the per-slot record external to router logs and immutable before parsing:

1. Freeze the selected catalog row (`endpoint id`, `connection id`, `model id`, `free`/source evidence, and timestamp), executable full path/hash, request bytes/hash, and run/slot ID.
2. Record dispatch start/end timestamps, process exit code, outer `RouterResponse.ok/error`, returned `data.ok`, exact endpoint/connection/model, provider request ID, HTTP status, usage as reported (missing remains missing), diagnosis, and every `inferenceAttempts[]` entry.
3. Save the exact request file and returned stdout bytes in the run folder. Note that router stdout only includes normalized assistant output plus bounded/sanitized response excerpts; it cannot recover intermediate full HTTP bodies. Do not report it as complete provider transport evidence.
4. Count each entry in `inferenceAttempts` as a provider HTTP attempt. If one slot produces multiple entries, mark it multi-attempt and do not silently treat it as one sample. A pipe error after connection is ambiguous and should be recorded as an unknown-delivery slot, not automatically replayed.

The explicit `--endpoint` prevents migration to a different endpoint in `InferAsync`; it does not prevent up to two same-endpoint retries. Valid successful completions ordinarily return after one HTTP attempt. Budget-exhausted content can trigger a retry with a doubled output budget (capped at 16384 and the endpoint's known context remainder); invalid tool output can trigger one retry. The total same-endpoint attempts are capped at three under the request timeout. HTTP/transport failures return without trying another endpoint on the exact path, but can update live route health. Do not set `maxRouteAttempts=1` under the mistaken assumption that this disables `ExecuteAsync` retries.

For deterministic attempt-count accounting and complete request/response bytes, the recommended controlled-pilot contract is a matching direct-adapter helper with **one HTTP send per slot**, no retries, redirects disabled, no router `Snapshot`/health/lease mutation, fixed endpoint and model validation before send, and an append-only failure or response receipt after send. It must reuse `ConnectionCredentialResolver` only in memory and use the matching registered adapter rather than reimplementing provider auth. The source surfaces to reuse are `ProviderAdapterRegistry`, `ConnectionCredentialResolver`, `OpenAiChatAdapter`/the selected protocol adapter, `AdapterRequest`, and `NormalizedInferenceRequest` in `src/StatefulClanker.Router/Inference/`. Implementing or running this helper is outside this read-only mapping task.

## Source map

This dependency map was reconstructed from the current source and docs; there is no pre-existing Graphify graph in the workspace for the router.

| Concern | Source | Evidence/result |
|---|---|---|
| CLI parser/autostart | `src/StatefulClanker.Router/Program.cs` | `infer --endpoint --request-file`; daemon start fallback when named pipe connection fails |
| Pipe dispatch | `src/StatefulClanker.Router/RouterPipe.cs` | `op="infer"` dispatch; root-hashed pipe identity; connection-only retry boundary |
| Exact and automatic paths | `src/StatefulClanker.Router/Inference/InferenceGateway.cs` | `InferAsync` exact-endpoint branch, `InferExactAsync`, `ExecuteAsync` same-endpoint retries |
| Endpoint/connection lookup | `src/StatefulClanker.Router/RouterEngine.cs`, `RouterStore.cs`, `Models.cs` | enabled workhorse catalog route `pool:<id>`, machine-root config loading |
| Credential handling | `src/StatefulClanker.Router/Inference/ConnectionCredentialResolver.cs` | environment reference or current-user DPAPI unprotect; failures return null |
| Wire protocol | `src/StatefulClanker.Router/Inference/ProviderAdapterRegistry.cs`, `Inference/Adapters/*.cs` | registered provider-specific request/response mapping |
| Public contract | `src/StatefulClanker.Router/Inference/InferenceModels.cs`, `InferenceRequestValidator.cs` | normalized request/result and validation schema |
| Operator documentation | `docs/DIRECT_INFERENCE.md`, `docs/COMPILED_ROUTER.md`, `docs/SETUP.md` | machine connection/project target pool distinction, install layout, router behavior |

The main operational blockers for reusing the live router in a controlled pilot are same-endpoint internal retries, incomplete per-attempt raw HTTP evidence, daemon auto-start fallback, and durable health/signal side effects under the machine root. The exact pinned route is concrete and avoids automatic model failover, but these remaining behaviors need a separate research wrapper or an explicit acceptance of multi-attempt/sanitized evidence before it can serve as a one-slot/one-request measurement path.

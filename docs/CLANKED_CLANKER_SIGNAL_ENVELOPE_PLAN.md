# clankedClanker — addressed signal envelope migration plan

## Status

Branch: `clankedClanker`

Purpose: make addressed signals a **primary architectural mechanism** across worker execution and machine inference routing. Preserve the authority hierarchy, worktree isolation, freshness gates, and deterministic acceptance, but freely restructure modules whose present boundaries make the signal architecture awkward or duplicate responsibility.

This is not a compatibility-preservation exercise. Compatibility shims are temporary migration tools. The target branch should finish with clean ownership boundaries even when that means moving code, deleting wrapper layers, or replacing the current compiled-router/PowerShell split.

---

## 1. Problem statement

StatefulClanker already captures a great deal of useful state. The recurring failure mode is not primarily missing persistence; it is that useful state is represented in subsystem-specific forms and is not consistently delivered to the next decision-maker in a bounded, typed, fresh form.

Worker-side examples:

- dependency propagation still reduces prior work primarily to task metadata plus bounded raw `stdout`;
- retry feedback exists, but is a bespoke `latestFeedback` projection over validator/critic stdout rather than a general continuation mechanism;
- task-definition fields and definition-of-done material are not yet represented as one canonical compiled contract;
- recovery and prior-attempt evidence are spread across progress, runs, validations, proposals, checkpoints, events, and session metadata;
- retrieval health is observable after compilation, but a zero-item result is not yet a first-class expected-vs-actual health signal;
- cross-task findings have no conservative addressed handoff path.

Router-side examples:

- the current bridge now reports `success` and `failure`, which is good, but this is still a router-specific outcome channel;
- failure classification is partly inferred from text and then mapped to a health scope;
- execution/harness failures, provider failures, request failures, endpoint failures, and connection failures need harder separation;
- task-level routing diagnostics and router health projections remain separate concepts;
- pre-dispatch and no-route outcomes need the same durable accounting discipline as worker-started attempts.

The desired architecture is:

```
producer
  -> append typed immutable signal
  -> deterministic domain reducer
  -> durable projection
  -> compiler / scheduler / router reads projection
```

Workers and router share the **signal grammar**, not one giant shared reducer or runtime event bus.

---

## 2. Preserve these existing strengths

This branch must not weaken:

1. Human directive -> Intent -> plan -> task -> compiled packet -> disposable worker authority.
2. RPK remains non-authoritative candidate knowledge.
3. Sanitized-base worktree isolation.
4. Existing worker filesystem guard and deny-wins capability layering.
5. Task-definition hashing and dispatch/commit freshness gates.
6. Candidate preflight and deterministic acceptance.
7. Machine-local ownership of endpoint selection, leases, health, cooldowns, probes, credentials, and routing state. The current router process may be substantially restructured to make that ownership coherent.
8. Asynchronous workers: no synchronous worker chat, no shared write-lock protocol, no peer worktree browsing.
9. Existing receipts/events remain available for diagnostics during migration.

The migration should make information flow more explicit **without** making authority fuzzier.

---

## 3. Core primitive

Introduce one small shared schema conceptually named `SCSignalEnvelope`.

The PowerShell and C# representations do not need to be the same class or serializer implementation, but they must preserve the same semantic fields.

Minimum v1 shape:

```json
{
  "schemaVersion": 1,
  "id": "sig-...",
  "domain": "execution",
  "kind": "validator_rejection",
  "createdAt": "2026-09-28T00:00:00Z",

  "source": {
    "component": "validator",
    "taskId": "t-112",
    "runId": "run-...",
    "validationId": "validation-..."
  },

  "subject": {
    "type": "task",
    "id": "t-112"
  },

  "audience": [
    {
      "type": "task",
      "id": "t-112",
      "qualifier": "next_attempt"
    }
  ],

  "authority": "corrective",
  "scope": "task",

  "freshness": {
    "taskDefinitionHash": "...",
    "compilationId": null,
    "fileHashes": {},
    "expiresAt": null
  },

  "payload": {
    "reasonCode": "ACCEPTANCE_FAILED",
    "summary": "...",
    "evidenceRefs": []
  }
}
```

### 3.1 Required semantics

**domain**
- `execution`
- `routing`
- reserve `project` for later, but do not use it initially.

**authority**
- `observed`: raw fact emitted by deterministic machinery.
- `corrective`: validated failure/rejection that a retry must address.
- `advisory`: useful but non-authoritative deduction.
- `authoritative`: reserved for already-authoritative human/Intent/task-control facts; do not synthesize this from worker output.

**scope**
- execution: `attempt`, `task`, `path`, `project`.
- routing: `request`, `model`, `endpoint`, `connection`, `provider`, `harness`.

**freshness**
Freshness must be deterministic. A consumer may reject a signal because:
- task definition hash changed;
- target file hash changed;
- compilation/read-set no longer matches;
- explicit expiry elapsed;
- referenced entity no longer exists.

No model decides signal freshness.

### 3.2 Storage

Start append-only and boring.

Project execution signals:

```
.statefulclanker/signals/execution/YYYY-MM-DD.jsonl
```

Machine router signals:

```
%LOCALAPPDATA%/StatefulClanker/routing/signals/YYYY-MM-DD.jsonl
```

Add compact indexes/projections only after write correctness is proven. Do not introduce SQLite in phase 1.

### 3.3 Signal IDs and evidence refs

Every signal must have a stable id. Payloads should prefer refs to durable records over copying large blobs:

- `run:<id>`
- `validation:<id>`
- `proposal:<id>`
- `checkpoint:<id>`
- `compilation:<id>`
- `event:<id>`
- `routeAttempt:<id>`

Signals summarize; receipts remain the audit trail.

---

# 4. Migration strategy: center first, then move outward

The migration should proceed symmetrically:

```
WORKER SIDE                               ROUTER SIDE

existing receipts                        existing success/failure
      |                                         |
      v                                         v
[signal producers]                       [signal producers]
      |                                         |
      +----------> shared grammar <-------------+
                         |
                deterministic reducers
                    /          \
                   v            v
        execution projection   routing projection
                   |            |
                   v            v
          context compiler      acquire/scheduler
```

Do not flip producers and consumers simultaneously.

For every seam:

1. scaffold schema;
2. shadow-write signals while old behavior remains authoritative;
3. build projection/reducer;
4. compare projection with old behavior;
5. move one consumer to the projection;
6. keep compatibility fallback;
7. remove fallback only after tests and real runs show equivalence.

---


## 4.1 Target architecture — signals are the spine, not an add-on

The end state should be allowed to look materially different from current main.

In particular, split responsibilities explicitly:

```
PROJECT / EXECUTION PLANE
  task state
  worker lifecycle
  validation
  completion manifests
  execution signals
  execution reducer
  WorkerPacket compiler

MACHINE INFERENCE PLANE
  connection catalog + protected credentials
  provider adapter registry
  inference gateway
  endpoint diagnostic service
  routing signals
  routing health reducer
  lease/capacity scheduler
```

The PowerShell worker runtime should not remain the long-term owner of provider wire protocols merely because it owns the worker loop today.

### Router/inference target

Refactor the current compiled router into a machine-local inference service with clear internal components, e.g.:

```
StatefulClanker.Router
  Signals/
    SignalEnvelope.cs
    SignalStore.cs
  Routing/
    RouterEngine.cs
    RoutingHealthReducer.cs
    LeaseManager.cs
    FailurePolicy.cs
  Inference/
    InferenceGateway.cs
    InferenceRequest.cs
    InferenceResult.cs
    ProviderAdapterRegistry.cs
    Adapters/
      OpenAiChatAdapter.cs
      AnthropicMessagesAdapter.cs
      GeminiNativeAdapter.cs
      ...
  Diagnostics/
    EndpointTestService.cs
    DiagnosticSanitizer.cs
  Catalog/
    ConnectionStore / endpoint catalog / probe catalog
```

Names are illustrative. The ownership boundary is not:

- routing in C#;
- request serialization in PowerShell;
- provider diagnosis half in each.

The ownership boundary should be:

> the machine inference plane owns endpoint selection, credentials, provider adapters, transport, response normalization, quota observations, and routing health.

PowerShell owns task/worker orchestration and consumes normalized inference results.

### Production inference and endpoint testing must share the same path

Do not build a separate "test request" implementation.

Both should pass through:

```
connection + endpoint
   -> adapter registry
   -> adapter builds request
   -> common transport
   -> adapter parses response
   -> normalized inference result
   -> routing signal
```

Then `test_endpoint` is trustworthy because it exercises the exact code workers use.

### Migration permission

It is acceptable to:

- split `RouterEngine.cs`;
- move protocol/auth/request construction out of `StatefulClanker.WorkerRuntime.ps1`;
- replace `success`/`failure` with a single structured completion/outcome operation;
- replace wrapper-heavy compilation with explicit pipeline stages;
- change internal JSON schemas with branch-local migration code;
- delete compatibility machinery after its consumer has moved.

Do not retain an ugly boundary solely because current main already has tests around it.

---

# 5. Phase 0 — baseline and migration guardrails

## Goal

Create a branch baseline that tells us exactly what current `main` already does before envelope code changes behavior.

## Work

### 5.1 Record current behavior tests

Extend/add tests around:

- `Get-SCDependencySummary`
- `New-SCCompilation`
- `latestFeedback`
- retry after validator rejection
- candidate preflight -> proposal -> validation -> completion
- compiled router `acquire`
- compiled router `success`
- compiled router `failure`
- failure class -> scope -> cooldown
- no-route/acquire-deferred behavior
- attempt counting before and after dispatch
- worktree retrieval behavior

Likely homes:

- `tests/PacketCompilation.Tests.ps1`
- `tests/WorkerSession.Tests.ps1`
- `tests/RecoveryEvidence.Tests.ps1`
- `tests/RoutingAvailability.Tests.ps1`
- new `tests/SignalEnvelope.Tests.ps1`

### 5.2 Freeze compatibility fixtures

Create representative JSON fixtures for:
- completed dependency run;
- validator rejection;
- resumable worker retry;
- non-resumable retry;
- 429;
- 401;
- model 404;
- transport timeout;
- malformed provider response;
- internal/harness exception;
- acquire with no currently eligible route.

### 5.3 Explicitly verify current-main deltas from the audit

Current main already appears to contain:
- compiled-router `success` and `failure` calls from `StatefulClanker.CompiledRouting.ps1`;
- router `success`/`failure` pipe operations;
- `latestFeedback` projection in `StatefulClanker.Context.ps1`.

Treat those as migration inputs, not missing features.

## Exit criteria

- tests capture current behavior;
- no signal code changes decisions yet;
- branch can prove later migrations are equivalent or intentionally different.

---

# 6. Phase 1 — envelope scaffolding only

## Goal

Make signals writable/readable without using them for decisions.

## Worker-side files

Add a focused module, for example:

`lib/StatefulClanker.Signals.ps1`

Responsibilities only:

- `New-SCSignalEnvelope`
- `Write-SCSignal`
- `Read-SCSignals`
- `Test-SCSignalFreshness`
- `Get-SCSignalsForAudience`
- schema validation
- bounded payload validation
- evidence-ref helpers

Do **not** put task policy or compilation-specific logic in this module.

Wire module load order once in the root loader rather than adding another `New-SCCompilation` wrapper.

## Router-side files

Add small C# equivalents under `src/StatefulClanker.Router`, e.g.:

- `SignalEnvelope.cs`
- `SignalStore.cs`

The router signal store should be machine-local and append-only.

## Tests

- stable round-trip JSON;
- unknown fields tolerated for forward compatibility;
- malformed/missing required fields rejected;
- payload size bounded;
- signal append survives concurrent readers;
- freshness comparisons are deterministic.

## Exit criteria

Signals can be produced and queried, but nothing consumes them to alter behavior.

---

# 7. Phase 2 — worker shadow producers

## Goal

Convert existing durable worker outcomes into typed signals **in parallel** with the current receipts/events.

### 7.1 Validation/review producer

When a validation or critic verdict is persisted, shadow-write:

- `validation_passed`
- `validator_rejection`
- `critic_advisory`
- `review_gate_rejected`

Audience:
- same task;
- `next_attempt` for corrective failures.

Payload:
- verdict;
- structured reason codes where deterministic;
- short summary;
- evidence refs;
- never copy the full stdout if a ref exists.

### 7.2 Attempt/run producer

On worker run finalization:

- `attempt_completed`
- `attempt_failed`
- `context_requested`
- `candidate_material`
- `candidate_empty`

Payload should include:
- exit code;
- changed files if known;
- candidate checkpoint/preflight refs;
- context request refs;
- run ref.

### 7.3 Task completion manifest producer

Introduce a structured completion manifest adjacent to run/proposal persistence.

Minimum:

```json
{
  "schemaVersion": 1,
  "taskId": "t-104",
  "result": "completed",
  "changedFiles": [],
  "artifacts": [],
  "conclusions": [],
  "invariantsDiscovered": [],
  "warningsForSuccessor": [],
  "validation": {
    "verdict": "pass",
    "validationId": "..."
  }
}
```

For change tasks, `changedFiles` should be deterministic from git/preflight, not trusted from worker prose.

Worker-provided conclusions/warnings are advisory and must be explicitly tagged as such.

Shadow-write a `task_completion` signal pointing at the manifest.

### 7.4 Retrieval health producer

Fix and then instrument retrieval.

Current `Get-SCRetrievalPacket` skips any resolved file whose full path begins with `Get-SCDir`. Under per-task worktrees this can exclude legitimate worktree files if `Get-SCDir` and the worktree topology overlap.

Required changes:

1. distinguish the **project worktree root** from the **control-state root**;
2. forbid only actual control-state paths, not all worktree paths under a shared parent;
3. record selector resolution before exclusion;
4. add expected/actual retrieval health:
   - selector count;
   - selectors matched;
   - files included;
   - excluded-by-boundary count;
   - unmatched count;
5. emit `retrieval_anomaly` when selectors were provided but all useful retrieval collapsed to zero.

Do not make retrieval anomaly fatal yet.

## Exit criteria

Every important worker-side lifecycle outcome has a signal mirror, but old context compilation remains authoritative.

---

# 8. Phase 3 — execution signal reducer and projection

## Goal

Stop asking the context compiler to rediscover the lifecycle graph directly.

Add deterministic reducer(s), for example:

`lib/StatefulClanker.ExecutionProjection.ps1`

Input:
- current task;
- fresh signals addressed to that task;
- referenced durable receipts.

Output:

```json
{
  "schemaVersion": 1,
  "taskId": "t-112",

  "executionDiagnostics": {
    "attemptCount": 2,
    "dispatchAttempts": 2,
    "workerStarts": 2,
    "lastFailureReason": "...",
    "blockReason": "...",
    "latestVerdict": "needs_rework"
  },

  "correctiveFeedback": [],
  "dependencyKnowledge": [],
  "priorAttemptKnowledge": [],
  "retrievalHealth": {},
  "continuation": {}
}
```

### Reducer rules

- latest valid corrective signal supersedes older corrective signals of the same cause;
- advisory deductions never override task/Intent authority;
- stale signals are omitted, not summarized as current;
- multiple attempts remain attributable;
- reducer output is bounded and deterministic;
- raw model prose can appear only as bounded summary fields with evidence refs.

Persist the projection if useful, but make it rebuildable from signals + receipts.

## Shadow comparison

For several runs, compile both:
- legacy `latestFeedback` / attempt history / dependency summary;
- new execution projection.

Emit a diagnostic mismatch event; do not change worker prompt yet.

## Exit criteria

The projection reproduces all essential old continuation information and exposes additional structured state without changing task decisions.

---

# 9. Phase 4 — compile a canonical WorkerPacket from the projection

## Goal

Move the **consumer** side.

Refactor `New-SCCompilation` so it consumes the execution projection instead of reaching into each lifecycle store ad hoc.

### 9.1 Avoid adding another wrapper layer

`New-SCCompilation` is currently decorated by later-loaded modules including semantics/RPK/directive behavior. Do not solve this by adding another scriptblock-capture wrapper.

Prefer:
- keep one base packet compiler in `StatefulClanker.Context.ps1`;
- expose explicit extension hooks / enrichment functions if needed;
- progressively migrate existing wrappers toward calling named enrichment stages.

The signal migration should reduce load-order magic, not add to it.

### 9.2 Canonical packet shape

Target:

```
WorkerPacket
  identity
  projectAuthority
  taskContract
  definitionOfDone
  currentState
  dependencyKnowledge
  correctiveFeedback
  priorAttemptKnowledge
  relevantAdvisories
  executionDiagnostics
  retrieval
  capabilities
  sources/evidenceRefs
```

### 9.3 Project currently hidden task-definition fields

Ensure the packet includes, where present:

- `implications`
- `proofObligations`
- `parentTaskId`
- `retrieval`
- `evidence`
- `targetArtifacts`

If these fields participate in task-definition hashing, the worker should not be held to them while being unable to see them.

### 9.4 Canonical Definition of Done

Compile existing authoring fields into:

```json
{
  "definitionOfDone": {
    "targetArtifacts": [],
    "mechanicalChecks": [],
    "semanticAcceptance": [],
    "proofObligations": []
  }
}
```

Do not immediately delete source fields. Keep provenance:

```
definitionOfDone.sources
```

The worker, critic, deterministic preflight, and validator should eventually consume the same compiled contract.

## Exit criteria

A newly-created worker and a resumed worker receive equivalent logical continuation data.

---

# 10. Phase 5 — migrate dependencies from stdout to completion manifests

## Goal

Replace the highest-value raw-prose handoff.

Current `Get-SCDependencySummary` should become a compatibility adapter, not the primary dependency transport.

### 10.1 New dependency projection

For each dependency, prefer:

- completion status;
- definition hash;
- completion manifest ref;
- changed files;
- artifacts;
- validated conclusions;
- validator verdict;
- bounded warnings;
- evidence refs.

### 10.2 Fair-share budget

Until raw text fallback is removed, budget per dependency fairly.

No first dependency may consume the entire dependency result budget.

### 10.3 Authority

- deterministic changed files/artifacts = observed;
- validator verdict = corrective/observed depending on state;
- worker conclusions = advisory;
- human/Intent facts remain authoritative through their original channel.

### 10.4 Fallback

If a legacy task has no manifest:
- synthesize a compatibility manifest from existing receipts;
- mark `compatibilitySynthesized=true`;
- allow bounded stdout as last resort.

## Exit criteria

Normal newly-completed dependencies no longer pass raw stdout as their principal downstream representation.

---

# 11. Phase 6 — retries, recovery, and session handoff converge

## Goal

Make retry continuation independent of provider/session mechanics.

Replace bespoke continuation sources with projection-backed fields.

### 11.1 Retry

`latestFeedback` remains for compatibility but becomes derived from `correctiveFeedback`.

### 11.2 Recovery

Build a bounded causal index:

```
task
 -> compilation
 -> worker session
 -> run
 -> candidate checkpoint
 -> proposal
 -> validation
 -> progress
 -> events
```

The reducer should surface:
- repeated failure pattern;
- latest valid correction;
- prior deductions still fresh;
- known changed files;
- missing required evidence.

### 11.3 Direct API vs CLI equivalence

A resumable direct-API worker may retain transcript, but a fresh CLI/new-session worker must receive the same structured continuation projection.

Session transcript is a bonus cache, not the only handoff mechanism.

## Exit criteria

Retry behavior is logically equivalent across resumable and non-resumable worker backends.

---

# 12. Phase 7 — restructure the router into the machine inference gateway

## Goal

Use the signal migration as the opportunity to fix the router boundary itself.

The current split is backwards for long-term maintenance: C# owns routing/health while `StatefulClanker.WorkerRuntime.ps1` still owns substantial provider protocol, auth-header, request-body, and response-shape logic. A route cannot be diagnosed cleanly when the router does not own the request that actually failed.

Move toward one machine-local inference plane.

### 12.1 Introduce an adapter contract

Create a provider adapter interface with responsibilities such as:

```
adapter id / protocol id
build request URI
build sanitized request description
apply provider-specific headers/auth conventions
serialize messages/tools
parse successful response
parse provider error evidence
extract usage/quota hints
declare capability quirks
```

Credentials remain resolved by the machine-local connection store and are never returned to project state or MCP output.

Initial adapters should correspond to actual wire protocols, not marketing provider names where several providers share a protocol:

- OpenAI-compatible chat/completions;
- Anthropic Messages;
- Gemini native generateContent;
- Cohere/native variants if still required;
- provider-specific subclasses/overrides only where wire behavior genuinely differs.

A provider preset selects/configures an adapter. Do not scatter hostname conditionals through the worker loop.

### 12.2 Add a normalized inference operation

The router service should expose an internal/CLI/pipe operation such as `infer`:

```
infer(endpoint, normalizedRequest, diagnosticMode=false)
```

It should:

1. resolve endpoint -> connection/model/adapter;
2. acquire or validate a lease as appropriate;
3. construct the provider request through the adapter;
4. send it;
5. normalize success/error response;
6. emit the routing signal;
7. update the health projection through the reducer;
8. return a normalized result.

During migration, PowerShell may still own the outer worker tool loop, but the actual model HTTP exchange should move behind this operation.

Eventually `Invoke-SCDirectApiProvider` should become a thin client of the inference gateway or disappear as protocol ownership moves into C#.

### 12.3 Replace success/failure with structured outcome ownership

Current `success`/`failure` verbs are useful migration seams, not the desired final API.

Once `infer` owns the request, the service already knows:

- HTTP status;
- transport exception type;
- adapter id;
- endpoint/connection/model;
- sanitized request shape;
- response headers;
- bounded response/error body;
- latency;
- usage;
- retry metadata.

It should emit the signal itself. PowerShell should not re-diagnose a string and report it back.

Keep old verbs only while non-gateway callers still exist.

### 12.4 Emit routing signals

On:
- acquire success;
- acquire deferred/no route;
- inference success;
- inference/provider failure;
- adapter/request-shape failure;
- explicit endpoint test;
- lease expiry;
- probe result;
- internal router/transport exception.

Signal kinds should include at least:

- `route_acquired`
- `route_unavailable`
- `inference_succeeded`
- `inference_failed`
- `adapter_diagnostic_failed`
- `endpoint_test_succeeded`
- `endpoint_test_failed`
- `probe_succeeded`
- `probe_failed`
- `lease_expired`
- `harness_routing_fault`

## Exit criteria

Normal worker inference can execute through the machine inference gateway, and the same adapter/transport path is available to endpoint diagnostics.

---


# 13. Phase 8 — first-class orchestrator `test_endpoint`

## Goal

Give the conversational/control-plane orchestrator a direct diagnostic tool that performs a **real, minimal inference** against one exact endpoint through the same production adapter used by workers.

This is distinct from catalog discovery, quota probing, or "Test & discover."

### 13.1 MCP tool

Expose:

`test_endpoint`

Suggested input:

```json
{
  "project": "...",
  "endpoint": "pool:connection::model",
  "mode": "minimal|tools",
  "prompt": "optional bounded diagnostic prompt"
}
```

Default behavior should use a tiny fixed prompt and minimal output tokens. `mode=tools` may exercise one harmless tool-call schema when testing tool compatibility.

The orchestrator should not need or receive credentials.

### 13.2 Result contract

Return a sanitized structured diagnostic, not merely pass/fail:

```json
{
  "ok": false,
  "endpoint": "...",
  "connection": "...",
  "model": "...",
  "adapterId": "anthropic-messages",
  "request": {
    "method": "POST",
    "uri": "https://api.example/.../messages",
    "headersPresent": [
      "content-type",
      "x-api-key",
      "anthropic-version"
    ],
    "headersRedacted": true,
    "bodyShape": {
      "topLevelKeys": ["model", "messages", "max_tokens"],
      "toolMode": "native"
    }
  },
  "response": {
    "httpStatus": 400,
    "headers": {},
    "bodyExcerpt": "...",
    "providerRequestId": "..."
  },
  "diagnosis": {
    "class": "bad_request",
    "scope": "request",
    "adapterSuspect": true,
    "providerHealthSuspect": false,
    "reasonCode": "REQUEST_SHAPE_REJECTED"
  },
  "signalRef": "sig-..."
}
```

Never return secret header values, API keys, tokens, DPAPI blobs, or environment-variable contents.

### 13.3 Diagnostic semantics

A failed test must distinguish at least:

- credential/auth failure;
- rate limit/quota;
- provider/model unavailable;
- transport/DNS/TLS;
- provider capacity;
- malformed provider response;
- request body rejected;
- missing/wrong required header;
- unsupported tool schema;
- adapter parser failure;
- router/harness internal failure.

Most 400/422/protocol-shape failures should **not** mark the provider unhealthy. They should create an adapter/request diagnostic with request/harness scope.

A successful real inference is strong evidence that the endpoint and adapter are usable and may heal appropriate degraded health.

### 13.4 Make adapter repair actionable to the orchestrator

The result should include enough sanitized provenance for the orchestrator to investigate the implementation:

- adapter id;
- provider/preset id;
- protocol id;
- source implementation path/name;
- request URI pattern;
- header names present/missing, never values;
- top-level body keys;
- bounded provider error body;
- provider request id;
- exact status code;
- model id;
- tool mode;
- connection configuration hash/version.

When `adapterSuspect=true`, the control plane should be able to:

1. inspect the adapter implementation;
2. inspect the provider preset;
3. research the provider's current official API documentation when external research tools are available;
4. compare documented endpoint, headers, auth scheme, body schema, tool schema, and response shape against the sanitized test evidence;
5. patch the provider adapter/preset;
6. run unit/mock tests;
7. invoke `test_endpoint` again against the exact endpoint;
8. only then return the endpoint to normal routing.

Do not make the router autonomously edit its own source. The orchestrator performs and audits the code change.

### 13.5 Production-path invariant

A test is invalid if it uses a request builder that normal inference does not use.

Required invariant:

> if `test_endpoint` passes for adapter X and endpoint Y, a normal inference using the same normalized request features must traverse the same adapter serialization, auth/header builder, HTTP transport, and response parser.

Add tests that intentionally break an adapter field/header and prove both production inference and `test_endpoint` fail with the same structured diagnosis.

### 13.6 Tool placement

Implement the MCP surface alongside `connection_catalog` and `target_pool_list` in `mcp/StatefulClanker.McpExtensions.ps1`, backed by the router client rather than a duplicate PowerShell HTTP call.

Also expose a router CLI/pipe operation for tests and non-MCP callers, e.g. `test-endpoint`.

## Exit criteria

The orchestrator can name an exact endpoint, send a real minimal inference, receive sanitized diagnostic evidence, identify whether the adapter is suspect, patch the adapter when warranted, and retest the same production path.

---

# 14. Phase 9 — close the router taxonomy and harden scope

## Goal

Prevent request/harness faults from poisoning provider health.

Adopt a closed failure taxonomy. Exact strings can match existing names where practical:

- `auth`
- `rate_limited`
- `billing_exhausted`
- `capacity`
- `model_unavailable`
- `endpoint_unavailable`
- `transport`
- `timeout`
- `bad_request`
- `context_too_large`
- `malformed_response`
- `protocol_error`
- `session_incompatible`
- `harness_internal`
- `cancelled`
- `unknown`

### 13.1 Orthogonal scope

Scope is a second field, never implied solely by the word "failure":

- request
- model
- endpoint
- connection
- provider
- harness

Examples:

```
429 provider response
class = rate_limited
scope = endpoint or provider/connection only when provider metadata proves shared quota
```

```
401 for credential
class = auth
scope = connection
```

```
404 for one model
class = model_unavailable
scope = model/endpoint
```

```
PowerShell file lock
class = harness_internal
scope = harness
```

A `harness_internal` signal must never decrement provider health.

### 13.2 Retry timing

Every retryable routing state must have a deterministic `nextRetryAt`.

Prefer, in order:
1. explicit provider Retry-After;
2. quota-window reset metadata;
3. failure-policy backoff;
4. bounded default.

No cooldown-like state with a null retry time.

## Exit criteria

Taxonomy tests prove that unrelated connections are not quarantined by endpoint/request/harness failures.

---

# 15. Phase 10 — router reducer becomes authoritative

## Goal

Move the router consumer from imperative one-off health mutation toward a projection reduced from outcomes.

Target routing projection:

```json
{
  "endpoint": "...",
  "status": "cooldown",
  "consecutiveFailures": 2,
  "lastSuccessAt": "...",
  "lastFailureAt": "...",
  "lastFailureClass": "rate_limited",
  "nextRetryAt": "...",
  "evidenceRefs": ["sig-..."]
}
```

States remain small:

- healthy
- degraded
- cooldown
- quarantined
- disabled
- unknown

### Migration

1. Reducer computes shadow health from signals.
2. Compare shadow health with current `routing/health.json`.
3. Log mismatches.
4. Make `Snapshot` optionally expose both during development.
5. Make `Acquire` read the reduced projection only after equivalence tests pass.
6. Keep rollback switch to old health mutation for one release cycle.

Probes and real traffic must feed the same reducer.

## Exit criteria

Router health can be rebuilt from durable routing signals plus static endpoint/connection configuration.

---

# 16. Phase 11 — unify dispatch/execution accounting

## Goal

A task that cannot start must still make progress in diagnostic state.

Separate counters:

- `dispatchAttemptCount`
- `executionAttemptCount`
- existing/high-level `attemptCount` only if its semantics remain clear.

A no-route cycle should emit an execution-domain signal referencing the routing outcome:

```
kind: dispatch_deferred
subject: task:t-112
payload:
  reason: NO_ELIGIBLE_ROUTE
  routingSignalRef: sig-...
  nextEligibleAt: ...
```

This allows:
- bounded backoff;
- stagnation detection;
- clear tray diagnostics;
- no infinite non-counting dispatch loop.

Do not count an unavailable route as a worker execution attempt.

## Exit criteria

Tasks cannot spin forever between scheduler passes with zero durable attempt/defer accounting.

---

# 17. Phase 12 — optional path-addressed advisory handoff

## Goal

Only after worker continuation and router health are stable, test conservative cross-task cooperation.

This phase is experimental and may be rejected.

A worker/reviewer may produce:

```
kind: path_advisory
subject:
  type: path
  id: src/Fauna/FaunaLibrary.cs
audience:
  type: future_reader_of_path
authority: advisory
freshness:
  fileHashes:
    src/Fauna/FaunaLibrary.cs: <sha>
```

Rules:

- no peer worktree reads;
- no peer chat;
- no blocking sibling signal;
- advisory only;
- invalidate on file hash change;
- compiler includes only advisories matching the current read/target set;
- strict token/character cap;
- every advisory carries source/evidence refs.

Measure whether this reduces rediscovery before making it default.

---

# 18. Phase 13 — RPK promotion gate, only if justified

Do not dump signals directly into RPK.

If repeated fresh advisories look like durable project knowledge:

```
signal(s)
 -> candidate lesson
 -> needs_review
 -> explicit normalization/review
 -> RPK
```

RPK remains non-authoritative.

This is deliberately last because task-local continuation should solve most of the observed rediscovery without converting ephemeral execution details into permanent "knowledge."

---

# 19. Specific current code seams

## Worker/context

Primary migration surfaces:

- `lib/StatefulClanker.Context.ps1`
  - `Get-SCDependencySummary`
  - `Get-SCRetrievalPacket`
  - `New-SCCompilation`
  - prompt construction
- `lib/StatefulClanker.Execution.ps1`
  - run/proposal/validation lifecycle
  - progress records
  - candidate preflight integration
- `lib/StatefulClanker.WorkerRuntime.ps1`
  - candidate checkpoints
  - candidate preflight
  - resumable session state
- `lib/StatefulClanker.Concurrency.ps1`
  - retry eligibility
  - worker completion/reap/integration handling
- `mcp/StatefulClanker.McpExtensions.ps1`
  - recovery surfaces

Be careful with layered compilation behavior in:

- `lib/StatefulClanker.Semantics.ps1`
- `lib/StatefulClanker.ReflexiveKnowledge.ps1`
- `lib/StatefulClanker.Directives.ps1`

One success condition of this work should be **fewer implicit wrapper layers around context compilation**.

## Router

Primary migration surfaces:

- `lib/StatefulClanker.CompiledRouting.ps1`
- `src/StatefulClanker.Router/RouterPipe.cs`
- `src/StatefulClanker.Router/RouterEngine.cs`
- `src/StatefulClanker.Router/FailurePolicy.cs`
- `src/StatefulClanker.Router/RouterStore.cs`
- `src/StatefulClanker.Router/Models.cs`
- `src/StatefulClanker.Router/EndpointMonitor.cs`
- `src/StatefulClanker.Router/ProviderProbeCatalog.cs`
- new inference-gateway/provider-adapter/endpoint-diagnostic components
- `lib/StatefulClanker.WorkerRuntime.ps1` protocol/auth/request builders, which should migrate behind the gateway rather than remain duplicated
- `mcp/StatefulClanker.McpExtensions.ps1` for the orchestrator-facing `test_endpoint` tool

UI readers of route state must not become writers:

- `src/StatefulClanker.Tray/EndpointsRoutingUi.cs`
- `src/StatefulClanker.Tray/CockpitWidgets.cs`

---

# 20. Definition-of-done for the migration

The branch is ready to merge when all of these are true:

1. Signals are immutable, typed, durable, and attributable.
2. Worker lifecycle produces structured completion/correction/continuation signals.
3. New dependencies consume completion manifests rather than raw stdout.
4. Retry continuation is projection-backed and provider/session independent.
5. Context compilation consumes a deterministic execution projection.
6. Definition of Done is canonical in the compiled packet.
7. Retrieval health distinguishes empty-by-design from broken/blocked retrieval.
8. Worktree retrieval no longer excludes legitimate project files because they live under the state/worktree parent topology.
9. Router traffic, explicit endpoint tests, and probes all emit routing signals.
10. Production inference and `test_endpoint` share the same adapter serialization/auth/transport/parser path.
11. Provider wire-protocol ownership has moved out of the PowerShell worker loop into a coherent machine-local adapter layer.
12. The orchestrator has a sanitized `test_endpoint` MCP tool that performs real minimal inference and returns adapter-aware diagnostics.
13. Adapter/request-shape failures are distinguishable from provider-health failures and do not poison unrelated routes.
14. Router failure class and scope are separate.
15. Harness-internal faults cannot mutate provider health.
16. Every retryable routing state has `nextRetryAt`.
17. Router health can be reconstructed from signals.
18. No-route dispatches create durable defer diagnostics without consuming worker execution attempts.
19. Existing authority, worktree isolation, freshness, preflight, and acceptance tests remain green.
20. No worker-to-worker synchronous communication or shared-write coupling is introduced.
21. Compatibility paths are removed when their consumer moves; the final architecture does not keep legacy seams merely for historical symmetry.

---

# 21. Suggested commit sequence

Keep commits narrow enough to bisect:

1. `test: freeze worker and router information-flow baseline`
2. `feat: add execution signal envelope storage scaffolding`
3. `feat: add router signal envelope storage scaffolding`
4. `feat: shadow-write worker lifecycle signals`
5. `fix: separate worktree retrieval from control-state exclusion`
6. `feat: emit retrieval health signals`
7. `feat: add task completion manifests`
8. `feat: reduce execution signals into task projection`
9. `refactor: compile worker packet from execution projection`
10. `feat: compile canonical definition of done`
11. `feat: migrate dependency handoff to completion manifests`
12. `feat: unify retry and recovery continuation projection`
13. `refactor: split router routing, inference, and diagnostic responsibilities`
14. `feat: add provider adapter registry and normalized inference gateway`
15. `refactor: move provider request/auth/response shaping out of WorkerRuntime`
16. `feat: emit inference and adapter diagnostic signal envelopes`
17. `feat: expose orchestrator test_endpoint over production inference path`
18. `refactor: separate router failure class from health scope`
19. `feat: add shadow routing health reducer`
20. `feat: route acquire through reduced health projection`
21. `feat: account for dispatch deferrals separately from worker attempts`
22. `experiment: add hash-invalidated path advisories` (optional)
23. `refactor: remove proven legacy compatibility paths`

Each behavior-changing commit should include the test that proves the new invariant.

---

# 22. First implementation campaign

The first actual clanking pass should stop after the architecture can carry envelopes end-to-end without depending on them.

Scope:

1. baseline tests;
2. PowerShell signal module;
3. C# router signal model/store;
4. carve the router into explicit routing / inference-adapter / diagnostics boundaries, even if the legacy worker HTTP path still temporarily exists;
5. define the provider adapter contract and normalized inference/result types;
6. add the `test-endpoint` router operation and MCP `test_endpoint` surface against the new gateway skeleton;
7. shadow producers for:
   - validator rejection/pass,
   - worker run completion/failure,
   - compiled-router success/failure/no-route,
   - endpoint-test success/failure,
   - probe success/failure;
8. no execution consumer changes except diagnostics;
9. fix the worktree retrieval/control-state-path distinction because it blocks meaningful worker-side measurement;
10. add retrieval expected-vs-actual health telemetry.

At that checkpoint we should be able to inspect two real task runs and answer:

- What signals were produced?
- Which task/route were they about?
- Who were they addressed to?
- Which were still fresh?
- What would the future reducers have consumed?
- Did signal capture change any current behavior? It should not have.

Only after that checkpoint should we begin moving consumers.

---

## Final design rule

**Receipts say what happened. Signals say who needs to know. Reducers say what it currently means. Compilers/schedulers decide what to do with that reduced state.**

Do not let those four responsibilities collapse back together.

# StatefulClanker architecture

## Purpose

StatefulClanker is a **Windows-first durable orchestration runtime** for long-running agentic projects where project truth must survive disposable model contexts.

The central rule is:

> The project persists. Model contexts are replaceable compute.

The native Windows application is the normal resident host. A conversational model is the human-facing control plane. StatefulClanker owns durable project authority, compilation, dispatch, review gates, event persistence, backend routing, and worker capability policy.

## Implemented system

```text
human
  ↓
conversational control plane over MCP
  ├─ aggressively clarifies ambiguous human intent
  ├─ maintains Current Human Directives
  ├─ reconciles normalized Intent
  ├─ semantically plans/decomposes
  └─ reports meaningful project changes
  ↓
StatefulClanker durable authority
  ├─ human source artifacts
  ├─ Current Human Directives
  ├─ reconciled Intent Contract
  ├─ plan/task graph
  ├─ context compiler + freshness read set
  ├─ durable control-event inbox
  ├─ backend routing
  └─ worker capability policy
  ↓
worker backend
  ├─ provider-owned CLI harness
  └─ StatefulClanker-owned direct inference harness
        ├─ bounded repo/shell/git tools
        ├─ read-only human/normalized intent tools
        └─ authorized external MCP tools
  ↓
worker receipt → critic → validator → freshness/authority gate
  ↓
accepted project state / commit
```

No worker response becomes canonical merely because it exists.

## Authority chain

StatefulClanker separates direct human authority from model interpretation:

```text
verbatim human source evidence
       ↓
Current Human Directives
(latest direct human word per named scope)
       ↓
reconciled Intent Contract
(control-plane interpretation)
       ↓
plan
       ↓
task
       ↓
compiled truth packet
       ↓
worker / critic / validator evidence
       ↓
accepted state transition
```

### Human source artifacts

Material human wording is persisted under `.statefulclanker/input/` and addressed by stable `human:<id>` references, optionally with line ranges. Source evidence is read-only historical provenance; it is not automatically current authority.

### Current Human Directives

A directive is the current direct human position for one stable decision/scope. Updating the same directive id supersedes its prior active value. Superseded revisions remain available for audit but are excluded from normal worker context.

When a directive changes, dispatch is blocked until the control plane reconciles the full current directive set into a fresh Intent revision.

### Intent Contract

The orchestrator-owned Intent Contract normalizes objective, requirements, constraints, invariants, non-goals, decisions, preferences, open questions, and success definition. Each revision records the exact directive revision/hash it reconciled.

Workers may inspect and challenge Intent with `INTENT_QUESTION` / `INTENT_CONFLICT`, but never rewrite it.

## Conversational control plane

The conversational model owns semantic reasoning about the human request:

1. clarify materially ambiguous human intent;
2. preserve relevant direct wording as source/directive authority;
3. keep the current directive set internally non-conflicting;
4. reconcile directives into normalized Intent;
5. plan and semantically decompose work;
6. assign semantic task size and capability profile where useful;
7. react to worker/context/review failures;
8. keep the human informed through the durable control inbox.

If two competent implementers could make materially different product choices, the control plane should ask the human rather than silently selecting one. Mechanical file/line/token splitting is retrieval tooling, not semantic decomposition.

## Plans and tasks

`SCPLAN 1` is the preferred repeatedly-consumed authoring format. JSON remains valid for RPC, settings, receipts, and compatibility imports.

A task may carry:

- id/title/instruction;
- semantic size (`tiny|small|medium|large`);
- durable source references;
- governing Intent references;
- dependencies and typed relations;
- retrieval/evidence selectors;
- acceptance criteria;
- backend/provider override;
- role and human gate;
- optional `capability-profile`;
- task-local `tool-allow` / `tool-deny` narrowing.

Capability policy participates in the task definition hash. Changing a task's capability profile or local tool policy makes prior work stale.

## Context compiler and freshness

Every dispatched worker receives a cold-start truth packet containing enough authority to understand the bounded task without conversational memory:

- project goal;
- current Human Directives and directive revision/hash;
- reconciled Intent revision/hash;
- task semantics, acceptance criteria, source and Intent references;
- dependency outcomes;
- bounded retrieved project evidence;
- capability profile/task-local policy metadata.

Each compilation records a read set and fingerprints. Dispatch/commit freshness checks prevent older work from overwriting newer goal, directive, Intent, task, dependency, or retrieved-file authority.

## Worker backends

Task semantics are backend-neutral. Routing chooses a configured **worker backend**.

### CLI harness backend

A `cli` backend delegates the inner coding-agent loop to a provider/local harness such as Codex, Claude Code, OpenCode, Antigravity, Gemini CLI, or another configured command. StatefulClanker supplies the compiled truth packet and captures the receipt; the external harness owns its own internal tools.

### Direct inference backend

An `api` backend points to a machine-local inference connection. StatefulClanker owns a deliberately small tool loop and talks directly to an OpenAI-compatible endpoint such as Ollama, LM Studio, vLLM, OpenRouter, or another compatible gateway.

Both paths converge on the same critic, validator, freshness, event, and commit machinery.

## Worker capability policy

The central runtime authorization hierarchy for StatefulClanker-owned workers is tighten-only:

```text
machine grants
  ↓
optional named capability profile
  ↓
project policy
  ↓
role policy
  ↓
stage policy
  ↓
task-local allow/deny
```

Deny wins. No lower layer can grant a capability absent from the machine allow-list.

Built-in capability classes include repository tools and separate read-only authority readers:

- `intent.human.read` — inspect preserved direct human source evidence;
- `intent.normalized.read` — inspect reconciled Intent plus current directives.

External MCP services such as Toaster or MemPalace are registered machine-locally and exposed as capabilities like `mcp.toaster.search`. Merely registering a source does not grant its tools.

Provider-owned CLI harnesses retain their own internal permission systems; StatefulClanker does not pretend to revoke hidden tools inside another harness.

## Event-driven control plane

Low-level audit events remain in `.statefulclanker/events.jsonl`. Human-facing project changes also enter a durable sequenced control inbox:

```text
.statefulclanker/control/events.jsonl
.statefulclanker/control/state.json
```

Control events are `fyi`, `attention`, or `human_required`. The durable cursor is the correctness mechanism; MCP push notifications are wake-up signals only.

## MCP protocol eras

StatefulClanker serves both MCP behavior families from the same endpoint:

### Legacy era (through 2025-11-25 behavior)

- `initialize` handshake;
- existing JSON-RPC tool/resource behavior;
- no false advertisement of legacy `resources/subscribe` because StatefulClanker does not implement that legacy event stream.

### Modern era (`2026-07-28`)

- stateless requests;
- no `initialize` handshake;
- optional `server/discover` capability probe;
- protocol/client capability metadata carried per request;
- Streamable HTTP validates `MCP-Protocol-Version`, `Mcp-Method`, and applicable `Mcp-Name` headers;
- `Mcp-Session-Id` is rejected on modern requests;
- `subscriptions/listen` carries level-triggered control-resource updates.

The stdio bridge preserves the request's protocol era when forwarding into the resident HTTP host.

## Windows application authority

The installed WinForms application owns machine-local runtime concerns:

- tray lifecycle;
- saved projects and explicit active project;
- resident MCP endpoint;
- integration status;
- API connections;
- worker backend visibility;
- worker capability grants/profiles;
- external MCP worker tool sources;
- project telemetry.

There is no hidden default project. If the last active path is unavailable, the app enters a no-active-project state rather than substituting another project.

Machine-local state lives under `%LOCALAPPDATA%\StatefulClanker`. Project authority travels under `<project>\.statefulclanker`.

## Parallelism and state ownership

Parallel tasks use git worktrees. `WorkRoot` is the isolated checkout a worker edits; `StateRoot` remains the canonical project state directory. Cross-process state mutations use a named mutex and atomic file replacement.

The resident autofill supervisor is the normal execution scheduler for the active Windows project. It holds a per-project supervisor mutex, reaps and merges completed worktree workers serially, and on its configurable cadence (300 seconds by default) fills vacant slots from the oldest dispatchable ready tasks up to `maxConcurrent`. It does not create tasks or reinterpret Intent. Holds, human gates, dependency readiness, unreconciled directives, a dirty main worktree, or an empty queue all suppress dispatch. While resident, it owns dispatch so ad-hoc manual runs cannot race its worktree/merge authority.

Distributed multi-writer authority is not claimed. StatefulClanker currently assumes one canonical state authority per project.

## Review and acceptance

Worker output is candidate evidence. Critic and validator answer different questions:

- critic: what is wrong, incomplete, contradictory, risky, or based on a bad assumption?
- validator: do the stated acceptance conditions pass from available evidence?

Required gates fail closed. Human-authority shortcuts are explicit and disabled over MCP unless deliberately enabled.

## External memory boundary

Cross-project memory such as Toaster/MemPalace is non-authoritative candidate knowledge. Workers may query it when policy permits, but retrieved lessons never outrank current project directives, reconciled Intent, or inspected project state.

## Invariants

1. Durable project state outranks model recollection.
2. Latest direct human wording per directive scope is current human authority.
3. Superseded wording is audit history, not worker specification.
4. Intent is reconciled against current directives before dispatch.
5. Semantic planning/decomposition belongs to the conversational plane.
6. Workers receive standalone compiled truth packets.
7. Worker results are proposals, not self-certified completion.
8. Freshness prevents older authority from overwriting newer authority.
9. Backend transport does not change task semantics.
10. Worker capability inheritance is tighten-only.
11. External memory/tool services are not project authority.
12. Human-relevant state changes are durably resumable through the control inbox.
13. The Windows app has an explicit active project and machine-local configuration authority.
14. Activity and accepted progress remain separately observable.

# StatefulClanker

StatefulClanker is a **Windows-first resident orchestration application** for long-running agent work where **the project persists and model context does not**.

A conversational agent steers the resident app through MCP. StatefulClanker preserves current human authority, compiles bounded cold-start worker context, routes tasks into replaceable worker backends, controls tools for its inherent worker loop, persists project updates, and applies critic/validator/freshness gates before accepted state advances.

```text
human
  ↓
conversational control plane
  ↓
Current Human Directives → reconciled Intent → semantic plan/task graph
  ↓
StatefulClanker resident Windows app
  ├─ durable state + control-event inbox
  ├─ backend routing
  └─ worker capability policy
  ↓
worker backend
  ├─ provider-owned CLI harness
  └─ StatefulClanker direct-inference harness
       ├─ bounded repo/shell/git tools
       ├─ direct + normalized intent readers
       └─ authorized external MCP tools
  ↓
critic → validator → freshness/authority gate → accepted state
```

The central rule is:

> **The project persists. Individual model contexts are replaceable compute.**

## Human intent is first-class authority

Material direct human decisions are kept as **Current Human Directives**. Updating the same directive id supersedes the prior active wording for that scope. Old revisions remain audit history but are excluded from normal worker context.

Verbatim human evidence is preserved under `.statefulclanker\input\` with stable references such as:

```text
human:h-20260916010203-ab12cd
human:h-20260916010203-ab12cd#L4-L11
```

The conversational control plane reconciles the full current directive set into a normalized Intent Contract. New work is blocked while directives and Intent disagree.

The MCP instructions explicitly prioritize:

1. aggressively clarifying materially ambiguous human intent;
2. keeping the human informed about meaningful project-state changes;
3. semantically decomposing and delegating implementation.

Workers may report `INTENT_QUESTION`, `INTENT_CONFLICT`, or `CONTEXT_REQUEST` instead of guessing.

## Windows application

The normal product surface is a self-contained `.NET 8` WinForms tray application. It provides:

- saved-project navigation and exact active-project restoration;
- no silent default-project substitution;
- resident bearer-protected loopback MCP;
- stdio bridging into the same authority;
- project telemetry/activity;
- client integration management;
- worker backend/routing visibility;
- **Connections** for validated machine-local inference access and live model discovery;
- **Worker Capabilities** for machine grants, reusable profiles, project policy, and external MCP tool sources.

Machine-local state lives under `%LOCALAPPDATA%\StatefulClanker`. Project authority lives under `<project>\.statefulclanker`.

## Worker backends

StatefulClanker has two interchangeable execution paths above the same task/Intent/freshness/review machinery.

### CLI harness backend

Delegates the inner coding loop to an installed harness such as Codex, Claude Code, OpenCode, Antigravity/`agy`, Gemini CLI, or another configured command. This preserves consumer-subscription and provider-owned harness access.

### Direct inference backend

Points at a machine-local API connection and uses StatefulClanker's deliberately small worker loop. The initial adapter is OpenAI-compatible `/chat/completions`, intended especially for:

- Ollama
- LM Studio
- vLLM
- OpenRouter
- arbitrary compatible local/remote gateways

Connections support native function calling or a strict text-JSON fallback. Secrets remain machine/user state via DPAPI or environment variables.

Connections are validation-first: choose a service preset, enter its credentials, then **Test & discover**. StatefulClanker authenticates against the live service and retrieves the models currently available there. Selected connection/model pairs become project **endpoints** on **Endpoints & Routing**; credentials remain machine-local and can be reused by many endpoints/projects.

The inherent harness's actual tools are **policy-driven**, not hardcoded. Built-ins include read/search/write/replace, bounded PowerShell, git diff/status, and finish/escalation. Authorized workers may also receive separate read-only human/normalized Intent tools and external MCP tools such as Toaster or MemPalace.

See [`docs/DIRECT_INFERENCE.md`](docs/DIRECT_INFERENCE.md) and [`docs/WORKER_CAPABILITIES.md`](docs/WORKER_CAPABILITIES.md).

## Worker capability policy

StatefulClanker-owned workers use tighten-only authorization:

```text
machine grants
  → optional named capability profile
  → project policy
  → role policy
  → stage policy
  → task-local allow/deny
```

Deny wins. A lower layer cannot grant a capability absent from the machine allow-list.

External MCP tools use stable capability ids such as:

```text
mcp.toaster.search
mcp.toaster.read_lesson
mcp.mempalace.search
```

Merely registering a source does not grant all of its tools.

Reusable profiles and task-local narrowing are first-class task semantics. `SCPLAN 1` supports:

```text
capability-profile research-readonly
tool-allow builtin.read_file
tool-allow intent.*
tool-allow mcp.toaster.search
tool-deny builtin.run_command
```

Capability policy participates in the task-definition hash, so changing worker authority makes older compiled work stale.

## Compact plans

`SCPLAN 1` is the preferred repeatedly-consumed plan/task authoring format:

```text
SCPLAN 1
plan active-project
summary Restore the exact last active Windows project.
source human:h-0012#L3-L18
intent REQ-ACTIVE-PROJECT

task t-021
size small
title persist active project
instruction Persist the selected project as machine-local application state.
source human:h-0012#L3-L18
intent REQ-ACTIVE-PROJECT
capability-profile coding
tool-deny mcp.*
accept the same project is selected after restart
accept a missing project produces no-active-project state
end
```

See [`docs/TASK_RECORD_FORMAT.md`](docs/TASK_RECORD_FORMAT.md).

## MCP compatibility

One resident endpoint serves two MCP behavior families.

### Legacy clients

Handshake-era clients use `initialize` and the existing tool/resource RPC surface. StatefulClanker does not falsely advertise legacy `resources/subscribe`.

### MCP `2026-07-28`

Modern requests are stateless:

- no `initialize` handshake;
- optional `server/discover`;
- protocol/client capability metadata per request;
- Streamable HTTP routing through `MCP-Protocol-Version`, `Mcp-Method`, and applicable `Mcp-Name`;
- no modern `Mcp-Session-Id`;
- `subscriptions/listen` for level-triggered project update notifications.

Push is a wake-up optimization. Durable sequenced control events and `control_events_since` are the correctness/resume path.

See [`docs/MCP.md`](docs/MCP.md).

## Execution pipeline

A normal task cycle is:

```text
retrieve
  → compile standalone truth packet
  → freshness check
  → selected worker backend
  → persist receipt
  → critic
  → validator
  → freshness/authority recheck
  → commit/merge or reject
```

Parallel ready tasks can run in isolated Git worktrees while canonical `.statefulclanker` state remains in the main project root.

### Resident autofill

The Windows host starts a per-project autofill supervisor for the active project by default. It is deliberately not a planner: every five minutes (configurable) it checks the already-authorized ready queue and tops the active worker pool back up to `maxConcurrent`. It never bypasses dependencies, human gates, project holds, or unreconciled human directives, and it does nothing when the queue is empty.

Project config controls it with `autofillEnabled` (default `true`) and `autofillIntervalSeconds` (default `300`). While the supervisor is resident it owns execution dispatch; manual `run`/`run parallel` calls fail closed instead of racing the worktree scheduler. `StatefulClanker.ps1 autofill status` reports it and `autofill stop` requests a graceful drain.

## Install / build

Use the Windows installer release when available. To build from source:

```powershell
winget install Microsoft.DotNet.SDK.8
winget install JRSoftware.InnoSetup
.\install\Build-Installer.ps1 -Version 0.8.11
```

The build publishes a self-contained `win-x64` WinForms executable plus the PowerShell runtime, MCP scripts, docs, skills, examples, and tests.

The Windows app is normal mode, but headless PowerShell/MCP remain first-class troubleshooting and automation surfaces.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — current authority/runtime architecture
- [`docs/WINDOWS_FIRST_DESIGN.md`](docs/WINDOWS_FIRST_DESIGN.md) — native application responsibilities
- [`docs/MCP.md`](docs/MCP.md) — legacy + 2026 control-plane protocols and tools
- [`docs/INTENT_CONTRACT.md`](docs/INTENT_CONTRACT.md) — human directives and reconciled Intent
- [`docs/TASK_RECORD_FORMAT.md`](docs/TASK_RECORD_FORMAT.md) — SCPLAN/task authoring
- [`docs/DIRECT_INFERENCE.md`](docs/DIRECT_INFERENCE.md) — API-backed inherent worker loop
- [`docs/WORKER_CAPABILITIES.md`](docs/WORKER_CAPABILITIES.md) — profiles, policies, external MCP tools
- [`docs/SETUP.md`](docs/SETUP.md) — Windows setup/integration

StatefulClanker is experimental personal tooling. It intentionally favors transparent files, local processes, replaceable inference backends, explicit authority, and recoverable state over a large hosted platform.

MIT licensed.

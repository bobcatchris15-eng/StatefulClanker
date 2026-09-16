# Windows-first application and control-plane design

This document is the product-direction contract for StatefulClanker. Where older documentation describes StatefulClanker primarily as a PowerShell orchestration harness with adjacent UI and MCP surfaces, this document defines the intended end state.

## Product identity

StatefulClanker is a **Windows-resident orchestration application** for durable agentic project work.

The installed application owns the running system:

- notification-area / system-tray presence
- project registry and active-project selection
- Streamable HTTP MCP endpoint
- stdio MCP bridge support
- provider CLI configuration and invocation
- task/plan persistence
- telemetry and project observability
- worker, critic, and validator coordination

PowerShell remains a first-class automation and troubleshooting interface, but it is not the product shell.

The conversational model is the human-facing orchestrator. StatefulClanker is the durable state machine, dispatcher, context compiler, review coordinator, and observability plane.

## Control flow

```text
human
  |
  v
conversational-plane agent
  |  MCP
  v
StatefulClanker Windows application
  |
  +-- durable intent / human-source artifacts
  +-- semantic plan + task graph
  +-- context compiler
  +-- telemetry / receipts / reviews
  |
  v
provider CLI adapters
  |
  +-- codex ... {promptFile}
  +-- agy ... {promptFile}
  +-- claude ...
  +-- opencode ...
  +-- gemini ...
  +-- arbitrary configured local/consumer CLI
```

StatefulClanker does not require direct provider APIs as its normal execution path. A configured provider is an ordinary local command line. This intentionally preserves compatibility with provider-owned CLIs, consumer subscriptions, local model runners, and unusual tools that can accept a prompt through a file or stdin.

## Conversational plane responsibilities

The conversational-plane agent is not merely a UI wrapper around a scheduler. It is responsible for semantic work that requires reasoning:

1. understand the human's requested outcome
2. aggressively surface ambiguity
3. use the host's questionnaire / structured-question facility when available
4. record material human wording as durable source evidence
5. maintain the authoritative Intent Contract
6. build the plan
7. decompose the plan into coherent cold-start worker tasks
8. size those tasks by semantic complexity rather than file count or arbitrary line/token thresholds
9. revise the graph when critic results, context faults, or new human direction show the decomposition was wrong

StatefulClanker may warn that a task appears broad, but it must not pretend that regexes, file counts, line counts, or token counts are semantic task decomposition.

### Decomposition target

Prefer tasks that a small, disposable worker can understand and verify from a bounded context packet. Task size is a planning hint, not a mechanical truth.

Recommended classes:

- `tiny` — mechanical or highly local change
- `small` — one bounded concern, commonly suitable for fast/cheap worker models
- `medium` — coherent multi-file or nontrivial reasoning task
- `large` — tightly coupled work that resisted useful decomposition

Do not split tightly coupled work simply to achieve a smaller label. The useful boundary is an independently understandable and independently verifiable outcome.

Provider routing may map these classes to whatever CLIs/models are configured on the current machine. The task graph must not depend on vendor-specific model names.

## Human-source evidence

The Intent Contract is an interpretation of human direction; it is not the original evidence.

Material direct human input should therefore be preservable as a durable source artifact. Examples include:

- a relevant excerpt of session chat
- a plan/specification document supplied by the human
- a later clarification
- a decision recorded through a structured questionnaire

Tasks should carry either the relevant excerpt or, preferably, a stable reference to the durable artifact plus the governing intent clauses.

Conceptual project layout:

```text
.statefulclanker/
  input/
    h-0001.txt
    h-0002.txt
  intent/
    contract.*
  plans/
  tasks/
  runs/
  reviews/
  telemetry/
```

The authority chain is:

```text
human source
    -> Intent Contract
    -> plan
    -> task
    -> compiled worker packet
    -> worker / critic / validator evidence
    -> accepted project state
```

A later orchestrator must be able to audit a derived requirement against the original human source instead of trusting a chain of paraphrases.

## MCP is the conversational control plane

The installed application exposes MCP while it is running.

### Streamable HTTP

The application owns a loopback Streamable HTTP endpoint for clients that can connect to a local URL. The endpoint is machine-level, not tied to launching a particular project process.

Switching the active project does not restart the MCP server.

### stdio

Clients that require stdio should launch a thin bridge/shim. The bridge talks to the already-running StatefulClanker application through a local IPC channel (preferred target: named pipe) rather than becoming a second independent orchestration authority.

The semantic tool surface is identical across transports.

### Ambiguity behavior

Server instructions should explicitly tell the conversational orchestrator to use structured questionnaire tools aggressively when a material ambiguity exists.

A material ambiguity is one where two competent implementations could satisfy the visible request in meaningfully different ways.

Preferred behavior:

1. host questionnaire / structured question tool when available
2. MCP input-required / elicitation mechanism when supported by the client/protocol
3. ordinary MCP result containing explicit clarification questions as a compatibility fallback

Do not silently invent product intent merely to keep work moving.

## Active project, not default project

The desktop application has an **active project**.

There is no semantic "default project" that silently substitutes for the project the user thinks is open.

Behavior:

- project registry appears in the left navigation pane
- selecting a project makes it active
- the last active project is restored on application launch
- if that path no longer exists, show an explicit missing-project / no-active-project state
- never silently choose another project
- MCP conversations initially attach to the active project unless they explicitly select another project
- UI telemetry is always scoped to the selected/active project

## Machine state versus project state

Machine-local configuration belongs under a Windows application-data location such as `%LOCALAPPDATA%\StatefulClanker`:

```text
settings
project registry
last active project
provider CLI definitions
provider-class routing
integration registrations
MCP endpoint/token/IPC information
window/UI state
```

Project-local durable state belongs under `<project>\.statefulclanker`:

```text
human sources
intent contract and revisions
plans and tasks
specialist context
compilations
runs
critic/validator receipts
progress
events
telemetry
```

Provider executable locations and integration registrations are properties of a PC. Intent, task history, and execution evidence are properties of a project and should travel with it.

## Provider CLI adapters

A provider adapter describes how to call an existing command-line agent. It is intentionally small:

```text
name
command
argument template
prompt delivery: file | stdin | inline
capability/size classes
roles: worker | critic | validator
```

The normal worker flow is:

1. compile a bounded prompt packet
2. write it to a prompt file
3. invoke the configured CLI, commonly with `{promptFile}` or stdin
4. capture command, arguments, exit code, stdout, stderr, timings, and process metadata
5. persist the receipt
6. route the result through configured review gates
7. commit/merge accepted work

Examples such as `codex ... {promptFile}` or `agy ... {promptFile}` are configuration patterns, not hard-coded provider integrations.

Persistent provider sessions may be exploited as an optimization when a CLI supports them, but project semantics must not depend on provider session identity.

## Compact worker-facing records

JSON remains appropriate for APIs, RPC, settings, and internal receipts where it is useful.

The repeatedly consumed plan/task representation should be compact, line-oriented, grep-friendly, `Get-Content`-friendly, and cheap for models to ingest. See `docs/TASK_RECORD_FORMAT.md`.

Workers should not need to reconstruct a large JSON tree simply to locate their task, source references, acceptance criteria, or retrieval selectors.

## Desktop application

The application should take design cues from the current Toaster Windows release:

- native Windows application
- persistent system-tray icon
- closing/minimizing hides to tray rather than terminating
- dark Windows chrome and compact status presentation
- status/metric tiles for at-a-glance health
- dedicated Integrations page
- copyable MCP endpoint/configuration information
- clear connection/provider status

StatefulClanker adds a provider-GUI-style project tree on the left.

Suggested top-level pages for the active project:

- **Overview** — project identity, intent revision, running agents, queued/blocked/completed work, latest critic/validator state
- **Plan** — task/dependency view and current decomposition
- **Activity** — worker launches, receipts, commits, reviews, failures, retries, context/intent escalations
- **Integrations** — stdio/Streamable HTTP client registrations and connection status
- **Providers** — configured CLIs, tests, role/class routing
- **Settings** — app/MCP/project-independent settings

The overview should expose project-scoped telemetry such as:

- worker sessions spawned
- critic sessions
- validator sessions
- commits made
- tasks complete / blocked / needs-rework
- retries / non-advancing attempts
- current active processes
- latest review verdicts
- outstanding intent questions/conflicts

The GUI is primarily an observation and configuration plane. Normal planning/direction remains conversational through MCP.

## Specialists

A specialist is primarily a reusable project context profile, not necessarily a persistent process.

It may define:

- specialist name/role
- durable project-specific notes
- preferred retrieval selectors
- preferred provider class
- task types it is suited to

When invoked, StatefulClanker compiles the specialist context into the provider CLI call. If a provider supports durable sessions, reusing one is an optional optimization rather than an architectural dependency.

## Migration direction

The current PowerShell runtime remains valuable and should be preserved while the host changes underneath it.

Recommended sequence:

1. make this document and the Intent Contract/planner rules authoritative
2. add compact task/plan records alongside existing JSON compatibility
3. introduce machine-local project registry and active-project semantics
4. make human-source capture first-class
5. build the native Windows host using the Toaster application's structure/theme as a starting point
6. move the long-lived Streamable HTTP endpoint into the app host
7. make stdio a bridge to the resident host
8. migrate telemetry and provider configuration into the host while retaining CLI/PowerShell access
9. retire duplicated orchestration authority from independent tray/MCP processes

Do not require a flag-day rewrite. Compatibility shims are preferable to losing the working execution engine.

## Product invariants

1. Windows is the primary product platform, not an afterthought.
2. The running desktop application is the machine-local orchestration authority.
3. MCP is the normal conversational steering plane.
4. The conversational agent performs semantic planning and task decomposition.
5. Mechanical chunking is retrieval tooling, not task planning.
6. Material human wording remains recoverable as durable source evidence.
7. Workers receive bounded, source-linked tasks that survive conversational amnesia.
8. Provider execution remains command-line based and provider-agnostic.
9. Consumer/provider CLI compatibility is a feature, not a temporary hack.
10. The active project is explicit and restored; no hidden default-project substitution.
11. Desktop telemetry is scoped to the project currently selected.
12. Persistent provider sessions are optional optimizations, not project authority.
13. API/RPC formats may use JSON; worker-facing durable records should optimize for compact retrieval and model context.
14. Durable project truth remains authoritative over any model's recollection.

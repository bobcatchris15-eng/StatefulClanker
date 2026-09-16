# Windows-first application and control-plane design

This document describes the implemented product direction rather than the original migration path.

## Product identity

StatefulClanker is a **Windows-resident orchestration application**. The resident app owns machine-local runtime/configuration; project truth remains durable under each project's `.statefulclanker` directory.

The conversational model is the human-facing control plane. Its primary job is preserving human intent, its second job is keeping the human informed, and implementation is delegated to worker backends.

## Control flow

```text
human
  ↓
conversational control plane
  ↓ MCP
resident StatefulClanker app
  ├─ active project + project registry
  ├─ Current Human Directives + reconciled Intent
  ├─ semantic plan/task graph
  ├─ event/control inbox
  ├─ backend routing
  └─ worker capability policy
  ↓
worker backend
  ├─ provider CLI harness
  └─ direct-model StatefulClanker harness
```

## Human intent handling

Material human direction is stored as named **Current Human Directives**. The latest direct human word for a scope is authoritative; changing the same directive id supersedes its prior active wording. Verbatim source artifacts remain available for verification/audit.

The conversational plane reconciles the full current directive set into a contradiction-free Intent Contract. New dispatch is blocked while directive reconciliation is pending.

The control plane should aggressively ask the human when two reasonable implementations would differ materially. Structured questionnaire tools are preferred when available.

## Active project

The app has one explicit active project.

- selecting a saved project makes it active;
- the exact last active project is restored when available;
- a missing path produces no-active-project/missing state;
- another project is never silently substituted;
- MCP follows the active project unless an explicit project is supplied;
- telemetry is scoped to the selected project.

## Machine-local state

Machine state lives under `%LOCALAPPDATA%\StatefulClanker` and includes:

```text
app.json / project registry / active-project.txt
mcp-http.json
connections.json
worker-capabilities.json
worker-capability-audit.jsonl
```

It includes API endpoints/credentials, worker capability grants/profiles, external MCP tool-source definitions, UI state, and integration details.

## Project-local state

Project state lives under `<project>\.statefulclanker` and includes:

```text
input/
directives/current + directives/history
intent/
plans/
tasks/
compilations/
runs/ critiques/ validations/ proposals/
progress/ reviews/ telemetry/
control/
worker-policy.json
state.json / config.json / events.jsonl
```

Project policy may narrow machine worker capabilities but cannot grant new machine capabilities.

## Worker backends

The Providers surface represents **worker backends**, not only CLIs.

### CLI backend

Delegates the inner coding loop to an installed harness such as Codex, Claude, OpenCode, Antigravity, Gemini CLI, or another command-line agent.

### Direct API backend

Uses a machine-local API connection (especially Ollama, LM Studio, vLLM, OpenRouter, or another OpenAI-compatible endpoint). StatefulClanker owns a minimal tool loop.

The same task/directive/Intent/review/freshness semantics apply to both.

## Worker capabilities UI

The Windows app exposes a **Worker Capabilities** page for machine-level execution policy:

- machine allow/deny patterns;
- reusable named capability profiles;
- registered external MCP worker tool sources;
- per-source machine grants;
- direct access to the active project's tighten-only `worker-policy.json`.

Profiles and project/task policy are narrowing layers only. `run_command` and external write/action tools should be treated as high-trust capabilities.

## API Connections

The **API Connections** page stores multiple machine-level inference profiles. Secrets are DPAPI-encrypted for the current Windows user or referenced via environment variables. Project backend configuration stores only the connection id.

OpenRouter is exposed as a first-class machine setup: one **OpenRouter API Key** field populates the managed free-model profiles, all sharing the same DPAPI-protected credential and fixed OpenRouter base URL. The generic custom-connection editor remains for other OpenAI-compatible endpoints.

## MCP host

The resident app starts the loopback bearer-protected HTTP server and writes details to `%LOCALAPPDATA%\StatefulClanker\mcp-http.json`.

One endpoint serves both MCP eras:

- legacy handshake-era clients (`initialize`);
- modern `2026-07-28` stateless clients (`server/discover` / per-request metadata).

The stdio bridge preserves the incoming era when forwarding to the resident HTTP server. Modern `subscriptions/listen` is used for control-event wake-up notifications; the durable event cursor remains the correctness path.

## Desktop pages

Current/expected top-level surfaces are:

- **Overview** — active project authority and headline metrics;
- **Activity** — durable project event activity;
- **Integrations** — MCP endpoint/stdio bridge/client registration;
- **Providers** — configured CLI/API worker backends and routing;
- **API Connections** — direct inference connection profiles;
- **Worker Capabilities** — machine grants/profiles and external MCP tool sources.

Planning remains conversational through MCP; the desktop app is primarily observation and configuration.

## Windows implementation principles

1. Windows is the primary platform.
2. The tray app is persistent; close/minimize hides rather than silently killing orchestration.
3. No administrator rights should be required for normal operation.
4. Loopback networking should avoid URLACL/admin dependencies.
5. PowerShell remains inspectable/first-class but is not a second product shell.
6. Machine secrets/configuration never become project artifacts.
7. Project truth is portable independently of one model/provider installation.
8. UI configuration must not create a second semantic authority: it edits the same machine/project files the runtime reads.

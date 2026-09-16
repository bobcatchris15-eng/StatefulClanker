# StatefulClanker

StatefulClanker is a **Windows-first resident orchestration application** for long-running agent work where **the project persists and model context does not**.

The native tray app owns the running system. A conversational agent steers it through MCP. StatefulClanker persists current human directives, normalized intent, plans and receipts, compiles bounded worker context, routes work into either provider-owned CLI harnesses or direct inference endpoints, and applies critic/validator gates before accepted state advances.

```text
human
  ↓
conversational planner over MCP
  ↓
Current Human Directives + reconciled Intent + compact task graph
  ↓
StatefulClanker resident Windows app
  ↓
worker backends
  ├─ provider CLI harnesses
  └─ StatefulClanker minimal direct-inference harness
  ↓
Git/worktrees + durable receipts + accepted project state
```

## What makes it different

StatefulClanker does **not** ask one giant model session to remember an entire project.

It externalizes continuity into durable project artifacts and treats model sessions as replaceable compute:

- current human directives with superseded history kept audit-only
- reconciled authoritative Intent Contract
- verbatim human-source artifacts
- compact semantic plans/tasks
- task dependency graph and relations
- bounded compiled context receipts
- worker/critic/validator run receipts
- freshness and authority checks
- context/intent escalations
- project-scoped telemetry and resumable control events
- Git worktree isolation for parallel tasks

The central rule is:

> The project persists. Individual model contexts do not.

## Windows application

The normal product surface is a native `.NET 8` WinForms application installed per-user.

It lives in the notification area and provides:

- a provider-app-style project tree on the left
- restoration of the exact last active project
- no silent replacement when that project is missing
- resident Streamable HTTP MCP
- stdio MCP bridging into the same resident authority
- active-project telemetry for workers, commits, critics and tasks
- integration status/registration
- configured worker-backend and semantic-size routing status
- machine-local **API Connections** setup for local/OpenAI-compatible inference endpoints and gateways

Machine-local application state lives under:

```text
%LOCALAPPDATA%\StatefulClanker\
```

Project authority lives under:

```text
<project>\.statefulclanker\
```

## Conversational control plane

MCP is the normal steering interface.

The server's `initialize` instructions tell the conversational model to:

- use structured questionnaire/question tools aggressively for material ambiguity
- treat the latest direct human word for a named scope as authoritative
- keep current Human Directives separate from normalized Intent
- reconcile contradictions before dispatching new work
- preserve important direct wording/source evidence
- semantically decompose work into bounded cold-start tasks
- never invent task boundaries from regexes, line counts, file counts or token thresholds
- report meaningful project-state changes back to the human
- leave implementation work to configured worker backends

The conversational agent is the planner/decomposer. StatefulClanker is the durable state machine, context compiler, dispatcher, observer and review coordinator.

## Compact plans

Substantial plans can be applied directly over MCP with `plan_apply` using the line-oriented `SCPLAN 1` format:

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
accept the same project is selected after restart
accept a missing project produces no-active-project state
accept no other project is silently substituted
end
```

It is deliberately easy to inspect with `Get-Content`, `Select-String`, `rg`, `findstr`, or any ordinary text tool.

See [`docs/TASK_RECORD_FORMAT.md`](docs/TASK_RECORD_FORMAT.md).

## Current directives and durable human input

Material direct human decisions are maintained as **current directives**. Updating the same directive id supersedes its earlier active wording for that scope. Superseded revisions remain available for audit/debugging but are filtered out of ordinary worker context.

Execution-relevant human wording is stored under:

```text
.statefulclanker\input\
```

and receives references such as:

```text
human:h-20260916010203-ab12cd
human:h-20260916010203-ab12cd#L4-L11
```

When a directive changes, new dispatch is blocked until the current directive set has been reconciled into a fresh Intent revision. Workers receive the current directive snapshot and reconciled Intent directly in their compiled truth packet.

## Worker backends

StatefulClanker has two interchangeable execution paths above the same task/Intent/freshness/review machinery.

### Provider CLI harnesses

StatefulClanker can delegate the inner agent loop to installed tools such as:

- Claude Code
- Antigravity / `agy`
- Codex CLI
- OpenCode
- Gemini CLI
- Aider / Goose / other configured tools
- local-model CLIs

Prompts are written to files and delivered via stdin or a prompt-file argument according to provider configuration.

### Direct inference + minimal StatefulClanker harness

A project backend may instead point at one of the machine-local API connections configured in the Windows app. StatefulClanker then owns a deliberately small coding loop with only:

- file read/search
- exact file write/replace
- bounded PowerShell command execution
- git status/diff
- finish / intent-context escalation

The initial direct transport is OpenAI-compatible `/chat/completions`, aimed particularly at:

- Ollama
- LM Studio
- vLLM
- OpenRouter
- arbitrary compatible local/remote providers and gateways

Connections support native tool calls or a strict text-JSON fallback for local models whose servers do not expose reliable function calling. API keys entered in the app are encrypted for the current Windows user; connections may instead name an environment variable. Project state contains only a connection id, never the secret.

See [`docs/DIRECT_INFERENCE.md`](docs/DIRECT_INFERENCE.md).

Example project backend/routing shape:

```json
{
  "defaultProvider": "opencode",
  "criticProvider": "agy",
  "validatorProvider": "claude",
  "providerBySize": {
    "tiny": "local-qwen",
    "small": "local-qwen",
    "medium": "opencode",
    "large": "claude"
  },
  "providers": {
    "opencode": {
      "type": "cli",
      "command": "opencode",
      "args": ["run"],
      "mode": "stdin"
    },
    "local-qwen": {
      "type": "api",
      "connection": "local-qwen"
    }
  }
}
```

Task size is assigned semantically by the planner. The runtime only uses it as a routing hint.

## Execution pipeline

A task cycle is:

```text
retrieve
  -> compile bounded truth packet
  -> freshness check
  -> selected worker backend
  -> persist receipt
  -> critic
  -> validator
  -> freshness/authority check
  -> commit or reject
```

Workers can explicitly stop advancement with:

```text
CONTEXT_REQUEST: <missing state>
INTENT_QUESTION: <ambiguity>
INTENT_CONFLICT: <contradiction>
```

The conversational orchestrator resolves those and recompiles; workers are not told to guess through missing authority.

## Parallel execution

`run_parallel` places ready tasks in separate Git worktrees. Passing tasks are committed and merged back; conflicting or failed tasks remain explicit rather than silently overwriting one another.

Git is therefore both an implementation-isolation mechanism and a useful source of project telemetry.

## Install

Use the Windows installer release:

```text
StatefulClankerSetup-0.6.0.exe
```

It installs the self-contained native application plus the PowerShell orchestration runtime, MCP scripts, docs, skills and examples.

PowerShell 7 is recommended because the orchestration/runtime layer is intentionally inspectable and scriptable; the direct worker command shim remains compatible with Windows PowerShell 5.1.

See [`docs/SETUP.md`](docs/SETUP.md).

## Build from source

On Windows:

```powershell
winget install Microsoft.DotNet.SDK.8
winget install JRSoftware.InnoSetup
.\install\Build-Installer.ps1 -Version 0.6.0
```

The build publishes a self-contained `win-x64` WinForms executable and packages it with Inno Setup.

## Headless compatibility

The Windows application is the normal mode, but the CLI remains first-class.

```powershell
cd C:\work\my-project
C:\tools\StatefulClanker\StatefulClanker.ps1 init
C:\tools\StatefulClanker\StatefulClanker.ps1 status
```

A fixed-project MCP server can also be launched deliberately:

```powershell
pwsh -NoProfile -File .\mcp\StatefulClanker.McpHttp.ps1 `
  -ProjectPath C:\work\my-project `
  -Port 7337
```

## Documentation

- [`docs/WINDOWS_FIRST_DESIGN.md`](docs/WINDOWS_FIRST_DESIGN.md) — product/application architecture
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — durable state and orchestration semantics
- [`docs/MCP.md`](docs/MCP.md) — conversational control plane and tools
- [`docs/DIRECT_INFERENCE.md`](docs/DIRECT_INFERENCE.md) — API connections and minimal worker harness
- [`docs/TASK_RECORD_FORMAT.md`](docs/TASK_RECORD_FORMAT.md) — compact SCPLAN/task records
- [`docs/INTENT_CONTRACT.md`](docs/INTENT_CONTRACT.md) — directive/Intent authority model
- [`docs/SETUP.md`](docs/SETUP.md) — Windows setup and integration walkthrough

## Status

StatefulClanker is an experimental personal tool. The architecture intentionally favors transparent files, local processes, replaceable inference backends and recoverable state over a large hosted platform.

MIT licensed.

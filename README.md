# StatefulClanker

StatefulClanker is a **Windows-first resident orchestration application** for long-running agent work where **the project persists and model context does not**.

The native tray app owns the running system. A conversational agent steers it through MCP. StatefulClanker persists intent, plans and receipts, compiles bounded worker context, launches whatever provider CLIs the user already has, and applies critic/validator gates before accepted state advances.

```text
human
  ↓
conversational planner over MCP
  ↓
Intent Contract + compact task graph
  ↓
StatefulClanker resident Windows app
  ↓
provider CLI workers / critics / validators
  ↓
Git/worktrees + durable receipts + accepted project state
```

## What makes it different

StatefulClanker does **not** ask one giant model session to remember an entire project.

It externalizes continuity into durable project artifacts and treats model sessions as replaceable compute:

- authoritative Intent Contract
- verbatim human-source artifacts
- compact semantic plans/tasks
- task dependency graph and relations
- bounded compiled context receipts
- worker/critic/validator run receipts
- freshness and authority checks
- context/intent escalations
- project-scoped telemetry
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
- configured provider CLI and semantic-size routing status

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
- preserve important human wording as durable source evidence
- maintain the Intent Contract as specification authority
- semantically decompose work into bounded cold-start tasks
- prefer small tasks where separation is natural
- never invent task boundaries from regexes, line counts, file counts or token thresholds
- leave implementation work to provider CLI worker sessions

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

## Durable human input

Execution-relevant human direction is stored verbatim under:

```text
.statefulclanker\input\
```

and receives a reference such as:

```text
human:h-20260916010203-ab12cd
```

Tasks may reference the whole source or a line range:

```text
human:h-20260916010203-ab12cd#L4-L11
```

That gives later orchestrators a way to audit the normalized Intent Contract against what the human actually said.

## Provider CLIs, not provider APIs

Worker execution remains ordinary local command invocation. StatefulClanker can call consumer-subscription or local-model CLIs such as:

- Claude Code
- Antigravity / `agy`
- Codex CLI
- OpenCode
- Gemini CLI
- Aider / Goose / other configured tools
- local runners

Prompts are written to files and delivered via stdin or a prompt-file argument according to provider configuration.

StatefulClanker does not require direct provider API billing. This is intentional: the provider CLI is the compatibility layer.

Example configuration shape:

```json
{
  "defaultProvider": "opencode",
  "criticProvider": "agy",
  "validatorProvider": "claude",
  "providerBySize": {
    "tiny": "agy",
    "small": "agy",
    "medium": "opencode",
    "large": "claude"
  }
}
```

Task size is assigned semantically by the planner. The runtime only uses it as a routing hint.

## Execution pipeline

A task cycle is:

```text
retrieve
  -> compile bounded packet
  -> freshness check
  -> provider CLI worker
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

PowerShell 7 is recommended because the orchestration/runtime layer is intentionally inspectable and scriptable.

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

The stdio transport likewise supports `-ProjectPath` when running without the resident app.

## Documentation

- [`docs/WINDOWS_FIRST_DESIGN.md`](docs/WINDOWS_FIRST_DESIGN.md) — product/application architecture
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — durable state and orchestration semantics
- [`docs/MCP.md`](docs/MCP.md) — conversational control plane and tools
- [`docs/TASK_RECORD_FORMAT.md`](docs/TASK_RECORD_FORMAT.md) — compact SCPLAN/task records
- [`docs/INTENT_CONTRACT.md`](docs/INTENT_CONTRACT.md) — authoritative intent model
- [`docs/SETUP.md`](docs/SETUP.md) — Windows setup and integration walkthrough

## Status

StatefulClanker is an experimental personal tool. The architecture intentionally favors transparent files, local processes and recoverable state over a large hosted platform.

The Windows-first native host, resident MCP control plane, compact plans, durable human-source references and semantic provider routing are implemented in the current codebase. Provider CLI flags can change independently, so verify configured commands with `provider_test` before relying on them for unattended work.

MIT licensed.

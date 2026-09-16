# StatefulClanker MCP control plane

StatefulClanker is designed to be steered by a conversational agent through MCP while the resident Windows application owns project selection, telemetry, provider configuration, and the long-lived orchestration state.

The division of responsibility is deliberate:

- **Human + conversational agent:** clarify intent, use structured questionnaires, build the plan, semantically decompose it into cold-start worker tasks, respond to ambiguity and project-level decisions.
- **StatefulClanker:** persist authority, compile bounded task context, launch provider CLIs, record receipts, run critic/validator gates, isolate parallel work, and expose telemetry.
- **Provider CLIs:** disposable implementation/review processes such as Codex, Antigravity/`agy`, Claude, OpenCode, Gemini, or local tools configured by the user.

The conversational model is the planner. StatefulClanker does not pretend that file counts, regexes, line counts, or token thresholds can semantically decompose work.

## Resident transports

When the Windows application is running it starts one loopback MCP authority automatically.

### Streamable HTTP

Connection details are written to:

```text
%LOCALAPPDATA%\StatefulClanker\mcp-http.json
```

The default endpoint is:

```text
http://127.0.0.1:7337/mcp
```

It is loopback-only and bearer-token protected. The Integrations tab exposes the live endpoint/token status.

The HTTP server is intentionally started without a fixed project. Calls that omit `project` follow the project currently selected in the StatefulClanker application.

### stdio

Clients that launch MCP commands use:

```powershell
pwsh -NoProfile -File <install>\mcp\StatefulClanker.Mcp.ps1
```

While the Windows app is running this process is a thin stdio bridge to the resident HTTP authority, so stdio and HTTP clients see the same active project and state. If no resident server exists it falls back to an in-process MCP server for headless use.

`Install-McpServer.ps1` emits or writes client registration without pinning a project by default:

```powershell
.\Install-McpServer.ps1 -Client claude-desktop -Write
.\Install-McpServer.ps1 -Client claude-code
.\Install-McpServer.ps1 -Client vscode
```

Use `-ProjectPath` only when deliberately creating a fixed-project/headless registration.

## Active project

The Windows app stores its machine-local project registry and active project under:

```text
%LOCALAPPDATA%\StatefulClanker\
```

The selected project is also written to `active-project.txt` for the resident MCP process.

An explicit `project` argument on a tool call always wins. A headless MCP process may also be started with `-ProjectPath`. Otherwise the resident app selection is the authority.

If the last-active project is missing at startup, StatefulClanker enters a no-active-project state. It does not silently substitute another saved project.

## Initialization instructions

The MCP `initialize` response tells the conversational agent to:

- use the host questionnaire/question tool aggressively for material ambiguity
- ask contrastive questions where multiple reasonable implementations exist
- capture execution-relevant human wording durably
- preserve source and intent references through planning
- decompose semantically into bounded cold-start tasks
- prefer small tasks where natural, without arbitrary micro-tasking
- use `SCPLAN 1` for substantial plans
- leave implementation to provider CLI worker sessions
- treat `INTENT_QUESTION`, `INTENT_CONFLICT`, and `CONTEXT_REQUEST` as non-advancing escalations

This behavior is part of the control-plane contract rather than optional prose in a README.

## Durable human sources

`direction_add` now stores the human wording verbatim under the project's `.statefulclanker/input/` directory and returns a source reference such as:

```text
human:h-20260916010203-ab12cd
```

Line ranges can be referenced explicitly:

```text
human:h-20260916010203-ab12cd#L4-L11
```

`source_add`, `source_get`, and `source_list` expose the same source store for other material input.

The intended provenance chain is:

```text
human wording -> durable source -> intent contract -> plan/task -> compiled worker packet
```

The Intent Contract remains normalized specification authority; a source reference preserves what the human actually said so later orchestrators can audit that normalization.

## Compact plans

`plan_apply` accepts a complete compact plan directly from the conversational agent:

```text
SCPLAN 1
plan active-project
summary Make the selected Windows project the resident MCP authority.
source human:h-0012#L3-L18
intent REQ-ACTIVE-PROJECT

task t-021
size small
title persist active project
instruction Persist the exact selected project as machine-local application state.
source human:h-0012#L3-L18
intent REQ-ACTIVE-PROJECT
accept the same project is selected after application restart
accept a missing project produces no-active-project state
a ccept no other project is silently substituted
end
```

The canonical format is documented in `docs/TASK_RECORD_FORMAT.md`. It is line-oriented so agents and operators can cheaply inspect it with `Get-Content`, `Select-String`, `rg`, or `findstr`.

`.json` plan import remains supported for compatibility. `plan_import` accepts either JSON or `.scplan` files.

## Semantic task size

Tasks may declare:

```text
size tiny
size small
size medium
size large
```

The conversational planner assigns this semantically. StatefulClanker never derives it from file count, line count, diff size, regexes, or token count.

Machine/project provider configuration may map those classes to provider CLI names through `providerBySize`. Routing precedence is:

1. explicit provider override for the run
2. critic/validator provider when applicable
3. task-specific provider
4. `providerBySize.<task size>`
5. `defaultProvider`

This makes it practical to aim routine bounded tasks at consumer-subscription models/CLIs while retaining stronger workers for work that genuinely needs them.

## Main tool surface

### Project and intent

- `project_init`
- `project_use` (primarily useful in headless/fixed-project operation)
- `project_status`
- `goal_set`
- `direction_add`
- intent inspection/replacement remains available through the StatefulClanker runtime and operator skill

### Planning/tasks

- `plan_apply` — preferred conversational SCPLAN import
- `plan_import` — JSON or SCPLAN file
- `task_list`
- `task_show`
- `task_add` — supports `size`, `source`, `intentRef`
- `task_retry`
- `task_block`

### Execution

- `run_start` — detached single task cycle
- `run_parallel` — detached worktree-isolated ready-task batch
- `run_status` — poll active work/log tail

A normal task cycle is:

```text
compile -> worker CLI -> critic CLI -> validator CLI -> freshness check -> commit/reject
```

Provider execution is intentionally ordinary command-line invocation. Prompts are written to files and may be supplied by `{promptFile}` or piped through stdin depending on provider configuration. StatefulClanker does not require direct provider API billing.

### Observation

- `telemetry_active`
- `telemetry_history`
- `telemetry_run`
- `context_faults`
- `compilation_get`
- `proposal_get`
- `progress_history`
- `events_recent`
- `source_list`
- `source_get`

### Provider configuration

- `provider_list`
- `provider_set`
- `provider_test`

The Windows Providers tab presents the configured command, whether that CLI is currently found, special critic/validator/default roles, and semantic size routes.

## Review and authority gates

Worker output remains a proposal, not authority. Critic and validator stages inspect the same compiled context receipt used for the worker.

`task_complete`, `plan_approve`, and `hold_clear` represent human-authority shortcuts/gates and remain disabled over MCP unless `mcp.allowHumanAuthorityTools` is explicitly enabled for the project.

Workers may emit:

```text
CONTEXT_REQUEST: <specific missing state>
INTENT_QUESTION: <specific ambiguity>
INTENT_CONFLICT: <specific contradiction>
```

These stop advancement. The conversational orchestrator should resolve the cause, revise intent/plan/retrieval if necessary, then recompile rather than telling the worker to guess.

## Headless operation

The native Windows application is the normal product surface, but the runtime remains scriptable.

A fixed-project HTTP server can still be started explicitly:

```powershell
pwsh -NoProfile -File .\mcp\StatefulClanker.McpHttp.ps1 -ProjectPath C:\work\project -Port 7337
```

Likewise a stdio server may be launched with `-ProjectPath` if there is no resident app. This compatibility path is intentional; it does not change the Windows-first application model.

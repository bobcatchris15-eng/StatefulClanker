# Driving StatefulClanker from a conversational agent

> Setting this up for the first time? **`docs/SETUP.md`** is the step-by-step
> walkthrough. This page is the tool reference.

StatefulClanker exposes an MCP server so a chat session can act as the *planner*
while the harness keeps owning worker dispatch, review gating, and durable state.

The division of labour matters:

- **The session** decides what the work is: sets the goal, decomposes it into tasks,
  declares retrieval, starts cycles, reads receipts, and re-scopes on failure.
- **StatefulClanker** decides what is *true*: compiles context, dispatches cold-start
  workers, runs critic and validator, and commits state only through a validated
  proposal.

The agent proposes. The harness certifies. That boundary is the point of the tool,
so the MCP surface is built to preserve it rather than route around it.

## Transports

| | stdio | HTTP |
|---|---|---|
| Script | `mcp/StatefulClanker.Mcp.ps1` | `mcp/StatefulClanker.McpHttp.ps1` |
| Started by | the MCP client | you, manually |
| Use when | the client launches a local command | the client only accepts a URL |

Both share `mcp/StatefulClanker.McpCore.ps1`, so the tool surface is identical.

### stdio

```powershell
.\Install-McpServer.ps1 -Client claude-code   -ProjectPath C:\work\myproject
.\Install-McpServer.ps1 -Client claude-desktop -ProjectPath C:\work\myproject -Write
.\Install-McpServer.ps1 -Client opencode      -ProjectPath C:\work\myproject
.\Install-McpServer.ps1 -Client vscode        -ProjectPath C:\work\myproject
.\Install-McpServer.ps1                       # generic snippet, no file written
```

Only `-Write` touches a config file, and it keeps a `.bak`.

### HTTP

```powershell
pwsh -NoProfile -File .\mcp\StatefulClanker.McpHttp.ps1 -ProjectPath C:\work\myproject -Port 7337
```

It prints a bearer token and writes connection details to
`%LOCALAPPDATA%\StatefulClanker\mcp-http.json`.

```text
Endpoint: http://127.0.0.1:7337/mcp
Header:   Authorization: Bearer <token>
Health:   http://127.0.0.1:7337/health   (no auth)
```

The listener binds to the loopback interface only and requires the token. `-NoAuth`
disables the token; only use it if you understand that any local process can then
drive your projects.

> **Reachability caveat.** A loopback endpoint only works for a client that makes the
> HTTP request *from your machine*. Some products' "connectors" are fetched by the
> vendor's own backend, which cannot reach `127.0.0.1` on your laptop — for those,
> stdio is the answer, or a tunnel you set up deliberately. Test your specific app
> against `/health` before assuming.

It is built on a raw `TcpListener` rather than `System.Net.HttpListener` on purpose:
`HttpListener` requires Administrator rights or a `netsh http add urlacl` reservation
on Windows, which is a hostile install step for a local dev tool.

## Multiple projects, one registration

`-ProjectPath` sets the *default* project. Every tool also takes an optional
`project` argument, and `project_use` switches the default for the session. One
registered server drives as many projects as you like.

## Tools

### Project

| Tool | Purpose |
|---|---|
| `project_init` | Initialize or migrate durable state in a directory |
| `project_use` | Set the default project for this session |
| `project_status` | Goal, plan approval, cycle state, task summary |
| `goal_set` | Set or replace the project goal |

### Tasks and plans

| Tool | Purpose |
|---|---|
| `task_list` / `task_show` | Read the task graph |
| `task_add` | Add a task with acceptance criteria, retrieval, relations |
| `task_retry` | Reset to ready, invalidating affected dependents |
| `task_block` | Block with a reason |
| `plan_import` | Import a JSON plan/task graph |
| `task_complete` / `plan_approve` | **Gated.** See below. |

### Execution

| Tool | Purpose |
|---|---|
| `run_start` | Start ONE cycle **detached**; returns immediately |
| `run_parallel` | Start SEVERAL ready tasks at once, each in its own git worktree |
| `run_status` | Poll: in-flight, active agents, log tail |

### Providers

| Tool | Purpose |
|---|---|
| `provider_list` | Show configured providers and the default/critic/validator assignment |
| `provider_set` | Add or update a provider; optionally assign it. **Required before the first `run_start`** |
| `provider_test` | Dispatch a probe prompt and report whether the provider is genuinely usable |

Provider configuration lives only in `config.json` and has no CLI command, so
without `provider_set` a freshly installed server can be connected but can never
actually run anything.

`provider_set` validates before writing: the command must exist on PATH, and `args`
must contain `{prompt}` or `{promptFile}`, or the worker receives no task at all.

`provider_test` exists because the two realistic failures are both quiet. An expired
CLI login exits nonzero with an auth message; a permission-gated headless CLI exits
**zero having produced nothing**, which then surfaces much later as a critic
rejecting an empty result. The probe names both directly.

### Observation

`direction_add`, `telemetry_active`, `telemetry_history`,
`telemetry_run`, `context_faults`, `compilation_get`, `proposal_get`,
`progress_history`, `events_recent`.

## Running a cycle is asynchronous

A cycle is worker + critic + validator in sequence — tens of seconds at best, and
unbounded with a slow provider. That cannot be a blocking tool call, so `run_start`
spawns the cycle detached and returns a handle in well under a second.

```text
run_start  -> { taskId, processId, logPath }
run_status -> { inFlight, processAlive, busyTasks, activeAgents, logTail, errorTail }
```

Poll `run_status` until `inFlight` is false, then read `task_show` and
`progress_history` to find out what actually happened.

### Running several tasks at once

`run_parallel` dispatches up to `maxConcurrent` ready tasks simultaneously. Each
gets **its own git worktree**, so two workers cannot overwrite each other's files.
When a task's cycle passes, its worktree is committed and merged back into the main
checkout; when it fails, the worktree is discarded.

Requirements: the project must be a git repository with a **clean working tree**.
Both are refused with a clear message rather than risking a destructive merge.

Worktree isolation is used because tasks declare what they **read** (`retrieval`,
`evidence`) and never what they **write**. The scheduler therefore cannot know
whether two ready tasks will touch the same file. On a shared checkout that is
silent corruption — both workers report success and one overwrites the other. A
worktree turns it into an explicit merge-time question instead.

When two tasks do collide, the first merges and the second is **held**: the merge is
aborted so the main tree is never left with conflict markers, the work is preserved
on its `sc/task/<id>` branch, and the task returns to `needs_rework` saying why.

**Merging cleanly is not the same as still working.** Two changes that each passed
their own review can break together with no textual conflict — a renamed function
one worker updated only within its own files, a caller left pointing at a changed
signature. Git resolves text; nothing checked semantics. Run your own suite after a
multi-task merge; `run_parallel` warns you when more than one branch landed.

**Only one BATCH runs at a time per project.** This is enforced with an atomic lock
file, not with task status. Task status is not usable as a lock: the detached process
does not mark a task `running` until it has started, so two `run_start` calls
milliseconds apart both see an idle project and both launch. That was observed in
testing — two cycles on one task, fighting over the same state. The harness itself has
no locking at all, and `maxConcurrent` in `config.json` is dead config that nothing
reads.

A second `run_start` while one is in flight returns an error telling you to poll.

## Gated tools

`task_complete` and `plan_approve` are **disabled by default**.

Both bypass the validation gate: `task_complete` marks a task done with no critic or
validator, and `plan_approve` satisfies `requireHumanApprovalForPlan`. An agent that
can approve its own plan and then complete its own tasks has routed around every
check the tool exists to provide, and `progress_history` would fill with
`human-commit` records that no human made.

They are still reachable from the CLI, where they are recorded as human authority.

To enable them for MCP anyway, in `.statefulclanker/config.json`:

```json
{
  "mcp": { "allowHumanAuthorityTools": true }
}
```

`project_status` reports the current setting as `humanAuthority`.

## Errors

Tool failures come back as a **result with `isError: true`**, not as a JSON-RPC
protocol error, so the model sees the message and can react. Protocol errors are
reserved for genuinely malformed requests. Every response echoes the request `id`,
including on the failure paths.

## A worked session

```text
project_use    { project: "C:\\work\\myproject" }
project_init   {}
goal_set       { text: "Add a local-first semantic cache" }

task_add       { taskId: "cache-index",
                 title: "Implement the cache index",
                 instruction: "Implement the index described in docs/cache.md.",
                 accept: ["Tests pass", "Existing behaviour unchanged"],
                 retrieval: ["docs/cache.md", "src/*.ps1"] }

run_start      { taskId: "cache-index" }
run_status     {}                       -> inFlight: true   ... poll ...
run_status     {}                       -> inFlight: false

task_show      { taskId: "cache-index" } -> status: needs_rework
                                            blockReason: "Critic rejected worker result."
context_faults {}                        -> what the worker said it was missing
task_retry     { taskId: "cache-index" } -> after widening retrieval
```

A rejection is the system working. Read `progress_history` to tell activity from
progress: `advanced: false` with a repeating `inputFingerprint` means the cycle is
spinning, and the packet needs re-scoping rather than another attempt.

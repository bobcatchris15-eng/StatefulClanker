# StatefulClanker MCP control plane

StatefulClanker is steered conversationally over MCP while the resident Windows application owns active-project selection, machine configuration, telemetry, and durable orchestration.

Priorities are explicit:

1. **Preserve human intent.** Aggressively clarify material ambiguity and maintain current human authority faithfully.
2. **Keep the human informed.** Surface meaningful project-state changes without flooding the conversation.
3. **Delegate execution.** Build semantic tasks and dispatch configured worker backends.

## Active project and resident host

The Windows app writes its active project and MCP endpoint under:

```text
%LOCALAPPDATA%\StatefulClanker\
  active-project.txt
  mcp-http.json
```

The loopback HTTP endpoint is bearer-token protected. An explicit `project` tool argument wins; a deliberate headless `-ProjectPath` is next; otherwise MCP follows the app's active project. Missing active projects never silently fall back to another saved project.

Clients requiring stdio run `mcp\StatefulClanker.Mcp.ps1`. While the app is running, ordinary stdio RPC is bridged into the resident HTTP authority. Without the resident app, stdio falls back to the same in-process tool surface for headless use.

## Protocol eras

StatefulClanker intentionally serves two MCP behavior families from the same endpoint.

### Legacy era (through 2025-11-25 behavior)

Legacy clients use the ordinary `initialize` handshake and the existing tool/resource RPC shape. StatefulClanker does **not** advertise legacy `resources/subscribe`, because it does not implement the old standalone event stream.

### Modern era (`2026-07-28`)

Modern MCP is stateless:

- there is no `initialize` handshake;
- clients may probe with `server/discover`, but discovery is optional;
- every request carries `params._meta["io.modelcontextprotocol/protocolVersion"] = "2026-07-28"` and request-scoped client metadata/capabilities;
- every normal modern result receives `_meta["io.modelcontextprotocol/serverInfo"]`;
- Streamable HTTP requires `MCP-Protocol-Version` and `Mcp-Method` headers;
- `Mcp-Name` is required when the method mirrors a tool/resource name (`tools/call`, `resources/read` here);
- `Mcp-Session-Id` is invalid on modern requests;
- header/body disagreement fails closed.

`server/discover` advertises both `2026-07-28` and the supported legacy revision, server capabilities, instructions, and cache hints.

The stdio bridge inspects modern request metadata and adds the equivalent modern routing headers when forwarding to the resident HTTP server, so protocol era is preserved across transports.

## Modern subscriptions and durable events

Human-facing project changes are persisted in:

```text
.statefulclanker/control/events.jsonl
.statefulclanker/control/state.json
```

Events are `fyi`, `attention`, or `human_required`, with a monotonically increasing sequence.

Modern clients may open `subscriptions/listen` for:

```text
statefulclanker://project/current/control-events
```

The first stream message is `notifications/subscriptions/acknowledged` for the honored resource subscription. Later durable sequence changes emit `notifications/resources/updated` with the subscription id in `_meta`.

Push is only a wake-up signal. Correct resume behavior is always:

```text
control_events_since(since=<last consumed cursor>)
```

A lost stream therefore loses no project state.

## Human authority

Material human direction should be maintained with stable directive ids:

```text
directive_set
  -> reconcile full current directive set
  -> intent_apply
```

Updating the same directive id supersedes the old active wording. Historical directive revisions remain audit-only. Dispatch is blocked while current directives and normalized Intent are unreconciled.

Workers receive Current Human Directives and reconciled Intent in every compiled packet. Inherent workers can also be authorized to call separate read-only tools for direct human evidence and normalized Intent.

## Worker backends

Task semantics do not depend on execution transport.

- `cli` backend: delegate the inner agent loop to Codex/Claude/OpenCode/Antigravity/Gemini/another configured CLI.
- `api` backend: StatefulClanker calls a machine-local inference connection directly and owns the bounded tool loop.

Semantic-size/provider routing selects the backend; critic/validator/freshness/event behavior is shared.

## Worker capability tools

The conversational plane can inspect and modify inherent-worker execution policy with:

- `worker_policy_get`
- `worker_policy_apply`
- `worker_source_set`
- `worker_source_remove`
- `worker_source_tools`
- `worker_profile_set`
- `worker_profile_remove`

Machine grants define the maximum possible capability set. Named profiles, project policy, role/stage policy, and task-local policy only narrow it.

External MCP worker tools use capability ids such as:

```text
mcp.toaster.search
mcp.mempalace.lookup
```

Registering a source does not itself grant all of its tools.

## Discovering MCP servers from other harnesses

StatefulClanker can scan this machine for MCP servers already configured in other AI harnesses (Claude Desktop, Cursor, VS Code, OpenCode, Claude Code CLI; Windsurf/Antigravity best-effort) and let a human opt a whole discovered server in for worker use, in one step, through the same `sources` machine catalog used by `worker_source_set`.

Sources are marked `verified=true` when the config file location and shape are confirmed (Claude Desktop, Cursor, VS Code) or `verified=false` when the path is a best-effort guess (OpenCode, Claude Code CLI, Windsurf, Antigravity). A `verified=false` harness that yields nothing found is reported as "not found," never as an error, and CLI output always shows the verified/unverified distinction.

```text
StatefulClanker.ps1 mcp discover      # scan + probe every candidate, cache results
StatefulClanker.ps1 mcp list          # print the cached results without rescanning
StatefulClanker.ps1 mcp import -Message <name>   # opt a whole discovered server in (all its tools)
StatefulClanker.ps1 mcp remove -Message <name>   # undo the import
```

`discover` probes each candidate server (spawning stdio processes or hitting HTTP `initialize`/`tools/list`, bounded to 15s) and reports name, harness, verified yes/no, probe result (ok with tool count, or fail with reason), and whether it is already imported. `import` writes the whole server into the machine catalog exactly as `worker_source_set` would, so its tools immediately flow through `Get-SCExternalWorkerToolRecords` as `mcp.<name>.<tool>` capabilities, gated by the same profile/project/role/stage/task policy layers as any manually-configured source. Import is per-server, not per-tool — granting a server grants all its current tools, subject to normal capability policy narrowing it later.

Both `stdio` (`command`/`args`/`env`) and `http`/`streamable-http` (`url`/`headers`) transports are supported for imported sources.

## Task authoring over MCP

`task_add` supports:

- semantic `size`;
- `source[]` and `intentRef[]`;
- `capabilityProfile`;
- `toolAllow[]`;
- `toolDeny[]`.

`plan_apply` accepts `SCPLAN 1`, including matching fields:

```text
capability-profile research-readonly
tool-allow intent.*
tool-allow mcp.toaster.search
tool-deny builtin.run_command
```

Capability policy is part of the task definition hash, so changing it invalidates older work.

## Main control-plane surfaces

### Authority

`project_init`, `project_use`, `project_status`, `goal_set`, `directive_set`, `directive_list`, `directive_get`, `directive_history`, `directive_retire`, `intent_apply`, `source_add`, `source_get`, `source_list`.

### Planning/execution

`plan_apply`, `plan_import`, `task_list`, `task_show`, `task_add`, `task_retry`, `task_block`, `run_start`, `run_parallel`, `run_status`, `project_review`, `autofill_status`, `autofill_control`.

### Human awareness

`control_snapshot`, `control_events_since`, project resources, telemetry tools, review/progress/history tools.

### Worker policy

`worker_policy_get/apply`, `worker_source_*`, `worker_profile_*`.

## Worker uncertainty

Workers may stop non-advancing work with:

```text
CONTEXT_REQUEST: <missing context>
INTENT_QUESTION: <material ambiguity>
INTENT_CONFLICT: <contradiction>
```

These are successful uncertainty detection, not permission to guess. Intent questions return to current authority/human clarification.

## Human-authority gates

Worker output is proposal evidence. Plan approval/manual task completion/hold-clear tools remain human-authority shortcuts and are disabled over MCP unless `mcp.allowHumanAuthorityTools` is explicitly enabled.

# StatefulClanker MCP control plane

StatefulClanker is steered by a conversational agent through MCP while the resident Windows application owns project selection, telemetry, provider configuration, and durable orchestration state.

The priorities are deliberately ordered:

1. **Intent fidelity:** clarify the human's meaning and transmit it faithfully into durable authority.
2. **Human awareness:** surface meaningful project-state changes back to the human.
3. **Execution:** semantically decompose work and delegate implementation/review to provider CLI sessions.

The conversational model is the planner and human-facing reasoning plane. StatefulClanker does not use file counts, regexes, line counts, or token thresholds as substitutes for semantic decomposition.

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

It is loopback-only and bearer-token protected. Calls that omit `project` follow the project currently selected in the StatefulClanker application.

### stdio

Clients that launch MCP commands use:

```powershell
pwsh -NoProfile -File <install>\mcp\StatefulClanker.Mcp.ps1
```

While the Windows app is running ordinary stdio RPC calls bridge to the resident HTTP authority. The stdio bridge handles project update subscriptions locally against the same durable event cursor, so it does not create a second state authority.

If no resident server exists it falls back to an in-process MCP server for headless use.

`Install-McpServer.ps1` emits or writes client registration without pinning a project by default.

## Active project

The Windows app stores its machine-local project registry and active project under:

```text
%LOCALAPPDATA%\StatefulClanker\
```

The selected project is written to `active-project.txt` for MCP. An explicit `project` argument wins; a deliberately headless server may use `-ProjectPath`; otherwise the app selection is authoritative.

If the last-active project is missing, StatefulClanker enters a no-active-project state. It never silently substitutes another saved project.

## Control-plane instructions

The MCP server instructions explicitly tell the conversational model that its primary job is to prevent semantic loss between the human and disposable workers.

It is instructed to:

- **aggressively clarify material ambiguity with the human**
- prefer the host's structured question/questionnaire/quiz mechanism when available
- ask contrastive questions when two reasonable interpretations differ materially
- avoid optimizing for fewer human turns
- maintain current direct human decisions as named directives
- treat the latest direct human word within a directive scope as authoritative
- ask when a newer statement might be a replacement, narrowing, exception, or separate rule
- reconcile current directives into a contradiction-free Intent Contract before dispatch
- semantically decompose work into bounded cold-start tasks
- treat worker `INTENT_QUESTION` / `INTENT_CONFLICT` as successful uncertainty detection
- subscribe to or poll the durable control-event inbox and keep the human informed about meaningful changes

This is part of the connector contract rather than advisory README prose.

## Current human directives versus Intent

Material current human direction should use `directive_set`, not merely `direction_add`.

Example:

```text
directive_set(
  id="ui-project-selection",
  scope="desktop.project-selection",
  text="Restore the exact last active project; never silently substitute another.",
  intentRefs=["REQ-PROJECT-RESTORE"]
)
```

Reusing the same directive id replaces its current value. The previous revision remains audit history but is excluded from ordinary worker context.

Directive tools:

- `directive_set` — set/replace latest direct human wording for a named scope
- `directive_list` — current authority only
- `directive_get` — one current directive
- `directive_history` — audit/debug only; never current specification
- `directive_retire` — remove a rule/decision from current authority

Every directive mutation sets a reconciliation gate. New worker compilation is blocked until the control plane reconciles the **entire current directive set** into the normalized Intent Contract with:

- `intent_apply` over MCP, or
- `intent replace` from the CLI

The resulting Intent revision records the exact directive revision/hash it reconciled.

The durable working authority chain is:

```text
current direct human directive/source
  -> normalized reconciled Intent
  -> plan
  -> task
  -> compiled worker truth packet
```

See `docs/INTENT_CONTRACT.md`.

## Durable human source artifacts

Current directive wording is persisted verbatim under `.statefulclanker/input/` and referenced as:

```text
human:h-20260916010203-ab12cd
human:h-20260916010203-ab12cd#L4-L11
```

Workers receive current directives directly. The compiled packet also exposes `stateRoot` and tells workers how to inspect a directive's source artifact when exact wording needs verification.

A task may still physically contain an old source reference created under a superseded directive. StatefulClanker filters such directive-origin sources from ordinary retrieval and compiled task metadata. Generic provenance sources remain available.

`source_add`, `source_get`, and `source_list` remain available for background/provenance material. Source history itself is not authority; `directive_list` determines which direct human wording is current.

## Event-driven human awareness

StatefulClanker maintains two logs for different purposes:

```text
.statefulclanker/events.jsonl          complete low-level audit log
.statefulclanker/control/events.jsonl  sequenced control-plane inbox
.statefulclanker/control/state.json    latest control-event sequence
```

Control events are classified:

- `fyi` — routine detail that may be batched
- `attention` — meaningful progress/failure/change normally worth summarizing
- `human_required` — ambiguity, directive reconciliation, or a hold that should return to the human instead of being guessed through

Every event has a monotonically increasing `sequence`.

### Pull/resume path

The correctness path is:

```text
control_events_since(since=<last cursor>)
```

The response returns both the new cursor and all matching durable events after the previous cursor. A restarted session can therefore resume without losing updates.

`control_snapshot` returns the current project-facing state in one call:

- project goal/revision
- current human directives
- directive reconciliation gate and pending directive ids
- reconciled Intent
- active plan/approval state
- project hold
- task counts
- active workers
- latest event cursor

### MCP resources

The current project exposes:

```text
statefulclanker://project/current/control-events
statefulclanker://project/current/directives
statefulclanker://project/current/snapshot
```

`resources/list` and `resources/read` work over both transports.

### Push path: MCP 2026-07-28

For clients supporting modern subscriptions, open `subscriptions/listen` with a resource subscription for:

```text
statefulclanker://project/current/control-events
```

For Streamable HTTP the request uses MCP 2026-07-28 headers and the response remains open as Server-Sent Events. The first stream message acknowledges the subscription. When the durable control sequence advances, StatefulClanker emits:

```text
notifications/resources/updated
```

The notification is intentionally only a **wake-up signal**. The client then reads the resource or calls `control_events_since` from its saved cursor. Events never exist only in the network stream.

The stdio transport emits the same subscription acknowledgement/update messages while reading the same durable cursor.

Legacy `initialize` remains supported for existing clients, but does not falsely advertise the older `resources/subscribe` mechanism. Modern capability discovery is exposed through `server/discover` with MCP `2026-07-28` support.

A host may or may not choose to wake/re-enter its language-model loop when it receives a server notification. StatefulClanker therefore treats push as a latency improvement and the durable cursor as the correctness mechanism.

See `docs/CONTROL_PLANE_DATA_FLOW.md`.

## Compact plans

`plan_apply` accepts a complete compact plan directly from the conversational agent:

```text
SCPLAN 1
plan active-project
summary Make the selected Windows project the resident MCP authority.
intent REQ-ACTIVE-PROJECT

task t-021
size small
title persist active project
instruction Persist the exact selected project as machine-local application state.
intent REQ-ACTIVE-PROJECT
accept the same project is selected after application restart
accept a missing project produces no-active-project state
accept no other project is silently substituted
end
```

The canonical format is documented in `docs/TASK_RECORD_FORMAT.md`. `.json` plan import remains supported for compatibility.

## Semantic task size and provider CLIs

Tasks may declare `tiny`, `small`, `medium`, or `large`. The conversational planner assigns this semantically.

Provider routing precedence is:

1. explicit run override
2. critic/validator provider
3. task-specific provider
4. `providerBySize.<task size>`
5. `defaultProvider`

Execution remains ordinary configured CLI invocation (`codex`, `agy`, `claude`, `opencode`, Gemini, local tools, etc.), preserving compatibility with consumer-subscription and local-model tooling rather than requiring direct provider API billing.

## Main tool surface

### Project/current authority

- `project_init`
- `project_use`
- `project_status`
- `goal_set`
- `directive_set`
- `directive_list`
- `directive_get`
- `directive_history`
- `directive_retire`
- `intent_apply`
- `direction_add` — legacy unstructured compatibility note/source capture

### Planning/tasks

- `plan_apply`
- `plan_import`
- `task_list`
- `task_show`
- `task_add`
- `task_retry`
- `task_block`

### Execution/review

- `run_start`
- `run_parallel`
- `run_status`
- `project_review`
- `review_history`
- `review_get`
- `hold_status`

A normal task cycle is:

```text
compile truth packet
  -> provider CLI worker
  -> critic CLI
  -> validator CLI
  -> freshness check
  -> commit or reject
```

### Observation

- `control_snapshot`
- `control_events_since`
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

## Worker ambiguity

Workers may emit:

```text
CONTEXT_REQUEST: <specific missing state>
INTENT_QUESTION: <specific ambiguity>
INTENT_CONFLICT: <specific contradiction>
```

Intent questions/conflicts become durable escalations and `human_required` control events. The conversational control plane should use current state first and then return to the human for unresolved intent rather than instructing the worker to guess.

## Authority gates

Worker output remains a proposal, not authority. Critic and validator stages inspect the same truth packet.

`task_complete`, `plan_approve`, and `hold_clear` are human-authority shortcuts/gates and remain disabled over MCP unless `mcp.allowHumanAuthorityTools` is explicitly enabled.

## Headless operation

The native Windows application is the normal product surface, but a fixed-project server can still be run directly:

```powershell
pwsh -NoProfile -File .\mcp\StatefulClanker.McpHttp.ps1 -ProjectPath C:\work\project -Port 7337
```

Likewise stdio may use `-ProjectPath` without the app. This compatibility path does not change the Windows-first product model.

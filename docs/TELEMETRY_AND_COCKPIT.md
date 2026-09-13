# StatefulClanker telemetry and cockpit

## Cockpit and telemetry

StatefulClanker records engine-owned subagent and context telemetry under `.statefulclanker/telemetry/`.

- `telemetry/active/` contains live agent records and heartbeats.
- `telemetry/runs/` contains durable historical invocation records.
- `telemetry/events.jsonl` is an append-only lifecycle stream.
- `telemetry/context-faults.jsonl` records explicit worker requests for missing context.

Each worker, critic, and validator invocation records its agent id, parent agent, task, stage, provider, lifecycle, process id, start/end/heartbeat times, prompt and retrieved-context sizes, compilation/input fingerprint pointers, command, exit code, verdict when applicable, and output file paths. Provider-specific usage/model/quota fields can be added later without changing the baseline control-plane model.

Inspect from the CLI:

```powershell
.\StatefulClanker.ps1 telemetry active
.\StatefulClanker.ps1 telemetry history
.\StatefulClanker.ps1 telemetry faults
.\StatefulClanker.ps1 telemetry show -RunId <agent-id>
.\StatefulClanker.ps1 context show -CompilationId <compilation-id>
.\StatefulClanker.ps1 progress history
```

A `CONTEXT_REQUEST:` is not merely informational telemetry: the corresponding worker cycle is non-advancing and does not create a completion proposal.

## Lightweight desktop cockpit

The prototype cockpit is a native WinForms PowerShell app; there is nothing to install or build:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\desktop\StatefulClanker.Cockpit.ps1 -ProjectPath C:\path\to\your\project
```

It shows active subagents, task state, recent events, historical subagent runs, and a Direction pane. `Record direction` invokes StatefulClanker's `event` command, which both writes the human direction into the durable event stream and advances the project direction revision. Any older in-flight compilation therefore becomes stale at its next freshness gate. `Run next task` invokes the engine.

The cockpit is intentionally a thin control surface rather than a complete state debugger; compilation, proposal, context-fault, and progress inspection remain available through the CLI/MCP surfaces.

## MCP server

`mcp/StatefulClanker.Mcp.ps1` is a lightweight stdio MCP server intended for provider desktop apps or other conversational front ends.

Example process configuration:

```text
command: powershell.exe
args:
  -NoProfile
  -ExecutionPolicy
  Bypass
  -File
  C:\path\to\StatefulClanker\mcp\StatefulClanker.Mcp.ps1
  -ProjectPath
  C:\path\to\your\project
```

Current MCP tools:

- `project_status`
- `task_list`
- `telemetry_active`
- `telemetry_history`
- `telemetry_run`
- `context_faults`
- `compilation_get`
- `progress_history`
- `proposal_get`
- `direction_add`

`direction_add` routes through the harness rather than appending JSONL directly, so the same direction-revision freshness semantics apply.

The desktop cockpit and MCP server intentionally consume the same on-disk project state. The repository also retains a Windows smoke workflow, but runtime correctness should be judged from the durable state/compile/propose/validate/commit invariants rather than from the UI surface.

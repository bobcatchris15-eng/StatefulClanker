# StatefulClanker telemetry and cockpit

## Cockpit and telemetry

StatefulClanker records engine-owned subagent telemetry under `.statefulclanker/telemetry/`.

- `telemetry/active/` contains live agent records and heartbeats.
- `telemetry/runs/` contains durable historical records.
- `telemetry/events.jsonl` is an append-only lifecycle stream.

Each worker, critic, and validator invocation records its agent id, parent agent, task, stage, provider, lifecycle, process id, start/end/heartbeat times, prompt and retrieved-context sizes, command, exit code, verdict when applicable, and output file paths. Provider-specific usage/model/quota fields can be added later without changing the baseline schema.

Inspect from the CLI:

```powershell
.\StatefulClanker.ps1 telemetry active
.\StatefulClanker.ps1 telemetry history
.\StatefulClanker.ps1 telemetry show -RunId <agent-id>
```

## Lightweight desktop cockpit

The prototype cockpit is a native WinForms PowerShell app; there is nothing to install or build:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\desktop\StatefulClanker.Cockpit.ps1 -ProjectPath C:\path\to\your\project
```

It shows active subagents, task state, recent events, historical subagent runs, and a Direction pane. `Record direction` writes the conversation note into StatefulClanker's durable event stream; `Run next task` invokes the engine. This is intentionally a thin control surface rather than an IDE replacement.

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
- `direction_add`

The desktop cockpit and MCP server intentionally consume the same on-disk state and telemetry. The Windows smoke workflow parses all PowerShell entrypoints and exercises the full worker/review/telemetry lifecycle.

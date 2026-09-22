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

## Resident desktop cockpit

The installed .NET 8 Windows host is now the primary resident cockpit. The older PowerShell cockpit remains useful as a lightweight fallback:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\desktop\StatefulClanker.Cockpit.ps1 -ProjectPath C:\path\to\your\project
```

The resident cockpit is organized around three persistent regions:

- left rail: project list above a compact recent-activity feed;
- center: Overview, Activity & Telemetry, Integrations, Endpoints & Routing, and Connections tabs;
- right rail: durable task state and task-level diagnostics/actions.

Overview is intentionally a control surface rather than a dashboard collage. Its two dominant panes are the live worker/reviewer blinkenlights and the embedded project TUI/console. Everything else is compressed into motherboard/server-style readouts: project/MCP/autofill state, worker/queue counts, Intent revision, and the exact next healthy/unoccupied endpoint predicted by the machine-wide round-robin router. Large usage, authority, event, and telemetry views stay off the Overview page; the durable event stream, active/recent worker telemetry, and context faults live on Activity & Telemetry.

### Embedded project terminal

The Overview terminal is a real ConPTY-backed terminal using the Windows Terminal renderer, not a simulated textbox console. Every session starts with the active project as its working directory. The WinForms/WPF bridge explicitly returns keyboard focus to the renderer on click/entry, enables Win32 input records, captures Tab and direction keys for TUIs, treats navigation/editing keys as terminal input rather than dialog navigation, and re-lays out the host on resize. PowerShell, agy, Goose, bundled Pi, OpenCode, and custom commands can all run in the same interactive pane.

Presets include:

- PowerShell;
- Antigravity CLI (`agy`);
- OpenCode (`opencode`);
- OpenCode mini (`opencode mini`);
- a custom command.

Agent CLI presets deliberately launch through PowerShell and keep the shell alive after the TUI exits. This matches opening PowerShell in the project directory and manually entering `agy` or `opencode`, including PowerShell resolution of aliases, scripts, and command shims.

The embedded terminal has the same local authority as the desktop user running StatefulClanker. It is **not** constrained by StatefulClanker's worker capability profiles. Commands entered there, and coding-agent TUIs launched there, can read/write/execute according to the user's Windows permissions and the CLI's own permission model. Treat it as an operator shell, not as a bounded worker.

Changing projects terminates the previous embedded terminal and opens a fresh PowerShell session rooted in the newly active project. Closing the resident host also terminates the embedded terminal process tree.

Task-specific run/critic/validation diagnostics remain available from the right task rail; deeper compilation/proposal/progress inspection remains available through CLI/MCP surfaces.

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

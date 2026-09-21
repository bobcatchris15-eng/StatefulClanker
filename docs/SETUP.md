# StatefulClanker Windows setup

StatefulClanker is a Windows-first resident orchestration application. The normal installation gives you a native tray app, a resident loopback MCP control plane, project-scoped telemetry, integration status, configurable CLI worker backends, and machine-local direct-inference connections.

The conversational agent clarifies intent, plans, and semantically decomposes work. StatefulClanker persists current Human Directives and reconciled Intent, compiles bounded context, dispatches the selected worker backend, records receipts, and applies review/freshness gates.

## Requirements

For an installed release:

- Windows x64
- PowerShell 7 recommended (`winget install Microsoft.PowerShell`)
- Git for parallel worktree execution and commit telemetry
- at least one worker backend:
  - a non-interactive coding/agent CLI already installed and signed in, such as Claude, Antigravity/`agy`, Codex, OpenCode, Gemini, or another local tool; **or**
  - an OpenAI-compatible inference endpoint such as Ollama, LM Studio, vLLM, OpenRouter, or another compatible provider/gateway

The packaged Windows application is self-contained and does not require a separate .NET runtime.

Building an installer from source additionally requires the .NET 8 SDK and Inno Setup 6.

## Install

Run:

```text
StatefulClankerSetup-0.8.13.exe
```

The installer is per-user and normally needs no administrator rights. It can create a startup shortcut so StatefulClanker starts when the user signs in.

The native application remains in the Windows notification area. Closing its main window hides it; use **Exit** from the tray menu to stop the application and its resident MCP child process.

## Add a project

Open StatefulClanker and choose **+ Add / open project** in the left project pane.

Select the actual project directory, not the StatefulClanker install directory. If the folder is not initialized, the app offers to create `.statefulclanker/` state there.

The project becomes the active project and the resident MCP control plane follows it.

StatefulClanker stores machine/application state under:

```text
%LOCALAPPDATA%\StatefulClanker\
```

That includes the saved project registry, last active project, resident MCP connection details, and machine-local API connection profiles.

Project authority remains in:

```text
<project>\.statefulclanker\
```

If the last-active project later disappears or moves, startup enters **No active project**. StatefulClanker does not pick a different saved project on its own.

## Configure worker backends

Project backend/routing configuration still lives in the active project's `.statefulclanker/config.json`.

A backend can be one of two types.

### CLI harness backend

```json
"opencode": {
  "type": "cli",
  "command": "opencode",
  "args": ["run"],
  "mode": "stdin"
}
```

Older project configs that omit `type` remain compatible and are treated as `cli`.

### Direct API backend

```json
"local-qwen": {
  "type": "api",
  "connection": "local-qwen"
}
```

The `connection` name points to a machine-local API profile configured through the app. Project files never contain the secret itself.

Example routing:

```json
{
  "routing": {
    "maxRouteAttempts": 6
  },
  "providers": {
    "opencode": {
      "type": "cli",
      "command": "opencode",
      "args": ["run"],
      "mode": "stdin",
      "disabled": false
    }
  }
}
```

Automatic API inference is selected from `.statefulclanker/routing/target-pool.json`, maintained from the **Connections** page or through the Clanker's target-pool MCP tools. Worker, critic, validator, and task sizes do not pin particular models. The `providers` object above is retained for CLI/legacy compatibility and explicit operator overrides.


The task's semantic size is assigned by the conversational planner. The runtime only uses that declared size as a routing hint. CLI and API backends can be mixed freely for workers, critics, and validators.

## Configure inference connections

Open the **Connections** tab in the Windows app. Choose a service preset, follow its setup instructions, enter any required account/key values, then use **Test & discover**. Save is enabled only after the service authenticates and returns a model catalog.

A connection profile contains:

- connection id
- base URL
- model id
- tool protocol (`native` or `text`)
- optional API key or API-key environment variable
- optional extra HTTP headers
- maximum worker loop steps

Built-in presets fill the usual base URLs for:

```text
Ollama     http://127.0.0.1:11434/v1
LM Studio  http://127.0.0.1:1234/v1
vLLM       http://127.0.0.1:8000/v1
OpenRouter https://openrouter.ai/api/v1
```

Select discovered models and add them to the active project as endpoints, then use **Connections / target pool** to set priority and the worker/validator target pool. Use **Custom OpenAI-compatible** for any other compatible provider or gateway. OpenCode can remain a CLI endpoint using its own provider catalogue.

API keys typed into the app are encrypted with Windows DPAPI for the current Windows user. Alternatively specify an environment variable such as `OPENROUTER_API_KEY` and leave the key field empty.

**Test** probes the connection's `/models` endpoint. **Add backend to active project** adds a project backend that references the selected machine connection by id.

See `docs/DIRECT_INFERENCE.md` for the direct worker protocol and security boundary.

## Connect a conversational client

Open the **Integrations** tab.

The top of the page shows the resident Streamable HTTP endpoint and the stdio bridge command. Below that, known MCP clients show whether they appear installed, whether StatefulClanker is already registered, and whether the config location is verified.

For verified integration targets, **Register selected** writes/updates the MCP registration using the existing integration catalogue. For an unverified client/config path, the app refuses to write a guessed location; copy the stdio command or endpoint into that client's MCP settings instead.

### stdio registration

The normal stdio entry is conceptually:

```json
{
  "command": "pwsh",
  "args": [
    "-NoProfile",
    "-NonInteractive",
    "-File",
    "C:\\...\\StatefulClanker\\mcp\\StatefulClanker.Mcp.ps1"
  ]
}
```

Do **not** add `-ProjectPath` for the normal resident setup. The stdio shim bridges into the running app and follows its current active project.

### Streamable HTTP

The resident application starts the loopback server automatically. Connection details are written to:

```text
%LOCALAPPDATA%\StatefulClanker\mcp-http.json
```

The default endpoint is:

```text
http://127.0.0.1:7337/mcp
```

It requires the bearer token displayed/copied through the Integrations page. Because this is loopback-only, a cloud/server-side connector cannot reach it directly.

## Start a conversational project

Once a client is connected, the MCP `initialize` response instructs the conversational model to act as StatefulClanker's control plane.

For substantial work the expected sequence is:

1. Read the project snapshot, current Human Directives, reconciled Intent, task graph, and unconsumed control events.
2. Use the host questionnaire/question tool aggressively to clear material ambiguity.
3. Update the stable directive id for material human direction rather than leaving competing current rules.
4. Reconcile the full current directive set into a contradiction-free Intent revision.
5. Build a semantic task graph, preferably as compact `SCPLAN 1` text.
6. Apply it with `plan_apply`.
7. Dispatch ready tasks with `run_start` or `run_parallel`.
8. Consume live event notifications when supported and resume from the durable control-event cursor when needed.
9. Resolve `CONTEXT_REQUEST`, `INTENT_QUESTION`, and `INTENT_CONFLICT` rather than asking a worker to guess.

StatefulClanker deliberately blocks dispatch while current directives are awaiting Intent reconciliation.

## What worker execution looks like

### CLI backend

The compiled packet is delivered to the configured CLI by stdin or prompt-file argument. The provider's harness owns the inner coding/tool loop.

### API backend

StatefulClanker sends the compiled packet directly to the configured inference endpoint with one small bounded-worker system instruction. StatefulClanker itself owns the inner loop and exposes only read/search/write/replace, bounded PowerShell command execution, git diff, and finish/escalation tools.

`native` tool mode uses OpenAI-compatible function/tool calls. `text` mode uses one strict JSON tool command per model turn and exists primarily for local models/servers without reliable native function calling.

Both execution paths produce the same outer run receipts and flow through the same validator/freshness/commit machinery. Periodic whole-project review remains a separate critic + validator layer.

## Build from source

From a checkout on Windows:

```powershell
winget install Microsoft.DotNet.SDK.8
winget install JRSoftware.InnoSetup
.\install\Build-Installer.ps1 -Version 0.8.13
```

The build script publishes `src\StatefulClanker.Tray` as a self-contained `win-x64` executable and packages the app, PowerShell runtime, MCP scripts, docs, examples, skills, and local tests with Inno Setup.

Output is placed under:

```text
install\output\
```

## Headless compatibility

The Windows application is the normal product surface, but the CLI/runtime remains usable directly.

```powershell
cd C:\work\my-project
C:\path\to\StatefulClanker\StatefulClanker.ps1 init
```

A fixed-project HTTP control plane can be launched without the desktop app:

```powershell
pwsh -NoProfile -File C:\path\to\StatefulClanker\mcp\StatefulClanker.McpHttp.ps1 `
  -ProjectPath C:\work\my-project `
  -Port 7337
```

A stdio client may likewise launch `StatefulClanker.Mcp.ps1 -ProjectPath <path>` when deliberately operating headless.

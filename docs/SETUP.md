# StatefulClanker Windows setup

StatefulClanker is a Windows-first resident orchestration application. The normal installation gives you a native tray app, a resident loopback MCP control plane, project-scoped telemetry, integration status, and configurable provider CLI workers.

The conversational agent plans and semantically decomposes work. StatefulClanker persists that plan, compiles bounded context, launches provider CLIs, records receipts, and applies review gates.

## Requirements

For an installed release:

- Windows x64
- PowerShell 7 recommended (`winget install Microsoft.PowerShell`)
- at least one non-interactive coding/agent CLI already installed and signed in, for example Claude, Antigravity/`agy`, Codex, OpenCode, Gemini, or a local tool
- Git for parallel worktree execution and commit telemetry

The packaged Windows application is self-contained and does not require a separate .NET runtime.

Building an installer from source additionally requires the .NET 8 SDK and Inno Setup 6.

## Install

Run:

```text
StatefulClankerSetup-0.6.0.exe
```

The installer is per-user and normally needs no administrator rights. It can create a startup shortcut so StatefulClanker starts when the user signs in.

The native application remains in the Windows notification area. Closing its main window hides it; use **Exit** from the tray menu to stop the application and its resident MCP child process.

## Add a project

Open StatefulClanker and choose **+ Add / open project** in the left project pane.

Select the actual project directory, not the StatefulClanker install directory. If the folder is not initialized, the app offers to create `.statefulclanker/` state there.

The project becomes the active project and the resident MCP control plane follows it.

StatefulClanker stores only machine/application state under:

```text
%LOCALAPPDATA%\StatefulClanker\
```

That includes the saved project registry, last active project, and resident MCP connection details.

Project authority remains in:

```text
<project>\.statefulclanker\
```

If the last-active project later disappears or moves, startup enters **No active project**. StatefulClanker does not pick a different saved project on its own.

## Configure provider CLIs

The **Providers** tab reads the active project's `.statefulclanker/config.json` and shows:

- configured provider name
- command/executable
- whether the CLI is currently found
- default / critic / validator roles
- semantic `tiny`, `small`, `medium`, `large` routes

The shipped example demonstrates the configuration shape. Provider flags vary between CLI versions, so `provider_test` should be used after configuration rather than assuming a preset remains correct forever.

Example routing shape:

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

The task's semantic size is assigned by the conversational planner. The runtime only uses that declared size as a routing hint.

## Connect a conversational client

Open the **Integrations** tab.

The top of the page shows the resident Streamable HTTP endpoint and the stdio bridge command. Below that, known MCP clients show whether they appear installed, whether StatefulClanker is already registered, and whether the config location is verified.

For verified integration targets, **Register selected** writes/updates the MCP registration using the existing integration catalogue. StatefulClanker keeps backups where the integration helper already supports them.

For an unverified client/config path, the app refuses to write a guessed location. Copy the stdio command or endpoint into that client's MCP settings instead.

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

Once a client is connected, the MCP `initialize` response instructs the conversational model to act as StatefulClanker's planner/orchestrator.

For substantial work the expected sequence is:

1. Read project status and existing Intent Contract.
2. Use the host questionnaire/question tool to clear material ambiguity.
3. Record new human direction with `direction_add`; retain the returned `human:<id>` source reference.
4. Update the Intent Contract where clarified human meaning changes authority.
5. Build a semantic task graph, preferably as compact `SCPLAN 1` text.
6. Apply it with `plan_apply`.
7. Dispatch ready tasks with `run_start` or `run_parallel`.
8. Poll `run_status` and inspect project telemetry/review results.
9. Resolve `CONTEXT_REQUEST`, `INTENT_QUESTION`, and `INTENT_CONFLICT` rather than asking a worker to guess.

Example compact plan:

```text
SCPLAN 1
plan sample-change
summary Add the bounded behavior discussed with the human.
source human:h-0012#L1-L8
intent REQ-012

task t-001
size small
title implement bounded behavior
instruction Implement the requested behavior without changing adjacent interfaces.
source human:h-0012#L1-L8
intent REQ-012
retrieve src/*
accept the requested behavior is observable
accept existing interface behavior remains unchanged
end
```

See `docs/TASK_RECORD_FORMAT.md` for the format and `docs/MCP.md` for the full control-plane reference.

## What worker execution looks like

StatefulClanker does not require direct provider API credentials or API-rate billing. A task packet is written to a prompt file and the configured provider command is launched locally.

Depending on the CLI, that can mean a prompt-file argument or stdin, for example the equivalent of:

```text
provider-cli <non-interactive flags> <prompt-file>
```

or:

```text
type prompt-file | provider-cli <non-interactive flags>
```

The exact command remains provider configuration data. This preserves compatibility with consumer-subscription CLIs and local model runners.

## Build from source

From a checkout on Windows:

```powershell
winget install Microsoft.DotNet.SDK.8
winget install JRSoftware.InnoSetup
.\install\Build-Installer.ps1 -Version 0.6.0
```

The build script:

1. generates the multi-resolution application icon
2. publishes `src\StatefulClanker.Tray` as a self-contained `win-x64` executable
3. packages the app, PowerShell runtime, MCP scripts, docs, examples, skills, and local tests with Inno Setup

Output is placed under:

```text
install\output\
```

## Headless compatibility

The Windows application is the normal product surface, but the CLI/runtime remains usable directly.

Initialize a project:

```powershell
cd C:\work\my-project
C:\path\to\StatefulClanker\StatefulClanker.ps1 init
```

Run a fixed-project HTTP control plane without the desktop app:

```powershell
pwsh -NoProfile -File C:\path\to\StatefulClanker\mcp\StatefulClanker.McpHttp.ps1 `
  -ProjectPath C:\work\my-project `
  -Port 7337
```

A stdio client may likewise launch `StatefulClanker.Mcp.ps1 -ProjectPath <path>` when deliberately operating headless.

That compatibility path is useful for scripting and unusual environments, but it is not the default Windows application model.

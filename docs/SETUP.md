# Setup: from nothing to a running cycle

Installing StatefulClanker on a Windows machine and driving a project from a
desktop chat app.

`docs/MCP.md` is the reference for the tool surface. This page is the walkthrough.

**Time:** about 10 minutes. **You will need:** Windows, PowerShell 7, and at least
one CLI coding agent that you are already signed in to.

---

## The quick path: the installer

Download `StatefulClankerSetup-<version>.exe` and run it. It is a **per-user**
install, so there is no UAC prompt and no administrator rights are needed.

It offers to start StatefulClanker when you sign in. Either way you get a tray
icon; the app lives there and the window closes back to it rather than exiting.

Open it from the tray and work left to right through the tabs:

| Tab | What it does |
|---|---|
| **Projects** | Pick the folder holding your code, and initialize it |
| **Providers** | Pick the agent CLI that does the work, save it, then **Test** it |
| **Integrations** | Register the MCP server with your chat app in one click |
| **Server** | Only if your app wants a URL rather than a local command |

The **Integrations** tab always shows the exact connection details for whichever
app is selected — the stdio JSON block and the HTTP URL plus bearer token — so an
app the installer cannot write to automatically can still be set up by pasting.

Two buttons are worth calling out:

- **Providers → Test provider** dispatches a real probe prompt. Use it. The two
  failures you will actually hit are both quiet: an expired CLI login exits
  nonzero, and a permission-gated headless CLI exits *zero having done nothing*,
  which otherwise only shows up later as a critic rejecting an empty result.
- **Integrations → Register** merges into the app's config and keeps a timestamped
  backup. It refuses to touch a config file it cannot parse rather than
  overwriting the other MCP servers you have configured there.

Rows marked **UNVERIFIED** are best guesses — a preset command line, or a config
path that was not confirmed on a real install. They are starting points, which is
exactly why Test and Copy exist next to them.

### Building the installer yourself

```powershell
winget install JRSoftware.InnoSetup
.\install\Build-Installer.ps1 -Version 0.5.0
```

Output lands in `install\output\`.

---

The rest of this page is the manual path: what the installer automates, and what
to do when something does not work.

## Step 1 — Prerequisites

```powershell
$PSVersionTable.PSVersion      # need 7.x
git --version
```

If PowerShell 7 is missing: `winget install Microsoft.PowerShell`, then reopen the
terminal. Windows PowerShell 5.1 runs the harness but the MCP servers are developed
and tested against 7.

### The part people skip: a worker CLI

StatefulClanker does not talk to any model API itself. It **shells out to a CLI you
already have**, and you must have at least one installed and *signed in*. Any
non-interactive CLI works — `claude`, `opencode`, `agy`, or your own script.

Verify yours actually works headlessly before going further:

```powershell
claude -p "say OK"
```

If that prints an auth error, fix it now. It will otherwise fail later as a mystery
worker failure at the point where you are least able to debug it.

---

## Step 2 — Install (manual)

```powershell
git clone https://github.com/bobcatchris15-eng/StatefulClanker.git C:\tools\StatefulClanker
cd C:\tools\StatefulClanker
.\tests\Smoke.ps1
```

The smoke test must end with two PASS lines. It uses a mock provider, so it proves
the harness works without touching a real model.

---

## Step 3 — Create a project

The project is **your code**, not this repo. StatefulClanker keeps its state in a
`.statefulclanker` folder inside it.

```powershell
cd C:\work\myproject
C:\tools\StatefulClanker\StatefulClanker.ps1 init
```

This creates `.statefulclanker\`. It is gitignored by default; delete that rule if
you want the agent's durable state version-controlled with the project.

---

## Step 4 — Configure a provider

**This is the step with no defaults that work.** The shipped config points at
`opencode` with a guessed command line. If you do not have that exact CLI, the
first run fails.

Edit `.statefulclanker\config.json`:

```json
{
  "defaultProvider": "claude",
  "criticProvider": "claude",
  "validatorProvider": "claude",
  "providers": {
    "claude": {
      "command": "claude",
      "args": ["-p", "{prompt}"],
      "mode": "inline"
    }
  }
}
```

`args` **must** contain `{prompt}` (the task text as an argument) or `{promptFile}`
(a path to a file holding it). `{projectRoot}` and `{taskId}` are also substituted.

Two things worth knowing, both learned the hard way:

- **The worker needs permission to edit files.** A CLI in headless mode cannot
  prompt, so it auto-denies its own tools and exits 0 having done nothing. Your
  critic then correctly rejects an empty result. Use whatever that CLI's
  non-interactive edit flag is (for example `--mode accept-edits`).
- **Check the example config before copying it.** The `agy` entry in
  `statefulclanker.example.json` uses `run --prompt-file`, which does not match the
  `agy` CLI actually shipping today. Verify against `<your-cli> --help`.

Verify the provider works:

```powershell
C:\tools\StatefulClanker\StatefulClanker.ps1 provider list
```

Once MCP is connected (Step 5) you can do better: `provider_set` writes this config
for you with validation, and `provider_test` dispatches a real probe prompt and
tells you whether the provider is genuinely usable — it distinguishes an expired
login from a headless permission gate, which are the two failures you will actually
hit.

---

## Step 5 — Connect your app (manual)

```powershell
cd C:\tools\StatefulClanker
.\Install-McpServer.ps1 -Client claude-desktop -ProjectPath C:\work\myproject -Write
```

`-Write` is the only thing that touches a config file, and it keeps a `.bak`.
Without it you get the snippet printed to paste yourself.

| App | Command |
|---|---|
| Claude Desktop | `-Client claude-desktop -Write` |
| Claude Code | `-Client claude-code` (prints a `claude mcp add` line) |
| VS Code | `-Client vscode` → `.vscode/mcp.json` |
| Cursor | `-Client cursor` → `~/.cursor/mcp.json` |
| Opencode | `-Client opencode` → `opencode.json` |
| Antigravity / other | `-Client antigravity` (standard `mcpServers` shape) |
| Anything else | `-Client generic` |

Restart the app, then ask it to list its tools. You should see `project_status`,
`task_add`, `run_start`, and about twenty more.

`-ProjectPath` only sets the *default*. Every tool takes an optional `project`
argument, and `project_use` switches the default — one registration handles all your
projects.

### Apps that want a URL instead

```powershell
pwsh -NoProfile -File .\mcp\StatefulClanker.McpHttp.ps1 -ProjectPath C:\work\myproject -Port 7337
```

It prints a bearer token. Point the app at `http://127.0.0.1:7337/mcp` with header
`Authorization: Bearer <token>`.

Check it is alive:

```powershell
curl http://127.0.0.1:7337/health
```

> **Before you wire up ChatGPT or Gemini connectors:** a loopback URL only works if
> the app makes the request *from your machine*. Where a connector is fetched by the
> vendor's own backend, it cannot reach `127.0.0.1` on your laptop, and no amount of
> configuration will change that — you would need a tunnel you set up deliberately.
> Test `/health` from the app first. For anything that launches a local command,
> stdio is simpler and has no such problem.

---

## Step 6 — Your first cycle

In the chat app:

```text
Set the goal to "Add retry logic to the HTTP client", then add a task to
implement it using src/http.ps1 as retrieval, and run it.
```

The session will call `goal_set`, `task_add`, and `run_start`. Then:

```text
Poll run_status until it finishes and tell me what happened.
```

A cycle takes tens of seconds. `run_start` returns immediately and the session polls
`run_status`; only one cycle runs at a time per project.

### Reading the result

| Outcome | Meaning |
|---|---|
| `status: complete` | Worker, critic, and validator all passed; the proposal was committed. |
| `needs_rework` + "Critic rejected" | The critic found a real problem. Read the critique. |
| `needs_rework` + "requested missing context" | A context fault. Widen `retrieval` and retry. |
| `failed` + "Worker exited N" | The provider itself failed. Run `provider_test`. |

**A rejection is the system working.** In testing, the critic caught generated code
that called a nonexistent cmdlet and silently returned empty. That is the whole
point of the tool, and if you find yourself reaching for `task_complete` to force
past it, re-read what the critic said first.

Ask for `progress_history` to tell activity from progress: `advanced: false` with a
repeating `inputFingerprint` means the cycle is spinning, and the task needs
re-scoping rather than another attempt.

---

## Troubleshooting

**No tools appear in the app.** Restart it fully. Verify the path in the config
exists and that `pwsh` in the `command` field is a real path — the installer writes
an absolute one. Check the app's MCP log.

**"Provider 'x' not configured".** Step 4. The name in `defaultProvider` must match a
key under `providers`.

**Worker exits 0 but nothing changed.** The permission gate described in Step 4. Run
`provider_test` — it reports this case explicitly.

**"Not a StatefulClanker project".** You never ran `init` in that directory, or the
app is pointed at a different path. `project_status` prints the path it is using.

**"A cycle is already in flight".** One cycle at a time per project. Poll
`run_status`. If a process was killed, the lock is released on the next poll.

**"Active plan requires approval".** You imported a plan.
`requireHumanApprovalForPlan` is true, and `plan_approve` is gated from MCP on
purpose. Approve from the CLI:

```powershell
C:\tools\StatefulClanker\StatefulClanker.ps1 plan approve
```

**Task stuck in `running` after a crash.** `task_retry` resets it.

---

## What stays yours

Two tools are disabled by default, and both bypass the validation gate:
`task_complete` (marks a task done with no critic or validator) and `plan_approve`.
An agent that can approve its own plan and then complete its own tasks has routed
around every check the tool exists to provide.

Both still work from the CLI, where they are recorded as human authority. To hand
them to the agent anyway, in `.statefulclanker\config.json`:

```json
{ "mcp": { "allowHumanAuthorityTools": true } }
```

`project_status` reports the current setting as `humanAuthority`.

---

## Known limits

- **The CLI has no locking.** The MCP layer serialises cycles with a lock file, but
  two `StatefulClanker.ps1 run` invocations from two terminals will still interleave
  writes to `state.json`. `maxConcurrent` in the config is dead — nothing reads it.
- **Windows-first.** The MCP servers assume Windows path separators.
- **The validator does not execute code.** It judges from the worker's evidence, so
  it can pass code that does not run. In testing it approved a file containing
  `Export-ModuleMember` outside a module. Keep your own tests in the loop.

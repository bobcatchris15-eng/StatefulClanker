# StatefulClanker — project context

Windows-first PowerShell harness. Durable project state on disk; models are
disposable cold-start workers. See README.md and docs/ARCHITECTURE.md.

## Layout

- `StatefulClanker.ps1` — CLI entrypoint. Parses args, dot-sources `lib/`, dispatches.
- `lib/StatefulClanker.Core.ps1` — state, tasks, events, config, plans.
- `lib/StatefulClanker.Context.ps1` — retrieval and context compilation.
- `lib/StatefulClanker.Execution.ps1` — provider dispatch, review, proposals, commit.
- `mcp/` — MCP server exposing the project to a conversational agent.
- `desktop/StatefulClanker.Cockpit.ps1` — local telemetry viewer.

## VALIDATE

```
Fast:    pwsh -NoProfile -File .\tests\Smoke.ps1
Full:    pwsh -NoProfile -File .\tests\Smoke.ps1
Probe:   none
Seed:    nothing — the repo is self-contained PowerShell, no vendored toolchain.
         The smoke test builds its own throwaway project under $env:TEMP and
         dispatches to tests/MockProvider.cmd, so no real model or network is needed.
Cost:    ~1 MB per tree, provisioning ~0s. Smoke run ~30s wall.
Notes:   Smoke is self-cleaning (STEP 8 removes its temp project).
         It parse-checks every .ps1 in the repo and greps for the
         bareword-concatenation shape (`return'PASS'`), which PARSES CLEAN but
         tokenizes into a command name and only fails at runtime. Three shipped
         bugs of exactly that shape made the harness non-functional; do not
         remove those guards.
```

## Gotchas

- Everything is CWD-relative: `Get-SCRoot` is literally `(Get-Location).Path`.
  Any code entering a project must `Push-Location`/`Pop-Location` around the call.
- `Add-SCTask` and friends take NO parameters — they read `$Title`, `$Instruction`,
  `$Accept`, etc. from `StatefulClanker.ps1`'s script scope. They are not callable
  as ordinary functions; shell out to the CLI instead.
- `maxConcurrent` in config.json is dead config. Nothing reads it, and there is no
  locking anywhere. Task status is the only guard against double-running a task.
- `Set-StrictMode -Version 2.0` is on. Test optional properties with
  `$x.PSObject.Properties['name']` before reading them.

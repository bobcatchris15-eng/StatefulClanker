# MCP control plane — orchestrator ledger
Updated: 2026-09-14 | HEAD: c338dab | Graph: n/a (no graphify build for this repo)

## Objective
Make StatefulClanker installable on a Windows machine such that it exposes an MCP
server a desktop chat app (Claude, ChatGPT, Gemini, Hermes, Opencode, Antigravity)
can connect to locally, and from that session fully drive a StatefulClanker project
— set goal, add/import tasks, run cycles, inspect state — while the harness keeps
owning worker coordination, validation gating, and durable state.

## Decisions
- D1 2026-09-14: MCP `run` must be ASYNC. `Invoke-SCTask` runs worker+critic+validator
  inline (37s measured with agy; unbounded with a slow provider). A synchronous MCP
  tool call would block the client past its timeout. `run_start` spawns detached and
  returns a handle; caller polls. Revisit if MCP clients gain long-call streaming that
  the target apps actually implement.
- D2 2026-09-14: Tools that BYPASS the validation gate (`task_complete` manual commit,
  `plan_approve`) sit behind config `mcp.allowHumanAuthorityTools`, default false.
  Rationale: the project's own stated invariant is "worker output proposes state; it
  does not certify state" and "human approval is a first-class state transition". An
  agent that can approve its own plan and manually complete its own tasks erases both
  gates. Revisit if the user says they want full autonomy.
- D3 2026-09-14: Dispatch layer extracted to mcp/StatefulClanker.McpCore.ps1 so the
  stdio host and the HTTP host share one tool implementation. Two hosts, one dispatch.
- D4 2026-09-14: Writes shell out to StatefulClanker.ps1 rather than dot-sourcing lib/.
  Add-SCTask takes no parameters — it reads $Title/$Instruction/etc from the CLI
  script scope, so it is not callable as a function. Shelling out is the only correct
  path and matches the existing direction_add tool.
- D5 2026-09-14: Not engaging Mode P / clanker dispatch for this effort. The whole
  repo is ~460 lines and already read into this context; the work is sequential
  (HTTP host depends on McpCore). Dispatch overhead would exceed the work, which is
  the documented exception in the orchestrator rules. Revisit if scope grows past
  the MCP surface into lib/.

## Tasks
| id | targets | status | attempts | last return line |
|----|---------|--------|----------|------------------|
| t0 | lib/*.ps1 mcp/*.ps1 tests/Smoke.ps1 | DONE | 1 | 3 tokenization bugs fixed; smoke green; pushed |
| t1 | mcp/StatefulClanker.McpCore.ps1 | DONE | 1 | shared dispatch; 24 tools; CLI bridge via child pwsh |
| t2 | mcp/StatefulClanker.Mcp.ps1 (stdio host) | DONE | 1 | thin transport; id echo fixed on all failure paths |
| t3 | mcp/StatefulClanker.McpHttp.ps1 | DONE | 1 | TcpListener, loopback, bearer token; verified 401/200 |
| t4 | tests/Mcp.Tests.ps1 + Smoke wiring | DONE | 1 | 8 MCP tests green as Smoke STEP 9 |
| t5 | docs/MCP.md + install script | DONE | 1 | Install-McpServer.ps1 + docs/MCP.md + README section |

## Unverified assumptions
- ChatGPT / Gemini connector support for a localhost MCP URL is UNVERIFIED. Their
  connectors have historically been fetched server-side, which cannot reach 127.0.0.1.
  stdio is known-good for Claude Desktop/Code and Opencode. Must be tested per app by
  the user; do not claim it works.
- `maxConcurrent` in config.json is dead config — never read by any code path. The
  MCP layer now serialises cycles with an atomic lock file, but the CLI itself is
  still unguarded: two `StatefulClanker.ps1 run` invocations from two terminals will
  still interleave writes to state.json. Fixing that belongs in lib/, not mcp/.

## Confirmed by testing (was assumption, now fact)
- D1 was right for a stronger reason than predicted: task status is NOT a usable lock.
  Two run_start calls ~50ms apart BOTH launched cycles on the same task, because the
  detached process had not yet flipped status to 'running'. Replaced with an atomic
  CreateNew lock file; re-tested, second call now refused.
- `pwsh -File` passes arguments as literal tokens with no expression parsing, so a
  comma-joined array arrives as ONE element. This silently collapsed acceptance
  criteria into a single bogus string. Fixed by emitting a quoted PowerShell command
  instead of -File. Regression test is MCP 4.
- The CLI reports via Write-Host, which does NOT reach stdout, so in-process
  redirection captured nothing. Running the CLI as a child process fixes capture and
  $LASTEXITCODE together.

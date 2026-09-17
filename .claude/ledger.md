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
| t6 | provider_set/provider_test + docs/SETUP.md | DONE | 1 | closed the no-provider-config gap; 10 MCP tests green |
| t7 | lib/Integrations.ps1 + tray app + Inno installer | DONE | 1 | Setup.exe built, installed, verified, uninstalled clean |
| t8 | c1: state/work root split + cross-process state lock | DONE | 1 | SCWorkRoot/SCStateRoot split + named mutex; smoke green |
| t9 | c2: worktree provisioning + parallel scheduler | DONE | 1 | 3 tasks concurrent in 4s, own worktree each |
| t10 | c3: merge gate + conflict hold | DONE | 1 | clean merges land; collision held on branch, tree clean |
| t11 | periodic project critic + validator | DONE | 1 | interval + multi-merge triggers; hold + remediation verified |
| t12 | prompt delivery: stdin everywhere + length guard | DONE | 1 | 11.5k prompt via stdin to real agy; inline refused |

- D7 2026-09-14: Verdict parsing relaxed from 'first non-empty line must be exactly
  VERDICT: X'. The user hit real false FAILs: a reviewer that explains itself before
  voting was scored FAIL on work that passed. New rule: a verdict must be its OWN
  line (decoration tolerated, prose mentions ignored), any FAIL wins, no verdict is
  FAIL. Any-FAIL-wins rather than last-match-wins is deliberate - the user's interim
  fix matched VERDICT anywhere and took the last hit, so 'VERDICT: FAIL ... on
  reflection VERDICT: PASS' returned PASS. Ambiguity must fail closed. Revisit if a
  reviewer legitimately needs to revise a verdict within one response.

- D8 2026-09-14: Tray app is WinForms-in-PowerShell, matching the existing Cockpit.
  No .NET SDK on this box and the repo has never had a build step; a compiled app
  would add a toolchain dependency for a local dev tool. Revisit if the UI outgrows
  what WinForms-by-script can carry.
- ~~D8~~ SUPERSEDED 2026-09-17: the UI did outgrow the script. There is now a
  compiled WinForms C# tray at src/StatefulClanker.Tray/Program.cs (the
  blinkenlights rack, csproj, `dotnet build` verified clean) alongside the
  original desktop/StatefulClanker.Tray.ps1. The .NET SDK IS installed on this
  box (`dotnet` on PATH, net8.0-windows). D8's premise was wrong by the time of
  this check; don't cite it as a reason to avoid touching src/StatefulClanker.Tray.
- D9 2026-09-14: Installer is Inno Setup, PER-USER (PrivilegesRequired=lowest). No
  UAC, and the MCP client configs it manages are per-user anyway. Inno 6.7.3 was
  already installed at %LOCALAPPDATA%\Programs, so nothing new was added to the box.
- D10 2026-09-14: Hidden launch uses a .vbs (WScript.Shell.Run style 0). A shortcut
  to pwsh flashes a console even with -WindowStyle Hidden, because the host is
  created before the style applies. Needs nothing beyond stock Windows.
- D11 2026-09-14: Integration/provider catalogue entries carry a `verified` flag and
  the UI surfaces UNVERIFIED loudly. Config paths and preset command lines that were
  not confirmed on a real install are guesses, and the shipped agy preset being wrong
  is precisely the failure this advertises rather than hides.

- D12 2026-09-14: CONCURRENCY WAS NEVER IMPLEMENTED. Confirmed: Invoke-SCTask does
  Select-Object -First 1 (one task per invocation, fully synchronous), maxConcurrent
  is read by no code at all, and the MCP run_start lock I added refuses a second
  cycle outright. ARCHITECTURE.md:318 already admitted this. User hit it testing with
  opencode. Building it for real, user chose: git worktree per worker + harness-side
  scheduler.
- D13 2026-09-14: The blocking design problem is that Get-SCRoot serves two different
  roles - it locates .statefulclanker AND resolves the worker's files. A worktree
  cycle needs shared state in the MAIN tree but file resolution in the WORKTREE, so
  those must be split into SCStateRoot and SCWorkRoot before anything else can work.
  Sequenced as t8 -> t9 -> t10; t8 is load-bearing for both others.
- D14 2026-09-14: Tasks declare what they READ (retrieval/evidence) but never what
  they WRITE. That is why shared-tree concurrency was rejected: the scheduler cannot
  know if two ready tasks will edit the same file. Worktrees sidestep it by making
  collision a merge-time question instead of a silent corruption.

- D15 2026-09-14: Parallel merge gate COMMITS on the user's behalf. The harness
  previously never touched git; worktree isolation requires it to commit each
  worktree and merge the branch. Refuses to start if the tree is dirty, because
  merging into uncommitted work is destructive. Conflicts abort the merge, keep the
  branch, and set the task needs_rework - the main tree is never left conflicted.
- D16 2026-09-14: NOT doing an automatic post-merge full re-validate. The harness has
  no project-level test command to run - VALIDATE lives in each project's own
  CLAUDE.md, which the harness does not read. Instead run_parallel WARNS when more
  than one branch merged. Revisit if a per-project validate command is ever added to
  config.json; that is the missing piece for a real integration gate.

- D17 2026-09-14: Periodic PROJECT review added (every N completed tasks, default 5,
  plus after any multi-branch merge). This is the integration gate D16 said was
  missing. projectValidateCommand supplies the only direct evidence the project still
  runs; without it the validator is told to say it could not verify rather than infer
  success from absence of failure.
- D18 2026-09-14: On FAIL the harness HOLDS dispatch and queues a HUMAN-GATED
  remediation task. Holding is the point - it stops the queue piling work onto a
  broken base. Human-gated because this is the first time the harness generates its
  own work; a human reads the review before releasing it. Release is CLI 'hold clear'
  or MCP hold_clear, which is gated with the other human-authority tools.
- D19 2026-09-14: Worktree children (-StateRoot) must NOT run project reviews; the
  scheduler runs one for the whole batch. Otherwise a 3-way parallel run would fire
  three full project reviews.
- FOUND (pre-existing, present in the original upstream clone b6db03e): every .jsonl
  writer used `ConvertTo-SCJson $x 12 -replace ...`, which binds -replace as a
  PARAMETER of the command rather than as an operator. The newline flattening never
  happened, so events.jsonl, telemetry/events.jsonl and context-faults.jsonl were all
  written as pretty-printed multi-line JSON. Every line-by-line reader got garbage,
  and it stayed invisible because the readers swallow parse errors in try/catch -
  context faults simply read back empty. Fixed in all three writers; Smoke STEP 6b
  now asserts every .jsonl line parses standalone.

- D20 2026-09-14: ALL prompt delivery moves to stdin. User flagged it; confirmed it
  is a live bug, not style. cmd.exe caps a command line at 8191 chars and
  CreateProcess at 32767, while the shipped retrieval budgets total 36000. Measured:
  an 11k prompt fails with 'The command line is too long', exit 1 - indistinguishable
  from a broken provider. Every one of the 11 presets I shipped used inline {prompt},
  so this affected all of them. Verified end to end: 11,483-char prompt over stdin to
  a real agy worker, which created its file and passed critic+validator.
- D21 2026-09-14: 'stdin' means NO prompt flag carrying a value. claude -p reads
  stdin; agy reads stdin only when -p is ABSENT (a bare -p errors 'flag needs an
  argument'). Both verified against the real CLIs. The preset note records this.
- FOUND: my own concurrency work had a read/write race. Writes were under the state
  mutex but READS were not, and Write-SCJson replaces via temp-file + Move-Item, so a
  concurrent reader could catch the target absent and get $null - surfacing as a
  spurious 'Unknown task' that killed a cycle mid-review. Seen once as an
  intermittent conflict-test failure (task stuck at 'reviewing'). Get-SCTask,
  Get-SCState and Get-SCTasks now take the same lock; concurrency test run 6x clean.
- NOTE for later: unmatched retrieval selectors do NOT stop a cycle. A task whose
  retrieval matched nothing compiles an empty working set and the worker, critic and
  validator can all still pass. Recorded in the compilation receipt, acted on by
  nothing. Worth a guard.

## Unverified assumptions
- Project review quality is unverified: the test providers vote PASS or FAIL
  unconditionally, so the TRIGGERING, evidence packet and failure handling are
  proven but the usefulness of a real model's project-level judgement is not.
- Reviewer providers are assumed read-only. A reviewer configured in an edit-capable
  mode will dirty the tree and block the next parallel run. Documented, not enforced.
- Parallel execution is verified with the mock/writing test providers only. It has
  NOT been run against a real agent CLI doing real edits, where workers are slower
  and far likelier to touch overlapping files.
- Tray app: only the PROJECTS tab was visually confirmed to render correctly. The
  workstation locked partway through, after which CopyFromScreen returns black, so
  Integrations/Providers/Server were verified by logic and parse only. They use the
  same dock-layout helpers as Projects, but a visual pass is still owed.
- Config paths for Windsurf, Opencode and Antigravity are unconfirmed guesses
  (flagged verified=$false, and the UI warns before writing).
- Provider presets for opencode/aider/goose/openhands/pi/codex/gemini/cursor-agent
  are unverified command lines. claude and agy were confirmed against the real CLIs.
- ChatGPT / Gemini connector support for a localhost MCP URL is UNVERIFIED. Their
  connectors have historically been fetched server-side, which cannot reach 127.0.0.1.
  stdio is known-good for Claude Desktop/Code and Opencode. Must be tested per app by
  the user; do not claim it works.
- `maxConcurrent` in config.json is dead config — never read by any code path. The
  MCP layer now serialises cycles with an atomic lock file, but the CLI itself is
  still unguarded: two `StatefulClanker.ps1 run` invocations from two terminals will
  still interleave writes to state.json. Fixing that belongs in lib/, not mcp/.

- D6 2026-09-14: Added provider_set/provider_test. Provider config lived ONLY in
  config.json with no CLI command and no doc anywhere, so the install path dead-ended:
  connect the server, call run_start, fail. provider_test probes with a real prompt
  because both realistic failures are quiet - expired login exits nonzero, a headless
  permission gate exits ZERO with empty output. Revisit if provider config ever moves
  behind a real CLI command.

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
- Start-Process -ArgumentList joins an ARRAY WITHOUT QUOTING, so any project path
  containing a space was split into separate arguments. Fixed with an explicit
  CommandLineToArgvW-rules quoter; verified by running a full cycle from a path with
  a space in it.

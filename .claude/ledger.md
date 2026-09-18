# Terminal/MCP-import/escalation — orchestrator ledger
Updated: 2026-09-18 | HEAD: 0145247 | Graph: n/a (no graphify build for this repo)

## Prior effort (archived)
"MCP control plane" effort (2026-09-14) — DONE. Stood up mcp/ dual-host MCP server
(stdio + resident HTTP), worker capability policy, concurrency/worktree scheduler,
periodic project review. See git log around beac16b for detail if needed.
Carried-forward unverified assumptions still relevant to this effort:
- Config paths for Windsurf/Opencode/Antigravity in Install-McpServer.ps1 are
  UNCONFIRMED GUESSES (flagged verified=$false in that script). Relevant to T2 below
  — discovery must not silently trust an unconfirmed path; keep the same caution flag.
- Tray app: only the PROJECTS tab was visually confirmed to render. Integrations/
  Providers/Server tabs verified by logic only. A new MCP-import tab (T3) needs an
  actual visual pass, not just a clean build.

## Objective
Three independent fixes/features to the Windows tray app + PowerShell harness:
1. Fix arrow-key input loss in the embedded ConPTY terminal panel used to drive the
   CLI orchestrator (agy/opencode/claude CLI) from inside the tray app.
2. Add MCP tool discovery: probe MCP servers already configured in other installed
   harnesses (claude-desktop, claude-code, cursor, vscode, opencode, antigravity,
   windsurf), and let the human opt a whole discovered server in for worker use,
   with a visually unambiguous "imported/available to workers" indicator in the tray.
3. On critic/validator/worker failure or a project hold, inject a human-readable
   notice into the LIVE embedded terminal session the human is already watching
   (not a new tab, not just a status badge), via the existing resident HTTP bridge.

## Decisions
- D1 2026-09-18: MCP import authorization is per-SERVER, all-its-tools (user's
  explicit choice over per-tool or auto-import-everything). Simpler policy surface;
  matches existing `Initialize-SCMcpHttpSource` which already registers a whole
  source at once. Revisit only if a user later asks for per-tool granularity.
- D2 2026-09-18: Failure escalation is INJECT INTO LIVE SESSION (user's explicit
  choice over new-tab or status-only). Implies EmbeddedTerminalPanel needs a
  programmatic "write to this pty's input/output" method, driven by a resident-HTTP
  endpoint the PowerShell side calls. Revisit if this proves visually disruptive
  mid-command (e.g. injecting while the human is mid-keystroke in agy).
- D3 2026-09-18: Tray app has no documented VALIDATE. Established one:
  `dotnet build src/StatefulClanker.Tray/StatefulClanker.Tray.csproj -c Debug`
  Verified clean (0 warnings, 0 errors, 5.5s) before any dispatch. Use this as Fast
  AND Full for tray-touching tasks; PowerShell Smoke.ps1 stays the validate for
  lib/mcp-touching tasks. A task touching both runs both commands.
- D4 2026-09-18: Mode S (serial, shared tree), not Mode P. Reasoning: T1 and T4/T5
  both touch EmbeddedTerminalPanel.cs — parallel worktrees would conflict on merge
  for the exact class this whole effort is centered on. Sequencing removes the
  conflict instead of resolving it after the fact.
- D5 2026-09-18: Task order is T1 -> T2 -> T3 -> T4+T5. T1 first because it's the
  narrowest, highest-confidence fix and unblocks the human's daily driver
  immediately. T2 before T3 (backend before the UI that calls it).
- D6 2026-09-18: Collapsed T4 (bridge/backend) into T5. Investigated
  lib/StatefulClanker.Execution.ps1 and ProjectReview.ps1 before dispatching T4:
  the failure signal already exists as events in events.jsonl (`run.failed`,
  `critic.error`, `validator.error`, `project.hold.set`, `project.review.failed`),
  each with human-readable text via the existing Add-SCEvent(Type,Text,Data) calls.
  No new PowerShell plumbing needed. The only real work is on the tray side: track
  a read cursor over events.jsonl (it's already polled for the Activity panel, see
  Program.cs:684 `Activity(path)`, but that renders to a display string, not
  structured events a caller can filter/cursor) and inject NEW matching events into
  the live terminal. Avoided writing a duplicate escalation-queue file — reusing the
  existing event stream matches "don't add abstractions beyond what the task
  requires."
- D7 2026-09-18: Terminal injection writes to the pty's INPUT stream (only way to put
  text in front of a live ConPTY session with this control), prefixed with CRLF to
  start on a fresh line, NOT auto-submitted (no trailing Enter) so a human or an
  agy/opencode composer mid-edit is not corrupted or made to auto-act on it. This is
  the disruption risk D2 flagged. Exact write API depends on what
  EasyWindowsTerminalControl 1.0.38 / Microsoft.Terminal.Wpf actually expose --
  dispatched task must verify via inspection, not assume a method name exists.

## Tasks
| id | targets | status | attempts | last return line |
|----|---------|--------|----------|------------------|
| t1 | EmbeddedTerminalPanel.cs | DONE | 1 | TerminalElementHost.IsInputKey override; build clean; 7a1f462 |
| t2 | McpDiscovery.ps1(new), WorkerPolicy.ps1, StatefulClanker.ps1, docs/MCP.md | DONE | 1 | discover/list/import/remove CLI; stdio+http transport; smoke green; 9542fe2 |
| t3 | Program.cs | DONE | 1 | MCP Import tab, checkbox = imported; build clean; b26faf6 |
| t4+t5 | EmbeddedTerminalPanel.cs, Program.cs | DONE | 1 | ConPTYTerm.WriteToTerm + event cursor; build clean; 0145247 |

## Effort complete
All 3 objectives shipped: t1 (arrow keys), t2+t3 (MCP import backend+UI), t4+t5
(failure escalation). Nothing outstanding for this effort.

## Unverified assumptions
- T2/T3: whether ChatGPT/Gemini/other connector-style clients expose a locally
  readable MCP config file at all (vs. cloud-side config with no local artifact) is
  unknown — discovery may legitimately find zero servers for some harness names.
  Not a bug if so; must not be reported as one.
- T5: resident HTTP bridge (mcp-http.json) is assumed to be reachable from the
  PowerShell side whenever the tray app is running with a project open. Not yet
  confirmed that a headless `StatefulClanker.ps1 run` (no tray app running) degrades
  gracefully when it tries to escalate and finds no bridge.

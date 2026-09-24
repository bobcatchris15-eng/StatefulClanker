# Design-doc conformance — orchestrator ledger
Updated: 2026-09-24 | HEAD: 3f5f684 (fix/rpk-args-commit-freshness-gate, based on origin/main b87df2f) | Graph: n/a

## Prior effort (archived)
2026-09-18 terminal/MCP-import/escalation effort — DONE (t1–t7, see git log ~c618fd6).
Carried forward: escalation notices reach the terminal via a tray-side events.jsonl
cursor (old D6), NOT the HTTP bridge — so disabling the bridge by default should not
break escalation. Verify in t1.

## Objective
Bring origin/main closer to STATEFULCLANKER_CONSOLIDATED_DESIGN.md (2026-09-24) on the
gaps the user picked from the conformance audit. Work lands on
fix/rpk-args-commit-freshness-gate; the user merges into local main themselves (their
main is 5 behind with uncommitted edits to DispatchGuard.ps1/WorkerRuntime.ps1 — never touch it).

## Decisions
- D1: Worktrees are created manually from the fix branch (Agent isolation:worktree would
  base on stale local main). Mode P, budget 3.
- D2: Keep Pi's "implementation repair" ability — user wants the control-plane escape hatch.
- D3: Worker HTTP MCP client (WorkerPolicy.ps1) stays: it is interop with external MCP
  servers, not a duplicate control path. Install-McpServer -Transport http stays (opt-in).
- D4: HTTP bridge becomes opt-in (tray setting, default off, never started by refresh).
- D5: Co-op packets excluded from packet compilation — cooperation protocol doesn't exist.
- D6: Per-project endpoints = optional project allowlist, default all (keeps current
  machine-wide pool behaviour). Priority = integer weight for weighted round-robin,
  default equal. Revisit if user wants strict priority tiers.
- D7: Pin behaviour (#4) undecided by user — do not touch route migration.

## Tasks
| id | targets | status | attempts | last return line |
|----|---------|--------|----------|------------------|
| t0 | RPK args, commit freshness, validator-off gate | DONE | 1 | 3f5f684 |
| t1 | Tray refresh/opt-in HTTP | DONE | 1 | merged 60797aa; needs user visual check |
| t2 | SubscriptionPump watcher | DONE | 1 | merged 0b20087 |
| t6 | RPK code graph | DONE | 1 | merged abb7b7c |
| t3 | Packet: lessons, neighbours, attempt history | DONE | 1 | merged; context faults on RPK failure |
| t8 | Router weights + project allowlist | DONE | 2 | merged ae92b37; attempt 1 was packet scope (missing Router/Program.cs) |
| t9 | Boundary violation event + escalation | DONE | 1 | merged; orchestrator added Eventing attention + Pi problem regex (no tray whitelist exists anymore) |
| t4+t5 | validation/repair/merge checkpoints; evidence-based failure + stagnation | RUNNING | 0 | |
| t7 | Lesson MCP tools + worker record_lesson | DONE | 1 | merged c7f0e65; WorkerRuntime conflict w/ t9 resolved (signatures only) |

## Unverified assumptions
- 4 tray tests (OverviewUi, TrayRefreshStability, TraySplitterVisibility, TrayTargetPoolLayout)
  fail on pristine origin/main (stale source-string contracts). Tray changes are gated by
  build + smoke only; t1 needs a visual/interactive check by the user.
- LifecycleIntegration.Tests.ps1 fails "Not initialized" on pristine origin/main — pre-existing, not ours.

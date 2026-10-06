# Pi extension pivot — orchestrator ledger
Updated: 2026-10-06 | HEAD: 32dd803 | Graph: n/a

## Prior effort (archived)
2026-09-24 design-doc conformance on PS harness — superseded by pivot (see git log).

## Objective
Replace the PS/C#/Tray harness with a TypeScript Pi extension at
pi/extensions/statefulclanker/ per the user's 119-section spec: a parent Pi session
that works itself and coordinates heterogeneous Pi RPC workers, with durable state in
.statefulclanker/. Plan: ~/.claude/plans/alright-this-has-become-linear-hennessy.md

## Decisions
- D1 10-06: delete legacy PS/C#/Tray outright (user). Port shapes before deleting.
- D2 10-06: endpoint catalog ported to TS in-process, not C# router exe (user).
- D3 10-06: MVP = spawn+RPC+result slice first (user). Phases P1..P5.
- D4 10-06: Mode S serial for P1 (t1->t2->t3 depend on each other).
- D5 10-06: P2 uses Pi modelRegistry as the pool; drop router connection layer + seed catalogs. Design: pi/extensions/statefulclanker/docs/model-selection.md
- D6 10-06: profiles machine + project overlay; pool respects scopedModels when set; unknown models eligible, ranked low (user).

## Tasks
| id | targets | status | attempts | last return line |
|----|---------|--------|----------|------------------|
| t1 | protocol/ project/ workers/registry | DONE | 1 | STAT: PASS; validate = node --test tests/unit/*.test.ts |
| t2 | workers/runtime manager status jsonl, worktrees/create | DONE | 1 | STAT: PASS; 9/9 tests; channel = notify "SC1 {json}" |
| t3 | index operator worker ui prompts reconstruct e2e | DONE | 1 | STAT: PASS; 12 unit + 1 real-pi e2e |
| t4 | catalog/ (profiles, observations, health, leases, select) | PENDING | 0 | |
| t5 | wire selection into worker_spawn + endpoint tools + RPC health; worktree by worker id | PENDING | 0 | |
| p0 | delete legacy, rewrite docs/CLAUDE.md | PENDING (after P3 ports) | 0 | |

## Unverified assumptions
- node:sqlite available in bundled install/pi-runtime/node.exe (check version).
- Worktree dir/branch keyed by task id, not worker id (spec §46 wants worker). Minor; fix in P2.
- Operator session paths (session_start, before_agent_start, setWidget, worker_spawn in a live parent) never exercised — needs manual run.
- research/: breadth1 discarded (user 10-06). RESUME_MANUAL.md edit + untracked runs/breadth2/ remain — go with research/ in P0.

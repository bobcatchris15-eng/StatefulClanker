# Pi extension pivot — orchestrator ledger
Updated: 2026-10-06 | HEAD: e625a63 (v1.0.0, pushed) | Graph: n/a

## Prior effort (archived)
2026-10-06 legacy leftovers deleted from disk (install/ src/ research/ pi/ desktop/ .clanker/ .superpowers/).
2026-09-24 design-doc conformance on PS harness — superseded by pivot (see git log).

## Objective
Maintain the TypeScript Pi extension at the repository root
per the user's 119-section spec: a parent Pi session
that works itself and coordinates heterogeneous Pi RPC workers, with durable state in
.statefulclanker/. Plan: ~/.claude/plans/alright-this-has-become-linear-hennessy.md

## Decisions
- D1 10-06: delete legacy PS/C#/Tray outright (user). Port shapes before deleting.
- D2 10-06: endpoint catalog ported to TS in-process, not C# router exe (user).
- D3 10-06: MVP = spawn+RPC+result slice first (user). Phases P1..P5.
- D4 10-06: Mode S serial for P1 (t1->t2->t3 depend on each other).
- D5 10-06: P2 uses Pi modelRegistry as the pool; drop router connection layer + seed catalogs. Design: docs/model-selection.md
- D6 10-06: profiles machine + project overlay; pool respects scopedModels when set; unknown models eligible, ranked low (user).
- D7 10-06: Pi model library moves to default ~/.pi/agent (user). User copies models.json/settings.json from %LOCALAPPDATA%/StatefulClanker/pi (holds credential refs; not handled by Claude). Sync-PiCatalog retired. Get-Credential.ps1 not needed (user).
- D8 10-06: repo is a pi package installed from GitHub (user). Root package.json pi.extensions=./index.ts; peers "*"; legacy removed. Released v1.0.0 (user chose 1.0 over 0.1).

## Tasks
| id | targets | status | attempts | last return line |
|----|---------|--------|----------|------------------|
| t1 | protocol/ project/ workers/registry | DONE | 1 | STAT: PASS; validate = node --test tests/unit/*.test.ts |
| t2 | workers/runtime manager status jsonl, worktrees/create | DONE | 1 | STAT: PASS; 9/9 tests; channel = notify "SC1 {json}" |
| t3 | index operator worker ui prompts reconstruct e2e | DONE | 1 | STAT: PASS; 12 unit + 1 real-pi e2e |
| t4 | catalog/ core | DONE | 1 | STAT: PASS; 27/27; presets mins looser than spec §16 (deliberate: weights carry spec emphasis) |
| t5 | selection wired: pool, CatalogService, worker_spawn, endpoint tools, health feed | DONE | 1 | STAT: PASS; 33 unit + e2e. agent_end error shape inferred, not observed |
| t6 | worker self-naming + w-NN branches | DONE | 1 | STAT: PASS; 37 unit + e2e |
| t7 | pool == Pi available; forward parent -e + agent dir | DONE | 1 | STAT: PASS |
| t8 | repo root = pi package; legacy deleted; load guard; README/CLAUDE | DONE | 1 | STAT: PASS; validate 39+1; pi install <path> loads clean |
| p0 | delete legacy source and build pipeline, rewrite docs/CLAUDE.md | DONE in tracked source; untracked 0.8.20 installer deletion blocked by execution policy | 0 | 2026-10-10 source audit: no PS/C#/installer pipeline tracked |

## Unverified assumptions
- Provider-error signal from agent_end (stopReason/errorMessage) inferred; verify on first real 429. 
- Operator session paths (session_start, before_agent_start, setWidget, worker_spawn in a live parent) never exercised — needs manual run.

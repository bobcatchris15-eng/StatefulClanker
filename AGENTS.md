# StatefulClanker — Pi package

Pi extension at repo root. Entry `index.ts` (operator vs worker by `SC_WORKER_ID`).

## Layout

- `index.ts` — entry + double-load guard; `operator.ts` / `worker.ts` — mode registration
- `catalog/` — profiles, observations, health, leases, selection, pool
- `workers/` — spawn manager, runtime, registry; `workspace/` — cooperative checkouts, proposals, publish; `protocol/`, `project/`, `ui/`, `prompts/`
- `pools/` — OpenCode session-server transport, agy headless runner, Jules REST client, persistent external pool supervisor
- `skills/statefulclanker-orchestration/SKILL.md` — pool-neutral operator skill included in the Pi package
- `tests/unit`, `tests/e2e` (runs real pi from root node_modules with a mock provider)

## Gotchas

- Erasable TS only (no enums/namespaces/param properties); imports use `.ts` extensions.
- Worker<->parent channel is `SC1 {json}` lines via notify.
- Pi **model** candidate pool == Pi's available models (model registry), nothing else. The operator also has **three peer execution backends**: OpenCode, agy, Jules REST. Never merge their models/quotas into Pi's inference provider catalog.
- For `worker_spawn`, specify the `backend` deliberately. All four pools have equal dispatch priority when eligible; select by task fit and constraints. Read the packaged orchestration skill.
- Jules REST needs `JULES_API_KEY`; sources must already be connected. Do not expose the key in receipts. Jules outputs require patch retrieval and explicit application.
- OpenCode uses authenticated `serve` sessions and client models; attach with `OPENCODE_SERVER_URL` if desired. OpenCode/agy see dirty shared files. Jules sees the pushed branch.
- External runs submit task receipts to independent `task_verify`; backend completion is not verification.
- Tests set `SC_MACHINE_DIR` to isolate machine state.
- Workers share the repository cwd, do not create Git worktrees, and use checkout_claim / checkout_publish for file authority. This is cooperative, not filesystem-enforced. Checkout proposals/solicitations are persisted and notified through workspace/dispatch.ts and the operator's live pump; helper spawns are proposal-only and share the checkout.\n- Workers get `-e <this index.ts>`; parentExtensionArgs excludes self. Double-load guard uses `Symbol.for("statefulclanker.loaded")`.

## VALIDATE

```
Fast:    npm run typecheck && npm test
Full:    npm run validate
Probe:   none
Seed:    npm install
Cost:    node_modules ~444 MB per tree; install ~30-60s (npm install, network)
Notes:   e2e needs no network (mock provider, PI_OFFLINE=1). Needs node >= 22 (type stripping).
```

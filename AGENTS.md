# StatefulClanker — Pi package

Pi extension at repo root. Entry `index.ts` (operator vs worker by `SC_WORKER_ID`).

## Layout

- `index.ts` — entry + double-load guard; `operator.ts` / `worker.ts` — mode registration
- `catalog/` — profiles, observations, health, leases, selection, pool
- `workers/` — spawn manager, runtime, registry; `workspace/` — cooperative checkouts, proposals, publish; `protocol/`, `project/`, `ui/`, `prompts/`
- `tests/unit`, `tests/e2e` (runs real pi from root node_modules with a mock provider)

## Gotchas

- Erasable TS only (no enums/namespaces/param properties); imports use `.ts` extensions.
- Worker<->parent channel is `SC1 {json}` lines via notify.
- Candidate pool == Pi's available models (model registry), nothing else.
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

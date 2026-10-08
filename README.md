# StatefulClanker

A [Pi](https://github.com/earendil-works/pi) package. The parent Clanker (your Pi session) is worker zero; it spawns heterogeneous Pi RPC workers, all in the same project checkout with per-file/subtree right-of-way, and picks models by ability from Pi's own model registry. Project state is durable on disk under `.statefulclanker/`. Workers name themselves.

## Install

```
pi install git:github.com/bobcatchris15-eng/StatefulClanker@v1.0.0
pi install -l git:github.com/bobcatchris15-eng/StatefulClanker@v1.0.0   # project-local
```

## Supervisor panel

While the operator is in TUI mode, a boxed supervisor panel renders above the editor via `ctx.ui.setWidget('sc-rack', <component factory>)`. It is a blinkenlight rack: **every worker carries a bank of lamps** that light up as its state changes and blink while it is live.

```
┌ SUPERVISOR · RUN 2 · WAIT 1 · BLOCK 1 · jobs 3/8 ───────────────┐
│ ● ░▒▓█████ W01 Rivet  Job 1: rebuild the operator… glm  editing … │
│ ◐ ····▓██  W03 Brace  t-0003                      m3-long-model  │
│ ○ ·······█  W07 Idle                               m5            │
└─────────────────────────────────────────────────────────────────┘
```

- **Lamp bank** (the point of the panel): `DEFAULT_LAMPS` = 8 sockets per worker in the widget, 24 in `/rack`. Every observed status change lights one new lamp at the right, scrolling the oldest off; lamps fade `█` → `▓` → `▒` → `░` as they age, and unlit sockets render as `·` so the cell keeps a fixed width and the columns never jitter. Lamp colour comes from the same per-state tokens as the head glyph.
- **Blinking**: the newest lamp of an *active* worker (STARTING/RUNNING/WAITING/BLOCKED) blinks at 2.5 Hz; the row head glyph blinks only for RUNNING/BLOCKED. Idle/done/failed/cancelled/lost lamps hold steady, so a blink means "live right now". Blink phase is offset per worker id (FNV hash) so a rack of lamps does not strobe in unison.
- **Animation clock**: a 120 ms ticker advances a clamped phase (max 500 ms of dt per tick, so a suspended laptop cannot make lamps jump) and asks Pi for a coalesced `requestRender()`. Worker rows are re-read on a slower 500 ms cadence. The ticker is unref'd, only runs in `mode === 'tui'` with `hasUI`, and is cleared on `session_shutdown`. `renderRack()` stays pure — phase and lamp banks are inputs, never `Date.now()` inside the renderer — so the panel is unit-testable without a terminal.
- **Seeding**: a worker already running when the panel mounts gets a lamp on first sight, not an empty socket. `LampBank.sync()` is idempotent, so the periodic re-read never floods a bank; banks for departed workers are pruned after 60 s.
- **`/rack`**: fullscreen console (`ctx.ui.custom()`) reusing the same pure renderer with `maxLamps: 24`, more rows, plus a state legend and lamp key. `esc`/`q`/`enter` closes it. The shared clock and banks outlive the screen.
- Integration point: `setWidget` with the **component factory** overload (documented in `docs/tui.md`) — Pi has no dock-right primitive, and a `custom()` overlay would steal keyboard focus from the editor, which an always-visible blinkenlight cannot afford. The component factory also hands us the *real* viewport width (`render(width)`) and the active theme, replacing the old `process.stdout.columns` guess and hand-rolled `s.length` truncation (`visibleWidth`/`truncateToWidth` now do the measuring).
- Head glyph + theme token per state: `●` RUN success, `◌` START accent, `◐` WAIT warning, `!` BLOCK error, `✓` DONE success, `✗` FAIL error, `⊘` CANCEL dim, `⊗` LOST error, `○` IDLE muted, `?` unknown. No hardcoded colours — all through `theme.fg(token, …)`.
- Header counts non-zero states in supervisor priority order (RUN, WAIT, FAIL, LOST, START, DONE), dropping the ones that do not fit; `jobs a/b` is distinct active job ids over distinct job ids.
- Rows sort in-flight workers above IDLE above finished, id order within a group. Columns: glyph, lamp bank, id, display name, task title (falls back to `task_id`), model, current action — each clipped by visible columns. The bank is allocated space before any text column and shrinks first when the terminal is narrow.
- Zero workers still renders the box with an idle line (the widget never collapses). Capped at `DEFAULT_MAX_ROWS` (8) rows; overflow shows `… +N more (see /worker_list)`. Below `MIN_BOX_WIDTH` (24) the box is dropped for bare stripped lines.
- State changes are also pushed event-driven (`worker` events/results/exit) and throttled to ~300 ms; the component reads fresh worker state in `render()` and the theme per render, so a theme switch is picked up without re-registering.

## Tools

- Operator (parent session): intent/task recording, task list/update, project reconstruct, worker spawn with ability-based selection (`dry_run` supported), worker rack, supervisor panel (worker rack blinkenlight strip + `/rack` console), endpoint/catalog status tools.
- Worker (child session): self-naming, progress/result reporting over the `SC1 {json}` notify channel.
- Shared workspace: checkout_claim / checkout_list / checkout_hash / checkout_propose / checkout_proposal_read / checkout_accept / checkout_reject / checkout_publish / checkout_release. The operator alone can checkout_transfer an orphaned or reassigned claim. The owner writes and commits; anyone can read or submit a proposed write.
- **Collaboration (first exposed layer):** checkout_propose durably queues a notification to the checkout owner and the live Pi RPC broker steers/follows up that worker. Acceptance/rejection notifies the contributor. Notices are replayed after operator restart (at-least-once delivery possible).
- **Solicit proposals:** the owner calls `checkout_solicit(paths, objective, target="W02")` to request an existing worker, or `checkout_solicit(paths, objective, spawn_new=true, ability_profile="implementation")` to request a fresh specialist. A new helper is selected through existing model/endpoint machinery (automatic helpers require a **free** endpoint), spawns with **no file claims**, and can only propose changes to the owner's files; the owner remains final committer. If neither target nor spawn_new is given, the request enters the operator routing inbox for `checkout_dispatch`. `checkout_requests` shows status and the helper's completion summary, and `checkout_request_close` closes an assistance request once reconciled. The owner may have up to three unresolved assistance requests.
- **Scheduling and durability:** the operator pumps the persisted collaboration inbox approximately every 500ms and wakes on child signals. There is a conservative cap of three active child workers for automatic help; new-worker requests wait for available capacity. Helper spawns are reserved before launch, so an interrupted dispatch needs operator intervention rather than accidentally generating duplicate workers.
- Pass `files` to `worker_spawn` to preclaim those paths; `src/` means the whole subtree. Conflicted paths stay owned by their existing worker and are returned as `checkout_conflicts`. Unspecified paths must be claimed before direct modification. There are no per-worker branches or filesystem snapshots.
- These are cooperative ownership rules, **not OS write locks**. Arbitrary shell/file edits and raw Git commands can bypass them; agents must use the checkout tools. A crashed worker's dirty checkout is preserved for operator handoff. Concurrent external Git commits are outside the broker guarantee.

## State

- Project: `<repo>/.statefulclanker/` (tasks, events, workers, receipts).
- Machine: catalog profiles, observations, health, leases (override dir with `SC_MACHINE_DIR`).

## Status

P1 (workers, shared-checkout ownership, state) and P2 (model selection) implemented. Checkout collaboration notification and proposal solicitation are implemented; the broker is cooperative and needs live concurrency hardening. Broader context compiler/RPK, general peer messaging, verification/integration are pending.

## Develop

`npm install && npm run validate`

# StatefulClanker

A [Pi](https://github.com/earendil-works/pi) package. The parent Clanker (your Pi session) is worker zero; it spawns heterogeneous Pi RPC workers, all in the same project checkout with per-file/subtree right-of-way, and picks models by ability from Pi's own model registry. Project state is durable on disk under `.statefulclanker/`. Workers name themselves.

## Install

```
pi install git:github.com/bobcatchris15-eng/StatefulClanker@v1.0.0
pi install -l git:github.com/bobcatchris15-eng/StatefulClanker@v1.0.0   # project-local
```

## Tools

- Operator (parent session): intent/task recording, task list/update, project reconstruct, worker spawn with ability-based selection (`dry_run` supported), worker rack, endpoint/catalog status tools.
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


## Living shared context (Pi fork v0.87+)

Every worker and the operator share the Git-tracked Markdown foundation at `.clanker/foundation.md` and documents under `.clanker/knowledge/**/*.md`.

- The `memory_search`, `memory_read`, `memory_graph` and `memory_write` tools are available to all agents. `memory_write` uses an exact SHA-256 `base_hash` (null for new files), claims and publishes free paths through the checkout broker, and proposes changes to another checkout owner instead of overwriting their work.
- Deterministic retrieval combines task description, active human intent, file overlap, verified status and one-hop Markdown `[[wikilinks]]`. The index is rebuilt from files; no embeddings, daemon or local model are needed.
- The Pi `context_with_system` hook silently recompiles the living Markdown section before each provider request. No memory-change messages are delivered to workers; model sessions retain separate episodic histories.
- The `context` hook keeps the original assignment and recent contiguous transcript window in the effective provider payload; the canonical on-disk session remains untouched. `SC_CONTEXT_HISTORY_CHARS` sets this soft window (default 26000; 8000–120000 supported). Native Pi compaction still handles actual overflow.
- A context receipt is stored in `.statefulclanker/context/receipts/latest-<actor>.json` whenever the selected knowledge fingerprint changes. Receipts include source paths and revision hashes.
- The operator explicitly stewards and revises the knowledge graph, and can suggest improvements to the Clanker harness itself. In human-authorized autonomous/clanker-mode it may run bounded reversible experiments and report their results; destructive/irreversible changes and spending still require appropriate permission.

The foundation is seeded automatically if a project has none. Commit `.clanker/` in projects where you want its evolving knowledge to travel with Git. This is soft context projection, not a destructive compaction or extra LLM summarization call; workers should preserve important findings in knowledge before depending on old transient tool results.

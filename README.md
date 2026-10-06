# StatefulClanker

A [Pi](https://github.com/earendil-works/pi) package. The parent Clanker (your Pi session) is worker zero; it spawns heterogeneous Pi RPC workers, each in its own git worktree (`clanker/w-NN` branches), and picks models by ability from Pi's own model registry. Project state is durable on disk under `.statefulclanker/`. Workers name themselves.

## Install

```
pi install git:github.com/bobcatchris15-eng/StatefulClanker@v1.0.0
pi install -l git:github.com/bobcatchris15-eng/StatefulClanker@v1.0.0   # project-local
```

## Tools

- Operator (parent session): intent/task recording, task list/update, project reconstruct, worker spawn with ability-based selection (`dry_run` supported), worker rack, endpoint/catalog status tools.
- Worker (child session): self-naming, progress/result reporting to the parent over the `SC1 {json}` notify channel.

## State

- Project: `<repo>/.statefulclanker/` (tasks, events, workers, receipts).
- Machine: catalog profiles, observations, health, leases (override dir with `SC_MACHINE_DIR`).

## Status

P1 (workers, worktrees, state) and P2 (model selection) done. Pending: context compiler/RPK, collaboration, verification/integration.

## Develop

`npm install && npm run validate`

---
status: provisional
tags: [pools, jules, external-agents, checkout, concurrency]
verified_by: local CLI help output, run on this machine
---

# The Jules pool is cloud + patch-on-pull, not a local child process

Verified by running `jules --help`, `jules remote --help`, `jules new --help` locally. `jules --version`
is not a valid flag (errors with `unknown flag`) — do not build a version probe on it.

## Shape of the CLI

- `jules new "<prompt>"` / `jules remote new` — "Assign a new session to Jules in a **remote VM**".
- `--repo <owner/name>` — defaults to the **current working directory's repository**.
- `--parallel N` (1-5) — several sessions for the same task in one dispatch.
- `jules remote list --session` — enumerate sessions and their states.
- `jules remote pull --session <id>` — fetch the result.
- `jules remote pull --session <id> --apply` — "Pull and apply the **patch** to the local repository".
- `jules teleport <id>` — clone repo + checkout branch + apply patch, or apply to existing repo.

## Three non-obvious consequences

1. **Async, not a spawned process.** The lifecycle is dispatch -> poll remote state -> pull -> done.
   Jules has no local child to supervise, so the local-pool `lost`/kill/timeout semantics do not
   transfer. The pane needs a state meaning "in a cloud VM", distinct from local `running`.

2. **No live shared-tree writes, so the race is inverted.** Jules edits its own cloud clone; the only
   write to the shared tree is the single `pull --apply`. The risk is therefore *not* "jules clobbers my
   file while I work" but "`pull --apply` lands on top of edits opencode/agy made during the (possibly
   long) cloud run". This is where touched-path visibility pays off: show the applied file set and
   surface overlap with another pool's touched paths. Do not block the apply.

3. **Pushed-repo precondition.** Because `--repo` defaults to the cwd's repo on GitHub, Jules codes
   against the last **pushed** commit, not the working tree. Unpushed commits mean Jules is coding
   against different content than everyone else, and `--apply` lands on top of local drift. Worth an
   indicator in the row rather than a silent proceed.

## Relation to the direct-write autonomy decision

The human accepted direct writes for local pools because shared state is recoverable via git
(commit at acceptance). Jules is the same trade with one extra hop: cloud clone -> patch -> apply.
The recovery path is `git checkout` on the applied paths. See [[external-agent-pools]] and
[[checkout-authority-model]].

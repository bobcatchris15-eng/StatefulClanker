---
name: statefulclanker-orchestration
description: Orchestrate coding and research across StatefulClanker's Pi, OpenCode, Antigravity (agy), and Google Jules REST worker pools. Use when delegating, selecting workers, collaborating, steering existing sessions, handling quotas, or verifying results.
---

# StatefulClanker — pool-neutral orchestration

The operator is worker zero. It stewards human intent, the task graph, the checkout broker, and the shared knowledge graph. **Pi, OpenCode, Antigravity and Jules are peers in dispatch priority.** Neither the operator's own Pi runtime nor the most recently successful pool receives a default preference.

## Decision procedure for every bounded job

1. Ask whether the operator can complete it directly. Otherwise inspect the existing worker roster and prefer steering a suitable session that already has relevant context.
2. Evaluate **all four** pool types for a new assignment. Do not eliminate a pool merely because it is external, and do not mistake a client session for a Pi inference endpoint.
3. Exclude only demonstrated mismatches: inaccessible files, unavailable authentication, quota exhausted, unsupported tooling, conflicting file ownership, blocked transport, task-specific instructions or explicit user cost constraints.
4. Rank eligible pools by the assignment's actual needs: live dirty-tree access, tool-use reliability, repository branch/source, model capability, context continuity, expected turnaround and observed health. Use measured evidence instead of stereotypes.
5. When equally capable, diversify/rotate to avoid Pi favoritism and undue concentration. Prefer using available **independent** quotas; never promise that a particular free model is available without verification.
6. Specify an explicit `backend` in `worker_spawn` for every delegated job, including `pi`. The omission default in legacy code is not a routing policy.
7. Keep the task and expected outputs stable across backend changes. Dispatch is not verification; after the worker submits results, inspect artifacts and tests, then use `task_verify`.

## Pool capability cards

| Pool | Dispatch | Live dirty files | Continuity | Quota and model ownership |
|---|---|---|---|---|
| Pi | `worker_spawn backend=pi` | Yes, shared checkout | Pi RPC messaging/follow-up | Pi model registry/endpoint leases |
| OpenCode | `worker_spawn backend=opencode` | Yes, shared checkout | OpenCode HTTP session, `external_worker_message` and abort | Installed OpenCode client/server; its own models and authentication |
| Antigravity | `worker_spawn backend=agy` | Yes, shared checkout | Current adapter: headless one-shot; record `conversation_id` for follow-up | Installed agy client; its own models and authentication |
| Jules REST | `worker_spawn backend=jules` | No; reads pushed GitHub source/branch | Persistent remote session, `external_worker_message`, plan approval | `JULES_API_KEY`; its own task/concurrency limits; **not** an inference endpoint |

OpenCode session API can handle multiple sessions on one server. Do not model it as a Pi provider endpoint or bypass the OpenCode client by sending requests directly to its underlying model vendor. Unless the user specifically requests a model, let the OpenCode client select one.

Agy writes local files and emits NDJSON status events; a zero CLI exit code is not proof of successful work. Its current transport differs from OpenCode: do not claim interactive mid-turn steering when using a one-shot invocation.

Jules works on a remote Git revision, not uncommitted files. Check the branch/source. The local scheduler defaults to 100 REST task submissions per rolling 24 hours and 15 simultaneous tasks, configurable by `SC_JULES_DAILY_LIMIT` and `SC_JULES_CONCURRENT_LIMIT`. These are local safeguards, not live remaining-quota measurements. Collect the git patch without modifying the checkout, and explicitly apply only when merging the remote result. Jules remote sessions continue during an operator shutdown.

## Collaboration and receipts

- Call `external_worker_list` to inspect external jobs and local quota counters; `worker_list` covers native Pi workers. `external_worker_refresh` reconciles live OpenCode and Jules status.
- Send peer feedback through `external_worker_message` for OpenCode/Jules or native `worker_message`/`worker_follow_up` for Pi.
- Assign unrelated files where practical. Pi checkout claims are cooperative; external clients can write directly. Keep ownership and conflict hazards visible without adding blanket approval gates the human did not request.
- All pools must produce an accountable task receipt. API/process success means *submitted for review*; only independent evidence-backed verification completes a task.
- Never silently substitute paid inference or exhaust an unknown client quota when the task is free-only. Do not collapse independent backend budgets into Pi endpoint health.
- Maintain the project Markdown knowledge graph: important discoveries, changes in backend behavior, failure modes, and successful workarounds should become linked, revisable project knowledge.

## Setup and troubleshooting

Set `JULES_API_KEY` in the invoking process environment for Jules REST (do not commit credentials). OpenCode needs the installed `opencode` executable and authenticated model configuration; the extension can start a loopback server or attach to `OPENCODE_SERVER_URL` with `OPENCODE_SERVER_PASSWORD` if configured. Agy needs the installed authenticated `agy` executable. On Windows verify whether the resolved command is a native `.exe` or an npm shim.

Do not mistake a visible CLI binary for functioning authentication. Query and test the actual client when available. Distinguish a missing executable, failed authentication, provider rate limit, permission denial, interrupted session, remote task failure and source/branch drift in receipts. The live testing machine may have a different version than the documentation; verify against its installed help/schema when possible.

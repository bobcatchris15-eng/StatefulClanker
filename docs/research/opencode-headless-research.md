# OpenCode headless requirements for StatefulClanker

Researched 2026-10-10. Local OpenCode upgraded from 1.18.32 to 1.18.35 with `npm install -g opencode-ai@1.18.35`. The existing stable package's latest version was verified against npm and the [upstream release](https://github.com/anomalyco/opencode/releases/tag/v1.18.35).

## Recommendation

Use a supervised, authenticated OpenCode HTTP server for each active project, with one session per StatefulClanker worker. Run the server in the exact existing checkout; all sessions share physical source files while keeping separate conversations. StatefulClanker retains ownership of task records, file claims, model capacity, receipts, and acceptance of results.

This is a proposed integration, not an implemented backend. Current `workers/manager.ts` constructs `PiRpcRuntime` directly, and `catalog/service.ts` receives Pi registry context. OpenCode is not yet interchangeable with a Pi worker.

## Verified on this machine

Executable: `C:\Users\Chris\AppData\Roaming\npm\node_modules\opencode-ai\bin\opencode.exe`.

`opencode --version` and server health both report 1.18.35. `run --help`, `serve --help`, and `acp --help` are available. Credential metadata lists OpenCode Go and OpenCode Zen API credentials; their validity and quota were not tested. Credential values were not read or printed.

The repeatable [probe](opencode-headless-probe.mjs) uses isolated XDG config/data/cache/state directories and a temporary Git repository, disables updates, sharing, and snapshots, and makes no inference requests. The [receipt](opencode-headless-probe-1.18.35.json) records eight passing checks:

- The server directory and Git worktree resolve to the fixture checkout.
- Dirty tracked files and untracked files are readable.
- A parent edit after startup is immediately readable.
- Two sessions have the same directory.
- Session histories remain separate.
- Unauthenticated requests return HTTP 401.
- Exactly one Git worktree exists.
- Both sessions and stored context survive a controlled server restart.

These are server/API checks, not a live model-tool-use or concurrent-write acceptance test. The probe shuts down its own server and leaves its fixture and OpenAPI schema in temp for inspection.

## Interfaces and version boundary

| Interface | Appropriate use | Integration requirements |
|---|---|---|
| `opencode run --format json` | Bounded scripts and initial smoke tests | Explicit model, agent, directory and session; drain stdout/stderr; reconcile structured events and final messages; enforce deadlines. |
| `opencode serve` plus HTTP/SDK | Stateful worker fleet; recommended | Own server lifecycle, session mapping, event subscriptions, pending approvals/questions, cancellation and recovery. |
| `opencode acp --cwd ...` | A portable agent transport over stdio | Implement ACP initialization, capabilities, JSON-RPC correlation, session updates, permission callbacks and cancellation. ACP is not Pi RPC. |

The installed CLI also offers `run --attach`, `--session`, `--dir`, `--model`, `--agent`, `--variant`, and `--auto`. Use explicit session IDs; continuing the last session is ambiguous in a fleet. [CLI documentation](https://opencode.ai/docs/cli/) and [ACP documentation](https://opencode.ai/docs/acp/).

The official website separately promotes OpenCode V2 and a different `@opencode/cli` package. Its [installation instructions](https://opencode.ai/v2/docs/) say Windows package managers are unsupported and link standalone Windows binaries. This audit updated the existing stable 1.x installation; it did not migrate to V2.

V1 uses `permission`/`bash`/`task`; V2 uses `permissions`/`shell`/`subagent`. Never mix those schemas. See [V2 permissions](https://opencode.ai/v2/docs/permissions). Version-pin the binary, SDK and plugin dependencies together, and validate against the running binary's `/doc`, rather than assuming examples from another release apply.

## Required runtime contract

1. Launch the native executable with an argument array, `shell: false`, `windowsHide: true`, and a canonical absolute checkout directory. Avoid depending on the npm PowerShell/CMD wrapper. Resolve the executable during installation/discovery, not by a permanent hard-coded user path.
2. Bind to loopback with an explicit or discovered port and a generated server password. Confirm authenticated health and version before dispatch. Keep startup, transport, inactivity and whole-task timeouts separate. [Server documentation](https://opencode.ai/docs/server/).
3. Persist the backend kind, worker ID, server identity, project directory, session ID, task ID, model, agent, variant and request/message IDs. A shared server PID is not enough to determine whether an individual worker is alive.
4. Create one session per worker. Attach directory context explicitly to applicable requests, then verify returned paths/session directory. Never invoke worktree creation or move sessions into another checkout.
5. Subscribe to events before submitting work; correlate by session and message. Normalize tool activity, retries, errors and waits into existing worker statuses. Reconcile session history/status after event disconnection; do not assume an event stream replays everything missed.
6. Treat prompt submission as admission, not completion. Require a validated result record and completed turn with no terminal model/tool error. Idle, HTTP 200 and process exit alone do not prove task success.
7. Cancel the individual session before escalating. Killing a shared server affects every worker. Test whether cancellation also stops long-running shell descendants on Windows. Release model capacity only after execution has stopped; preserve dirty claims for handoff.
8. On orchestrator restart, reconcile persisted sessions, pending permission/question requests and outstanding messages before dispatching new work. The probe proves history persistence, not automatic resumption of interrupted inference.

Installed 1.18.35 exposes compatibility `/session` APIs and an additional `/api` surface. Its live schema includes `/api/session/{sessionID}/prompt` with `delivery: steer|queue`, plus an interrupt endpoint. These were inspected, not exercised with active inference. Implement busy-session steering only after a pinned-version test proves it. Otherwise serialize turns with an orchestrator-owned queue.

The installed compatibility prompt schema accepts `format`, not `outputFormat`; this is one reason to inspect the live schema. `noReply: true` still required explicit model identity in the isolated probe: with an empty provider pool, context insertion returned HTTP 500. The corrected probe uses an enumerated model and makes no inference request.

## Authentication, model selection and budget

OpenCode owns its provider connections independently of Pi. Pi credentials and model IDs do not automatically work in OpenCode. Preconfigure provider authentication before unattended work, enumerate the connected provider/model pool, and pin provider/model plus reasoning variant per assignment. Refresh/token-expiry and model removal are runtime failures to handle explicitly. [Provider documentation](https://opencode.ai/docs/providers/).

Add a backend dimension to StatefulClanker model selection and leases. Reuse ratings, observations and health logic, but do not manufacture OpenCode candidates from Pi's registry or silently substitute another model. Normalize outcomes such as rate limiting, auth failure, timeout, malformed tools and context exhaustion.

For a free-only task, require current verified price/policy metadata and fail closed when unknown; never fall back to paid models. Set wall-time, step, concurrency and output budgets. Validate provider-specific output-limit controls before relying on them: the installed `run` help has no generic max-token flag. Earlier project notes warned that locally assigned zero prices were not authoritative; no historical free-model roster is reused here.

## Unattended permissions and shared checkout tools

An unattended worker needs a deliberate permission policy or an orchestrator that services approval requests. Handle user questions too; deny or route them into a bounded BLOCKED state rather than leaving the worker waiting forever. The installed schema exposes pending permission/question queries, replies and question rejection. [V1 permission documentation](https://opencode.ai/docs/permissions/).

Provide an OpenCode plugin/custom-tool or MCP bridge to the existing broker: task context, naming/progress/result reporting, claims, hashes, proposals, acceptance/rejection, solicitation, publish and release. OpenCode does not load Pi `index.ts`, and Pi's `SC1` notify channel is not an OpenCode completion protocol.

Identity must come from a trusted session-to-worker mapping. Several sessions share one server process, so process environment `SC_WORKER_ID` cannot identify each session. Do not accept an arbitrary model-supplied owner ID as authority. OpenCode custom tools receive session and directory context, which is useful for this binding. [Custom tool documentation](https://opencode.ai/docs/custom-tools/).

Start with proposal-only helpers: reads allowed, direct edits and raw shell writes restricted, changes submitted through checkout proposals, and the existing owner validates/publishes. For direct-writing workers, enforce live ownership in tools/hooks and restrict bypass paths. Bash permissions alone cannot turn cooperative ownership into an OS lock.

Audit the effective configuration, including global/project config, agents, plugins and MCP. Config sources merge rather than replace one another. Disable automatic updates and sharing for supervised workers. Disable or constrain automatic formatters and mutating tools that could edit unclaimed files. In a shared checkout, do not use session undo/revert to restore the whole workspace: it can overwrite a peer's changes. Disabling snapshots avoids relying on that rollback mechanism. [Configuration documentation](https://opencode.ai/docs/config/).

Plugin tool hooks and session events can support ownership checks and result delivery; dependency installation during startup must be completed and tested before workers are dispatched. Pin/preinstall plugin packages, and use `--pure` only for baseline probes that intentionally exclude the bridge. [Plugin documentation](https://opencode.ai/docs/plugins/).

## Acceptance gates before calling the backend reliable

The next implementation should pass deterministic tests, then a bounded real-provider run:

- Real OpenCode agent reads the parent's dirty and untracked files with its own tool; peer edit visibility is checked in both directions.
- Claim conflicts, stale proposals and scoped publishing preserve unrelated dirty/staged work.
- Permission and question requests become visible BLOCKED states and resolve without a TUI.
- Two active sessions do not cross-deliver messages/results or identities.
- A dropped event connection is reconciled without duplicate task execution.
- Abort stops one session while a second continues; shell descendants are checked.
- Parent and server restarts retain receipts and reconcile outstanding work without silently re-running it.
- Mocked 429, auth failure, provider timeout, invalid structured output and unavailable-model cases produce bounded failure/recovery.
- Explicit free-only policy prevents paid fallback; observed costs and output budgets are recorded.

Current confidence: strong evidence for headless transport, authentication, shared physical file reads and persisted sessions on native Windows. Live agent execution, shell cancellation, provider reliability and fleet ownership integration remain unverified.

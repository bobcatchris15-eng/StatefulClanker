---
id: external-agent-pools
status: provisional
tags: [orchestrator, opencode, agy, jules, supervisor-pane, pools]
paths: [operator.ts, ui/, workers/, catalog/, protocol/]
links: [living-context, shared-checkouts, evidence-discipline]
---
# External agent pools (opencode, agy, Google Jules)

Goal: the operator's orchestrator should also lean on non-Pi execution sources, each treated as an
**unrelated pool** with its own model/catalog semantics, lifecycle, health and receipts.

All three CLIs are installed and authenticated on this machine (verified 2026-03 by running `--help`
and the list subcommands locally). Prefer local `--help` output over web docs; it is the primary evidence
for these contracts.

| Source | Kind | Local? | Contract |
|---|---|---|---|
| Pi (`pi --mode rpc`) | local child process | yes | JSONL RPC; exported `RpcClient`; one Pi per worker (`workers/runtime.ts`) |
| opencode 1.18.35 | local child process | yes | `opencode run [msg]` with `--format json` raw JSON events, `-s/--session <id>`, `-c/--continue`, `--fork`, `-m/--model provider/model`, `--variant`, `--agent`, `--dir`, `-f/--file` (repeatable), `--title`, `--print-logs`/`--log-level`, `--attach URL`/`--port`. **No per-run read-only flag**: the only safety lever is opencode's own permission deny-list, so do not auto-approve permissions by default. |
| agy 1.3.3 (`agy.exe`) | local child process | yes | `agy exec -p <prompt>` (subcommand optional). `--output-format text\|json\|stream-json`, `--input-format text\|stream-json` (NDJSON in), `--json-schema`, `--conversation <id>` (resume by id - there is no `--session` switch), `-c/--continue`, `--mode accept-edits\|plan` (**`plan` = safe headless default**), `--sandbox`, `--dangerously-skip-permissions`, `--add-dir <path>` (repeatable), `--project`, `--model`, `--agent`, `--effort low\|medium\|high\|xhigh\|max`, `--print-timeout <dur>` (0 = no limit). Subcommands: `models`, `agent`, `mcp`, `plugin`, `remote-control`, `install`, `update`. **There is no git autocommit flag** (an earlier draft of this note claimed autocommit - wrong, see [[evidence-discipline]]). |
| Google Jules | cloud VM, via local `jules` CLI | no | `jules new "<task>" [--repo owner/name] [--parallel 1-5]`; script-friendly `jules remote new --session "<task>"`; `jules remote list --session` -> columns `ID \| Description \| Repo \| Last active \| Status`; `jules remote list --repo`; `jules remote pull --session <id> [--apply]`; `jules teleport <id>`; `jules login/logout/version`. Observed Status values: `Planning`, `Completed`. IDs are large numeric strings. Connected repo: `bobcatchris15-eng/StatefulClanker`. Prefer the `jules remote ...` family in code: it is the script-friendly surface. **Never pass `--apply` automatically** - that applies a remote branch into the local tree; leave the PR/branch as the receipt. Supersedes an earlier sketch of a raw REST API (`POST /v1beta/sessions`). |

Per-pool catalogs (do not merge with the Pi selection ranking):
- opencode: model ids from its own config/models output, plus `--agent` presets.
- agy: `agy models` verified -> `gemini-3.8/3.7/3.6-flash-{high,medium,low}`, `gemini-3.1-pro-{high,low}`,
  `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, `gpt-oss-120b-medium`. `agy agent` printed nothing, so
  agent names are unverified.
- jules: no model choice; the human's intent selects what the session description asks for.

Consequences for the design:

1. **Pool separation.** Jules has no local process and cloud-side git authority: its only local effect is
   `jules remote pull --apply`, which must be operator-mediated and must never be automatic. It must never
   take checkout ownership (see [[shared-checkouts]]). opencode/agy edit the shared tree, so they need the
   same `checkout_claim`/`checkout_propose` discipline as native workers.
2. **Receipts are CLI-output level, not `worker_finish` JSON.** Normalize to a common record shape
   (pool, external_session_id, task, status, model, started/last-active, summary, changed_files, receipt)
   so the supervisor can render any pool without knowing the source. `changed_files` comes from
   `git status --porcelain` differences - never stage, never commit from a pool adapter.
3. **Supervisor pane split (`ui/pool-pane.ts`, pure renderer).** Native workers keep the animated pane;
   each external pool gets its own static pane, hidden when empty, header carrying pool availability +
   last error. External pools only have coarse lifecycle, so no animation. Layout rules:
   minimum column width 24; below `24 * activeColumns` the pane degrades to a vertical stack in pool order
   (native, opencode, agy, jules); above it, column widths are proportional to natural content width clamped
   to `[24, floor(width/activeColumns)]` with the remainder given to the widest column; columns are padded
   to the tallest column and separated by one blank column. Deterministic - no `Math.random`, no `Date.now`
   inside the renderer; time arrives as `nowMs`. Glyphs are single-width and exported: queued `·`,
   starting `◌`, running `▶`, waiting_input `?`, succeeded `✓`, failed `✗`, cancelled `—`, unknown `~`.
   `externalPoolIds()` returns `["opencode","agy","jules"]` so operator.ts iterates in stable order.
4. **Protocol separation.** The `SC1 {json}` worker<->parent channel stays native-only; external pools get
   their own message namespace so the two cannot collide.
5. **Jules lifecycle has no per-session detail subcommand**: poll `jules remote list --session` until a
   terminal status, matching on session ID. Concurrent operators' sessions appear in the same table, so
   match by ID and never by position.
6. **Bounded, cancellable, injectable adapters.** Every pool adapter takes injected
   `spawnFn`/`nowMs`/poller seams so unit tests need no real CLI. `run()` never throws - it returns a
   receipt with `failed` + reason. Availability probes (`opencodeAvailable`, `agyAvailable`, `julesAvailable`)
   must be cheap and must return false (not throw) when the CLI is missing or unauthenticated; on win32
   resolve both `agy` and `agy.exe`.
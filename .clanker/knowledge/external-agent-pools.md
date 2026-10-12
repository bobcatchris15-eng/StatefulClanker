---
id: external-agent-pools
status: provisional
tags: [orchestrator, opencode, agy, jules, supervisor-pane, pools]
paths: [operator.ts, ui/, workers/, catalog/, protocol/, pools/]
links: [living-context, shared-checkouts, evidence-discipline]
---
# External agent pools (opencode, agy, Google Jules)

Goal: the operator's orchestrator should also lean on non-Pi execution sources, each treated as an
**unrelated pool** with its own model/catalog semantics, lifecycle, health and receipts.

All three CLIs are installed and authenticated on this machine (verified by running `--help` and the
list subcommands locally). Prefer local `--help` output over web docs; it is the primary evidence
for these contracts. See [[evidence-discipline]].

| Source | Kind | Local? | Contract |
|---|---|---|---|
| Pi (`pi --mode rpc`) | local child process | yes | JSONL RPC; exported `RpcClient`; one Pi per worker (`workers/runtime.ts`) |
| opencode 1.18.35 | local child process | yes | `opencode run [msg]` with `--format json` raw JSON events, `-s/--session <id>` (the documented session switch), `-c/--continue`, `--fork`, `-m/--model provider/model`, `--variant`, `--agent`, `--dir`, `-f/--file` (repeatable), `--title`, `--print-logs`/`--log-level`, `--attach URL`/`--port`. **No per-run read-only flag**: the only safety lever is opencode's own permission deny-list, so do not auto-approve permissions by default. |
| agy 1.3.3 (`agy.exe`) | local child process | yes | **Print mode, not a subcommand**: `agy --print "<prompt>"` with aliases `-p` / `--prompt` (there is NO `agy exec`). Options: `--output-format text\|json\|stream-json`, `--input-format text\|stream-json` (NDJSON stdin, one message per line, requires `--output-format stream-json`), `--json-schema`, `--conversation <id>`, `-c/--continue`, `--mode accept-edits\|plan` (**`plan` = safe headless default**), `--sandbox`, `--dangerously-skip-permissions`, `--add-dir <path>` (repeatable), `--project`, `--model`, `--agent`, `--effort low\|medium\|high\|xhigh\|max`, `--print-timeout <dur>` (0 = no limit), `--new-project`, `--disable-slash-commands`, `--log-file`, `--remote-control`, `-i/--prompt-interactive`. Real subcommand list (only these): `agent`, `agents`, `changelog`, `help`, `install`, `mcp`, `mic-serve`, `models`, `plugin`, `plugins`, `remote-control`, `update`. **No git autocommit flag.** |
| Google Jules | cloud VM, via local `jules` CLI | no | `jules new "<task>" [--repo owner/name] [--parallel 1-5]`; script-friendly `jules remote new --session "<task>"`; `jules remote list --session` -> columns `ID \| Description \| Repo \| Last active \| Status`; `jules remote list --repo`; `jules remote pull --session <id> [--apply]`; `jules teleport <id>`; `jules login/logout/version`. Observed Status values: `Planning`, `Completed`. IDs are large numeric strings. Connected repo: `bobcatchris15-eng/StatefulClanker`. Prefer `jules remote ...`: it is the script-friendly surface. **Never pass `--apply` automatically.** Supersedes an earlier sketch of a raw REST API. |

Session resume, per source (deliberately asymmetric - see the human intent note in [[evidence-discipline]]):
- opencode: `-s/--session <id>`, plus `-c/--continue` and `--fork`. Documented and supported.
- agy: the human states agy has **no** `--session`. `--conversation <id>` and `-c/--continue` appear in
  `--help` but are unverified in practice, so resume must be an **optional** pool capability: agy workers
  must complete correctly without it. Do not make the pool contract depend on it.
- jules: session identity is the Jules session ID itself.

Per-pool catalogs (do not merge with the Pi selection ranking):
- opencode: model ids from its own config/models output, plus `--agent` presets.
- agy: `agy models` -> `gemini-3.8/3.7/3.6-flash-{high,medium,low}`, `gemini-3.1-pro-{high,low}`,
  `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, `gpt-oss-120b-medium`. `agy agent` printed nothing, so
  agent names are unverified.
- jules: no model choice; the task description selects the work.

Consequences for the design:

1. **Pool separation.** Jules has no local process and cloud-side git authority: its only local effect is
   `jules remote pull --apply`, which must be operator-mediated and never automatic. It must never take
   checkout ownership (see [[shared-checkouts]]). opencode/agy edit the shared tree, so they need the same
   `checkout_claim`/`checkout_propose` discipline as native workers.
2. **Receipts are CLI-output level, not `worker_finish` JSON.** Normalize to a common record shape
   (pool, external_session_id, task, status, model, started/last-active, summary, changed_files, receipt)
   so the supervisor can render any pool without knowing the source. `changed_files` comes from
   `git status --porcelain` differences - never stage, never commit from a pool adapter.
3. **Supervisor pane split (`ui/pool-pane.ts`, pure renderer).** Native workers keep the animated pane;
   each external pool gets its own static pane, hidden when empty, header carrying pool availability +
   last error. External pools only have coarse lifecycle, so no animation. Layout: minimum column width
   24; below `24 * activeColumns` the pane degrades to a vertical stack in pool order
   (native, opencode, agy, jules); above it, column widths are proportional to natural content width clamped
   to `[24, floor(width/activeColumns)]` with the remainder given to the widest column; columns are padded
   to the tallest and separated by one blank column. Deterministic - no `Math.random`, no `Date.now` inside
   the renderer; time arrives as `nowMs`. Glyphs are single-width and exported: queued `·`, starting `◌`,
   running `▶`, waiting_input `?`, succeeded `✓`, failed `✗`, cancelled `—`, unknown `~`.
   `externalPoolIds()` returns `["opencode","agy","jules"]` so operator.ts iterates in stable order.
4. **Protocol separation.** The `SC1 {json}` worker<->parent channel stays native-only; external pools get
   their own message namespace so the two cannot collide.
5. **Jules lifecycle has no per-session detail subcommand**: poll `jules remote list --session` until a
   terminal status, matching on session ID. Concurrent operators' sessions appear in the same table, so
   match by ID and never by position.
6. **Bounded, cancellable, injectable adapters.** Every pool adapter takes injected
   `spawnFn`/`nowMs`/poller seams so unit tests need no real CLI. `run()` never throws - it returns a
   receipt with `failed` + reason. Availability probes (`opencodeAvailable`, `agyAvailable`, `julesAvailable`)
   must be cheap and return false (not throw) when the CLI is missing or unauthenticated; on win32 resolve
   both `agy` and `agy.exe`.
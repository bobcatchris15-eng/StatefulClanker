---
id: external-agent-pools
status: provisional
tags: [orchestrator, opencode, agy, jules, supervisor-pane, pools]
paths: [operator.ts, ui/, workers/, catalog/]
links: [living-context, shared-checkouts]
---
# External agent pools (opencode, agy, Google Jules)

Goal: the operator's orchestrator should also lean on non-Pi execution sources, each treated as an
**unrelated pool** with its own model/catalog semantics, lifecycle, health and receipts.

Survey (2026-03, verified locally: `opencode --version` = 1.18.35, `agy --version` = 1.3.3):

| Source | Kind | Local? | Contract |
|---|---|---|---|
| Pi (`pi --mode rpc`) | local child process | yes | JSONL RPC; exported `RpcClient`; this repo already drives one Pi per worker (`workers/runtime.ts`) |
| opencode | local child process | yes (`opencode run`) | `opencode run --print-logs [--agent <name>] <prompt>`; exit code = result; OpenAgent SDK is TS-in-process, not a stream protocol |
| agy | local child process | yes (`agy.exe`) | `agy exec -p <text>`, JSON/JSONL events on stdout; autocommit by default; `-` stdin, `-d/--dir`, `-m/--mode`, `-A/--model`, `-w/--write`; `agy mcp` exposes agy as MCP; unknown whether it can suppress git writes |
| Google Jules | cloud | no | `POST /v1beta/sessions` -> poll `GET /v1/{id}` until state `FINISHED`; outputs land in a **Google Cloud worktree VM**, mirrored to a GitHub branch by a bot PR; API key + `X-Google-Api-Client-Version` header required |

Consequences for the design:

1. **Pool separation.** Jules has no local process, no local checkout edit, and cloud-side git authority:
   it must never share checkout ownership with local pools. opencode/agy edit the shared tree, so they
   need the same `checkout_claim`/`checkout_propose` discipline as native workers - probably enforced by a
   `--permission`/tool-restriction flag, not by convention.
2. **Receipts are filesystem- or API-level, not `worker_finish` JSON.** Each adapter must normalize to a
   common `WorkerRecord`-ish shape (id, pool, task, status, summary, changed_files, receipt) so the
   supervisor can render them without knowing the source.
3. **Supervisor pane split.** Native workers show animated lamps; external pools only have coarse
   lifecycle state, so they belong in their own static panes. Layout proposal: lamps left, one static
   column per pool (native / opencode / agy / jules), collapsed when empty, with a header carrying pool
   name, availability and last error.
4. **Catalog.** `catalog/` today assumes "pool == Pi model registry". External pools need their own
   discovery: opencode `models` from config, agy `agy models list`, Jules no model choice at all (or
   agent-class presets). Keep per-pool catalogs; never merge into the Pi selection ranking.

Open questions: agy's ability to run without git writes; whether opencode exposes per-session resume;
Jules API key source and rate limits; how to map a Jules branch/PR back to this repo's shared tree.
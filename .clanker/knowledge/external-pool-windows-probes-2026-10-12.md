---
id: external-pool-windows-probes-2026-10-12
status: provisional
tags: [external-pools, windows, opencode, agy, jules, troubleshooting]
links: [external-agent-pools, jules-cloud-pool, evidence-discipline]
---
# External pool Windows live probes (2026-10-12)

Host: Windows desktop with `E:\\StatefulClanker`, Node 24.15.0, OpenCode 1.18.35,
agy 1.3.3 and Jules CLI 0.1.42. The live probes ran with disposable fixtures
under the user's OS temporary directory rather than editing repository files.

## Confirmed successful

- `npm run validate`: TypeScript typecheck, unit tests, real Pi mock-provider E2E passed.
- **Antigravity**: CLI `--print --output-format stream-json` reported init,
  file-reading tool events and terminal `result.status=SUCCESS` plus
  `conversation_id`. A real `ExternalPoolManager.launch({pool:'agy'})` run
  completed in ~10s with a durable receipt and expected fixture answer.
- **Jules REST**: key present in the persisted Windows current-user environment.
  The remote-process environment had not inherited it. `JulesRest` now reads
  the current-user variable on Windows if `process.env.JULES_API_KEY` is absent;
  never print or commit the key.
  `GET /sources` authenticated and matched the connected project.
  A real **read-only** `POST /sessions` created a remote session, its activities
  contained the expected marker, and `sendMessage` successfully steered it.
  This consumed one Jules REST task; it did not submit a code patch.
  Jules creation omitted `state` in its response. The adapter now records
  the returned session name *before* performing a separate status lookup.
  The in-flight session was recovered without repeating the task.
- **OpenCode transport**: native installed `opencode.exe` located under its
  npm package; authenticated loopback server health, V2 session creation,
  model selection and durable prompt admission all verified.
  Windows npm shim spawn formerly orphaned an `opencode.exe` process; fixed
  by direct native executable launch and process-tree disposal.
  The 1.18.35 V2 `/api/session/{id}/prompt` returns an admission ID and
  emits `session.next.prompt.admitted` + `session.next.prompted`.
  The compatibility `prompt_async` route can return 204 without creating a
  visible user message, so V2 is used instead.

## Unresolved OpenCode inference

OpenCode has two configured credentials and lists models. However, several
independent direct `opencode run` probes (normal, `--pure`, `--auto`,
OpenCode free and OpenCode Go models) stalled after the CLI `init` log without
a model response. HTTP V2 sessions likewise recorded prompts but emitted no
agent step or assistant message during the bounded observation windows.
Do not report this as a successful agent task or assume a model was actually
contacted. A real `ExternalPoolManager` session was correctly aborted and
classified `timeout` at its configured 12-second diagnostic limit.

The precise cause is not established. The same behavior happens with the
client independently of StatefulClanker's transport. Follow-up: inspect the
installed OpenCode runtime's bootstrap and worker/queue logs in a controlled
session and verify interactive TUI model execution on this exact host.
Do not kill unrelated `opencode serve` instances on the user's machine.

## Test/implementation implications

- Do not count HTTP 204, prompt admission, zero process exit or a cloud create
  response as verified task success.
- Preserve Jules session IDs before state parsing and recover remote work after
  operator restart; never automatically repeat ambiguous cloud creates.
- Normalize `timeout` separately from `failed`, and terminate only a
  supervisor-owned OpenCode process tree.
- Distinguish the presence of provider credentials and listed models from
  actual inference availability.
- The rest of the shared checkout remained unchanged; an untracked `tmp/`
  directory existed before testing and was not deleted.

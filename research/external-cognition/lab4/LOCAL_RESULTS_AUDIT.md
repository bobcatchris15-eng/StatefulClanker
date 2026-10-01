# Independent audit: local Qwen run

## Finding

The completed `local-qwen2` run is internally consistent with its saved requests, responses, protocol receipts, event log, frozen inputs, and source snapshots. It completed the 12-call schedule with 11 HTTP 200 responses and one HTTP 500. Four model outputs failed JSON parsing, seven protocol events were accepted, no coefficient claims were committed, and no fork was opened. Both integrators produced two accepted final responses, but all four answers were incorrect under independent enumeration of the public packets.

This run therefore did not demonstrate useful cooperative performance under its declared envelope. It is one small, capped local-model run and does not establish that cooperative engines are infeasible more generally.

## Independent check

I independently enumerated every affine coefficient triple and every target pair over mod 11 using only the saved public observations. The unique relations and target solutions are:

| Case | u relation | v relation | Target (x, y) |
|---|---|---|---|
| 4201 | (3, 5, 4) | (7, 2, 10) | (2, 10) |
| 4202 | (6, 10, 10) | (10, 5, 8) | (8, 4) |

The four accepted integrator answers were 4201 shared (9, 5), raw (9, 5); 4202 shared (1, 8), raw (1, 3). None matches its independently derived target. There were no accepted relation claims to combine; the integrators worked from the available evidence reports and empty claim set.

## Integrity and accounting

All 12 scheduled slots have distinct saved request records, with no retries. Each request uses one user message whose content matches the frozen prompt; request model alias, generation settings, and prompt hashes match the run configuration and frozen artifacts. For all 11 HTTP 200 calls, returned model aliases are allowed, response-body and content hashes reconcile across transport logs, raw content, call records, and protocol submissions, and saved receipts agree with the event log. The remaining call, v-proposer for case 4202, returned HTTP 500 with retained body `{"error":"runlist failed execution"}`; it has no model content or protocol submission.

Two calls used the full 512-token completion cap. Both report `finish_reason="stop"`, not `"length"`, and contain malformed JSON. This supports reporting cap-reaching malformed outputs, but does not establish that the server truncated them. Usage is partial because the HTTP 500 has no token usage: the 11 successful responses sum to 10,617 prompt tokens and 3,095 completion tokens (13,712 total), matching the resource summary.

The recorded model alias was `qwen3.5-9b-FLM`, returning checkpoint `qwen3.5:9b`, with temperature 0, timeout 300 seconds, context length 70,728, and non-streaming requests. Source and snapshot checksums reconcile for all ten frozen files and four frozen input snapshots; run manifest, readiness, and evaluation hashes reconcile with the completion receipt. Replaying the saved events reproduces the recorded projection. No live stale-fork behavior was observed; that behavior is covered only by mechanical tests.

The earlier `local-qwen1` attempt is separate and incomplete: six slots attempted, six unattempted, no evaluation. Its two proposer calls timed out at about 300 seconds; the reviewer calls returned, while both integrator attempts have no collected outcome. It is not included in the completed-run score. Health and model-list requests were preflight diagnostics, not scheduled inference calls.

## Scope

The evidence covers two synthetic mod-11 cases, one local Qwen checkpoint/configuration, temperature 0, a 512 completion-token cap, and 12 scheduled requests. It says nothing conclusive about other models, larger tasks, or cooperative performance across a broader workload.

Machine-readable checks and per-call evidence are in [LOCAL_RESULTS_AUDIT_DATA.json](LOCAL_RESULTS_AUDIT_DATA.json).

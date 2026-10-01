# Local Qwen execution and feasibility results

Qwen responds through Lemonade. A direct request returned **READY in 2.11 seconds**, a JSON request returned `{"ok":true}`, and two concurrent tiny requests returned ALPHA and BETA. The coordinator changed no Lemonade settings; the user-configured context remained 70,728. See [diagnostics](diagnostics/qwen-endpoint/README.md) for exact requests/responses.

## First run: interrupted, not scored

The first frozen local run requested 4096 output tokens per call with a 300-second timeout. Both proposers timed out. Two subsequent review calls returned: one accepted envelope and one invalid JSON. On the user's direction to test the endpoint, the coordinator stopped the runner while two integrator requests were in flight. Six slots were attempted, six unattempted; the two in-flight responses were not collected. No offline score was produced, and these slots were not retried or replaced. Original sources, plan and records remain in [local-qwen1](runs/local-qwen1).

## Second run: twelve outcomes, separate frozen plan

After the diagnostic calibration, a new exploratory run changed only the requested output ceiling to 512 tokens. It retained temperature 0, timeout 300 seconds, stream false, the same two public cases and role schedule, the same Qwen checkpoint/FLM NPU backend, and context 70,728. Every request was a fresh single-user-message context. There were no retries, output repairs or correctness feedback. The run lasted approximately 8 minutes 6 seconds.

| Case | Proposal state | Review state | Shared final | Raw final |
|---|---|---|---|---|
| 4201 | Both invalid JSON; neither committed | One accepted fallback report, one invalid JSON | (9,5), wrong; true (2,10) | (9,5), wrong |
| 4202 | u invalid JSON; v HTTP 500 | Two accepted fallback reports | (1,8), wrong; true (8,4) | (1,3), wrong |

All twelve slots have outcomes: eleven HTTP 200 responses and one HTTP 500 response containing `runlist failed execution`. Seven envelopes were accepted by the protocol, four rejected as invalid JSON, and the backend failure had no submitted envelope. All four final envelopes were valid and accepted, but none matched the public-observation solutions. Shared final correctness was 0/2; raw final correctness was 0/2. No model-authored relation claim entered shared state, and no corrected candidate was retained. Therefore this run is not a successful test of deriving new answers from shared relation claims: that intervention was substantially lost through proposal attrition.

The fallback reviews were generated without an accepted peer claim and referred to the immutable problem itself. Their structural acceptance is not evidence of successful peer error detection or useful mathematical correction. Structural acceptance and final-answer truth remain separate measurements.

## Resource and integrity evidence

Usage was supplied for eleven HTTP 200 responses: 10,617 reported prompt tokens, 3,095 completion tokens, 13,712 total tokens. The failed call supplied no usage, so these totals are partial. The two u proposals used exactly the requested 512-token cap, while the provider reported finish_reason `stop`; this does not establish that their outputs were complete. Other malformed outputs also reported `stop`. Reported review decoding speeds were around eight tokens per second. Request pairs overlapped at the client; backend timings are consistent with serialization, and physical parallel inference is not established.

The integrated suite passed 33 tests before this freeze. All ten frozen source/test/document snapshots and current v2 source hashes matched after execution; both state stores replay exactly. No stale fork was induced. Post-run health still reported qwen3.5-9b-FLM with context 70,728. Exact bodies, content, receipts, usage and timing are in [local-qwen2](runs/local-qwen2); see [independent audit](LOCAL_RESULTS_AUDIT.md), [resource summary](runs/local-qwen2/RESOURCE_SUMMARY.json) and [verification](runs/local-qwen2/VERIFICATION.json).

## What this means for the user's goal

Comparative advantage is unnecessary; useful cooperative success within a practical budget is the intended criterion. This configuration has not met it on these cases. The provider-neutral engine can execute local participants and preserve their structured contributions, but envelope generation and arithmetic must become reliable before a harder-task or general 50% success claim is meaningful. The earlier native pilot remains separate: its shared and raw integrators were both correct 2/2, with useful cross-review. Neither run proves a universal external representation of reasoning or native capacity extension.

The next interface change should move deterministic transport fields—identity, routing, message IDs and pinned read references—into the runner, while asking the model for a compact purpose-specific payload. That tests whether a small model can reliably contribute useful state without spending its output budget recreating the transport envelope. Use a separately frozen control against full-envelope generation, measure payload/schema and mathematical accuracy independently, and keep the store structurally validating rather than solving the problem. Larger-task cooperative acceptance should be benchmarked only after this interface calibration.

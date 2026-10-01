# Lab 4 pilot preregistration

## Question and scope

This pilot asks whether a small structured shared-state protocol can carry useful, auditable intermediate claims between participants who all have access to the complete problem. It also checks whether the implementation's access, concurrency, replay, and retraction mechanics behave as specified. The work is exploratory and descriptive: two deterministic cases cannot establish general effectiveness, statistical reliability, or a general hard-problem capability.

## Hypotheses and observations

The operational expectation is that both relation proposals can commit from a common immutable problem snapshot, peer reviewers can inspect and challenge a peer claim using the full problem, and a fresh shared-state integrator can use the committed claim/review state. The raw-only integrator is a control for the presence of shared intermediate state, while retaining all complete task facts and instructions. The pilot will record whether the state mechanisms execute as designed, what each participant submits, whether reviewers catch or preserve errors, and how each final answer scores against the offline evaluator.

These are descriptive observations, not confirmatory hypotheses. No significance test, pooled estimate, or extrapolation across tasks/models will be reported. The two seeds are named cases, not a representative sample.

## Cases and ground truth

Cases use the existing Lab 3 deterministic generator `make_case(seed)` without modifying Lab 3:

| Seed | Domain | Public to every participant | Hidden until offline scoring |
|---|---|---|---|
| 4201 | Invertible affine map over integers mod 11 | Three labeled non-collinear observations, modulus, declared affine family, observed target image `(u,v)`, complete task/output instructions | True coefficient triples and target answer `(x,y)` |
| 4202 | Same | Same public fields as seed 4201, generated from seed 4202 | Same hidden fields |

An independent Lab 4 adapter turns each generated case into an immutable problem packet at revision 1. It supplies the entire public packet to each participant, including both final integrators. The final shared-state condition additionally receives the structured workspace, including original claims, all reviewer assessments, and all corrected candidate values. The store does not select a winning candidate. The raw-only condition does not receive that workspace; it does not lose any original problem fact. Hidden coefficients, target answer, and evaluator results are never included in a participant prompt or submission receipt.

## Participants, access, and fixed call budget

Use fresh sessions with the native Luna-low route for every call unless the frozen run manifest explicitly records an available route change before any subject call. The first pilot is not evidence about a local model; local execution is outside scope until a specific runtime is configured and recorded. Keep provider/model/effort, prompt hash, raw response bytes, timestamps, and route metadata for each call.

For each seed, make exactly six calls:

1. `u-proposer` and `v-proposer` run in parallel. Each sees the complete public problem at the same immutable snapshot. They independently propose one relation claim, with different claim IDs (`u-relation`, `v-relation`).
2. `u-reviewer` and `v-reviewer` run in parallel after both proposal outputs have been saved. Each sees the complete public problem and the peer claim assigned to it; neither receives the other review. A reviewer emits one structured `CHALLENGE` or `REPORT_EVIDENCE`, and may include an uncommitted corrected candidate in that same envelope. No follow-up call is allowed.
3. Two fresh final integrators run after review messages are fixed. `shared-integrator` sees the complete public problem plus the committed shared claim/review projection. `raw-integrator` sees the same complete public problem and answer instructions without intermediate shared state. They do not see one another's output and each emits one `CONCLUDE`.

This is twelve model calls in total across both seeds. The budget caps calls, not tokens, latency, or compute; conditions are not token- or compute-matched. Parallel phases are recorded as parallel dispatch groups. Calls that fail or return malformed output still consume the budget and are retained; no repair, retry, replacement, semantic feedback, or oracle patch is allowed. If a proposal is rejected structurally, continue the reviewer/final schedule when the frozen prompts remain meaningful, record attrition, and do not fabricate accepted state.

## Frozen interface and access policy

Before the first subject call, freeze and hash the problem packets, prompt templates, model route, participant IDs, access rules, envelope schema, read references, call schedule, rejection policy, and evaluation procedure in a run manifest. Proposers share the same problem ref, and their writes use distinct claim IDs. Reviewers receive only their assigned peer claim plus the same complete problem packet. The shared integrator reads the claim and review references available at the fixed final snapshot. The raw integrator reads the full raw packet only. Reads are directed by per-participant prompt construction/mailbox access; agents cannot inspect the database or unrelated raw outputs directly.

No participant sees hidden coefficients, target answer (x,y), or evaluator correctness feedback. Public target (u,v) and structured peer claims/reviews are explicitly available under the registered access rules. The engine's receipts may report only structural acceptance/rejection and stable codes, never semantic hints. Save exact prompt bytes and response bytes before parsing. Record rejections and failures without mutation or automatic retries.

## Outcomes and scoring

### Mechanical outcomes

Record for each message: parse/schema outcome, receipt code, accepted event sequence, read snapshot, claim revision/status, recipient scope, and raw/prompt hashes. Verify through the run records that (a) distinct proposals from the common problem snapshot can both commit, (b) reviewers are directed to the specified claim/problem context, (c) the final state can be replayed deterministically, and (d) a tested retraction propagates invalidation without deleting history. The engine unit tests cover concurrency and retraction mechanics independently of model content; model pilot outputs are not a substitute for those tests.

### Domain outcomes

Only after all prompts, outputs, and receipts are saved, score the final outputs and claims offline using an independent enumerative evaluator over all 121 `(x,y)` pairs modulo 11. Report, per seed and per condition, exact relation coefficients when recoverable, final answer validity and true target correctness, review/challenge disposition, and whether a final output is structurally parseable. Report the two cases individually. Do not show evaluator results to participants or feed them back into the event log.

### Interpretation limits

Shared-state and raw-only integrators receive equal complete raw task facts and the same instructions, but the shared-state integrator receives additional derived claim/review state. The comparison is not information- or token-matched and can only describe this intervention in these two generated cases under the recorded route. A correct final result does not by itself show that the protocol caused correctness; a wrong result does not show that the representation is inherently inadequate. No claim will be made that generic claim envelopes encode all useful reasoning, that local models achieved a result, or that the method scales to harder or real-world problems.

## Deviations and stopping

Any change after freeze to prompts, fields, read references, route, or access is a deviation; retain the original artifacts and identify the change in the run record. If the protocol cannot produce the frozen prompts or receipts, stop that case without semantic repair and report the structural failure. Do not expand the call ceiling, add seeds, or add participants within this pilot. Any follow-on study requires its own frozen plan.

## Pre-live user refinement
Potential forks replace discard-on-stale for coherent historical PROPOSE envelopes; main state remains unchanged. Independent protocol tests cover fork retention/export and explicit evidence-backed archival; the twelve native calls and two case seeds remain unchanged. Cross-review mapping is u-reviewer inspecting v-relation and v-reviewer inspecting u-relation. No automatic selection of candidate corrections or forks occurs. PROTOCOL.md defines the final structural contract.

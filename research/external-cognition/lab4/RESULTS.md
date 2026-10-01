# Lab 4: structured parallel reasoning pilot

Completed 2026-10-01. Twelve fresh gpt-6-luna low participants, two generated affine-map cases, six calls per case. Parallel proposers, parallel cross-reviewers, then fresh shared-state and raw-facts integrators. All twelve envelopes were structurally accepted; no failed calls, repairs, retries, or evaluator feedback. The source and initial inputs were frozen before dispatch; later peer prompts were saved and hashed before dispatch.

| Case | Original proposals | Cross-review | Shared final | Raw final |
|---|---|---|---|---|
| 4201 | u correct; v incorrect | Incorrect v challenged; correct u supported; no replacement candidate | Correct (2,10) | Correct (2,10) |
| 4202 | u correct; v incorrect | Incorrect v challenged with correct candidate (10,5,8); correct u supported | Correct (8,4) | Correct (8,4) |

Original relation proposals were correct 2/4. Reviewers correctly challenged both incorrect proposals and supported both correct proposals. The one supplied replacement candidate matched all public observations and the generated world. Both final conditions were correct 2/2. This is a descriptive result for two cases, not evidence of an accuracy advantage: the raw control also solved both cases. Participants had complete raw facts, and the shared condition additionally received derived state; tokens and compute were not matched.

The final answers differed from what the original proposal pairs imply. Those pairs yield (6,1) and (1,6), respectively, while the shared integrators returned the correct targets. Thus the shared integrators did not blindly solve the original submitted pair. The available output does not establish whether they used the review/candidate, recomputed from raw facts, or combined those routes. A follow-on causal intervention must distinguish these possibilities.

## What the implementation establishes

The provider-neutral standard-library protocol carries immutable problem resources, versioned model-authored claims, provenance, dependencies, directed peer messages, candidates and conclusions. Purpose-specific envelopes cover PROPOSE, CHALLENGE, REQUEST_EVIDENCE, REPORT_EVIDENCE, RETRACT and CONCLUDE. Parallel disjoint proposals commit from the same problem snapshot. The store validates structure and references; domain mathematics is evaluated offline. Deterministic encoding and replay apply to recorded data and a fixed event sequence, not to model inference or parallel arrival order.

Changed-premise proposals with coherent historical read references are retained as potential forks, including historical and proposed snapshots. They do not overwrite current claims. Archival requires an explicit designated-admin decision, a workability attestation, and accepted outcome evidence with still-current pinned premises. Archived history remains available. No native stale fork was induced in this pilot; retention/export/archival and dependency invalidation are covered by independent mechanical tests. Automatic fork merging and semantic proof of workability remain outside the prototype.

## Evidence and limits

The integrated pre-live suite passed 23 tests. All 16 frozen files and their snapshots retained their hashes; both six-event stores replay to their current projections. Exact prompts, raw outputs, receipts, route metadata and offline scoring are in [campaign1](runs/campaign1). See [independent audit](RESULTS_AUDIT.md), [preregistration](PREREGISTRATION.md), [protocol](PROTOCOL.md), and [verification](runs/campaign1/VERIFICATION.json).

One participant initially created an empty staging output file and then wrote its final envelope before collection; this was recorded in dispatches.json. It made one model call and received no feedback. Assigned-file-only access was procedural rather than sandbox enforced. Model token/sampler statistics were unavailable. Native Luna is not a tested local backend, these are small toy problems, and no native capacity extension, universal reasoning representation, efficiency gain or harder-problem capability has been demonstrated.

## User's success criterion: cooperative feasibility

Accuracy superiority is not required. The intended outcome is a repeatable engine in which smaller/local participants cooperate through external state and structured communication to achieve useful solutions. Matching a reference solver, or reaching a useful partial success rate such as 50% on a specified benchmark, can satisfy that goal if the resource envelope and operational reliability are useful. The benchmark, reference, success threshold, resource limits and treatment of failures must be fixed in advance. This pilot establishes a working coordination mechanism and correct collective answers on two small cases, but its native route and easy tasks do not establish that local/harder-task goal. Comparisons remain diagnostic measurements rather than a requirement to outperform a raw control.

## Next discriminating experiment

Use a configured small local model and a preregistered larger problem family with independently measured single-agent performance and a named stronger reference solver. Set a useful cooperative-success threshold before running (potentially 50% of benchmark cases, or 50% of reference successes; these are different criteria), plus resource and reliability limits. Hold model, raw facts, output budget and total compute constant across small-model independent parallel attempts, unstructured communication, structured shared state, and structured state with communication removed. Measure the stronger reference separately with its actual resource cost. Include delayed conflicting writes and changed premises. Randomize whether coherent potential forks are retained for bounded exploration or archived after independently verified main-branch success. Score final correctness, error repair, useful fork recoveries, invalid transitions and resource cost. Hide the evaluator until completion. Primary acceptance is useful cooperative performance within the declared budget; controls diagnose the contributions of communication, representation and fork retention without requiring superiority.

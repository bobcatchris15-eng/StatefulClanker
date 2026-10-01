# Cycle 3: agent-authored state and fresh reasoning

All21 registered semantic responses are preserved and independently audited. Three agents inferred exact intermediate relationships without seeing the downstream target. Fresh agents then used, lacked, or received altered versions of those relationships. The store accepted structure only; no semantic feedback or answer repair was supplied.

| Outcome | Observed cases |
|---|---|
| Initial agent-authored relationships exact |3/3|
| Intact-state consumer exact |1/3|
| Raw-evidence control exact |1/3; other two abstained|
| Altered-state consumer follows altered relationship |2/3; original-world answer0/3|
| Missing-state consumer reports underdetermined |3/3|
| Revision replaces the intended relationship correctly |2/3|
| Revised consumer follows submitted relationship |2/3|
| Revised consumer matches intended revised world |1/3|

Seed3102 demonstrates a correct intermediate relationship followed by a new correct inference; its altered control follows the predicted counterfactual relationship. Seed3103 correctly revises the relationship and reaches the new intended answer. Seed3101 also illustrates coherent use of wrong state: its revised consumer follows an incorrectly revised relationship. Correct initial relationships did not ensure correct downstream reasoning.

These cases demonstrate bounded fresh reasoning from model-authored external state and sensitivity to that state. They do not establish reliable composition, superiority to raw evidence, resource efficiency, local-model performance, or a universal reasoning representation. The omission control removes necessary information and is not a native-capacity test. Invalidation was explicitly requested.

The original frozen EVALUATION.json has a revision scoring defect: one field compares with the original-world answer. It is preserved unchanged. RESULTS_AUDIT.md and RESULTS_AUDIT_DATA.json independently recompute the intended revised-world outcome and expose the defect; any corrected runtime/evaluation is explicitly post-campaign.

Quota interruption produced23 dispatch records for21 responses: two no-output attempts were resumed in fresh contexts; one agent's already-written response was salvaged without rerun. No extra semantic trials, retries, or oracle states were inserted. All42 prompt/response hashes and10 frozen snapshots verified. Native gpt-6-luna low substitutes for the unavailable exact Luna Light route. Procedural file isolation and missing token/sampling/self-report information limit resource and compliance claims. Full evidence is in runs/campaign1_frozen.

Post-campaign working evaluator v1.1 passes11 tests and adds consumer_intended_revised_world_correct. Its separate EVALUATION_v1_1.json agrees with the independent intended-world scores (only seed3103 succeeds); legacy original-world field remains documented. Frozen original source and evaluation unchanged.

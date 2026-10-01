# Independent cycle 3 live audit

Audit date: 2026-10-01. This review reads the frozen run and recomputes outputs independently. It made no subject calls and did not modify the frozen runtime, raw responses, evaluation, freeze snapshots, or dispatch log. Detailed enumerations and provenance checks are in `RESULTS_AUDIT_DATA.json`.

## Record integrity and dispatch accounting

The frozen run contains all 21 planned raw outputs at `inbox/01.raw` through `inbox/21.raw`, each represented in the campaign and matching its per-case response receipt. There are 23 dispatch records and 23 distinct fresh agent IDs: 20 ordinary successful dispatches, one position-9 quota interruption after its raw output was saved and structurally submitted, and two position-10/11 quota attempts with no output. Positions 10 and 11 were resumed using fresh agents and the same frozen prompts. Position 9 has no retry record. Thus all 21 planned semantic slots have one preserved output; the two extra records are no-output infrastructure attempts.

All 42 prompt/response hashes in `hashes.json` match files. Dispatch prompt/response hashes match their referenced files. All 10 snapshots in `FREEZE.json` match their listed digests and `FREEZE_VERIFICATION.json` reports each match. All 21 returned JSON objects are present in both the inbox and response receipt, and are structurally accepted. No semantic evaluation was fed back to a subject.

The recorded route is `gpt-6-luna` at low effort, fresh contexts, fork none. The exact Luna Light route was unavailable; this is the declared Luna-low substitute. The controls are not token/compute matched. Subject self-reports and runtime token statistics are incomplete, and the assigned-file-only isolation was procedural rather than a hard sandbox.

## Independent recomputation

I regenerated each fixed world with the frozen generator and independently enumerated all 121 coordinate pairs for every supplied relation/target. The producer recovered the exact hidden relation in all three cases. Results below compare each response both to the relation actually presented and, where relevant, the original or revised intended answer.

| Seed | Original target `(x,y)` | Intact | Altered (+1): answer / candidate | Raw observations | Omitted | Revision producer | Revised consumer / intended revised answer |
|---|---:|---|---|---|---|---|---|
| 3101 | (3,9) | (7,4), wrong; candidate (3,9) | (2,4), wrong; candidate (6,2) | (3,9), correct | Underdetermined | Wrong `u`; `v` preserved; invalidation declared | (2,4) follows submitted wrong map; intended map answer (9,6) |
| 3102 | (8,7) | (8,7), correct; candidate (8,7) | (5,6), correct under altered map; wrong for original | Underdetermined | Underdetermined | Correct `u+2`; `v` preserved; invalidation declared | (9,8), wrong; intended map answer (2,5) |
| 3103 | (5,4) | (8,2), wrong; candidate (5,4) | (10,7), correct under altered map; wrong for original | Underdetermined | Underdetermined | Correct `u+2`; `v` preserved; invalidation declared | (4,10), correct under submitted and intended revised maps |

Across the three fixed cases: producer relations were exact 3/3; intact answers recovered the original target 1/3; raw-evidence answers recovered it 1/3 (the other two abstained despite a unique solution); altered answers matched the altered relation 2/3 and the original answer 0/3; all omitted arms abstained; revisions replaced `u` as intended in 2/3, preserved `v` and declared invalidation in 3/3; revised consumers matched the submitted map in 2/3 and the intended revised answer in 1/3. These are descriptive counts for these seeds only.

## Evaluation-file issue

`EVALUATION.json` contains a misleading revision field, `consumer_true_world_correct`. The frozen evaluator computes it by comparing the revised consumer answer with the **original** target coordinates. The preregistered revision outcome is agreement with the answer implied by the revised relation, using the **same original target image `(u,v)`**. The field is therefore stale/misnamed for revision and should not be reported as revised correctness.

Case 3103 makes the defect visible: the saved response `(4,10)` is the unique solution of both the submitted revision and the intended `u+2`, `v`-preserved revision under original target image `(5,3)`, while the original answer is `(5,4)`. `EVALUATION.json` correctly reports conditional agreement `true` but incorrectly suggests a failure with `consumer_true_world_correct:false`. Case 3101's response follows its wrong submitted revision `(2,4)` but not the intended revised map's `(9,6)`. Case 3102 has the intended revision `(2,5)` but the consumer answered `(9,8)`. The independent answer sets in `RESULTS_AUDIT_DATA.json` are the audit source for these distinctions. Do not edit the saved evaluation; report this caveat alongside it.

## Scope limits

This is a three-case mechanism demonstration with a single native Luna-low route. It does not establish population performance, efficiency, superiority to raw evidence, robust state maintenance, autonomous dependency discovery, or local-model capability. Revision explicitly instructed invalidation. A correct answer under a wrong stored revision (case 3101) is evidence of following that supplied state, not evidence that the state was correct.

# Campaign 1 independent results audit

Date: 2026-10-01. Scope: independently score the preserved live prompts and raw outputs for the frozen campaign using the frozen task instance and exhaustive enumeration. This report does not change or replace the preregistration, raw outputs, receipts, or historical summary files.

## Frozen inputs and scoring

The campaign's `frozen_source/core.py` and `frozen_source/lab.py` copies match the source hashes in `FREEZE.json`; the six frozen calibration prompt files and key file also match their registered hashes. The current workspace copies of `lab.py` and `test_lab.py` have since changed, so all campaign artifact checks here use the frozen source, saved prompts, and raw data. Each of the four full-task repeat prompts is byte-identical to the frozen `n4_seed1101` prompt. The saved subject prompts state the legality test `(b+x+y) mod 2 == stage.parity` separately from the outgoing boundary `y` and expose no scorer answer or expected frontier.

I independently enumerated all assignments for each calibration answer and every attempted chain prefix. Receipt SHA-256 values and raw byte lengths match the corresponding preserved response files for both chains. The checker receipts and the saved raw frontiers agree with independent scoring.

## Observed answers

| Call group | Independently exact | Details |
|---|---:|---|
| Complete-task calibration | 5/6 | Both two-stage and both four-stage answers were exact; one of the two eight-stage answers was wrong. |
| Four-stage full-task attempts on seed 1101 | 3/5 | The registered calibration attempt plus repeats 2–5 produced three exact answers. Among the four additional repeats alone, 2/4 were exact. |
| Vector chain, before input update | 4/5 proposals | Stage 0 was exact; the first stage-1 proposal was parity-invalid; its permitted repair and stages 2–3 were exact. Four transitions were committed and the initial final optimum was cost 11, bits `10000001`. |
| Records chain | 2/4 proposals | Stages 0–1 were exact; the stage-2 proposal and its one repair had incorrect cumulative costs. The chain stopped at stage 2 with two committed transitions. |
| Vector cost-update suffix | 3/3 proposals | After stage 1 `wx` changed from 3 to 1, all three recomputed suffix frontiers were exact; the updated full optimum was cost 11, bits `01100001`. |

The incorrect calibration answer was `n8_seed1101`: cost 25, bits `1000000100010101`. The reported cost matches the bits' weighted sum, but the final transition is infeasible: incoming boundary 1 with `x=0,y=1` has parity 0 while that stage requires parity 1. Independent enumeration returns cost 26, bits `1000000100010111`.

The rejected vector stage-1 receipt reports version 1 and a 219-byte store, matching the preceding accepted stage-0 receipt; the accepted repair also uses base version 1 and advances to version 2. In records, both stage-2 attempts report version 2 and a 464-byte store, matching the preceding accepted stage-1 state. These receipts support that rejection did not advance the logical state. The campaign did not record a before/after state hash at each rejection, so byte-for-byte equality at those historical instants cannot be independently reconstructed from the saved run.

## Input update

The saved initial vector snapshot has version 4 and all four history frontiers match independent enumeration for the original problem. The update preserves stage 0's exact frontier, changes the problem hash, and resets the computed suffix. Each of `update-s1`, `update-s2`, and `update-s3` has a checked accepted receipt with versions 5→6, 6→7, and 7→8 respectively. Their raw frontiers match exhaustive enumeration under the updated problem. The final updated frontier and optimum are correct. This validates prefix reuse and suffix recomputation for this task instance.

## Summary-counter discrepancy

The raw chronology contains exactly one repair after a rejection: vector `s1` was rejected and `s1-repair` was accepted; records `s2` was rejected and `s2-repair` was rejected. The saved initial vector summary reports zero repairs. The records summary reports one, which is numerically right but its filename-sorted counter can count the original attempt as the repeated attempt because `s2-repair.json` sorts before `s2.json`.

I ran the frozen CLI summary on the completed vector directory without saving over either historical summary. It reproduces `vector_updated_summary.json` exactly and reports one repair. That number is still misattributed: the lexically later `update-s1` receipt has the same stage index as the initial rejection but a new problem/version, so the stage-only algorithm counts it as the repair. Therefore the correct campaign count is one repair, derived from the saved prompts, receipts, base versions, and chronological dispatch log; neither vector summary counter establishes it. Preserve both saved summaries as historical artifacts. A corrected post-campaign counter should associate attempts by stage and base version/problem version and use dispatch order.

## Deviations and interpretation

The repair prompts use conditional semantic feedback built from the frozen checker issue class and include the rejected proposal verbatim. The preregistration permitted identifying the violated rule and prohibited revealing a corrected frontier; neither repair prompt exposed the correct frontier, a correct cost, or the oracle answer. The exact wrapper text was not itself frozen verbatim, so record it as a minor wording deviation. The records repair remained wrong after feedback.

The four additional full-task attempts were fresh calls to the exact same prompt as the registered four-stage calibration item. The combined five outcomes are descriptively useful, but matching call counts does not match total inference work, tokens, or sampling resources. Token and sampler telemetry are unavailable. The vector and records chains also change visible representation and backing codec together, so their outcomes do not isolate either factor. The frontier carries answer-bearing partial computation; success does not establish that the subject needed external state or that any capacity threshold was crossed.

The deterministic replay results in `REPLAY_REPORT.md` are implementation replays of these preserved outputs, not additional subjects or live storage-effect controls. For the same decoded state, JSON storage is 691 bytes and packed storage is 266 bytes; that is a codec size difference, not a cognition result. The JSON replay reused the accepted stage-1 repair output while presenting the ordinary stage-1 prompt, so its subject context differs from the original repair call and it cannot be treated as a faithful replay of that live interaction. The unchecked replay's acceptance of the original invalid stage-1 proposal confirms only the unchecked-arm mechanics on this preserved response; it did not execute later subject work.

The campaign used 22 live calls: six calibration calls, four additional full-task repeats, five vector-chain calls including the stage-1 repair, four records-chain calls including the stage-2 repair, and three updated-suffix calls. These results remain descriptive observations from one synthetic task family and one model route, not a population estimate, general capacity measurement, or evidence for a learned latent state.

## Post-campaign runtime v1.1 review

This review is separate from the frozen campaign assessment. Runtime v1.1 adds a writer-locked `submission_order` to new receipts and counts retries by `(stage, base_version)`, so the later updated stage-1 transition does not count as a retry of the earlier rejected transition. Its timeline test uses filenames ordered opposite to submission order, then changes the input and submits the same stage at a new base version. A legacy-receipt test exercises the mtime fallback and confirms the old receipt bytes are left untouched. The fallback is explicitly best-effort; it cannot recover chronology if filesystem timestamps were altered or tied.

The rerun summaries are preserved separately as `vector_summary_runtime_v1_1.json` and `records_summary_runtime_v1_1.json`. Each reports one repair and labels its basis `legacy_mtime_ns_fallback` with 8 and 4 legacy receipts, respectively. I independently checked receipt mtimes: each arm's timestamps are strictly increasing in the raw dispatch order, and the one repair is supported by the corresponding rejection/repair pair. The original `vector_initial_summary.json`, `records_initial_summary.json`, and `vector_updated_summary.json` remain unchanged; their stage-only filename-order counters are the historical discrepancies described above.

The custom calibration axes validate nonempty integer lists, unique sizes and seeds, positive sizes, and preserve the original defaults. Tests compare generated tasks, keys, and prompt schema to the core generator/oracle and exercise CLI parsing. I independently ran the four targeted runtime tests for retry ordering, custom axes, legacy receipt preservation, and CLI operation: all four passed. The runtime receipt reports 31 total tests, 30 passed and one platform skip. I found no material defect in these post-campaign changes. They were not used to create or score campaign 1 subject outputs, and no subjects were launched for this maintenance update.

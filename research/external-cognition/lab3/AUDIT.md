# Independent audit

## Status

The reviewed engine and protocol are clear for pre-live freeze as of 2026-10-01. This review created no subject outputs. The root should freeze/hash the final files after the last engine change before starting subjects.

## Review findings

The first implementation had three material gaps: the omitted condition supplied a fake zero relation, the call schedule could place dependent calls before their prerequisites, and conditional evaluator scores compared against the original-world answer. A temporary end-to-end CLI run also found that revised prompt generation attempted to rewrite already frozen initial prompts. I reported each issue to the engine/root. The final source now omits the relation, orders each case's producer → initial consumers → revision producer → revised consumer, returns only the revised consumer prompt after revision, and compares consumer answers to enumerated solutions under the relation actually shown. The evaluator separately reports true-world accuracy and scores concrete coordinate answers in the omitted condition against the true answer.

The reviewed prompts define the affine family explicitly as `u=(a*x+b*y+c) mod 11` and `v=(d*x+e*y+f) mod 11`. Initial producer text contains observations only; generated campaign metadata has no target. Consumer arms have no producer transcript in prompt construction. Revision producer text has prior state and the intact consumer response, but no target or evaluator result. Revision prompt explicitly asks to preserve `v` and invalidate the cached answer; store acceptance still does not check mathematical truth or v preservation. These are consistent with the declared protocol and its limitations.

The three fixed worlds are invertible. Independently enumerating all coordinate pairs confirms the original, +1 altered, and +2 revised target solutions differ in all three seeds:

| Seed | Original | +1 altered | +2 revised |
|---|---:|---:|---:|
| 3101 | (3, 9) | (6, 2) | (9, 6) |
| 3102 | (8, 7) | (5, 6) | (2, 5) |
| 3103 | (5, 4) | (10, 7) | (4, 10) |

## Verification

- `python -m unittest discover -s research/external-cognition/lab3/tests -v`: all 9 tests passed, including omitted-answer scoring, altered/revision conditional scoring, omitted relation, schedule dependencies, revised prompt emission, and structural acceptance of a wrong relation.
- Temporary CLI integration exercised prepare, target-free producer prompt, producer submission, four original consumer prompts, intact/altered submissions, revision prompt/submission, revised consumer prompt/submission, offline evaluation, raw response receipts, prompt/response hashes, and dependency-valid schedule. It confirmed the altered and revised answers can agree with their presented relations while differing from the original-world answer. The fixture was ephemeral and was not a subject run.
- The implementation keeps evaluation separate from submit/prompt construction. The evaluator is offline-only; do not run it until the relevant raw subject outputs have been saved, as specified by the preregistration.

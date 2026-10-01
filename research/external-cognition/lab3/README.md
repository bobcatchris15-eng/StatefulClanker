# Lab 3 engine

This standard-library-only harness supports the preregistered three-case mod-11 affine relation study. It stores deterministic synthetic worlds, prompts, exact response bytes, structural state, and an offline enumerative evaluator. It does not call a model or score responses during submission.

Run from this directory:

```powershell
python experiment.py prepare --out-dir DIR
python experiment.py producer-prompt --campaign DIR\campaign.json --case 3101
```

`prepare --out-dir DIR` creates `DIR/campaign.json` with seeds 3101, 3102, and 3103, modulus 11, a deterministically shuffled 21-row schedule, and schedule SHA-256. The schedule shuffles case blocks and the four ready consumer arms while preserving producer → four controls → revision producer → revised consumer dependencies. Each synthetic world has three labeled noncollinear observations, an invertible affine map pair, and a hidden target. Producer prompts contain observations and family instructions only, never coefficients or target.

## Commands and persisted schema

`submit-producer --campaign FILE --case SEED --response PATH_OR_JSON` expects exactly `{"base_version":0,"u":[a,b,c],"v":[d,e,f]}`. Both triples must be integer residues `[0,10]`. Validation checks object keys, types, ranges, case, and base version. It accepts singular or mathematically wrong relations. Malformed or stale submissions are rejected without campaign state mutation; do not repair/retry. Omit dependent trials and report attrition.

Before JSON parsing, exact submitted bytes are saved beside the campaign as `responses/SEED/producer.raw`, `consumer-ARM.raw`, or `revision-producer.raw`. Existing receipts cannot be overwritten, including for malformed outputs. Prompt files are deterministic, refuse changed overwrites, and are SHA-256 recorded alongside responses in `hashes.json`.

`consumer-prompts --campaign FILE --case SEED` writes `intact`, `omitted`, `altered`, and `raw` prompts. After an accepted revision it writes only `revised`, preserving the original prompts. All consumer arms use the same instruction and response schema, without arm labels: `{"status":"solved","x":INTEGER,"y":INTEGER}` or `{"status":"underdetermined"}`. Coordinates are residues 0 through 10. Contexts are fresh and receive no producer transcript. Intact contains submitted relation; omitted has no relation; altered adds 1 to submitted u intercept modulo 11; raw has original observations. Revised receives revised relation and original target but no cached answer.

`submit-consumer --campaign FILE --case SEED --arm ARM --response PATH_OR_JSON` saves one response per arm. A well-shaped intact response is cached verbatim for the revision prompt even if wrong. Invalid or absent intact output leaves cache null.

`revision-prompt --campaign FILE --case SEED` includes prior relation, actual cached intact answer (or null), and authoritative observations after changing only u intercept by +2 modulo 11. It instructs update u, preserve v, and invalidate answer, without exposing target. `submit-revision` expects exactly `{"base_version":1,"u":[a,b,c],"v":[d,e,f],"invalidate":["answer"]}`. Structural acceptance does not check coefficient correctness or v preservation; it advances version to 2 and clears cached answer.

`summary --campaign FILE` reports schedule hash, planned calls, accepted states, saved arms, and producer attrition. `evaluate --campaign FILE` performs offline-only scoring: producer coefficient truth; consumer true-world answers; altered answers under both true and altered relations; omission classification; revision u correctness, v preservation, and invalidation; and revised-consumer outcomes. Its evaluator enumerates all 121 `(x,y)` pairs. No submit path calls the evaluator, and evaluator results never appear in subject prompts.

Run from the repository root with `python -m unittest discover -s research/external-cognition/lab3/tests -v`.

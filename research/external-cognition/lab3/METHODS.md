# Lab 3 methods

## Protocol

The engine generates three reproducible mod-11 affine worlds from seeds 3101, 3102, and 3103. Each hidden map is invertible and has two coordinate equations. Three noncollinear observations identify the affine relation. The target is generated separately and withheld from the producer. The producer's response is stored as opaque versioned state after shape and reference checks only. Mathematical evaluation happens offline after all relevant raw outputs are saved.

For each shape-valid producer output, run four fresh downstream calls in a deterministic shuffled order: (1) intact state, (2) relation omitted, (3) u intercept changed by +1 mod 11, and (4) raw observations. The downstream call receives the same target and no producer transcript. Every consumer arm offers identical neutral status choices. Then run a revision producer using replacement u observations, prior state, and the intact consumer's raw response, even if it is wrong. The initial producer is target-free; the revision producer receives neither target nor evaluator feedback. It is explicitly instructed to supersede u, retain v, and invalidate the cached answer. A fresh revision consumer receives the revised state and original target. The revised u intercept is shifted by +2 mod 11 so its expected answer differs from the original. The prompts make invalidation explicit; the protocol tests following that instruction rather than discovery of dependency relationships. Shape-valid but mathematically wrong producer state still proceeds through the full call plan.

## Scoring rules

The independent evaluator checks producer coefficients against the generated relation and enumerates coordinate candidates implied by each consumer's supplied relation. A structurally accepted state may be wrong; store acceptance is never treated as semantic validation. Report producer relation correctness, intact target correctness, raw-evidence target correctness, and each control's outcome per case. For altered state, give two scores: against the original generated world and against the altered relation's implied answer. This distinguishes a coherent inference from a correct-world answer.

The omitted condition contains no relation. Treat a clear abstention or explicit “not determined” response as an undetermined outcome, not an error. If the response nevertheless supplies coordinates, score those against the true answer and identify the guess as such. For revision, compare the new answer against the target coordinates implied by the revised relation; separately check preservation of v, replacement of u, and explicit invalidation of the cached result.

## Attrition and reporting

Malformed producer state is preserved as rejected and is never semantically repaired or retried. All downstream and revision calls for that case are omitted. A malformed revision patch is preserved and its revision consumer is omitted. Malformed downstream responses remain in the record as attrition. Report the call plan (21), completed calls, shape-valid cases, and each omission reason. Do not expose offline scores to live calls or append replacement calls after observing results.

Summarize descriptively by case and arm. Do not infer population rates from three fixed seeds. Token or input-size records may contextualize the representation, but the raw arm is not resource matched. The experiment supports only bounded claims about whether the saved state or supplied evidence enabled fresh inference in these specific prompted cases; it does not show that state improves inference efficiency, extends native capacity, or can maintain dependencies without explicit revision instructions.

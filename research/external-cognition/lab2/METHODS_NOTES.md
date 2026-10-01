# Methods notes and adversarial interpretation

These notes accompany the preregistration for Lab 2. They are a record of design limits and interpretation safeguards, not a replacement for the frozen protocol.

## What “external cognition” means in this campaign

The experiment manipulates a task-specific frontier: a compact summary of the best partial witnesses for the two possible boundary values. That artifact is useful intermediate computation. It is neither a neutral memory buffer nor an unprocessed copy of facts. Because it carries prior search results, any advantage over a full-task response could arise from decomposition, serial extra reasoning, answer-bearing state, prompting, or verification. The proposed contrast does not isolate storage from computation.

An opaque packed store can be a legitimate engineering design when the software, rather than the model, owns serialization and decoding. The model still receives numeric local observations in a familiar schema. Thus, the human need not inspect the persistent bytes, but this does not make those bytes a learned semantic/latent state. If a later study claims a benefit from opaque state itself, it must show that the subject interacts with the opaque payload (or specify which component reads it) and compare that mechanism with an otherwise identical decoded-state arm. A reversible codec round-trip is a storage property, not evidence of reasoning.

Vector versus record rows changes the surface form shown to subjects. Packed versus JSON changes backing representation. If both are changed together, the chain comparison confounds observation format and codec; it cannot identify which caused a difference. Even a codec-only ablation with identical prompts principally tests runtime/store behavior, because the subject never sees the codec. To test subject-visible representation, hold the backing codec fixed and change only exposed representation. Keep these claims distinct in reporting.

## Task difficulty and the calibration trap

The complete task has an obvious small dynamic-programming formulation with only two frontier states per stage. A subject could solve it by hand-like enumeration or infer the recurrence. Correct complete answers at sizes 2, 4, and 8 therefore establish success on those six instances under this route, not a boundary of native capacity. Failure at size 8 would also be ambiguous: arithmetic, instruction following, format error, sampling variation, or task difficulty can cause it. Two seeds per size do not estimate a stable reliability curve. A genuine task-family capacity estimate would require many held-out random instances per size, a predeclared reliability threshold, repeated fresh samples, and enough sizes to locate a transition; this campaign does not do that.

The calibration and chains answer different operational questions. Full-task exact scoring evaluates the final optimum. Chain scoring evaluates each transition against a task-specific exact frontier. A full-task call that succeeds shows the instance was solvable by the subject; a chain that succeeds shows fresh calls can use the supplied partial frontier on this instance. Neither establishes what the subject could or could not internally retain. Do not retrospectively select a “below-capacity” and “above-capacity” size from these outcomes.

## Checker and oracle are measurement instruments, not cognition

The checker can compute the unique expected transition and reject a wrong row. This is valuable for preventing silent state corruption and measuring transition exactness, but it risks making the overall system look more reliable than the proposal process alone. Report proposal accuracy before checker intervention, checker acceptance, committed-state integrity, repair outcomes, and final accuracy separately. Do not count a rejected proposal as a completed correct transition merely because the software preserved the last valid state.

An exact oracle, solver, fixture generator, or auto-correcting path must remain outside subject-visible prompts and responses. If checker diagnostics identify a concrete violated rule, that is semantic feedback and an additional information source. The registered one-repair cap limits but does not remove the added reasoning/call budget; count repair calls separately. Feedback must not disclose the correct row, witness, cost, or solution. A correct final chain after repair supports recovery under that feedback procedure, not unassisted persistence.

It is possible to build an implementation that passes every checker/codec test while every subject answer is wrong. Conversely, a subject may produce a correct final answer while an intermediate frontier is malformed. Therefore keep software correctness, transition exactness, and final-task correctness as separate results. Independent scoring should implement/check the task equations separately from the transition routine where feasible, especially on small cases where exhaustive enumeration is cheap.

## Controls and the remaining compute problem

The six registered full-task calls are calibration observations, not necessarily matched controls. Extra full-task attempts should match the number of chain calls where feasible, use the same seed/problem and answer schema, and be reported alongside every chain. Matching calls alone does not match token budgets, sampling budgets, total inference compute, or information: a chain uses prior proposals, checker feedback, and explicit intermediate work. Exposed tokens, if available, should be reported per prompt, response, and arm. If unavailable, say unavailable; characters and compressed-store bytes cannot stand in for tokens.

The vector/records comparison asks whether two visible schemas carry the frontier differently in this small task. It is not a full-context recomputation control. A stronger later mechanism study would include: (a) same-schema full-task baseline, (b) fact-only incremental condition, (c) frontier handoff, (d) compute/token-matched baseline allowed to rederive the same frontier, and (e) verifier/feedback contrasts. Add randomized held-out instances, multiple samples per condition, seeded stale/corrupt state, and broader task families. Keep resource caps equal and independently measure reliability before labeling instances above a model/task-family capacity estimate. These additions are beyond this first campaign.

## Interpretation template

Use claims of this form:

> On the registered generated instances and route, X of Y complete-task outputs exactly matched the oracle. The vector chain had A of B exact proposed transitions and [did/did not] reach the exact final optimum; the records chain had C of D. The checker rejected E proposals and the permitted repair attempts [did/did not] restore exactness. Call and character counts were …; token/sampler data were unavailable/…. These results demonstrate [only the observed operational behavior].

Avoid claims that the campaign found the model’s native capacity, that opaque packed bytes are latent cognition, that verification proves the subject reasoned correctly, or that a chain/full-task difference is a representation benefit when useful intermediate work and compute differ. A successful suffix update demonstrates the software's dependency invalidation and the subjects' performance on the changed suffix, not a general ability to update persistent beliefs.

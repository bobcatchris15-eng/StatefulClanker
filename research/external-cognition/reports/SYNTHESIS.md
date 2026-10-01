# External cognition research — first-cycle synthesis
Date: 2026-10-01. Status: first cycle complete; all three pilots executed and independently audited. Five research roles and13 fresh subjects.

The hypothesis is plausible as a claim about a coupled model–store–transition system, and has constructive computational precedents. Our first experiments do not establish its stronger empirical version: native representational incapacity was not measured, and structured state did not improve solution accuracy over complete-facts controls. The bounded-view experiment produced an invalid intermediate state that another fresh agent propagated.

## Research organization
Five gpt-6-luna agents at low reasoning effort served as advocate, skeptic, experiment designer, formal analyst and independent methods/source validator. The exact requested Luna Light name is not exposed; this was disclosed before dispatch. Runtime concurrency allowed coordinator plus three workers, so roles and subjects rotated. User-authorized direct debate is recorded in blackboard files. Fresh subjects had fork_turns none, their own output files, and procedural no-browse/no-computation-tool restrictions.

Human source instructions and constraints: HUMAN_HANDOFF.md. Authoritative active contract: CURRENT_WORK.md. Separate role blackboards avoid concurrent file writes. No external messages/posts or production changes were made.

## Hypothesis decomposition
1. Durable external state can preserve information across fresh contexts.
2. That state can encode intermediate computation and support further legal transitions.
3. A model with locally sufficient views can advance a global computation larger than its per-call view.
4. Such a system improves reliable reasoning beyond the particular model's measured native representational capacity under controlled resources.

These are distinct claims. A successful example of 1–3 is not evidence for 4. An imposed view restriction measures the harness condition, not native incapacity. Representations need not reproduce hidden activations: a task-relevant sufficient state may be enough for the next legal step. But summaries that omit distinctions needed by that step cannot guarantee correctness.

## Literature and debate
[Memory-augmented computational universality](https://arxiv.org/abs/2301.04589) gives a specific constructive external-memory system; it establishes computational possibility under its construction, not generic practical reliability. [Scratchpads](https://arxiv.org/abs/2112.00114) and [Tree of Thoughts](https://arxiv.org/abs/2305.10601) supply related mechanisms and empirical precedents, with training/compute/search confounds for this hypothesis. [MemoryAgentBench](https://arxiv.org/abs/2507.05257) distinguishes retrieval, test-time learning, long-range understanding and selective forgetting. [Lost in the Middle](https://arxiv.org/abs/2307.03172) cautions that nominal context size and reliable use are different. Human epistemic-action studies motivate the coupled-system framing but cannot establish LLM behavior.

Advocate argued external state can be actionable intermediate computation. Skeptic demanded independent capacity calibration and answer/compute controls. Experimentalist implemented constrained-selection handoffs. Formal analyst identified locally sufficient views, dependency maintenance, legal transitions and progress as sufficient conditions under task semantics. Independent validator found a vacuous delta, scoring defects, schema ambiguity and a forum-date error. The pre-run defects were fixed before subjects; the remaining post-run schema ambiguity was reported rather than repaired after observing results. Technical forums are retained as anecdotes, not performance evidence.

Detailed sources: sources/advocate.md, sources/skeptic.md, sources/formal_analyst.md and blackboard/experimentalist.md. Review: reports/final_methods_review.md.

## Pilot 1: structured state versus complete-facts re-solving
Two eight-project constraint problems; each arm used a fresh Phase1 and a fresh Phase2 subject (eight subjects total). Phase1 state included source facts and derived feasible-candidate ledger. Phase2 changed one project's availability, requiring a different optimum. Full-context control received complete original facts and the same delta; its Phase1 answer was withheld. Deltas were chosen before subjects, not after observing Phase1.

| Puzzle/condition | Phase1 composite | Phase2 composite | Phase2 exact ledger | Phase2 exact winner |
|---|---:|---:|---|---|
| A state |100|90|yes|yes|
| A control |60|90|yes|yes|
| B state |100|90|yes|yes|
| B control |100|80|yes|yes|

State mean90 versus control85 is the frozen composite score. Independent audit found all four Phase2 availability/removal updates semantically correct; the gap is solely underspecified serialization requirements (`unavailable` list versus availability mapping; removed ID arrays versus candidate rows). Therefore there is **no observed solution-accuracy advantage** in this pilot. Do not interpret this tiny composite gap as reasoning benefit. One control subject revised its saved draft before submission; original draft was not retained. No output was changed after scoring.

Facts checked by independent enumeration: A19 feasible sets before /14 after, winner AEFGH value27 -> CEFH value23. B10 before /6 after, winner DEFG value26 -> ABEG value22. This demonstrates usable handoff on small tasks, not a capacity-extension result.

## Pilot 2: three bounded-view fresh agents
Seven Boolean variables span slices ABC, CDE and EFG. Each fresh subject sees only one slice plus the previous derived frontier. A deterministic exhaustive oracle checks each frontier and final solution.

Stage1 passed. Stage2 returned C1/D0/E1 despite the required odd sum and omitted E's cost. Stage3 used that wrong frontier and reported an invalid global answer of cost2; true optimum cost4. Stages2 and3 were rejected. This is a genuine negative result for unverified coherent advancement on this instance. Original raw chain is preserved, with no retries.

The checker prints an acceptance/rejection policy; the pilot does not implement transactional persistent memory or rollback. We intentionally passed the rejected raw response forward as preregistered to observe propagation. A sound checking gate can detect this error, but detection and reliable autonomous recovery are different outcomes.

## Resource and validity limits
All subjects used gpt-6-luna low, fresh context, common procedural20000-character ceiling. Exact sampler settings, token counts and context limits are not exposed by the native spawning API. File access restrictions are procedural; no hard blinding. Two matched puzzles and one slice chain have no statistical power or generality. External state includes useful prior search work, so representation/storage is not isolated from computation. No independently measured native capacity threshold, scaling curve or repeated randomized seeds were tested.

## Next discriminating experiment
Calibrate a task-family-specific reliable native capacity curve on held-out generated problems first. Then preregister scaled below/above-threshold tasks, exact state semantics and dependency invalidation, full-context/fact-only/derived-state/extra-compute controls, equal exposed resource budgets, stale/corrupted-state variants, verifier-present/absent variants and independent transition/global scoring. Report representation benefit, checker benefit and extra-compute benefit separately. Avoid using an invented context cap as native-capacity evidence.

## Pilot 3: adaptive recovery from generic rejection feedback
Two new fresh subjects attempted a separately preregistered recovery. Stage2 received the same local task and accepted Stage1 frontier, its rejected predecessor's response, and generic exact-oracle mismatch feedback. No field-level diagnosis or oracle-correct answer was supplied. Its new frontier was still wrong: E0 cost3 instead of1 and E1 repeated illegal C1D0E1 with omitted E cost. The fresh Stage3 again propagated the invalid state. Both were rejected by the unchanged checker.

This one diagnostic attempt does not establish recovery impossibility. It suggests testing explicit semantic feedback, unanchored re-derivation, and deterministic repair/checking protocols rather than assuming a generic rejection message is enough. It is adaptive, unblinded, and has no control; do not pool it with the original run as a confirmatory success/failure rate.

## First-cycle conclusion
Five research/debate roles and13 fresh experiment subjects produced cited arguments, frozen inputs, raw outputs, deterministic scoring and independent critique. Local successful handoffs support a narrow mechanism demonstration; controls showed equal solution accuracy. Two slice-chain runs failed coherence and propagated mistakes. The broad hypothesis is supported conditionally by computational constructions, but its native-capacity and reliable-practical-reasoning claims remain unknown. This cycle is complete as an initial investigation, with the next discriminating experiment recorded above.

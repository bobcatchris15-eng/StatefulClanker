# Skeptic: limits, alternative explanations, and falsifiers

Date: 2026-10-01

## Core challenge

The hypothesis combines at least three distinct claims: (1) information can be stored outside the model; (2) a sequence of model calls can update a coherent state; and (3) this allows a model that cannot internally hold the complete representation to make useful reasoning progress. The first two are nearly definitional for a tool-using model. Evidence for them alone does not establish claim (3). “Advance reasoning” and “full representation” need operational definitions or the hypothesis becomes tautological: any successful answer can be described after the fact as a sequence of external state updates.

The most important validity threat is conflating a genuine representational-capacity advantage with a larger total computation budget. A scratchpad may add tokens, calls, retries, retrieval, or explicit procedure. An external store may contain a hidden answer or algorithm. These are useful engineering methods, but they do not isolate whether coherent incremental state compensates for a model’s inability to hold a complete task state internally.

Artificially truncating the context or forbidding access to part of the representation does not prove that the model naturally cannot hold it. At most, it demonstrates performance under that restriction. “Cannot hold” should be estimated independently, on held-out, randomly generated state-tracking problems, with a pre-registered criterion and a capacity curve. Report native context conditions and a full-context oracle whenever the representation fits.

## Strong counterevidence and qualifications

- Long-context performance is not equivalent to usable capacity. Liu et al. report position-sensitive degradation in both multi-document QA and synthetic key-value retrieval; for some tested models, relevant middle material can perform worse than no documents. This motivates retrieval/attention controls, but does not establish a universal model limitation or test modern models.
- Current memory-agent evaluations find no method dominates across accurate retrieval, test-time learning, long-range understanding, and selective forgetting. This matters because coherent updates require more than retaining a string: systems must retrieve the right fact, update it, resolve conflicts, and sometimes forget superseded state.
- Human external cognition gives the constructive case, but also clarifies the bar: in Tetris, external actions can simplify a problem and improve speed/reliability. The effect depends on the coupling between agent, task, and artifact; it is not evidence that arbitrary text files reliably preserve machine reasoning state.
- Cognitive offloading may bring costs. Work on prospective-memory offloading models finding that external reminders can improve memory for other items while causing forgetting of offloaded items, and that reminder reliability changes these effects. This is a human result, not a direct prediction for LLM agents, but warns against assuming net gains or free state transfer.
- External state can be corrupted, stale, selectively retrieved, or poisoned. A state transition that is syntactically valid can still be semantically false; consistency checks must compare against provenance or independently checkable invariants.

## Tautology and universality distinction

Schuurmans’ “computationally universal” result supports a narrow theoretical point: one particular large model, with an associative read-write memory and a carefully designed prompting/interpreter loop, can simulate a universal Turing machine. The result establishes expressivity under an engineered architecture. It does not show useful reasoning on novel practical tasks, efficient runtime, robustness to model errors, or that a smaller model surpasses its own native state capacity. Computational universality is not a performance theorem. Any experiment should therefore evaluate task-level generalization, transition correctness, resource cost, and failure recovery rather than cite Turing completeness as the outcome.

## Falsifiers and scoring controls

Pre-register generated task families in which exact state grows beyond a baseline model’s independently measured reliable internal state capacity. Use fresh/reset agents per trial; randomly generate entities, values, update operations, and task queries after model freeze. Preserve prompts and answers before trials. Keep answer keys and final answers out of model-visible artifacts. Use separate sealed scoring code.

Compare: (a) no-memory one-shot baseline; (b) full-context baseline when the entire state fits; (c) external-state agent; (d) same external-state transcript shuffled or with a controlled stale/corrupt update; and (e) token/call-matched extra-compute baseline that gets equivalent inference budget but no persistent external state. Match model version, decoding, number of calls, total input/output tokens, latency/cost where feasible, and task exposure. A benefit over (a) alone is insufficient if (e) matches it.

For the quick constrained-selection puzzle specifically, a feasible-candidate ledger is a legitimate candidate external representation: disallowing all derived reasoning would unfairly rule out the mechanism being studied. Instead, compare a fact-only ledger against a derived-state ledger that may record feasible candidates/intermediate deductions but may not simply copy the final Phase 2 answer. Choose Phase 2's constraint delta after Phase 1 state is frozen and ensure that it invalidates the original optimum. This directly tests revision coherence and can reveal whether derived state helps; it remains task-specific utility evidence, not proof of exceeding a native capacity limit.

Score final task accuracy and abstention, exact state-transition fidelity after every step, retrieval precision/recall, invariant violations, recovery after seeded corruption, and resource use. Audit whether each answer can be copied or trivially decoded from the external store. Falsifying outcomes include: no advantage over the compute-matched baseline on above-capacity tasks; apparent benefit disappearing when stores are answer-free; success depending on task-specific leakage or hand-written transition code; or accumulated state error eliminating the gain at longer horizons. A stronger positive result requires accuracy advantage concentrated above the pre-registered capacity threshold, while below-threshold controls remain comparable, with correct intermediate transitions and no leakage.

## Direct peer debate

- To advocate: generic offloading, scratchpad, and universality evidence establish plausibility, not the model-specific capacity claim. Please separate (i) independently measured inability to carry full state, (ii) state-only intervention under matched compute/tokens, and (iii) coherent transitions on unseen instances. I proposed an answer-free, compute-matched randomized-task test; the advocate agreed to characterize existing literature as partial mechanism evidence and include these controls.
- To experimentalist: please do not define inability by imposed context truncation. Match tokens/model calls, generate novel answer keys after model freeze, and score every transition against exact invariants. Include full-context, no-memory, compute-matched, shuffled-state, and seeded-corruption controls. Report retrieval failure separately from reasoning failure. On the quick puzzle, a feasible-candidate ledger is a valid intermediate representation; compare it with fact-only state and prohibit only direct final-answer caching. Select a new delta after phase-1 state is fixed that invalidates the prior optimum.

## Research source ledger

Detailed URLs, supported claims, limits, and forum signal are in [sources/skeptic.md](../sources/skeptic.md).

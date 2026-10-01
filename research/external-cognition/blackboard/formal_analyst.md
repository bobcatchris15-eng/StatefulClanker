# Formal analyst: state, transitions, and limits

Date: 2026-10-01

## Formal distinction

Let the task be a transition system with global state `S`, input or constraint delta `d`, legal transition relation `T(S,d,S')`, and goal predicate `G(S)`. A worker call sees only a view `V(S)` plus `d`, emits a proposed patch `p`, and an external mechanism applies or rejects it. External state is more than retained information only when the patch changes task-relevant state according to `T`, and that changed state enables a later valid transition or goal test.

This yields a useful separation:

- **Retention:** a durable encoding permits later retrieval of a fact or checkpoint. No claim follows about correct inference.
- **Incremental computation:** a changed input causes dependent derived state to be recomputed or invalidated, preserving the relation between base facts and derived results.
- **Coherent reasoning advancement:** accepted successive states form a valid path in the task's transition system, with enough dependency/provenance information to establish that each patch is legal. A correct terminal answer alone does not establish this path.

## Sufficient conditions, conditional on a task formalization

The following conditions suffice for *mechanically sound* advancement in a specified finite task; they do not establish that a general language model can invent the right algorithm.

1. **Explicit state and semantics.** Encode base facts, derived values, pending subgoals, and version/provenance in an unambiguous schema. Define `T` and the goal predicate independently of model prose.
2. **View sufficiency.** Each bounded worker view contains the patch target, the dependencies needed for that transition, and the relevant schema/rules. The full state may be larger than this view; otherwise the claimed bounded-view regime was not exercised.
3. **Patch completeness and atomicity.** A proposed patch names the state version it read, writes a bounded set of fields, and is committed atomically only if its preconditions still hold. Reject stale or malformed patches.
4. **Sound acceptance.** A checker verifies every patch against `T`, or a proof certificate that the checker validates. Without a sound checker, the guarantee is only probabilistic and model/task-specific.
5. **Dependency maintenance.** When source facts change, invalidate or update all affected derived values; preserve unaffected values only when their dependencies prove they remain valid. Incremental-computation literature makes this dependency trace/change propagation explicit.
6. **Progress condition.** A well-founded rank, finite search measure, or fair scheduler ensures accepted transitions eventually move toward a goal or report a dead end. Soundness alone can loop forever.
7. **Resource accounting.** Count worker calls, visible tokens, reads/writes, verifier work, and total wall time. External storage can exceed the worker's view only by shifting storage and often I/O/verification costs elsewhere.

Under these conditions the system can process a global state too large to expose in one call, by composing locally checkable transitions. This is a property of the *whole coupled system* (worker, store, transition protocol, and checker), not of the model in isolation.

## What theory establishes, and what it does not

Schuurmans' construction shows that a fixed-context language model augmented with associative read/write memory and a carefully designed prompt/interpreter can exactly simulate a universal Turing machine. This is a constructive computability result for the coupled architecture: unbounded writable external state changes what the bounded-context system can represent over time. It is not a result that ordinary prompting reliably causes useful novel reasoning, that execution is efficient, or that an arbitrary natural-language scratchpad has sound transitions. A 2024 paper also gives an autoregressive universality construction, but its extended decoding setup differs from fresh-call external-state persistence and likewise proves computability, not practical reliability.

Hutchins' *Cognition in the Wild* treats ship navigation as computation distributed over people, instruments, representations, and time. This supports using the coupled system as the unit of analysis; it is a descriptive account of human work and does not transfer a correctness theorem to LLM agents.

Self-adjusting computation provides the closest formal engineering analogy for *coherent updates*: record data/control dependencies, then propagate changes through affected computations while reusing unaffected computations. Its correctness depends on the trace and program semantics. A language model's free-form summary does not automatically carry equivalent dependency guarantees.

## Small constructive example

Suppose a generated record contains `n=10,000` Boolean bits, but a worker may inspect at most 50 bits per call. Goal: return the parity. The store holds a partitioned ledger `(block_id, parity, source_hash)`; each call sees one block of at most 50 bits and emits its parity and hash. A deterministic checker recomputes that block parity. The store then combines block parities with XOR in a balanced tree, checking each internal node from its two children. Every local view is at most 50 input bits, while the global ledger is larger; the root is exact parity. If one input bit changes, only its block and the nodes on one tree path need updating.

This demonstrates externalized state plus computation and change propagation. It does **not** demonstrate semantic reasoning by an LLM: the local operation and combine rule are fixed, simple, and machine-checkable; compute is performed across many calls/checker operations. It is a positive control for the infrastructure.

## Failure example

For the same parity task, suppose each worker writes a prose summary such as “the first block is mostly even,” the store silently overwrites a previous block result, and the next worker sees only the latest note. Retention is unreliable, dependencies are absent, and there is no checker. One plausible but wrong patch permanently corrupts the final answer. A long durable transcript does not repair missing state semantics, stale writes, or unverified transitions.

Another impossibility boundary: if a bounded worker's view omits a fact that can change which patch is legal, and it receives no query channel or sufficient summary of that fact, it cannot guarantee the correct action for all inputs. Two global states indistinguishable in the view but requiring different next actions force the same response in both; that response must be wrong for at least one. Thus a global state larger than the view is feasible only when each step has a sufficient local view, or the system can retrieve/query the needed dependency.

## Test implication: make global state exceed worker view

Use generated constraint-satisfaction instances whose canonical full ledger grows with `N`, while each worker prompt has a hard measured view cap `k` (e.g., 128 tokens). Each microtask operates on a bounded neighborhood and returns a typed patch plus source/version IDs. A separate deterministic checker validates local constraints and global invariants. Increase `N` beyond `k`-view capacity while keeping local degree fixed. Compare: (a) external persistent ledger with read/query interface; (b) stateless fresh-call baseline with the original facts and equal call/token budget; (c) token/call-matched extra-compute baseline; (d) shuffled/stale/corrupted ledger controls; and (e) a full-state oracle when it fits. Keep answers and hidden generated truth out of worker-visible state.

Score (i) facts successfully retrieved, (ii) valid local transitions, (iii) global invariant preservation after every commit, (iv) terminal solution accuracy, and (v) cost. Vary whether the checker is present: the contrast estimates how much benefit comes from external representation versus formal enforcement. A positive result establishes a scoped coupled-system benefit; a stronger “overcomes native capacity” result additionally requires an independently measured model capacity threshold and a benefit concentrated above it. A failure may arise from retrieval, serialization, invalid inference, or inadequate budget; log these separately.

## Claims and falsifiers

### F1 — External state can extend representable global computation beyond a bounded worker view

**Assertion:** A bounded-view worker coupled to unbounded writable external memory can process some tasks with global state larger than its per-call view.

**Evidence:** Schuurmans' exact UTM simulation is a reported construction; the parity ledger above is a direct constructive example under an explicit protocol.

**Status/applicability:** Theoretical/constructive; applies to coupled systems with external memory and suitable operation protocol. It does not imply useful unconstrained LLM reasoning.

**Strongest objection:** Unlimited memory/I/O and engineered prompting move the resources and algorithm outside the model.

**Falsifier:** For the specified parity protocol, any mismatch against exact parity under valid inputs falsifies the claimed implementation correctness; for broad LLM reasoning, this source alone has no such evidential reach.

### F2 — Coherent incremental advancement needs transition semantics and dependency maintenance

**Assertion:** Durable notes alone are insufficient for a correctness guarantee; legal transitions, dependency tracking/update, and sound acceptance are needed.

**Evidence:** Self-adjusting computation formalizes change propagation over recorded dependencies; the indistinguishable-state argument gives an information-theoretic limit when needed facts are outside the view.

**Status/applicability:** Formal engineering inference, given task semantics. Model proposals without a sound verifier only support empirical reliability claims.

**Strongest objection:** A model can learn implicit transition rules and track dependencies without explicit formal machinery.

**Falsifier:** Demonstrate reliable invariant preservation and recovery on held-out, growing tasks without explicit checker/dependency records, under matched resources and independently scored transitions.

### F3 — Retention, coherent reasoning, and capacity extension are separate empirical claims

**Assertion:** Success in retrieving stored facts does not establish valid derivation; valid staged derivation does not establish advantage beyond a model's native reliable capacity.

**Evidence:** This follows from different measured outcomes and the scope of the cited computability/incremental-computation results.

**Status/applicability:** Logical distinction; exact operational thresholds remain task- and model-dependent.

**Strongest objection:** For practical systems, coupled-system performance may be the only relevant criterion.

**Falsifier:** An operational evaluation could show that the separation adds no predictive value for the target deployment, though it would not collapse the conceptual distinctions.

## Debate notes

The advocate and skeptic both correctly distinguish mechanism plausibility from the capacity-extension claim. Formalization makes the conjunction sharper: (a) globally durable information, (b) locally sufficient views, (c) sound state transitions, and (d) a progress/resource condition. The experiments should report which condition failed rather than label all failures “reasoning.”

# Lab 4: shared external reasoning state

## Purpose and boundary

Lab 4 is a small, auditable pilot of whether locally available structured state helps agents coordinate on a coupled, multi-part synthetic task. Each participant receives the complete public problem. Independent agents propose parts of a solution; peer reviewers inspect one another's claims and can challenge or offer a corrected candidate; fresh integrators then solve from the complete problem, with one also receiving the committed shared state. This design tests message access and basic causal mechanics in two cases. It is not a general proof that a protocol represents cognition, nor a benchmark of local models or problem-solving performance.

The protocol is provider-neutral and file/CLI based. The pilot's initial runtime is the native Luna-low route. Any local-model route remains untested until a concrete runtime and invocation are selected. The runner must not change Lab 3 or its live-cycle artifacts.

## Approaches considered

1. **Free-form shared chat.** Minimal setup, but state and dependencies are difficult to replay or audit.
2. **A rigid domain-specific theorem schema.** Easy to score but forces every future task into one representation and gives the protocol an unwarranted claim to universal expressiveness.
3. **Generic envelopes with structured, versioned claims and opaque domain payloads (recommended).** The envelope and state transitions are deterministic; the domain payload can be any JSON value. A domain adapter supplies the complete task and later scores outputs offline. This is small enough to build with Python's standard library while preserving task flexibility.

## Components and data flow

An independent Lab 4 domain adapter obtains cases from the existing `lab3.experiment.make_case(seed)` generator for seeds 4201 and 4202. It renders a full problem packet containing the modulus, observations, declared affine family, observed target image `(u,v)`, and output requirements for every participant. Only the true coefficient triples and target answer `(x,y)` are hidden for offline evaluation. It does not patch or change Lab 3's execution path.

For each case, two fresh proposers run in parallel from the same immutable problem snapshot: one proposes the `u` affine relation and the other the `v` relation. Each proposal is routed to its assigned peer reviewer and to the registered `shared-integrator` mailbox. Two fresh cross-reviewers then run in parallel; each receives the entire problem plus the peer's claim, and returns a structured report or challenge, optionally with a corrected candidate claim. Each review is routed to `shared-integrator`. Candidate values and original claims are all shown to the shared integrator together with review records; the store never chooses which value to promote. The runner commits all messages through one append-only event log. Two fresh final integrators receive the same complete public problem facts. The shared-state integrator also receives the current structured claim/review state. The raw-only control receives the complete problem packet without shared intermediate state. Both return the same final-answer schema.

This is six model calls per case, twelve total. Calls within each proposer and reviewer pair are parallel. Final calls are fresh and occur after review state is fixed. Each participant sees the whole raw problem; no condition depends on withheld problem facts. No semantic feedback from the evaluator is sent to participants.

## State and persistence

Use a standard-library SQLite database. An append-only event table is the source of truth; a transactionally maintained projection exposes the current claim state. Every submitted envelope is structurally validated and committed atomically with its projection update. Persist exact input prompt bytes, output bytes, model/route metadata, timing, envelope parse result, receipt/rejection, event sequence, and hashes. A duplicate message ID with identical content returns its original receipt; reuse with different content is rejected.

The store enforces envelope shape, authorized sender/recipient, allowed intent, unique IDs, read-reference freshness, claim shape, dependency references, and revision/status transition rules. It does not evaluate affine equations, truth, evidence sufficiency, or mathematical correctness. Semantically incorrect but structurally valid claims remain visible and can be challenged. This separation makes the store a durable coordination mechanism rather than an oracle.

## Consistency rules

Each claim has a stable `claim_id`, integer value `revision`, independent integer `state_revision`, status, payload, provenance, and dependency references. The value revision advances when the claim value is replaced; the state revision advances on every accepted lifecycle change, including challenge, retraction, invalidation, or supersession. A read reference pins both revisions, so a reader of `active` cannot silently act on a later `challenged` projection. Dependencies pin claim value revisions, not review status. New claims are independent writes. Two proposals based on the same problem snapshot and targeting different claim IDs both commit. Updates must name both revisions they read; if either has changed, the update is rejected as stale. On RETRACT, the target claim becomes retracted and claims that depend on its value revision become invalidated recursively; the event log remains intact. A challenge does not silently overwrite the value. It adds a review event and, if supplied, a separately recorded corrected candidate.

Read references name immutable problem resources or exact claim value and lifecycle revisions. They are also frozen in the run manifest so two executions can replay the same access pattern. Event order is a monotonically increasing integer assigned by SQLite. Replaying the same committed event sequence reconstructs the same projection.

## Determinism and serialization

Messages are UTF-8 JSON objects. The engine emits canonical bytes by sorting object keys, using compact separators, rejecting duplicate keys, and permitting integer numeric values only (plus strings, booleans, null, arrays, and objects). Floating-point values are forbidden. This is a deliberately limited deterministic encoding; the implementation must not claim full RFC 8785 / JCS compliance. Hash exact canonical bytes. Domain payloads remain arbitrary structured JSON subject to these serialization constraints.

## Failure behavior

Malformed JSON, schema violations, unknown references, unauthorized routing, duplicate-ID conflicts, or unknown reads are rejected without state mutation and retained as raw outputs for audit. No automatic repair or retry is permitted. A rejected proposer prevents only dependent state from being presented as accepted; the run records attrition and may still run the raw-only control. Model/runtime failures are recorded and count against the call ceiling; no substitute call is made. Offline scoring begins only after all raw outputs and run receipts have been saved.

## Explicit non-goals

- A universal representation of cognition, proofs, or arbitrary domains.
- Semantic validation or correctness gating in the state store.
- A statistically powered comparison, a population claim, or a claim of general hard-problem capability.
- Token- or compute-matched conditions; the pilot caps calls, not tokens or reasoning effort.
- A local runtime result before the runtime is named, installed, and run.
- Changes to the Lab 3 code, subjects, or existing live-cycle artifacts.

## User-authorized fork refinement
Changed premises block an automatic main merge, but do not erase a proposal. The authoritative potential-fork contract is in PROTOCOL.md: captured coherent historical/proposed snapshots, inspectable held fork, and explicit designated-admin archival only with evidence and prevailing-workable attestation. No automatic semantic judgment. Cross mapping is u-reviewer to v-relation and v-reviewer to u-relation.

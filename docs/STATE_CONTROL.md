# State and context control

This document records how the current StatefulClanker implementation maps the project's design claims onto actual durable objects and where the boundary intentionally stops.

## Implemented now

### Disposable reasoning, durable project

Workers are cold-start invocations. Continuity is reconstructed from durable state and project evidence rather than assumed from conversation history.

### Context compilation

Every worker cycle creates a durable compilation receipt containing a typed model-visible IR, read set, input fingerprint, retrieval budget accounting, provenance/authority tags, file hashes, dependency identities, and the exact recent-event projection used.

### Freshness checks

The compiler read set is checked immediately before dispatch. Logical dependencies, goal identity, task definition, and active plan identity are checked again before completion is committed.

Filesystem hashes are intentionally dispatch-time guards only. A worker may legitimately modify files it read, so post-worker file-hash comparison would confuse expected writes with external races until StatefulClanker has explicit write-set attribution.

### Candidate vs canonical state

Normal successful worker output creates a completion proposal. Critic and validator results attach to that proposal. Canonical task completion changes only at an explicit commit boundary after required review and freshness checks.

### Selective invalidation

Scheduling dependencies are explicit. Retrying or blocking previously accepted upstream work invalidates affected descendants rather than letting downstream completion silently survive on stale assumptions.

### Causal graph structure

`dependsOn` means execution blocking. `relations` holds open-ended semantic edges such as `discovered_from`, `derived_from`, `evidence_for`, `supersedes`, `invalidated_by`, and `conflicts_with`.

### Context-fault telemetry

Workers may emit `CONTEXT_REQUEST:` when a required fact/artifact was omitted. The harness records those misses separately from generic run failure. Compilation receipts also retain unmatched selectors, truncation, and budget exhaustion.

### Progress telemetry

Terminal cycles record whether accepted project state actually advanced. Repeated non-advancing attempts against the same compiled input fingerprint generate a stagnation warning.

### Reviewer snapshot consistency

Critic and validator inspect the same compilation that drove the worker plus the worker receipt. They do not silently re-run retrieval against a potentially changed repository snapshot.

## Deliberately outside the core for now

### Cross-project experiential memory

Reusable agent expertise belongs in a separate system such as Toaster. StatefulClanker may consume candidate lessons later, but project authority and reusable experience remain different state classes.

A future memory integration should use:

`retrieve lesson -> check current applicability/freshness -> reconstruct project-specific guidance -> compile as candidate context`

not raw replay of historical instructions.

### Learned context policy

The current compiler is deterministic and inspectable. Learned retrieval/eviction/compression policy should wait until context-fault and progress telemetry provide a useful training/evaluation signal.

### Harness self-modification

Receipts can eventually support failure clustering and regression-tested policy repair. Automatic self-editing is not part of the core until the evaluation boundary is strong enough to prevent optimizing harness blind spots.

### Exactly-once external effects

Run receipts do not guarantee that arbitrary side effects are idempotent. A future effect layer should track authorization, idempotency key, dispatch, observed result, reconciliation, reversibility, and compensation.

### Distributed authoritative writes

Immutable receipts and append-only events are naturally merge-friendly. Authoritative plan heads, approvals, and task-completion commits are not yet a CRDT. Multi-machine ClankerFog execution should classify state by consistency needs before enabling concurrent writers.

## Structural invariants checklist

When changing the harness, verify all of the following:

- [ ] No model session is required to remember project history for correctness.
- [ ] Worker input can be reconstructed from durable objects.
- [ ] The exact compiled working set is persisted.
- [ ] Retrieval omissions/truncation are observable.
- [ ] Worker claims remain non-authoritative until commit.
- [ ] Required critic/validator stages fail closed.
- [ ] Reviewers judge the worker against the same compiled snapshot.
- [ ] Stale upstream assumptions cannot silently retain downstream authority.
- [ ] Scheduling dependencies are not conflated with semantic relationships.
- [ ] Failed/rejected attempts remain durable evidence.
- [ ] Activity and accepted progress are recorded separately.
- [ ] External/reusable memory cannot silently become canonical project truth.
- [ ] Features not actually enforced by the harness are described as future boundaries, not current guarantees.

If these remain true, implementation details may change without drifting from the project's central architecture.

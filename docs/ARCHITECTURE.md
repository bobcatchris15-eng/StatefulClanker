# StatefulClanker architecture

## Purpose

StatefulClanker externalizes the pieces of long-running agentic work that are usually trapped inside a model session. The system should be able to stop after any durable transition, start a new model session, and continue from project state without reconstructing intent from chat history.

The orchestrator is therefore a **state-transition and context-compilation engine**, not a giant prompt.

The project persists. Model reasoning is temporary compute.

## Canonical loop

```text
observe
  -> retrieve
  -> compile typed working set
  -> validate read-set freshness
  -> invoke one cold-start worker
  -> persist receipt
  -> propose state transition
  -> critique / validate / human gate as required
  -> revalidate logical dependencies
  -> commit or reject proposal
  -> record progress
  -> repeat
```

Every material boundary is observable and persistable.

## State authority

StatefulClanker distinguishes three things that are often conflated:

1. **Canonical state** — durable project objects that the harness currently accepts as true for execution.
2. **Compiled context** — a temporary projection of canonical state and project evidence for one invocation.
3. **Model output** — a probabilistic proposal/evidence artifact that may or may not be accepted.

A model response never becomes canonical simply because it exists.

## Durable objects

### Project state

`state.json` contains compact current project state: identity, goal, active plan, approval state, revision, and timestamps. Historical detail belongs in append-only events and receipts.

### Events

`events.jsonl` is append-only. Observations, decisions, failures, user direction, discoveries, invalidations, context faults, and commits are events. This prevents current state from becoming an accidental transcript while preserving replayable history.

### Tasks

Tasks are independent JSON documents under `tasks/`.

A task carries:

- id, title, instruction, acceptance criteria
- scheduling dependencies in `dependsOn`
- semantic relationships in `relations`
- retrieval intent and evidence selectors
- provider / role preference
- human-gate flag
- lifecycle status
- revision and attempt count
- pointers to latest compilation, proposal, run, critique, and validation

Core lifecycle states are:

`pending -> ready -> running -> reviewing -> validating -> complete`

with side states including `blocked`, `failed`, `needs_rework`, and `stale`.

`stale` means the task was once accepted but an upstream dependency was later invalidated. The old receipts remain evidence; the completion is no longer current authority.

### Typed relationships

`dependsOn` has execution semantics. `relations` preserve other causal or semantic structure without overloading scheduling.

Recommended relation types include:

- `discovered_from`
- `derived_from`
- `evidence_for`
- `supersedes`
- `invalidated_by`
- `conflicts_with`
- `related`

Relationship vocabulary is intentionally open. The harness only gives automatic scheduling semantics to `dependsOn`.

### Plans

Plans are versioned inputs that create task graphs. Human-readable plan prose is useful, but structured tasks and relationships are authoritative to execution.

### Compilations

A compilation under `compilations/` is the durable receipt for constructing one model-visible working set.

It contains:

- exact task projection
- current project goal / active plan identity
- dependency outcomes
- retrieved files/evidence
- hashes of retrieved files
- bounded recent events
- source authority labels
- retrieval budget/truncation/unmatched-selector statistics
- a logical/file read set
- an input fingerprint
- the exact typed intermediate representation sent to the worker

The compilation is not canonical state. It is a reproducible snapshot/projection derived from canonical state.

### Read sets and freshness

Every compilation records what it relied upon.

Before dispatch, StatefulClanker checks:

- project goal identity
- active plan identity
- task definition
- dependency state/receipt identity
- retrieved file hashes

Before committing completion, it rechecks logical dependencies and definitions. Retrieved file hashes are intentionally not used as a post-worker freshness gate because a worker may legitimately modify the files it read. Correct attribution of concurrent file writes requires a stronger write-set model and is not claimed yet.

This distinction prevents false staleness while still giving the harness a real plan/context freshness boundary.

### Runs

A run receipt records exactly what was dispatched and what came back:

- task, provider, agent id
- compilation id and input fingerprint
- command / arguments / prompt path
- timing and exit code
- stdout / stderr
- explicit worker context requests

A failed worker call should improve future execution rather than disappear into chat scrollback.

### Context faults

Workers are instructed to emit:

`CONTEXT_REQUEST: <specific missing state>`

when required project state or evidence was absent from the compilation.

These records are stored under `telemetry/context-faults.jsonl`. They provide an observable approximation of semantic page faults and make retrieval-policy mistakes measurable instead of anecdotal.

Compilation receipts additionally expose unmatched selectors, truncation, and budget exhaustion.

### Proposals

A normal successful run creates a candidate completion proposal under `proposals/`.

A proposal records:

- base compilation and input fingerprint
- task-definition hash
- worker run receipt
- critic receipt/verdict when enabled
- validator receipt/verdict when enabled
- commit or rejection state
- rejection reasons

The proposal is the explicit boundary between probabilistic model output and canonical project mutation.

### Critiques and validations

Critique and validation are separate artifacts because they answer different questions.

Critic: **What looks wrong, incomplete, risky, contradictory, or poorly reasoned?**

Validator: **Do the observable acceptance conditions pass from the available evidence?**

Neither silently rewrites the worker result. Both review the same compiled context used by the worker rather than re-running retrieval and accidentally judging a different world snapshot.

### Progress

`progress/` answers a different question from `runs/`.

A run says compute happened. A progress record says whether accepted project state advanced.

Each terminal cycle records:

- task and compilation
- input fingerprint
- attempt number
- advanced true/false
- outcome class
- reason

Repeated non-advancing attempts against the same input fingerprint raise a stagnation warning. This is deliberately simple; it creates the telemetry needed for later replanning or spin-control policies without pretending those policies are already solved.

## Context compiler

StatefulClanker treats prompt construction as a compiler pipeline:

```text
canonical state + task + dependencies + project evidence + recent events
        |
        v
normalize / classify sources
        |
        v
build read set + provenance + authority labels
        |
        v
apply working-set budget
        |
        v
typed context IR
        |
        v
cold-start worker prompt + compilation receipt
```

The compiler currently uses simple deterministic policy. It does not yet learn what to retrieve or evict.

## Retrieval

Retrieval is driven by declared task intent rather than repository dumping.

Useful selectors include exact files, directories, globs, generated artifacts, dependency outputs, and explicitly named evidence. The current implementation remains intentionally understandable: file retrieval and dependency receipts behind a bounded interface.

A future retrieval layer can become smarter without changing task or compilation semantics.

## Transactional completion

Normal automated completion follows:

```text
state N
  -> compile against N
  -> worker result
  -> candidate proposal
  -> critic / validator evidence
  -> freshness check
  -> COMMIT -> state N+1
       or
     REJECT -> canonical completion unchanged
```

This is not a database transaction in the distributed-systems sense, but it enforces the important semantic rule: **model writes are proposals until the harness accepts them**.

Manual completion is an explicit human-authority commit and is recorded separately.

## Dependency invalidation

When a completed upstream task is deliberately retried or blocked, its dependents cannot silently retain authority.

StatefulClanker recursively invalidates downstream tasks:

- completed dependents become `stale`
- unresolved dependents return to dependency-gated states
- original runs and validations are retained

This is closer to build-system invalidation than conversational memory refresh.

## Provider adapter

Providers remain ordinary command lines. StatefulClanker substitutes placeholders into configured argument vectors:

- `{prompt}` — full prompt inline
- `{promptFile}` — UTF-8 prompt path
- `{projectRoot}` — target repository root
- `{taskId}` — task id

Provider quirks remain configuration data wherever possible.

## Planner contract

A good task must survive total conversational amnesia.

It should:

- have one primary concrete outcome
- declare objective acceptance criteria
- name required retrieval/evidence
- declare scheduling dependencies
- preserve meaningful causal relationships
- avoid hidden references such as "as discussed earlier"
- identify genuine human decision gates
- be small enough that one cold-start worker can attempt it coherently

## Human interaction

The user is not a fallback parser. Human gates represent product, design, risk, credential, cost, or preference decisions that cannot be resolved mechanically from established project state.

Human direction should become a durable event and, when execution-relevant, a plan/task/state change.

## Concurrency

The task model still permits ready tasks with independent dependency closures to run concurrently, and configuration retains `maxConcurrent`.

The current PowerShell entrypoint dispatches one task per invocation. StatefulClanker does **not** yet claim a full distributed multi-writer consistency model. Append-only events and immutable receipts are naturally merge-friendly; authoritative plan heads, approvals, proposals, and completion commits will need stronger conflict control before ClankerFog-style distributed execution is allowed to write them concurrently.

## External effects

StatefulClanker currently records provider invocations and resulting receipts. It does **not** yet provide exactly-once semantics for arbitrary external side effects performed inside a worker.

Git-backed coding work is relatively recoverable. Email, cloud provisioning, purchases, deployments, and other irreversible or costly actions need a future effect ledger with idempotency keys, authorization, reconciliation, and compensation semantics.

This limitation is explicit rather than hidden behind run receipts.

## Experiential memory boundary

Reusable cross-project expertise is deliberately not part of the canonical StatefulClanker store.

Project state answers: **what is true / pending / decided here?**

Experiential memory answers: **what reusable lessons have prior work taught us?**

A future Toaster-like layer may provide candidate lessons to the context compiler. Those lessons should be checked against current project state before use and should never become project authority merely because they were retrieved.

## Harness self-improvement boundary

Receipts, compilations, context faults, and progress records create the corpus needed to evaluate the harness itself. Future tooling can mine recurring failures and propose changes to retrieval, decomposition, routing, compilation, or review policy.

Such changes should be regression-evaluated before promotion. StatefulClanker does not currently mutate its own policy automatically.

## Invariants

1. Durable project state is authoritative over model recollection.
2. Model-visible context is a compiled projection, not canonical state.
3. A compilation records the read set and exact projected IR used for an invocation.
4. A task cannot become ready until all scheduling dependencies are complete.
5. A task is marked running before provider invocation.
6. A run receipt is written even when the provider fails.
7. A worker cannot mark its own task complete merely by claiming success.
8. Automated completion advances through an explicit proposal/commit boundary.
9. Required review stages fail closed.
10. Logical dependencies are revalidated before a completion commit.
11. Retried/invalidated upstream work invalidates downstream authority.
12. Human-gated transitions require explicit human authority.
13. No worker needs the full historical transcript to operate correctly.
14. Activity and progress remain separately observable.
15. Cross-project skill memory is not canonical project state.
16. External side-effect exactly-once safety is not claimed until an effect ledger exists.

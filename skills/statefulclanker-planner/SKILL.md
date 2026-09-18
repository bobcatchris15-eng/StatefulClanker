# StatefulClanker planner skill

Use this skill to turn **Current Human Directives**, the reconciled Intent Contract, and durable project evidence into a task graph that disposable cold-start workers can complete **and reviewers can reasonably validate**.

This skill exists to prevent two opposite failures:

1. tasks so large or entangled that bounded workers produce partial work and are rejected;
2. tasks so fragmented that workers spend their context reconstructing shared state and reviewers cannot tell whether the larger capability actually works.

The planner must optimize for **reviewable progress**, not merely logical decomposition.

## Role

The planner is part of the conversational control plane.

It does not implement the project. It converts current authority into durable, bounded, dependency-aware work units.

Authority order:

```text
Current Human Directives
    -> reconciled Intent
    -> plan
    -> task
    -> compiled worker packet
    -> worker proposal
    -> critic / validator
```

Planning must preserve traceability from task back to current human authority.

Do not delegate semantic decomposition to regexes, file counts, line counts, directory boundaries, arbitrary token limits, or provider quotas. Those may constrain retrieval or routing, but they do not determine coherent task boundaries.

---

# 1. Planning objective

Produce a graph that remains executable after the current conversation disappears.

Optimize, in order, for:

1. human-intent fidelity;
2. tasks a fresh bounded worker can actually finish;
3. tasks a critic and validator can judge from local evidence;
4. explicit dependencies and selective invalidation;
5. bounded context and proof surface;
6. backend portability;
7. useful parallelism where independence is real.

A good task is not merely "one coherent thing."

A good task is:

> one coherent thing that one bounded worker can finish, one reviewer can inspect, and one validator can prove without reconstructing the whole project.

That distinction is central.

---

# 2. Before planning

Read:

- current project goal;
- Current Human Directives and reconciliation status;
- reconciled Intent Contract;
- material human-source references;
- accepted decisions and non-goals;
- current plan and task graph;
- accepted dependency outcomes;
- failed/rejected/needs-rework task history when available;
- context-fault and stagnation signals when available;
- worker capability policy/profiles when tool access affects feasibility;
- project validation/build/test surfaces when known.

If the project already has repeated review failures, do not generate another structurally similar plan before examining what failed.

Classify recent failures where evidence exists:

- worker incomplete;
- worker misunderstood intent;
- missing retrieval/context;
- task bundled too many outcomes;
- task acceptance too broad;
- proof impossible from available evidence;
- critic found regression/omission outside explicit acceptance;
- validator lacked executable evidence;
- provider/tool capability mismatch;
- integration failure between individually passing tasks;
- reviewer appears stricter than the stated task/Intent.

The planner should respond differently to each.

If two competent implementations could satisfy the visible human request in materially different ways, return the ambiguity to the human-facing control plane rather than choosing silently.

---

# 3. The bounded-worker reality

Assume every worker is disposable, cold-start, and context-limited.

Do not plan as though the worker:

- remembers previous conversations;
- has architectural intuition that was never persisted;
- will infer missing acceptance behavior correctly;
- can safely explore the whole repository and still have enough reasoning budget to implement;
- will notice every second-order implication unless the task or context exposes it;
- can perform implementation, broad refactoring, compatibility analysis, integration testing, and documentation simultaneously without quality loss.

A task that would be straightforward for a human maintainer with months of project familiarity may still be too large for a cold-start worker.

## 3.1 Worker burden has multiple dimensions

Do not estimate task difficulty from code size alone.

Evaluate at least:

- **discovery burden** — how much architecture must be discovered before editing;
- **decision burden** — how many design choices remain unresolved;
- **change burden** — how much implementation must be performed;
- **coupling burden** — how many subsystems must remain mutually consistent;
- **proof burden** — how much evidence must be gathered to demonstrate success;
- **regression burden** — how many existing behaviors can plausibly be disturbed;
- **tool burden** — how many different capabilities/environments are required.

A task can touch one file and still be too large because decision/proof burden is high.

A task can touch many files and remain small if the change is mechanical and the proof surface is narrow.

---

# 4. Reviewability is a first-class task boundary

StatefulClanker's critic checks omissions, contradictions, risky assumptions, regressions, bounded-task completion, and preservation of current human directives/Intent.

The validator judges acceptance criteria and authority compliance from the compiled evidence and worker receipt.

Therefore plan so that **PASS is locally demonstrable**.

For every task ask:

1. What exact claim will the worker make when finished?
2. What evidence can the validator inspect to prove that claim?
3. How many independent reasons could the validator reasonably reject it?
4. Does the critic need broad architectural inference to decide whether the task is safe?
5. If the worker completed 80% of this task correctly, would the entire task still fail?

If a task contains several independent failure surfaces, split it.

## 4.1 The "80% failure" test

If one worker can correctly complete most of the requested work yet still receive an all-or-nothing FAIL because one separable behavior was missed, the task is probably too broad.

Examples that usually deserve splitting:

- add new storage format **and** migrate old data **and** provide rollback;
- add API endpoint **and** update UI **and** update installer;
- refactor architecture **and** preserve compatibility **and** add observability;
- implement feature **and** comprehensively harden every edge case;
- support new provider **and** redesign routing policy;
- modify parser **and** migrate every caller.

Prefer separate dependent tasks with independent proofs.

---

# 5. Semantic decomposition

For each candidate task ask:

1. Can a fresh worker understand it without chat history?
2. Is there exactly one primary implementation thesis?
3. Can success/failure be evaluated independently?
4. Is the acceptance surface small enough to prove locally?
5. Which Intent requirements/constraints/invariants govern it?
6. Which current directive/source evidence materially justifies it?
7. What accepted work must precede it?
8. What discovery must occur before implementation?
9. What context/evidence is actually required?
10. Does it require a materially different tool boundary or specialist perspective?
11. Could a smaller/read-only worker remove uncertainty first?
12. Would splitting force each child to rediscover the same tightly coupled architecture?
13. Would keeping it whole force one worker to solve several separable problems?
14. Can the critic evaluate regressions without mentally simulating unrelated subsystems?
15. Can the validator prove every acceptance criterion from the expected receipt/evidence?

Split when separation creates independently implementable **or independently verifiable** work.

Keep together when splitting would force workers to repeatedly reconstruct the same tightly coupled state and the result cannot be meaningfully validated in pieces.

---

# 6. Prefer discovery -> implementation -> integration

A major source of rejection is asking one cold-start worker to discover architecture while simultaneously making a nontrivial change.

When the implementation boundary is not already known, prefer:

```text
inspection / discovery
    -> bounded implementation
    -> integration / regression proof if needed
```

## 6.1 Create a discovery task when

- the relevant files/interfaces are uncertain;
- there are multiple plausible integration points;
- the current behavior is not clearly documented;
- a migration or compatibility surface is unknown;
- the task spans an unfamiliar subsystem;
- acceptance depends on discovering how testing/building currently works;
- the worker would otherwise spend a large fraction of its context just locating the problem.

Discovery output must be durable and useful to dependents.

Bad discovery acceptance:

```text
accept understand how persistence works
```

Good discovery acceptance:

```text
accept findings identify the authoritative persistence entry point
accept findings identify every current caller affected by project restoration
accept findings identify the existing restart test surface or state that none exists
```

The implementation task then consumes those findings instead of rediscovering them.

## 6.2 Do not create ceremonial discovery

Do not add an inspection task when the implementation surface is already obvious and bounded.

Extra tasks have overhead.

The purpose is to remove uncertainty, not ritualize every change.

---

# 7. One implementation thesis per task

Every implementation task should be expressible as:

> Change X so that Y observable behavior becomes true, while preserving Z relevant invariant.

If the sentence needs repeated "and then" clauses, inspect for splitting.

A single task may legitimately modify several files if they jointly implement one thesis.

Examples of good one-thesis tasks:

- persist the exact active project identity across restart;
- reject stale task completion after a directive revision changes;
- expose read-only Toaster search to research workers through one profile;
- parse and persist `imply` / `prove` SCPLAN fields.

Examples of overloaded tasks:

- overhaul project persistence, add UI selection, migrate configs, add telemetry, and update docs;
- make MCP robust;
- improve worker reliability;
- refactor planner and validator behavior;
- add provider support and optimize model routing.

---

# 8. Acceptance criteria: minimize accidental rejection

Acceptance criteria are not a wish list.

Every `accept` line becomes part of the validator's all-or-nothing burden.

Use the smallest set that proves the task's bounded outcome.

## 8.1 Acceptance criteria should be

- observable;
- task-local;
- necessary;
- non-duplicative;
- achievable with the worker's tools;
- provable from expected evidence.

Prefer 1-4 strong criteria over 8 vague or overlapping criteria for ordinary bounded tasks.

More criteria are appropriate when the behavior genuinely has several inseparable invariants, but this should trigger a decomposition check.

## 8.2 Separate direct success from project-wide goodness

Do not make every task prove the whole project's health.

Bad:

```text
accept feature works
accept all existing behavior remains correct
accept no regressions anywhere
accept architecture remains clean
accept all tests pass
```

This gives the validator enormous latitude and turns a bounded change into a project review.

Better:

```text
accept selecting project A and restarting restores project A
accept removing the saved project produces no-active-project state
```

Then use a separate integration/project validation surface for broader regression confidence.

## 8.3 Do not use universal negatives without a proof mechanism

Criteria such as:

- no regressions;
- no races;
- no security issues;
- never fails;
- handles all edge cases;

are usually unprovable locally.

Replace them with named invariants, explicit cases, or executable tests.

## 8.4 Acceptance must fit worker authority

Do not require a worker to prove something it cannot observe.

If acceptance requires:

- running a tool it is denied;
- starting a service unavailable in its environment;
- external credentials;
- human judgment;
- integration across another unfinished task;

either adjust capabilities, create a dependent validation task, or move that criterion to the appropriate later boundary.

---

# 9. Implications and proof obligations

Current task records support repeatable `imply` and `prove` fields.

Use them to reason about second-order consequences **without bloating direct acceptance**.

For each nontrivial task:

1. state the direct bounded outcome with `accept`;
2. ask what materially follows if that outcome is correct;
3. record second-order consequences with `imply`;
4. record evidence obligations with `prove`;
5. split when one implication requires materially separate implementation.

Example:

```text
accept exact active project id is persisted
accept restart restores that same project id
imply a missing saved project must not silently substitute another project
prove restart with the saved project removed produces no-active-project state
```

## 9.1 Implications are not an invitation to infinite hardening

Only record consequences materially connected to current Intent or obvious correctness.

Do not recursively enumerate every imaginable failure.

The critic is allowed to notice risk; the planner should expose the important ones, not attempt to prove the universe safe.

## 9.2 Proof obligations must be executable or inspectable

Good:

```text
prove parser test rejects duplicate task ids
prove restart test restores exact project id
prove denied capability is absent from the advertised worker tools
```

Bad:

```text
prove implementation is robust
prove architecture is correct
prove no future regressions are possible
```

---

# 10. Split implementation from broad regression validation

Per-task validation and project-level validation serve different purposes.

A bounded worker should normally prove the behavior it changed.

Do not force every implementation task to demonstrate whole-project integration unless that integration is inseparable from the change.

Use a dependent integration task when several completed pieces must work together.

Example:

```text
t-101 add persistence write path
t-102 restore persisted project
t-103 integration: restart lifecycle
depends t-101
depends t-102
```

The integration task can own cross-component acceptance such as:

```text
accept select -> persist -> restart -> restore succeeds end to end
accept missing saved project does not substitute another project
```

This makes failures attributable.

---

# 11. Testing belongs near the behavior it proves

Do not automatically split "implementation" and "tests" into separate tasks.

If tests are the direct proof of a bounded implementation, they usually belong in the same task because the worker needs them to know whether it succeeded.

Split testing into a separate task when:

- testing requires a different environment/tool boundary;
- it is broad integration/regression testing across multiple tasks;
- a specialist validation harness is needed;
- the implementation worker cannot execute the relevant proof;
- test creation itself is a substantial independent artifact.

A worker task that says "implement X" but leaves all proof to a later worker is easier to falsely complete and harder for the validator to judge.

---

# 12. Semantic size classes

Use size as a **routing hint**, not as a substitute for decomposition.

- `tiny` — mechanical/local change or bounded inspection with almost no unresolved design.
- `small` — one bounded behavior with local proof and limited discovery.
- `medium` — one coherent thesis with meaningful multi-file reasoning or moderate coupling.
- `large` — tightly coupled work that genuinely cannot be usefully decomposed without destroying understanding or proof.

Large should be rare.

Before marking a task `large`, explicitly test whether discovery, migration, integration, documentation, or validation portions can become separate dependent tasks.

Do not mark an overloaded task `large` merely to route it to a smarter model.

Routing cannot repair a bad task boundary.

---

# 13. Complexity triggers that should force a split review

Before finalizing a task, perform a split review if any of these are true:

- more than one user-visible behavior changes;
- more than one independent subsystem is modified;
- migration and new behavior are both required;
- compatibility with old behavior is substantial;
- worker must both discover architecture and implement a nontrivial change;
- acceptance spans unrelated test suites;
- task includes implementation plus broad refactor/cleanup;
- task includes an irreversible/external side effect;
- more than ~4 materially distinct acceptance criteria are needed;
- proof obligations require a different environment from implementation;
- failure could reasonably leave useful partial work that deserves independent acceptance;
- critic would need to evaluate large amounts of unrelated code to judge regressions.

These are heuristics, not hard numeric laws. The question is whether splitting improves attribution and reviewability.

---

# 14. Dependency design

Use `depends` only when the upstream task must be **accepted** before the downstream task can safely start.

Good dependency reasons:

- downstream consumes an interface/schema created upstream;
- implementation depends on discovery findings;
- migration depends on new format support;
- integration proof depends on all participating components;
- compatibility adapter depends on the new canonical path.

Do not serialize work merely because tasks share a theme.

Use semantic relations for non-blocking meaning:

- `derived_from`;
- `evidence_for`;
- `supersedes`;
- `invalidated_by`;
- `conflicts_with`;
- `related`;
- `discovered_from`.

Parallelism is a result of true independence, not a planning target.

---

# 15. Human-source provenance

Execution-critical human meaning must not survive only as planner paraphrase.

For material direction:

1. ensure the control plane recorded/updated the correct current directive;
2. preserve the direct source reference;
3. cite governing Intent ids;
4. keep the task instruction focused on the bounded outcome.

Example:

```text
source human:h-0017#L4-L13
intent REQ-ACTIVE-PROJECT
intent INV-NO-SILENT-FALLBACK
```

Do not copy the entire human conversation into every task.

Give workers the authority they need, not conversational archaeology.

---

# 16. Retrieval design

Retrieval declarations say what the worker needs to know.

They are not a disguised repository dump.

Prefer:

- exact files when known;
- narrow globs;
- specific durable findings from discovery tasks;
- relevant tests/interfaces/config;
- direct source/Intent refs.

Avoid broad selectors such as the entire repository unless the task is genuinely repository-wide.

## 16.1 Retrieval budget check

Before finalizing a task ask:

- Does the worker need to read several large files before it can even begin?
- Are key files likely to be truncated by the working-set budget?
- Does the task require both broad source context and extensive generated evidence?
- Could a discovery task summarize the relevant architecture first?

If yes, split or materialize findings.

A task can be semantically bounded yet context-unbounded.

That still makes it a poor worker task.

---

# 17. Capability-aware task design

StatefulClanker's direct-worker permissions narrow through:

```text
machine grants
    -> optional capability profile
    -> project policy
    -> role policy
    -> stage policy
    -> task-local policy
```

Do not use task policy to attempt to grant new machine authority.

Prefer least privilege, but do not under-provision a worker and then ask it to satisfy acceptance it cannot prove.

Examples:

- inspection: read/search + intent + read-only knowledge tools;
- coding: repo write/replace + relevant test command capability;
- critic: read/search + intent, normally no writes;
- specialist external-memory mutation: explicit narrow write capability.

Capability profile and task-local policy are task semantics. Changing them invalidates prior compiled work.

Provider-owned CLI harnesses retain their own internal permission model.

---

# 18. Backend routing and task feasibility

Do not design task semantics around a vendor/model unless the human explicitly requires it.

Normally:

- planner assigns semantic size;
- project/machine config routes size/role to a backend;
- task-specific provider override is exceptional.

However, the planner must consider **worker-class feasibility**.

If a task requires:

- long-horizon architectural reasoning;
- many mutually constrained edits;
- broad migration logic;
- difficult debugging with sparse evidence;

first attempt better decomposition.

If it genuinely cannot be decomposed, mark it medium/large so routing can reflect that reality.

Do not disguise a large reasoning task as several independent small tasks if their outputs must be jointly reasoned about to be correct.

---

# 19. SCPLAN 1

Prefer `SCPLAN 1`.

Example:

```text
SCPLAN 1
plan active-project
summary Restore the exact active project without silent substitution.
source human:h-0017#L4-L20
intent REQ-ACTIVE-PROJECT
intent INV-NO-SILENT-FALLBACK

task t-021
size small
title map active-project persistence
instruction Inspect current project selection and persistence paths. Materialize the exact write path, restore path, missing-project behavior, and relevant tests.
source human:h-0017#L4-L20
intent REQ-ACTIVE-PROJECT
capability-profile research-readonly
tool-deny builtin.run_command
retrieve src/StatefulClanker.Tray/*
accept findings identify the active-project write path
accept findings identify the restore path and current missing-project behavior
accept findings identify the relevant existing tests or state that none exist
end

task t-022
size small
title persist exact active project identity
depends t-021
instruction Persist the selected project's exact identity through the existing machine-local application state path. Do not implement restoration in this task.
source human:h-0017#L4-L20
intent REQ-ACTIVE-PROJECT
capability-profile coding
accept selecting a project updates the durable active-project identity
accept persistence uses the exact selected project identity
prove a focused persistence test observes the saved identity
end

task t-023
size small
title restore exact active project
depends t-021
depends t-022
instruction On startup restore the exact persisted active project. If it is unavailable, leave no active project rather than substituting another.
source human:h-0017#L4-L20
intent REQ-ACTIVE-PROJECT
intent INV-NO-SILENT-FALLBACK
capability-profile coding
accept restart restores the exact previously persisted project when available
accept unavailable persisted project produces no-active-project state
imply nearest-match or default substitution is forbidden
prove restart test with persisted project removed leaves no active project
end

task t-024
size small
title validate active-project restart lifecycle
depends t-023
instruction Exercise the complete select -> persist -> restart -> restore lifecycle and the missing-project case. Fix only test/integration defects directly attributable to these completed tasks.
source human:h-0017#L4-L20
intent REQ-ACTIVE-PROJECT
intent INV-NO-SILENT-FALLBACK
capability-profile coding
accept end-to-end restart restores the exact selected project
accept end-to-end missing-project restart does not substitute another project
end
```

Notice that discovery, persistence, restoration, and integration proof are separate reviewable units.

---

# 20. Review the plan from the critic's perspective

Before emitting the final plan, simulate a skeptical critic.

For every task ask:

- What obvious omission would I complain about?
- What regression is directly implied by this change?
- Is that regression relevant to this task, or should it be an implication/integration task?
- Does the instruction accidentally authorize unrelated cleanup?
- Is an important non-goal missing?
- Does the worker need to guess a design decision?
- Could a worker satisfy the literal acceptance while violating Intent?

Fix the task definition before dispatch where possible.

Do not respond by making acceptance universally broad.

The goal is to remove ambiguity, not create an impossible checklist.

---

# 21. Review the plan from the validator's perspective

For each acceptance criterion ask:

> What exact evidence will exist after the worker runs that lets a validator say PASS?

If the answer is vague, change the criterion or task.

A validator should not need to infer:

- whether an unrun test probably passes;
- whether unrelated code probably still works;
- whether a UI "looks right";
- whether a broad refactor is conceptually sound;
- whether a hidden external side effect occurred.

Provide executable or inspectable proof.

---

# 22. Rejection-aware replanning

When a task is rejected, do not immediately retry it unchanged.

Read critic/validator evidence and classify the rejection.

## Worker did not complete explicit scope

Possible response:

- split the task;
- reduce implementation surface;
- add discovery prerequisite;
- route to a stronger worker only after decomposition check.

## Critic found a real omitted implication

Possible response:

- add the missing implication/proof;
- create a dependent task if it is separable;
- revise the task if it is inseparable.

## Validator lacked evidence

Possible response:

- add focused tests/commands;
- grant the required bounded capability;
- create a validation task in the correct environment;
- make acceptance observable.

Do **not** simply rewrite "PASS" wording.

## Validator failed because one separable criterion failed

This is strong evidence the task was too broad.

Split remaining behavior so completed work does not need to be redone.

## Repeated failures with the same compiled input

Treat as a planning problem until evidence shows otherwise.

Change the graph, context, proof surface, backend class, or authority.

Do not burn worker attempts on the same task definition.

## Reviewer complains outside task scope

Determine whether the complaint is:

- an actual governing Intent/invariant;
- a direct regression caused by the task;
- a legitimate project-level concern better handled separately;
- reviewer overreach unsupported by current authority.

Do not automatically expand every task to satisfy reviewer speculation.

If reviewer overreach appears systematic, that is evidence to inspect critic/validator prompting separately rather than endlessly bloating plans.

---

# 23. Plan-level integration checkpoints

Individually passing tasks can compose into a broken project.

Add integration checkpoints when:

- several tasks modify the same lifecycle;
- parallel branches affect interacting components;
- a migration spans old/new code paths;
- separate backend/frontend or producer/consumer changes must agree;
- project build/test behavior can fail only after composition.

Do not add an integration task after every trivial pair of tasks.

Use them at meaningful convergence points.

Project-level review remains useful for global health; task planning should make failures attributable before they reach that boundary.

---

# 24. Avoid cleanup hitchhikers

Workers are more likely to be rejected when a task mixes required work with opportunistic cleanup.

Do not bundle:

- unrelated refactors;
- style cleanup;
- dependency upgrades;
- documentation rewrites;
- test framework changes;
- generalized abstraction work;

unless they are required to implement the bounded outcome.

If useful, create separate follow-up tasks.

The critic sees extra changes as regression surface.

---

# 25. Migrations deserve explicit phases

For state/schema/API migrations, prefer explicit stages:

1. establish new representation/interface;
2. make current code able to read/use it;
3. migrate existing state/callers;
4. remove legacy path only after compatibility proof;
5. integration validation.

Do not ask one worker to rewrite the world atomically unless compatibility truly requires it.

Use temporary dual-read/dual-write behavior only when Intent permits it; do not invent compatibility requirements.

---

# 26. External side effects

Tasks involving deployments, external services, publishing, tickets, email, cloud mutation, or destructive actions require additional planning discipline.

Separate:

- preparation/change creation;
- validation;
- authorized external action;
- post-action verification.

Do not make a bounded worker both decide whether an external action is appropriate and perform it unless human authority already resolved that decision.

Define idempotency or post-action evidence where retries could duplicate effects.

---

# 27. Documentation tasks

Documentation should usually be separate from implementation when it has its own substantial audience/scope.

Keep docs in the implementation task when they are a tiny required interface update tightly coupled to the change.

Do not let "update all docs" turn a bounded implementation into a repository-wide review surface.

Name the exact docs that must change.

---

# 28. Refinement and fanout

Current task records persist:

- `implications`;
- `proofObligations`;
- `refinementStatus`;
- `refinementDepth`;
- `parentTaskId`;
- `childTaskIds`.

Treat refinement lineage as orchestration metadata.

Do not hand-edit it.

Do not assume a generic automatic fanout/refinement MCP tool exists unless the active control plane exposes one.

When performing planner-side refinement:

1. inspect the parent task;
2. identify separable implementation/proof units;
3. preserve governing sources/Intent;
4. create children with explicit dependencies;
5. ensure no required parent behavior disappears;
6. preserve lineage where the supported plan/task surface allows it;
7. invalidate/replace obsolete work through supported control-plane operations.

Fanout is useful when it improves independent completion and validation.

Fanout is harmful when every child needs the same large mental model.

---

# 29. Plan quality checklist

Before applying a plan, check every task:

- Is there one primary implementation thesis?
- Can a cold-start worker begin without rediscovering the whole subsystem?
- Is unresolved product/design ambiguity absent?
- Are source and Intent refs present where material?
- Is retrieval bounded?
- Are dependencies real acceptance dependencies?
- Is size honest?
- Are required capabilities sufficient but narrow?
- Are acceptance criteria observable and minimal?
- Are second-order implications captured without turning into infinite hardening?
- Is each proof obligation executable or inspectable?
- Could a validator prove PASS from expected evidence?
- Could a critic reject it for an obvious omission already visible now?
- If 80% succeeds, is the remaining 20% separable enough that the task should be split?
- Is broad integration proof deferred to an appropriate convergence task?
- Is unrelated cleanup excluded?
- Will failure be attributable to one meaningful cause?

If several answers are no, revise the task before dispatch.

---

# 30. Plan-level quality checklist

Before considering the graph ready:

- Does it cover every current Intent requirement relevant to the requested scope?
- Are non-goals preserved?
- Are major unknowns resolved by discovery before implementation?
- Are convergence/integration points tested after dependent work completes?
- Can useful independent tasks run in parallel?
- Will invalidating one upstream task invalidate only genuinely dependent work?
- Is any single worker being asked to own an entire subsystem rewrite without necessity?
- Are reviewers being asked to judge bounded changes rather than project-wide goodness every cycle?
- Does the graph create accepted progress in small enough increments that rejection does not throw away large amounts of work?

---

# 31. Context faults and replanning

Repeated `CONTEXT_REQUEST` means retrieval or decomposition is wrong.

Respond by:

- adding the specific missing evidence;
- narrowing the task;
- creating a discovery prerequisite;
- persisting architectural findings;
- correcting capability/tool access;
- clarifying Intent.

Do not indefinitely increase prompt size.

A context fault can indicate that two concerns thought to be separable are actually tightly coupled; in that case merge or restructure them deliberately.

---

# 32. Completion discipline

A task graph is good when disposable workers can advance it without reconstructing the original conversation, critics can assess each change without guessing its intended scope, validators can prove bounded claims from available evidence, and later orchestrators can trace important work through:

```text
task
    -> Intent
    -> Current Human Directive
    -> human source evidence
```

The planner should minimize rejection **without weakening correctness**.

The target is not "make validators say PASS."

The target is:

> make each worker assignment small, explicit, and provable enough that a correct implementation naturally earns PASS, and a FAIL identifies one useful thing to fix.

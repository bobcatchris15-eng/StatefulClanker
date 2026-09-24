# Planner module research slice

## Responsibility boundary

Planning is a separate, project-scoped subsystem.

Human <-> Interrogator <-> StatefulClanker.Planner -> accepted handoff -> Operator -> implementation workers.

Planner owns:
- the planning/execution phase barrier;
- quiescence and the stable planning baseline;
- structured questions and answers;
- candidate plan/Intent artifacts;
- accepted handoff manifests;
- a planning inference budget policy.

Planner does not currently:
- dispatch implementation workers;
- mutate the live task graph;
- replace Intent;
- run a resident daemon.

That last omission is intentional. Unlike routing, planning has no useful idle background responsibility yet.

## Durable layout

The Planner writes only under the managed project's .statefulclanker/planning directory:

    planning/
      active.json
      sessions/<session-id>/
        session.json
        baseline.json
        questions/
        candidates/
        handoffs/
        closed.json

Presence of planning/active.json is itself the dispatch barrier. The execution harness does not need to understand the Planner's internal state machine.

## Flow

    EXECUTING
        |
        | begin
        v
    QUIESCING
        |
        | settle after no task is running/reviewing/validating
        v
    PLANNING
        |
        | candidate
        v
    REVIEW
        |
        | accept
        v
    HANDOFF
        |
        | planning_control apply
        | journaled replacement transaction + verified release
        v
    EXECUTING

There is deliberately no planning-plus-execution state.

## Barrier first, baseline second

Begin writes the active planning barrier before it inspects outstanding implementation work. It also asks resident Autofill to pause, preserving whether Autofill had already been paused by the user.

Begin never claims the project is already stable. It always enters quiescing.

Settle is a separate operation. It refuses to capture a baseline while any task is running, reviewing, or validating.

This gives the transition a little inertia, but makes the boundary easy to reason about and recover after process/session loss.

## Baseline

The first baseline records:
- Git HEAD;
- dirty paths;
- durable state revision;
- Intent revision and file hash;
- current active plan id;
- task status counts;
- a hash of the task-record set.

The baseline is evidence of what the planners reasoned against.

## Questions

Planner questions currently carry:
- text;
- rationale;
- impact;
- owner;
- blocking flag;
- status;
- answer.

The Interrogator decides which uncertainty is worth asking the human. Planner only persists the channel.

Candidate acceptance fails while any blocking question remains open.

## Candidate and handoff

Candidate creation copies and hashes:
- one plan artifact;
- optionally one Intent artifact.

Acceptance turns that candidate into an inert handoff manifest and leaves the execution barrier in place.

Normal completion is now `planning_control apply`. The execution runtime validates the settled baseline, builds the complete replacement graph off to the side, journals backups, commits project goal/directives/Intent/plan/tasks/state under the canonical state mutex, and only then asks Planner to release the barrier.

The old `plan_apply` / `plan_import` paths remain additive compatibility machinery outside planning. They are blocked while isolated planning owns the project.

Low-level Planner `release` still exists as a recovery seam if the graph transaction committed but normal combined apply/release was interrupted. It verifies the active plan plus the exact `lastPlanningHandoffId` / `lastPlanningTransactionId` lineage before removing the barrier.

## Conversation entrypoints

Bundled Pi now has an explicit conversation role instead of guessing from prompt wording.

Normal execution/control:

    pi\pi.cmd

This launches the Operator role and only the Operator skill.

Deliberate planning/replanning:

    pi\interrogate.cmd

This launches Pi with:

- `STATEFULCLANKER_PI_ROLE=interrogator`;
- the Interrogator conversation skill;
- the decomposition specialist skill.

The Pi extension no longer contains a prompt-regex "planning intent" switch. The role is selected at launch and remains stable for that conversation.

Interrogator uses one MCP surface, `planning_control`, for Planner state:

    status -> begin -> settle -> ask/answer -> candidate -> accept -> apply

The ordinary `control_snapshot` also exposes `planning.active`, `planning.phase`, session id, baseline path, and accepted handoff id when available. This makes phase ownership observable to any control-plane client without requiring Planner-specific filesystem knowledge.

## Transactional replacement boundary

The first replacement transaction is implemented.

The transaction owns these live targets as one semantic unit:

- `state.json`;
- active `tasks/`;
- `plans/`;
- `intent/`;
- `directives/`;
- directive-origin `input/` sources.

Before touching them it verifies the handoff hashes and the settled baseline: active plan, goal, task-graph bytes, Intent bytes, current-directive bytes, Git HEAD, and dirty/untracked file content. Any drift rejects the handoff before mutation.

A complete replacement graph is staged and validated. Missing dependency targets and dependency cycles fail before commit.

Prior tasks receive one transaction disposition:

- `preserved-complete`: same stable id, identical definition, and compatible governing semantics;
- `carried-reset`: identical/compatible incomplete work, with runtime attempt/review state reset;
- `replaced`: same id but changed definition or governing semantics;
- `dependency-invalidated`: the task itself still matched, but one of its prerequisites did not remain complete; this invalidation propagates transitively;
- `new`: new id;
- `retired-complete` / `invalidated-removed`: old id omitted from the replacement graph.

The active task directory contains only the new graph. Historical/tombstoned nodes do not remain active merely to preserve provenance; the transaction backup and plan record preserve the old graph and disposition table.

Reuse is deliberately conservative. Explicit task Intent refs are compared clause-by-clause. Governing staged directive changes invalidate tasks that cite the old directive source or overlap the task's Intent refs. Untraced directive changes invalidate untraced completion. A changed project goal invalidates untraced completion. Finally, preserved-complete tasks are closed over dependencies: if any prerequisite becomes fresh, every completed dependent becomes fresh transitively.

Commit uses a write-ahead journal under `.statefulclanker/transactions/<id>/` plus full backups. Journal state advances:

    staging -> prepared -> committing -> committed

If startup finds a journal stuck in `committing`, it restores every backed-up target and marks the transaction `rolled_back`. A crash after all file copies but before the final committed marker therefore rolls back rather than guessing that the transaction was complete.

A committed handoff is idempotent: retrying apply before Planner release returns the existing committed transaction.

## Research test

On a Windows development checkout with the .NET SDK:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\PlanningHandoffTransaction.Tests.ps1

This integration test exercises:

- stable completed-task preservation;
- Intent/directive invalidation;
- transitive downstream invalidation;
- omitted-task retirement;
- staged project-goal replacement;
- baseline-drift refusal before mutation;
- idempotent handoff application;
- the real MCP `planning_control apply` combined apply/release path;
- startup rollback when a synthetic crash removes `state.json` during `committing`.

## Multi-agent planning shape

Keep the first planning swarm simple:

1. Intent normalization.
2. Architecture pass.
3. Parallel implication passes with distinct jobs.
4. Semantic decomposition using the planner specialist skill.
5. Adversarial task inspection.
6. One reconciliation/compression pass.

Do not have several agents mutate one shared draft concurrently.
Do not have several agents produce complete plans and vote.
Do not recursively let agents interview each other.

Have specialist passes return structured observations/deltas to one reconciler.

Initial token policy is parity: planning target approximately equals expected implementation inference. The session stores a 1.0 planning-to-execution ratio and can store an execution token estimate. Enforcement should wait for an actual planning inference runner with measured token receipts.

## Simple robustness findings

1. The execution harness only needs one new concept: an active planning barrier blocks dispatch.
2. The user-facing planning persona should be separate from the execution Operator.
3. Planning does not need a daemon yet.
4. Planning should own questions as durable data, not as worker-message plumbing.
5. Quiescence should be a real phase rather than a prompt convention.
6. Accepted planning ends in a handoff, not direct task mutation by Planner.
7. The execution runtime applies that handoff as one journaled replacement transaction.
8. Equal planning tokens should be a budget target, not equal token quotas for every pass.
9. One reconciler is simpler and safer than consensus voting.
10. Planning inertia is useful when it keeps the project from changing underneath implementation.

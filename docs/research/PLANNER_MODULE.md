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
        | future transactional execution-side apply
        | release after state.activePlanId proves application
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

The Planner intentionally does not call the existing additive plan import path. A real replan can invalidate or replace existing graph structure, so the correct next boundary is a transactional execution-side apply operation rather than teaching the research module to edit live tasks piecemeal.

Release currently requires an applied plan id that matches state.activePlanId. This prevents the Planner from reopening implementation merely because somebody generated a plan file.

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
6. Accepted planning should end in a handoff, not direct task mutation.
7. Replanning needs a transactional graph-apply boundary before this can safely replace active plans.
8. Equal planning tokens should be a budget target, not equal token quotas for every pass.
9. One reconciler is simpler and safer than consensus voting.
10. Planning inertia is useful when it keeps the project from changing underneath implementation.

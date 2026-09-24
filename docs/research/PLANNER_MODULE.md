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

    status -> begin -> settle -> ask/answer -> candidate -> accept -> release

The ordinary `control_snapshot` also exposes `planning.active`, `planning.phase`, session id, baseline path, and accepted handoff id when available. This makes phase ownership observable to any control-plane client without requiring Planner-specific filesystem knowledge.

## Deliberately incomplete boundary

The first research slice stops before **transactional plan application**.

An accepted handoff is intentionally inert. The Planner does not yet replace/rewrite live tasks, because the existing `plan_apply` / `plan_import` path is additive and does not define safe semantics for:

- completed tasks that remain valid;
- pending tasks invalidated by the replan;
- task ids that are replaced or superseded;
- downstream invalidation;
- Intent replacement plus graph replacement as one atomic operation;
- rollback if applying the new graph fails halfway through.

Until that transaction exists, the old import path remains compatibility machinery, not the replanning mechanism. The research flow therefore proves the phase barrier, stable baseline, question channel, candidate staging, and handoff boundary without pretending graph replacement is solved.

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

# StatefulClanker planner skill

Use this skill to turn the authoritative Intent Contract and durable human-source evidence into a task graph designed for disposable cold-start workers.

## Role

The planner is part of the **conversational plane**. Semantic decomposition is model work.

Do not delegate task decomposition to regexes, file counts, line counts, arbitrary token thresholds, or repository partitioning heuristics. Those mechanisms may help retrieve context; they do not decide what constitutes a coherent unit of work.

The authoritative Intent Contract outranks the plan. Human-source artifacts preserve the original evidence behind that contract.

## Before planning

Read:

- current project goal
- authoritative Intent Contract
- material human-source references
- accepted decisions/non-goals
- current task graph and accepted dependency outcomes

If two competent implementations could satisfy the visible request in materially different ways, return the ambiguity to the human-facing orchestrator for clarification rather than choosing silently.

When the host exposes a questionnaire/structured-question facility, the orchestrator should use it aggressively for material ambiguity.

## Planning objective

Produce a graph that remains executable after the current conversation disappears.

Optimize for:

- preservation of human intent
- small coherent cold-start tasks
- explicit dependencies
- objective acceptance boundaries
- bounded retrieval
- recoverability after failed workers
- selective invalidation
- provider portability
- cheap worker context

A plan is durable execution structure, not prose a future worker is expected to remember.

## Semantic decomposition

Start from the desired end state and derive independently verifiable outcomes.

For each candidate task ask:

1. Can a fresh worker understand this without chat history?
2. Is there one primary outcome?
3. Can success/failure be evaluated independently?
4. Which intent requirements/constraints/invariants govern it?
5. Which direct human-source artifact(s) materially justify it?
6. What must already be accepted before it starts?
7. What evidence/context is actually needed?
8. Does it require a materially different specialist perspective?
9. Does it contain several outcomes that could be validated separately?
10. Would splitting it force each worker to reconstruct the same tightly coupled state?

Split when separation creates independently understandable and independently verifiable work.

Do **not** split solely because:

- a file is long
- a directory is large
- the diff may exceed N lines
- a token budget was crossed
- a regex found several sections

Those are context-management signals, not semantic task boundaries.

## Task size classes

Assign a semantic size hint:

- `tiny` — mechanical/local change or bounded inspection
- `small` — one bounded concern suitable for fast/cheap disposable workers
- `medium` — coherent multi-file feature/debugging task with nontrivial reasoning
- `large` — tightly coupled work that resisted useful decomposition

Prefer `tiny`/`small` when the boundaries are natural. Do not create dozens of microscopic tasks whose workers all have to rediscover the same coupled context.

Size is a routing hint, not a deterministic measurement and not a provider name. Machine-local configuration may map `small` to a Flash/Haiku/Luna-class CLI today and something entirely different tomorrow.

## Human-source provenance

Execution-critical user meaning must not survive only as planner paraphrase.

For material direction:

1. ensure the conversational orchestrator persisted the relevant direct input or durable document
2. cite that source in the plan/task
3. cite governing intent ids where available
4. keep the task instruction focused on the bounded outcome

Example provenance:

```text
source human:h-0017#L4-L13
intent REQ-ACTIVE-PROJECT
intent INV-NO-SILENT-FALLBACK
```

If a long explanation is necessary to make a task intelligible, persist that explanation as an artifact and reference it rather than bloating every task.

## Compact plan format

The target worker-facing authoring format is `SCPLAN 1`, documented in `docs/TASK_RECORD_FORMAT.md`.

When the connected StatefulClanker runtime advertises compact-plan support, prefer it to JSON.

Example:

```text
SCPLAN 1
plan active-project
summary Replace hidden default-project semantics with an explicit active project.
source human:h-0017#L4-L20
intent REQ-ACTIVE-PROJECT

task t-021
size small
title persist project registry
instruction Store known projects in machine-local app state and expose stable lookup by project id/root.
source human:h-0017#L4-L20
intent REQ-ACTIVE-PROJECT
retrieve desktop/*
accept registry survives application restart
accept project-local state is not used for machine integration settings
end

task t-022
size small
title restore last active project
depends t-021
instruction Resolve and open the last active project on app startup; show no-active-project when it is missing.
source human:h-0017#L4-L20
intent REQ-ACTIVE-PROJECT
accept existing last active project is restored
accept missing project never causes silent substitution
end
```

Until compact-plan parsing is implemented in the runtime being driven, emit the existing JSON importer schema instead. Do not claim compact format support that the runtime does not have.

## JSON compatibility schema

For older/current runtimes, use:

```json
{
  "name": "short plan name",
  "summary": "human-readable plan intent",
  "tasks": [
    {
      "id": "stable-id",
      "title": "bounded outcome",
      "instruction": "cold-start instruction",
      "acceptance": ["observable condition"],
      "dependsOn": [],
      "relations": [],
      "retrieval": [],
      "evidence": [],
      "provider": null,
      "role": "worker",
      "humanGate": false
    }
  ]
}
```

Keep equivalent semantic source/intent references in the instruction or a referenced artifact until the runtime exposes dedicated fields.

## Scheduling dependencies versus semantic relations

Use `dependsOn` / `depends` only when another task must be accepted before this task can run.

Use semantic relations for provenance and causality that should survive without serializing execution:

- `discovered_from`
- `derived_from`
- `evidence_for`
- `supersedes`
- `invalidated_by`
- `conflicts_with`
- `related`

Do not make every relationship a scheduling blocker.

## Retrieval

Retrieval declarations say what a task needs; they are not a disguised repository dump.

Prefer exact files/globs/artifacts when known. When a semantic investigation is needed, consider an inspection task that materializes a small durable artifact, then make implementation depend on that result.

Mechanical chunking is appropriate inside retrieval/document processing. It is not how the plan decides task boundaries.

## Acceptance criteria

Good criteria are observable:

- a command exits successfully
- a defined test/probe passes
- a file exposes a specified interface
- a reproduction no longer fails
- generated output matches a schema
- a behavior changes as specified
- an invariant/non-goal remains demonstrably preserved

Avoid vague criteria such as `looks good`, `be robust`, `finish it`, or `understand the code`.

Passing local criteria is insufficient when the result violates the Intent Contract.

## Provider routing

Do not design tasks around a particular vendor model unless the human explicitly requires that provider.

Normally:

- planner assigns a semantic `size` class
- machine-local StatefulClanker configuration maps size/role to configured provider CLIs
- task-specific `provider` is an exception/override

The execution path remains ordinary provider-owned command lines accepting a prompt file or stdin.

## Context faults and replanning

Repeated `CONTEXT_REQUEST` results are feedback about retrieval or decomposition.

Choose among:

- add missing evidence
- improve the task boundary
- create a prerequisite inspection task
- persist a missing design artifact
- clarify intent

Do not merely grow every prompt indefinitely.

`INTENT_QUESTION` and `INTENT_CONFLICT` go back to the orchestrator/human authority. The planner must not invent a resolution.

## Completion discipline

A task graph is good when disposable workers can advance it without reconstructing the original conversation and when later orchestrators can trace important work back through intent to human-source evidence.

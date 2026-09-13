# StatefulClanker planner skill

Use this skill to turn a goal into a task graph designed for cold-start, one-shot workers operating through StatefulClanker.

## Objective

Produce plans that remain executable after the conversational session disappears. Optimize for low hidden context, explicit dependencies, cheap retrieval, objective validation, selective invalidation, and recoverability from failed worker calls.

A plan is not prose the worker is expected to remember. It is structured input to a context compiler and state-transition engine.

## Planning method

Start from the desired end state and derive observable acceptance conditions. Decompose backward into bounded tasks.

For each candidate task ask:

1. Can a fresh worker understand this with no chat history?
2. Is there one primary outcome?
3. What exact files, symbols, docs, errors, artifacts, or dependency receipts must be retrieved?
4. What must already be accepted before it starts?
5. Which facts/decisions/evidence will this task's plan depend upon?
6. How can another process independently determine whether it succeeded?
7. If this work discovers another task, how should that causal relation be preserved?
8. Does it contain a genuine human decision?

If a task needs a long narrative recap to make sense, decompose it further or persist the missing context as a project artifact.

## Task schema

Emit JSON compatible with StatefulClanker's plan importer:

```json
{
  "name": "short plan name",
  "summary": "human-readable intent",
  "tasks": [
    {
      "id": "optional-stable-id",
      "title": "bounded outcome",
      "instruction": "cold-start instruction",
      "acceptance": ["observable condition"],
      "dependsOn": [],
      "relations": [
        {"type": "discovered_from", "target": "task-or-artifact-id"}
      ],
      "retrieval": ["file/glob or explicit retrieval intent"],
      "evidence": ["explicit evidence selectors if already known"],
      "provider": null,
      "role": "worker",
      "humanGate": false
    }
  ]
}
```

## Scheduling dependencies vs semantic relations

Use `dependsOn` only when the target must be complete before the task is runnable.

Use `relations` for meaningful structure that should survive without changing readiness. Useful types include:

- `discovered_from`
- `derived_from`
- `evidence_for`
- `supersedes`
- `invalidated_by`
- `conflicts_with`
- `related`

Do not turn every relationship into a blocker. Preserve causality without serializing unrelated work.

## Decomposition rules

Prefer a task boundary when any of these materially changes:

- required expertise
- subsystem/files
- validation method
- dependency/read set
- provider/tool choice
- risk level
- human decision boundary

Do not decompose merely by number of files if one atomic behavioral change naturally spans them.

A task should fit into one coherent cold-start working set whenever practical. If it cannot, consider creating an inspection/research artifact first and making the implementation task depend on that artifact-producing task.

## Acceptance criteria

Good acceptance criteria are externally checkable:

- a command exits 0
- specified tests/probes pass
- a file exposes a defined interface
- a reproduction no longer fails
- generated output matches a schema
- an observable behavior changes as specified

Avoid criteria such as "looks good," "is robust," "finish implementation," or "understand the code."

When subjective quality genuinely matters, make the critic criteria explicit rather than pretending they are deterministic acceptance checks.

## Retrieval intent

Retrieval declarations describe what the task needs; they are not a disguised repository dump.

Prefer explicit selectors and artifacts when known. Examples:

- `src/cache/*`
- `docs/cache.md`
- `tests/cache*.ps1`
- a persisted implementation note from an upstream inspection task
- the exact config file governing a behavior

The current harness resolves filesystem selectors deterministically. If a semantic query is useful but not directly resolvable by today's engine, first create a bounded inspection/research task that materializes the result as an artifact.

## Plan freshness

Design tasks so stale assumptions can be invalidated selectively.

A downstream task should depend on the smallest upstream task whose accepted result it truly requires. Avoid broad "everything depends on planning" edges when only one decision or inspection output matters.

This makes later retries/supersession invalidate a narrow subgraph rather than the entire project.

## Context-fault-aware planning

If prior runs repeatedly request the same missing context, revise the plan or retrieval declaration rather than repeatedly increasing prompt size.

A context fault can indicate:

- omitted evidence
- ambiguous task boundary
- missing prerequisite inspection
- hidden decision dependency
- working-set pressure

Treat it as feedback about the plan/compiler interface.

## Human gates

Use `humanGate: true` only for actual choices: product behavior, destructive action, credentials, cost/risk tradeoffs, or unresolved preference.

Missing technical knowledge is normally a research/inspection task, not a human gate.

## Output discipline

Return the plan first as valid JSON. Any human explanation comes after it and must not contain execution-critical information absent from the JSON.

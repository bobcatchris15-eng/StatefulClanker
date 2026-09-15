# StatefulClanker planner skill

Use this skill to turn an authoritative Intent Contract into a task graph designed for cold-start, one-shot workers operating through StatefulClanker.

## Objective

Produce plans that remain executable after the conversational session disappears while preserving the user's actual intent across worker generations. Optimize for low hidden context, explicit dependencies, cheap retrieval, objective validation, selective invalidation, recoverability from failed worker calls, and resistance to semantic drift.

A plan is not prose the worker is expected to remember. It is structured input to a context compiler and state-transition engine.

The authoritative Intent Contract outranks the plan. Planning may decompose or operationalize intent, but it may not silently weaken, reinterpret, or replace it.

## Before planning

Read the current Intent Contract. If a material requirement is ambiguous enough that two competent implementations could diverge, do not resolve that ambiguity yourself. Return the ambiguity to the orchestrator for user interrogation and intent revision.

A planner may identify missing requirements. It may not author user intent by implication.

## Planning method

Start from the desired end state and success definition in the Intent Contract, then derive observable acceptance conditions. Decompose backward into bounded tasks.

For each candidate task ask:

1. Can a fresh worker understand this with no chat history?
2. Is there one primary outcome?
3. Which requirements, constraints, invariants, non-goals, decisions, and preferences from the Intent Contract govern it?
4. What exact files, symbols, docs, errors, artifacts, or dependency receipts must be retrieved?
5. What must already be accepted before it starts?
6. Which facts/decisions/evidence will this task's plan depend upon?
7. How can another process independently determine whether it succeeded?
8. If this work discovers another task, how should that causal relation be preserved?
9. Does it contain a genuine human decision or unresolved intent question?

If a task needs a long narrative recap to make sense, decompose it further or persist the missing context as a project artifact. Never use task prose as the only durable home for an execution-critical user requirement.

## Task schema

Emit JSON compatible with StatefulClanker's plan importer:

```json
{
  "name": "short plan name",
  "summary": "human-readable intent of this plan under the Intent Contract",
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

The current runtime compiles the entire authoritative Intent Contract into every worker packet, so tasks do not need to duplicate it. Task wording should state the bounded implementation outcome and may cite intent IDs/names for clarity, but duplicated prose is not authoritative over the contract.

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
- materially different intent constraints

Do not decompose merely by number of files if one atomic behavioral change naturally spans them.

A task should fit into one coherent cold-start working set whenever practical. If it cannot, consider creating an inspection/research artifact first and making the implementation task depend on that artifact-producing task.

## Acceptance criteria

Good acceptance criteria are externally checkable and must not contradict the Intent Contract:

- a command exits 0
- specified tests/probes pass
- a file exposes a defined interface
- a reproduction no longer fails
- generated output matches a schema
- an observable behavior changes as specified
- an invariant or non-goal remains demonstrably preserved

Avoid criteria such as "looks good," "is robust," "finish implementation," or "understand the code."

When subjective quality genuinely matters, make the critic criteria explicit rather than pretending they are deterministic acceptance checks.

Passing a task's local acceptance criteria is insufficient if the result violates the Intent Contract.

## Retrieval intent

Retrieval declarations describe what the task needs; they are not a disguised repository dump.

Prefer explicit selectors and artifacts when known. Examples:

- `src/cache/*`
- `docs/cache.md`
- `tests/cache*.ps1`
- a persisted implementation note from an upstream inspection task
- the exact config file governing a behavior

The current harness resolves filesystem selectors deterministically. If a semantic query is useful but not directly resolvable by today's engine, first create a bounded inspection/research task that materializes the result as an artifact.

The Intent Contract itself is supplied by the compiler as authoritative context and should not be added as an ordinary retrieval selector.

## Plan freshness

Design tasks so stale assumptions can be invalidated selectively.

A downstream task should depend on the smallest upstream task whose accepted result it truly requires. Avoid broad "everything depends on planning" edges when only one decision or inspection output matters.

This makes later retries/supersession invalidate a narrow subgraph rather than the entire project.

An Intent Contract revision is different: it changes specification authority. The orchestrator should determine which plan/task branches remain valid and selectively replace or invalidate those whose meaning changed.

## Context-fault-aware planning

If prior runs repeatedly request the same missing context, revise the plan or retrieval declaration rather than repeatedly increasing prompt size.

A context fault can indicate:

- omitted evidence
- ambiguous task boundary
- missing prerequisite inspection
- hidden decision dependency
- working-set pressure

Treat it as feedback about the plan/compiler interface.

`INTENT_QUESTION` and `INTENT_CONFLICT` are not ordinary context faults. Return them to the orchestrator; they require authoritative resolution, not a planner guess.

## Human gates

Use `humanGate: true` only for actual choices: product behavior, destructive action, credentials, cost/risk tradeoffs, or unresolved preference.

Missing technical knowledge is normally a research/inspection task, not a human gate. Missing user intent is an orchestrator interrogation/Intent Contract problem, not something a worker or planner should invent.

## Output discipline

Return the plan first as valid JSON. Any human explanation comes after it and must not contain execution-critical information absent from either the JSON or the authoritative Intent Contract.

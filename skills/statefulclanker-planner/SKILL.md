# StatefulClanker planner skill

Use this skill to turn **Current Human Directives**, the reconciled Intent Contract, and durable source evidence into a task graph designed for disposable cold-start workers.

## Role

The planner is part of the conversational control plane. Semantic decomposition is model work.

Do not delegate task decomposition to regexes, file counts, line counts, arbitrary token thresholds, or repository partitioning heuristics. Those mechanisms may help retrieval; they do not decide coherent work boundaries.

Authority order is:

```text
Current Human Directives -> reconciled Intent -> plan -> task
```

Verbatim human-source artifacts remain recoverable evidence behind current directives and Intent.

## Before planning

Read:

- current project goal;
- Current Human Directives and reconciliation status;
- reconciled Intent Contract;
- material human-source references;
- accepted decisions/non-goals;
- current task graph and accepted dependency outcomes;
- worker capability policy/profiles when tool access affects decomposition.

If two competent implementations could satisfy the visible request in materially different ways, return the ambiguity to the human-facing control plane rather than choosing silently. Use structured questionnaire tools aggressively when available.

## Planning objective

Produce a graph that remains executable after the current conversation disappears.

Optimize for preservation of human intent, coherent cold-start tasks, explicit dependencies, observable acceptance criteria, bounded retrieval, selective invalidation, backend portability, and only the worker capabilities actually needed.

A plan is durable execution structure, not prose a future worker is expected to remember.

## Semantic decomposition

For each candidate task ask:

1. Can a fresh worker understand it without chat history?
2. Is there one primary outcome?
3. Can success/failure be evaluated independently?
4. Which Intent requirements/constraints/invariants govern it?
5. Which current directive/source evidence materially justifies it?
6. What accepted work must precede it?
7. What context/evidence is actually needed?
8. Does it need a materially different specialist perspective or tool boundary?
9. Could it be completed safely by a smaller/read-only worker?
10. Would splitting force workers to reconstruct the same tightly coupled state?

Split when separation creates independently understandable and independently verifiable work. Do not split merely because a file/diff/repository/context is large.

## Semantic size classes

- `tiny` — mechanical/local change or bounded inspection
- `small` — one bounded concern suitable for fast/cheap disposable workers
- `medium` — coherent multi-file or nontrivial reasoning task
- `large` — tightly coupled work that resisted useful decomposition

Size is a routing hint, not a deterministic measurement or provider name. Machine/project configuration may route one class to a local API model and another to a provider CLI harness.

## Human-source provenance

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

## Capability-aware task design

StatefulClanker's inherent/direct-model worker permissions narrow through:

```text
machine grants -> optional capability profile -> project -> role -> stage -> task-local policy
```

Do not use task policy to attempt to grant new machine authority.

Prefer a reusable named profile when several tasks need the same environment:

```text
capability-profile research-readonly
```

Use task-local narrowing for exceptional restrictions:

```text
tool-allow builtin.read_file
tool-allow builtin.search_text
tool-allow intent.*
tool-allow mcp.toaster.search
tool-deny builtin.run_command
```

Examples of useful boundaries:

- inspection/research task: read/search + intent + read-only knowledge tools;
- coding task: repo edit/test tools, perhaps no external memory mutation;
- critic: read/search + intent, no writes;
- lesson-writing/specialist task: explicitly authorized knowledge-store mutation where intended.

Capability profile and task-local policy are task semantics: changing them invalidates prior compilation/results through the task-definition hash.

Provider-owned CLI harnesses retain their own internal permission model; capability profiles govern StatefulClanker's inherent worker loop.

## SCPLAN 1

Prefer the compact `SCPLAN 1` format supported by the runtime.

```text
SCPLAN 1
plan active-project
summary Replace hidden default-project semantics with an explicit active project.
source human:h-0017#L4-L20
intent REQ-ACTIVE-PROJECT

task t-021
size small
title inspect project persistence behavior
instruction Inspect the current persistence path and identify the bounded changes needed.
source human:h-0017#L4-L20
intent REQ-ACTIVE-PROJECT
capability-profile research-readonly
tool-deny builtin.run_command
retrieve src/StatefulClanker.Tray/*
accept findings identify the exact current persistence path
end

task t-022
size small
title restore last active project
depends t-021
instruction Implement restoration of the exact last active project with explicit missing-project behavior.
source human:h-0017#L4-L20
intent REQ-ACTIVE-PROJECT
capability-profile coding
accept existing last active project is restored
accept missing project never causes silent substitution
end
```

Dedicated task fields include `size`, `source`, `intent`, `capability-profile`, `tool-allow`, and `tool-deny`. JSON import remains a compatibility path, not the preferred planner output.

## Dependencies versus semantic relations

Use `depends` only when another task must be accepted first. Use typed semantic relations such as `derived_from`, `evidence_for`, `supersedes`, `invalidated_by`, `conflicts_with`, or `related` when the relationship should not serialize execution.

## Retrieval

Retrieval declarations say what a task needs; they are not a disguised repository dump.

Prefer exact files/globs/artifacts when known. When discovery is required, create a bounded inspection/research task that materializes durable findings, then make implementation depend on those findings where appropriate.

Mechanical chunking belongs inside retrieval/document processing, never in semantic task decomposition.

## Acceptance criteria

Good criteria are observable: a command/test passes, an interface exists, a reproduction stops failing, output matches a schema, specified behavior changes, or an invariant/non-goal remains demonstrably preserved.

Avoid `looks good`, `be robust`, `finish it`, or `understand the code`.

Passing local criteria is insufficient if the result violates Current Human Directives or reconciled Intent.

## Backend routing

Do not design tasks around a vendor/model unless the human explicitly requires it.

Normally:

- planner assigns semantic `size` and optional capability profile;
- machine/project StatefulClanker configuration maps size/role to a worker backend;
- a backend may be a provider-owned CLI harness or StatefulClanker's direct API harness;
- task-specific `provider` is an explicit override/exception.

The same task semantics should remain valid if routing changes between local inference and a provider CLI.

## Context faults and replanning

Repeated `CONTEXT_REQUEST` means retrieval or decomposition is wrong. Add missing evidence, improve the task boundary, create prerequisite inspection work, persist missing design state, or clarify intent rather than indefinitely growing prompts.

`INTENT_QUESTION` and `INTENT_CONFLICT` return to current authority/human clarification. The planner must not invent the resolution.

## Completion discipline

A task graph is good when disposable workers can advance it without reconstructing the original conversation and later orchestrators can trace important work through task -> Intent -> current directive -> human source evidence.

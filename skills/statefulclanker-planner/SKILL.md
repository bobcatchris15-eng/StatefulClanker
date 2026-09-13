# StatefulClanker planner skill

Use this skill to turn a goal into a task graph designed for cold-start, one-shot workers operating through StatefulClanker.

## Objective

Produce plans that remain executable after the conversational session disappears. Optimize for low hidden context, explicit dependencies, cheap retrieval, objective validation, and recoverability from failed worker calls.

## Planning method

Start from the desired end state and derive observable acceptance conditions. Then decompose backward into tasks.

For each candidate task ask:

1. Can a new worker understand this with no prior chat history?
2. Is there one primary outcome?
3. What files, symbols, docs, errors, or dependency receipts must be retrieved?
4. What must already be true before it starts?
5. How can another process determine whether it succeeded?
6. Does it contain a real human decision?

If a task requires a long narrative recap to make sense, decompose it further or persist that context as an artifact.

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
      "retrieval": ["file/symbol/error/query intent"],
      "evidence": ["explicit file pointers if already known"],
      "provider": null,
      "role": "worker",
      "humanGate": false
    }
  ]
}
```

## Decomposition rules

Prefer a task boundary when required expertise, files/subsystem, validation method, dependency set, provider/tool choice, risk level, or human decision boundary changes. Do not decompose merely by number of files if one atomic change naturally spans them.

## Acceptance criteria

Good acceptance criteria are externally checkable: a command exits 0, specified tests pass, a file contains a defined interface, a reproduction no longer fails, generated output matches a schema, or behavior is demonstrable with a probe.

Avoid criteria such as "looks good," "is robust," "finish implementation," or "understand the code." Replace subjective criteria with a critic role when subjective review is genuinely required.

## Retrieval intent

Retrieval entries describe what a worker needs, not a copy of the whole context. Examples: `src/cache/* and cache interface callers`, `symbol: Invoke-Provider`, `exact error: unable to acquire lock`, `latest failed run for task cache-index`.

## Human gates

Use `humanGate: true` only for actual choices: product behavior, destructive action, credentials, cost/risk tradeoffs, or unresolved preference. Missing technical knowledge is normally a research or inspection task, not a human gate.

## Output discipline

Return the plan first as valid JSON. Any human explanation comes after it and must not contain execution-critical information absent from the JSON.

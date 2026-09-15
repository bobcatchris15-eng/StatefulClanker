# Authoritative Intent Contract

StatefulClanker treats user intent as a separate authority layer rather than relying on task prose, chat history, or a rolling event window to preserve project meaning.

## Why this exists

Cold-start workers are intentionally disposable. That only works if the specification they inherit is durable too.

Without an explicit intent layer, a project can remain mechanically consistent while drifting semantically:

`user request -> planner interpretation -> task wording -> worker interpretation -> downstream worker interpretation`

Each step may be locally reasonable while the assembled result moves away from what the user actually asked for.

The Intent Contract provides a common, revisioned semantic anchor for every worker generation.

## Authority model

The current contract lives at:

`.statefulclanker/intent/contract.json`

Revision snapshots live at:

`.statefulclanker/intent/history/revision-NNNN.json`

Worker escalations live at:

`.statefulclanker/intent/escalations.jsonl`

The contract declares:

```json
{
  "authority": {
    "owner": "orchestrator",
    "workers": "read-only"
  }
}
```

Only the human-facing orchestrator is authorized to commit a replacement/revision. Workers, critics, validators, planners, and external memory systems may read or challenge the contract, but they do not acquire specification authority.

Implementation difficulty is not authority to change intent.

## Contract contents

The initial schema contains:

- `objective` — terminal outcome the user wants
- `requirements` — hard capabilities/behaviors
- `constraints` — platform, compatibility, architecture, cost, safety, or operational limits
- `invariants` — properties that must remain true while implementation evolves
- `nonGoals` — plausible interpretations explicitly outside scope
- `decisions` — choices already made and not to be casually reopened
- `preferences` — softer guidance that may yield to harder constraints
- `openQuestions` — unresolved user-intent questions
- `successDefinition` — observable state in which the project is complete

See `examples/intent.example.json` for a starter shape.

## Orchestrator interrogation

The orchestrator should establish the contract before approving substantial implementation work.

It should not merely paraphrase the user's opening request. It should actively search for ambiguities capable of producing materially different implementations.

When the host exposes a structured question, quiz, interview, or "grill me" tool, the orchestrator should prefer it for intent elicitation. Useful probes include:

- hard requirement vs preference
- intended terminal state
- platform and deployment boundaries
- explicit non-goals
- architectural choices already decided
- tradeoff priorities
- examples of plausible-but-wrong interpretations
- conditions that would make the user say the project missed the point

Contrastive questions are particularly useful: present multiple reasonable interpretations and ask which is intended. Rejected interpretations can become `nonGoals`, `constraints`, or `invariants`.

The goal is not a giant requirements ceremony. The goal is to remove ambiguity before it becomes semantic drift across model sessions.

## CLI

Inspect the current contract:

```powershell
.\StatefulClanker.ps1 intent show
```

Inspect revision history:

```powershell
.\StatefulClanker.ps1 intent history
```

Inspect unresolved worker escalations:

```powershell
.\StatefulClanker.ps1 intent escalations
```

Commit an orchestrator-authored replacement:

```powershell
.\StatefulClanker.ps1 intent replace -Path .\intent.next.json -Reason "User clarified deployment boundary"
```

Every committed revision advances human direction and changes the intent revision/hash used by compilation freshness checks.

## Worker behavior

Every worker compilation receives the same authoritative contract, its revision, and its hash.

Workers must not silently weaken or reinterpret it. If implementation exposes a specification problem, they emit one of:

```text
INTENT_QUESTION: <specific ambiguity requiring authoritative resolution>
```

```text
INTENT_CONFLICT: <specific contradiction between task/evidence and authoritative intent>
```

Either signal is non-advancing. StatefulClanker records the escalation and stops the cycle before a completion proposal can be accepted.

The orchestrator then resolves the issue from existing state or asks the user. If user intent changes, the orchestrator commits a new Intent Contract revision and updates/invalidate affected planning state.

## Freshness

A compilation records:

- Intent Contract revision
- Intent Contract content hash
- active plan identity and plan-summary hash
- project goal hash
- human-direction revision
- task definition/control revisions
- dependency state
- retrieval file hashes

If authoritative intent changes while a worker is in flight, the old compilation becomes stale and cannot commit normally.

## Events are not specification memory

The event log remains an audit trail and useful recent context, but durable execution-relevant intent must not survive only as a `user.note` that can fall out of the recent-event projection.

When new human direction changes what the project means, the orchestrator should update the Intent Contract, plan, or task graph as appropriate.

## Relationship to plans and tasks

The hierarchy is:

`Goal -> Intent Contract -> Plan -> Task -> Compilation -> Model output -> Accepted state`

Plans operationalize the contract. Tasks decompose the plan. Neither layer outranks the contract.

A task can pass its local acceptance checks and still fail overall if it violates the current Intent Contract.

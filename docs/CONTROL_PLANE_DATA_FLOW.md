# Control-plane data flow

StatefulClanker keeps the conversational agent, durable project state, and disposable CLI workers deliberately separate.

## Responsibilities

The conversational control plane has two ordered responsibilities:

1. preserve/transmit human intent as faithfully as practical
2. keep the human informed about meaningful project-state changes

Implementation is delegated to provider CLI workers.

## End-to-end flow

```text
human
  -> conversational control plane
       -> clarify material ambiguity aggressively
       -> update named current human directives
       -> reconcile normalized Intent
       -> build semantic SCPLAN/task graph
  -> StatefulClanker durable state
       -> compile worker truth packet
       -> dispatch provider CLI worker
       -> critic / validator
       -> accepted commit or rejected/stale result
       -> durable sequenced control event
  -> MCP resource update / polling fallback
  -> conversational control plane
       -> summarize meaningful progress OR ask human for required decision
```

## Durable authority state

Workers never depend on conversation history as project memory.

The compiled packet includes:

```text
PROJECT
  goal
  state revision
  active plan

CURRENT HUMAN DIRECTIVES
  global directive revision/hash
  latest direct human wording by named scope
  current human source references

NORMALIZED INTENT
  intent revision/hash
  directive revision/hash it reconciled
  requirements / constraints / invariants / non-goals / decisions / preferences

TASK
  bounded outcome
  acceptance criteria
  semantic size
  governing intent refs
  current source refs

EVIDENCE
  dependencies
  retrieval excerpts
  file hashes
```

A directive mutation immediately makes older compilations stale and blocks new compilation until Intent is reconciled.

## Durable control inbox

The low-level audit log remains:

```text
.statefulclanker/events.jsonl
```

The conversational plane consumes the separate sequenced inbox:

```text
.statefulclanker/control/events.jsonl
.statefulclanker/control/state.json
```

Every control event contains a monotonically increasing `sequence` and one of:

- `fyi` — routine information that may be batched
- `attention` — meaningful progress/failure/change that should normally be summarized
- `human_required` — ambiguity/hold/reconciliation state that should return to the human rather than be guessed through

The cursor makes delivery resumable. Notification loss or session restart does not lose project state.

## MCP update delivery

The current project exposes:

```text
statefulclanker://project/current/control-events
statefulclanker://project/current/directives
statefulclanker://project/current/snapshot
```

A modern MCP client can open `subscriptions/listen` for the control-events resource.

The stream is deliberately **level-triggered**:

1. server acknowledges the subscription
2. durable project event sequence advances
3. server sends `notifications/resources/updated`
4. client refetches the control-events resource or calls `control_events_since`
5. client saves the returned cursor

The notification itself is never the only copy of an event.

Clients without subscription support use:

```text
control_events_since(since=<last cursor>)
```

at the start of a resumed control-plane turn and after substantial actions.

## Human-required flow

A typical ambiguity path is:

```text
worker -> INTENT_QUESTION / INTENT_CONFLICT
       -> durable escalation
       -> human_required control event
       -> MCP update notification if supported
       -> conversational control plane
       -> structured questionnaire to human
       -> directive_set (replace current named decision)
       -> reconciliation gate active
       -> intent_apply
       -> affected work is replanned/retried
```

Independent work need not stop unless it depends on the changed authority, but no new compilation is allowed against an unreconciled directive set.

## Why push and pull both exist

MCP hosts differ in how aggressively they surface server notifications to the model. StatefulClanker therefore treats push as a wake-up/latency optimization and the durable cursor as the correctness mechanism.

A host that can resume the conversational agent from a notification can behave event-driven. A host that cannot still observes the exact same state on its next turn.

# StatefulClanker architecture

## Purpose

StatefulClanker externalizes the pieces of agentic work that are usually trapped inside a chat context. The system should be able to stop after any step, start a new model session, and continue from disk without reconstructing the project from conversation history.

The orchestrator is therefore a state-transition engine, not a giant prompt.

## Canonical loop

```text
observe
  -> retrieve
  -> compile
  -> invoke one worker
  -> parse result
  -> persist receipt
  -> critique / validate / human gate as required
  -> transition task state
  -> repeat
```

Every arrow is observable and persistable.

## Durable objects

### Project state

`state.json` contains only compact current state: project identity, goal, active plan, timestamps, and task index. Historical detail belongs in append-only receipts.

### Events

`events.jsonl` is append-only. Observations, decisions, failures, user direction, discoveries, and tool outcomes are events. This prevents the current state file from becoming an accidental transcript.

### Tasks

Tasks are independent JSON documents under `tasks/`. Each task carries its id, title, instruction, acceptance criteria, dependencies, status, retrieval intent, evidence pointers, preferred provider/role, human-gate flag, timestamps, and latest run id.

Task states are deliberately boring:

`pending -> ready -> running -> needs_review -> complete`

with side states `blocked` and `failed`.

### Plans

Plans are versioned inputs that create or supersede task graphs. Plan prose is useful to humans, but task graph structure is authoritative to execution.

### Runs

A run receipt records exactly what was dispatched and what came back: task id, provider, command, compiled prompt path, start/end time, exit code, stdout/stderr, and artifact/file pointers when known. A failed worker call should improve future execution rather than disappearing into chat scrollback.

### Critiques and validations

Critique and validation are separate artifacts because they answer different questions.

Critic: "What looks wrong, incomplete, risky, or poorly reasoned?"

Validator: "Did the observable acceptance conditions pass?"

Neither should silently rewrite the worker's result.

## Retrieval

Retrieval should be driven by the task's declared intent rather than by dumping the repository into context. Useful retrieval includes exact file pointers, symbol names, error strings, test failures, recent events for the same component, dependency receipts, and project conventions.

The first implementation keeps retrieval intentionally simple: dependency results, explicit evidence, and recent events are compiled into the prompt. More advanced code/search retrieval can be added behind the same interface.

## Provider adapter

Providers are configured as ordinary command lines. StatefulClanker substitutes placeholders into the configured argument vector:

- `{prompt}` - entire prompt inline
- `{promptFile}` - path to UTF-8 prompt file
- `{projectRoot}` - target repository root
- `{taskId}` - task identifier

This makes provider support data-driven. `opencode`, `claude`, `agy`, local model launchers, wrapper scripts, or future CLIs do not need first-class code unless they require special parsing.

## Planner contract

A StatefulClanker plan is optimized for workers that begin with no conversational history. A good task has one concrete outcome, names what to inspect/retrieve, declares dependencies, fits in one worker invocation where practical, carries objective acceptance criteria, does not rely on "as discussed earlier," and records a human gate when a real decision is required.

## Human interaction

The user is not a fallback parser. Human gates should represent genuine product, design, risk, or priority decisions. When blocked, persist the decision required, the minimum useful context, alternatives if known, and what work can continue independently.

## Concurrency

Ready tasks whose dependency closures do not overlap can run concurrently. The default configuration caps dispatch at three workers. The current PowerShell entrypoint dispatches one task per invocation; parallel scheduling can be added without altering task semantics.

## Invariants

1. The state on disk is authoritative over model recollection.
2. A task cannot become ready until all dependencies are complete.
3. A task is marked running before provider invocation.
4. A run receipt is written even when the provider fails.
5. A worker cannot mark its own task complete merely by claiming success.
6. Human-gated transitions require explicit approval state.
7. No worker needs the full historical transcript to operate correctly.

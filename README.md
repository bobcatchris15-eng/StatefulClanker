# StatefulClanker

StatefulClanker is a Windows-first PowerShell harness for long-running agentic work where **the project persists and model context does not**.

The canonical loop is now:

`observe -> retrieve -> compile -> freshness check -> one-shot inference -> persist -> propose -> critique -> validate -> commit -> repeat`

Durable project state lives on disk. Models are replaceable workers. Every worker gets a bounded, cold-start projection of the current task rather than a reconstructed conversation.

## Why

Long tasks become brittle when project continuity exists mainly inside a model's active context. StatefulClanker externalizes continuity into explicit objects:

- task graph and typed task relationships
- append-only project events
- versioned plans and approvals
- compiled context receipts and read sets
- worker run receipts
- candidate state-transition proposals
- critiques and validations
- progress / stagnation records
- context-fault telemetry
- provider configuration
- retrieved evidence and bounded file excerpts

This lets work resume across sessions, models, providers, context resets, or machines without pretending that an LLM has durable working memory.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- Git recommended
- At least one CLI model/tool to dispatch to, such as `opencode`, `claude`, `agy`, or another executable

StatefulClanker does not require or embed a particular model API. Provider support is ordinary command configuration.

## Quick start

```powershell
irm https://raw.githubusercontent.com/bobcatchris15-eng/StatefulClanker/main/StatefulClanker.ps1 -OutFile .\StatefulClanker.ps1

.\StatefulClanker.ps1 init
.\StatefulClanker.ps1 goal "Add a local-first semantic cache"
.\StatefulClanker.ps1 status
```

`init` creates `.statefulclanker` and copies `statefulclanker.example.json` into `.statefulclanker\config.json`. Running `init` again on an older project upgrades the durable layout in place while preserving prior receipts.

Add a task manually:

```powershell
.\StatefulClanker.ps1 task add `
  -Title "Implement cache index" `
  -Instruction "Implement the cache index described in docs/cache.md" `
  -Accept "Tests pass; existing behavior remains compatible" `
  -Retrieval "docs/cache.md","src/*.ps1" `
  -Relation "discovered_from:cache-design"
```

Then execute the next ready task:

```powershell
.\StatefulClanker.ps1 run
```

Or force a worker provider:

```powershell
.\StatefulClanker.ps1 run -Provider claude
```

## Execution pipeline

A run is a state-transition cycle, not a chat continuation:

1. Resolve one ready task.
2. Retrieve only task-declared files/evidence and dependency receipts.
3. **Compile** them into a typed, durable context receipt with provenance, file hashes, dependency state, and an input fingerprint.
4. Check that the compiled read set is still fresh immediately before dispatch.
5. Dispatch one cold-start worker.
6. Persist its complete receipt.
7. Convert missing-context requests into explicit context-fault telemetry.
8. Create a **candidate completion proposal**. Worker success alone does not mutate canonical task completion.
9. If enabled, run critic and validator against the same compiled context and worker receipt.
10. Revalidate logical dependencies before commit.
11. Commit the proposal only if the required review stages pass and its read set is still valid.
12. Record whether the cycle actually advanced the project.

This makes the model's reasoning ephemeral while preserving the inputs, evidence, state transitions, and verification boundary needed to reproduce or challenge the result.

## Compiled context

`retrieve -> compile` is intentionally literal.

Each compilation stores:

- project goal and active plan identity
- task definition and acceptance criteria
- typed task relationships
- dependency status and receipt identities
- retrieved context/evidence with hashes and authority labels
- bounded recent events
- working-set usage and truncation/unmatched-selector statistics
- a read set and deterministic input fingerprint
- the exact model-visible intermediate representation

Inspect it with:

```powershell
.\StatefulClanker.ps1 context show -CompilationId <id>
```

The worker sees only this temporary projection. The projection is not authoritative; the durable project objects are.

## Context faults

A worker that cannot safely proceed because required state is absent should emit:

```text
CONTEXT_REQUEST: exact description of the missing state or evidence
```

StatefulClanker records these as semantic/context page faults instead of forcing the worker to guess. Inspect recent faults with:

```powershell
.\StatefulClanker.ps1 telemetry faults
# or
.\StatefulClanker.ps1 context faults
```

This gives retrieval policy something measurable to improve: misses, repeated requests, budget pressure, unmatched selectors, and truncated sources.

## Candidate state and commit

A successful worker produces evidence for a transition; it does not certify the transition itself.

For normal automated completion StatefulClanker persists a proposal under `proposals/`, attaches critic/validator outcomes, checks that the task/goal/dependency read set has not become stale, and only then marks the task complete.

Manual `complete` remains an explicit human-authority commit and is recorded as such.

## Dependency invalidation

Scheduling dependencies remain in `dependsOn`. Non-scheduling semantic relationships live in `relations`.

Useful relation types include:

- `discovered_from`
- `derived_from`
- `evidence_for`
- `supersedes`
- `invalidated_by`
- `conflicts_with`
- `related`

When a previously completed upstream dependency is retried or blocked, StatefulClanker invalidates downstream work rather than silently treating the old completion as current truth. Completed dependents become `stale`; unresolved descendants return to dependency-gated states.

## Progress and stagnation

A receipt proves that compute happened. It does not prove the project moved.

Each terminal cycle therefore writes a progress record stating whether the task advanced, the outcome, attempt number, and compiled-input fingerprint. Repeated non-advancing attempts against the same fingerprint generate a stagnation warning once `stagnationWarningThreshold` is reached.

```powershell
.\StatefulClanker.ps1 progress history
```

The intent is to make "spin" observable before adding more elaborate replanning policies.

## Retrieval

`-Retrieval` and `-Evidence` accept files, directories, or glob selectors relative to the project root.

- `workingSetBudgetChars` caps the total retrieved text in one worker compilation.
- `maxFileChars` caps one file's contribution.
- evidence and ordinary context are tagged separately in the compiled packet.
- runtime files under `.statefulclanker` are never pulled in through normal selectors.

Unmatched selectors and truncation are persisted in the compilation receipt rather than disappearing as prompt-construction details.

## State layout

```text
.statefulclanker/
  config.json
  state.json
  events.jsonl
  tasks/
  plans/
  compilations/
  proposals/
  runs/
  critiques/
  validations/
  progress/
  prompts/
  telemetry/
    events.jsonl
    context-faults.jsonl
    active/
    runs/
```

`.statefulclanker/` is local runtime state by default and is ignored by this repository's `.gitignore`. Remove that ignore rule in a target project if the project's durable agent state should itself be version-controlled.

## Commands

```text
init                                  Initialize or migrate durable state
goal <text>                           Set or replace the project goal
status                                Show project/task status
task add ...                          Add a task
task list                             List tasks
task show -TaskId <id>                Show one task
task retry -TaskId <id>               Retry and invalidate affected dependents when needed
plan import -Path <file>              Import a JSON plan/task graph
plan approve                          Approve the active plan
run [-TaskId id]                      Run compile -> worker -> review -> commit
complete -TaskId id                   Explicit human completion commit
block -TaskId id -Reason ...          Block a task
event -Message ...                    Append a human observation/direction
provider list                         Show providers
telemetry active|history|faults       Inspect agent and context telemetry
telemetry show -RunId <agentId>       Inspect one telemetry run
context show -CompilationId <id>      Inspect one compiled context receipt
context faults                        Inspect context misses
progress history                      Inspect progress/stagnation records
```

## Worker, critic, and validator contracts

The **worker** performs only one bounded task from a cold-start packet. It should report changed files, commands, failures, and unresolved risks. If needed state was omitted, it requests that state instead of fabricating continuity.

The **critic** checks omissions, contradictions, risky assumptions, regressions, and task fit.

The **validator** independently judges acceptance criteria from available evidence. It is explicitly told not to trust the worker merely because the worker says something passed.

Reviewer output remains deliberately machine-simple: the first non-empty line must be exactly `VERDICT: PASS` or `VERDICT: FAIL`. Malformed review output fails closed.

## What StatefulClanker deliberately does not own

StatefulClanker is the **project-state and execution-control plane**, not a universal memory product.

It deliberately does not yet try to own:

- cross-project experiential/skill memory
- autonomous mutation of its own harness policy
- learned retrieval policy
- general semantic/vector knowledge storage
- exactly-once guarantees for arbitrary external side effects
- distributed multi-writer consistency for shared project state

Those concerns can integrate with StatefulClanker later, but folding them into the core now would blur the most valuable boundary: deterministic durable project state versus disposable probabilistic reasoning.

See `docs/ARCHITECTURE.md` and `docs/STATE_CONTROL.md` for the detailed model.

## Design principles

- The project persists; model context does not.
- Durable state beats conversational continuity.
- Workers get the smallest sufficient context.
- Context construction is a compilation step with a receipt.
- Plans are graphs, not prose checklists.
- Semantic relations preserve why work exists, not just what blocks it.
- Every model call produces a durable receipt.
- Worker output proposes state; it does not certify state.
- A validated commit boundary advances canonical state.
- Stale dependencies invalidate downstream assumptions.
- A failed or rejected run is evidence, not lost context.
- Activity and progress are different things.
- Providers are interchangeable.
- Human approval is a first-class state transition.
- The orchestrator must not secretly do the worker's job.
- Reusable expertise belongs in a separate memory layer.

## License

MIT. See `LICENSE`.

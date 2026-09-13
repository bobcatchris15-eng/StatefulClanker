# StatefulClanker

StatefulClanker is a Windows-first PowerShell harness for doing long-running agentic work without requiring any one model invocation to remember the project.

The core loop is deliberately simple:

`observe -> retrieve -> compile -> one-shot inference -> persist -> critique -> validate -> repeat`

The durable project state lives on disk. Models are treated as replaceable workers. A fresh worker gets only the state, task, evidence, constraints, dependency outputs, and project files it needs for the current step.

## Why

Large tasks fail when the model must carry the entire project in conversational context. StatefulClanker moves continuity into explicit state:

- task graph and dependencies
- event log
- plans and approvals
- run receipts
- critiques and validations
- provider configuration
- retrieved evidence and bounded file excerpts

This lets a project continue across sessions, providers, context resets, or machines without pretending an LLM has durable working memory.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- Git recommended
- At least one CLI model/tool you want to dispatch to, such as `opencode`, `claude`, `agy`, or another executable

No API key or specific model provider is built into StatefulClanker. It invokes existing CLI tools.

## Quick start

```powershell
# from your project directory
irm https://raw.githubusercontent.com/bobcatchris15-eng/StatefulClanker/main/StatefulClanker.ps1 -OutFile .\StatefulClanker.ps1

.\StatefulClanker.ps1 init
.\StatefulClanker.ps1 goal "Add a local-first semantic cache"
.\StatefulClanker.ps1 status
```

`init` copies `statefulclanker.example.json` into `.statefulclanker\config.json`. Adjust the provider commands for the CLIs installed on your system.

To add tasks manually:

```powershell
.\StatefulClanker.ps1 task add `
  -Title "Implement cache index" `
  -Instruction "Implement the cache index described in docs/cache.md" `
  -Accept "Tests pass; existing behavior remains compatible" `
  -Retrieval "docs/cache.md","src/*.ps1"
```

Then execute the next ready task:

```powershell
.\StatefulClanker.ps1 run
```

Or force the worker provider:

```powershell
.\StatefulClanker.ps1 run -Provider claude
```

## Execution pipeline

A successful `run` now executes the whole state transition:

1. Resolve one ready task.
2. Retrieve the task-declared files/globs and dependency receipts.
3. Compile a cold-start packet within `workingSetBudgetChars` and `maxFileChars`.
4. Dispatch a one-shot worker.
5. Persist the worker receipt.
6. If enabled, dispatch a critic against the task, worker receipt, and retrieved evidence.
7. If the critic passes, dispatch a validator against the acceptance criteria and evidence.
8. Mark the task `complete` only after the enabled review stages pass.
9. On review failure, mark it `needs_rework` and preserve every receipt.

The critic and validator can use separate providers through `criticProvider` and `validatorProvider`. If either is `null`, that stage falls back to the task provider and then the default provider.

Reviewer output is intentionally simple: the first non-empty line must be exactly `VERDICT: PASS` or `VERDICT: FAIL`. A malformed review is treated as failure rather than optimistic success.

## Retrieval

`-Retrieval` and `-Evidence` accept files, directories, or glob selectors relative to the project root. StatefulClanker reads matching text files into the invocation packet while respecting two config limits:

- `workingSetBudgetChars`: total retrieved text budget per invocation
- `maxFileChars`: maximum characters read from one file

Runtime state under `.statefulclanker` is never retrieved into worker context through these selectors.

## State layout

StatefulClanker creates this local directory in the target project:

```text
.statefulclanker/
  config.json
  state.json
  events.jsonl
  tasks/
  plans/
  runs/
  critiques/
  validations/
  prompts/
  retrieval/
```

`.statefulclanker/` is intended to be local runtime state and is ignored by this repository's `.gitignore`. If you want project state versioned, remove that ignore rule in the target project.

## Commands

```text
init                         Initialize state in the current project
goal <text>                  Set or replace the project goal
status                       Show project/task status
task add ...                 Add a task
task list                    List tasks
task show -TaskId <id>       Show one task
task retry -TaskId <id>      Reset a failed/rework task to ready
plan import -Path <file>     Import a JSON plan and task graph
plan approve                 Approve the active plan
run [-TaskId id]             Run worker + enabled review pipeline
complete -TaskId id          Mark a task complete manually
block -TaskId id -Reason ... Block a task
event -Message ...           Append an observation to the event log
provider list                Show configured providers
```

## Worker, critic, and validator contracts

A worker should not decide what the entire project means from scratch. StatefulClanker compiles a cold-start packet containing the project goal, one task and its acceptance criteria, dependency results, recent events, retrieved file evidence, constraints, and the output contract.

The **critic** does not perform the work. It checks omissions, contradictions, risky assumptions, regressions, and whether the result actually addresses the bounded task.

The **validator** independently judges the acceptance criteria from the available evidence. It is explicitly told not to trust the worker's claim merely because the worker says something passed.

Every invocation produces a durable receipt before state advances.

## Tests

A deterministic provider is included so the orchestration path can be tested without model quota or API access:

```powershell
.\tests\Smoke.ps1
```

The smoke test creates a temporary project and exercises:

`worker -> critic -> validator -> complete`

A `windows-latest` GitHub Actions workflow runs the same smoke test on pushes and pull requests.

## Skills

Two model-facing skills are included:

- `skills/statefulclanker/SKILL.md` — operating StatefulClanker conversationally while keeping durable state authoritative.
- `skills/statefulclanker-planner/SKILL.md` — converting a fuzzy goal into tasks optimized for cold-start, one-shot workers.

## Design principles

- Durable state beats conversational continuity.
- Workers get the smallest sufficient context.
- Plans are graphs, not prose checklists.
- Every model call produces a receipt.
- Retrieval is explicit, bounded, and task-scoped.
- A failed run or rejected review is evidence, not lost context.
- Providers are interchangeable.
- Human approval is a first-class state transition.
- The orchestrator must not secretly do the worker's job.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the detailed state model and execution lifecycle.

## License

MIT. See `LICENSE`.

# StatefulClanker

StatefulClanker is a Windows-first PowerShell harness for doing long-running agentic work without requiring any one model invocation to remember the project.

The core loop is deliberately simple:

`observe -> retrieve -> compile -> one-shot inference -> structured result -> persist -> repeat`

The durable project state lives on disk. Models are treated as replaceable workers. A fresh worker gets only the state, task, evidence, constraints, and files it needs for the current step.

## Why

Large tasks fail when the model must carry the entire project in conversational context. StatefulClanker moves continuity into explicit state:

- task graph and dependencies
- event log
- plans and approvals
- run receipts
- critiques and validations
- provider configuration
- retrieved evidence and file pointers

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

Copy `statefulclanker.example.json` to `.statefulclanker\config.json` and adjust the provider commands for the CLIs installed on your system.

To add tasks manually:

```powershell
.\StatefulClanker.ps1 task add `
  -Title "Implement cache index" `
  -Instruction "Implement the cache index described in docs/cache.md" `
  -Accept "Tests pass; existing behavior remains compatible"
```

Then execute the next ready task:

```powershell
.\StatefulClanker.ps1 run
```

Or force a provider:

```powershell
.\StatefulClanker.ps1 run -Provider claude
```

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
plan import -Path <file>     Import a JSON plan and task graph
plan approve                 Approve the active plan
run [-TaskId id]             Run the next ready task
complete -TaskId id          Mark a task complete manually
block -TaskId id -Reason ... Block a task
event -Message ...           Append an observation to the event log
provider list                Show configured providers
```

## Worker contract

A worker should not decide what the entire project means from scratch. StatefulClanker compiles a cold-start packet containing the project goal, one task and its acceptance criteria, dependency results, recent relevant events, explicit file pointers/evidence, constraints, and the requested output contract.

The worker returns a structured result. StatefulClanker records the complete receipt before advancing project state.

## Critic and validator roles

The intended flow is not "worker writes code and declares victory."

- **Worker** performs one bounded task.
- **Critic** checks the result for omissions, contradictions, risky assumptions, and likely edge cases.
- **Validator** checks objective acceptance criteria: tests, probes, file changes, commands, or other verifiable outcomes.
- **Human gate** is used where the plan or task explicitly requires a decision.

The first implementation stores these roles and receipts; provider-specific automatic critic/validator dispatch can be layered on top without changing the state model.

## Skills

Two model-facing skills are included:

- `skills/statefulclanker/SKILL.md` — operating StatefulClanker conversationally while keeping durable state authoritative.
- `skills/statefulclanker-planner/SKILL.md` — converting a fuzzy goal into tasks optimized for cold-start, one-shot workers.

## Design principles

- Durable state beats conversational continuity.
- Workers get the smallest sufficient context.
- Plans are graphs, not prose checklists.
- Every model call produces a receipt.
- Retrieval is explicit and task-scoped.
- A failed run is evidence, not lost context.
- Providers are interchangeable.
- Human approval is a first-class state transition.
- Do not make the orchestrator secretly do the worker's job.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the detailed state model and execution lifecycle.

## License

MIT. See `LICENSE`.

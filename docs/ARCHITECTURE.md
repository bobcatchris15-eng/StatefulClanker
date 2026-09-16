# StatefulClanker architecture

## Purpose

StatefulClanker externalizes the pieces of long-running agentic work that are usually trapped inside one model session.

The project persists. Model reasoning is temporary compute.

The intended product is a **Windows-resident orchestration application** with a persistent system-tray presence, project navigation, MCP control plane, provider CLI execution, durable state, and project-scoped telemetry.

The conversational-plane model is the human-facing orchestrator. StatefulClanker owns durable authority, dispatch, context compilation, review gates, and observability.

See `docs/WINDOWS_FIRST_DESIGN.md` for the product/UI/control-plane contract and `docs/TASK_RECORD_FORMAT.md` for the target compact plan/task authoring format.

## Top-level architecture

```text
human
  |
  v
conversational-plane orchestrator
  |  MCP: stdio bridge or Streamable HTTP
  v
StatefulClanker Windows host
  |
  +-- active project + project registry
  +-- human-source evidence
  +-- Intent Contract
  +-- plan / task graph
  +-- context compiler
  +-- provider routing
  +-- run/review/progress receipts
  +-- telemetry
  |
  v
Provider CLI Adapters
  |
  +-- codex / agy / claude / opencode / gemini / local CLIs / others
```

The normal execution boundary is an ordinary command line that accepts a prompt file or stdin. Direct provider API integration is optional, not required by the architecture.

## Windows application authority

The installed application is the machine-local host.

It owns:

- notification-area lifecycle
- active-project selection and restoration
- machine-local project registry
- provider CLI definitions and class/role routing
- integration registration/status
- long-lived Streamable HTTP MCP listener
- local IPC endpoint used by stdio bridges
- project-scoped telemetry presentation

PowerShell remains a first-class automation/troubleshooting interface. It should not become a second independent semantic authority when the resident app is running.

### Active project

The application has an **active project**, not an implicit default project.

- selecting a project makes it active
- the last active project is restored on startup
- missing paths are shown explicitly
- another project is never silently substituted
- the UI always makes project scope visible
- MCP conversations initially attach to the active project unless they explicitly select another project

## Machine state vs project state

Machine-local state belongs in a Windows application-data location such as `%LOCALAPPDATA%\StatefulClanker`:

```text
project registry
last active project
provider CLI definitions
provider class/role routing
integration registrations
MCP endpoint/token/IPC information
window/UI state
```

Project state belongs under `<project>\.statefulclanker`:

```text
input/
intent/
plans/
tasks/
compilations/
prompts/
runs/
critiques/
validations/
proposals/
progress/
reviews/
telemetry/
events.jsonl
state.json
config.json
```

Executable paths and app integrations are properties of one PC. Intent, plan history, task history, and execution evidence are properties of the project and should travel with it.

## Authority chain

StatefulClanker distinguishes source evidence, normalized specification, execution state, compiled context, and model proposals.

```text
human source
    -> Intent Contract
    -> plan
    -> task
    -> compiled worker packet
    -> model evidence
    -> critic / validator evidence
    -> accepted state transition
```

A model response never becomes canonical simply because it exists.

### Human-source evidence

The Intent Contract is an interpretation of user direction. Material direct human wording should remain recoverable as durable evidence.

Examples:

- session-chat excerpt
- uploaded plan/spec document
- questionnaire answer
- later clarification
- explicit rejection of another plausible interpretation

A task should carry or resolve a stable source reference and governing intent references when material. Later orchestrators should be able to audit the chain instead of trusting several generations of paraphrase.

## Conversational plane

The conversational model is responsible for semantic work that actually requires understanding:

- intent elicitation
- ambiguity detection
- maintaining the Intent Contract
- semantic planning
- task decomposition
- choosing prerequisite research/inspection work
- replanning after failures/context faults
- escalating genuine human decisions

When a host exposes a structured questionnaire/question tool, use it aggressively when two competent implementations could diverge materially.

StatefulClanker may detect suspiciously broad tasks and warn, but must not pretend that file counts, regexes, line counts, or token thresholds are semantic decomposition.

## Semantic task decomposition

A useful task boundary is an independently understandable and independently verifiable outcome.

Recommended semantic size hints:

- `tiny`
- `small`
- `medium`
- `large`

Prefer smaller work when boundaries are natural, but do not fragment tightly coupled behavior merely to hit an arbitrary size target.

Task size is assigned by the conversational planner and used as a routing hint. It is not inferred mechanically by the runtime.

## Plans and task records

Plans are durable execution structure.

The target authoring/import representation is the compact line-oriented `SCPLAN 1` format described in `docs/TASK_RECORD_FORMAT.md`. It is optimized for repeated model consumption and simple Windows shell inspection.

JSON remains valid for APIs, RPC, settings, internal receipts, and compatibility imports.

During migration, internal task storage may remain JSON while the compact plan format becomes the preferred planner output.

A task should preserve:

- id and bounded title
- cold-start instruction
- semantic size hint
- source references
- intent references
- scheduling dependencies
- semantic relations
- retrieval/evidence selectors
- acceptance criteria
- optional provider override
- role/specialist hint
- human-gate requirement
- lifecycle state/revisions
- latest execution/review pointers

## Canonical project state

`state.json` contains compact current project state: identity, goal, active plan, approval state, project revision, direction revision, and timestamps.

Historical detail belongs in append-only events and receipts rather than making current state a transcript.

## Events

`events.jsonl` is append-only. Observations, decisions, failures, user direction, discoveries, invalidations, context faults, and commits are events.

Direct human material that must survive as specification evidence should also be persisted as an explicit human-source artifact rather than only as an event message.

## Intent Contract

The orchestrator owns the authoritative Intent Contract. Workers, critics, and validators may read and challenge it but never silently rewrite it.

The contract carries objective, requirements, constraints, invariants, non-goals, decisions, preferences, open questions, and success definition.

An intent revision invalidates older compilations by revision/hash. Affected task branches should be selectively replanned or invalidated.

## Context compiler

Prompt construction is a compiler pipeline:

```text
canonical state
+ task
+ relevant human-source evidence
+ Intent Contract
+ dependencies
+ project evidence
+ bounded recent events
        |
        v
normalize / classify sources
        |
        v
build read set + provenance + authority labels
        |
        v
apply working-set budget
        |
        v
compiled context IR
        |
        v
cold-start worker prompt + compilation receipt
```

Mechanical slicing/chunking belongs here when needed for retrieval. It does not define the plan's semantic task boundaries.

## Retrieval

Retrieval is driven by declared task intent rather than repository dumping.

Useful selectors include exact files, directories, globs, generated artifacts, dependency outcomes, durable human-source excerpts, specialist notes, and explicitly named evidence.

A future smarter retrieval layer can evolve without changing task authority semantics.

## Read sets and freshness

Every compilation records what it relied upon.

Freshness checks include, as appropriate:

- project goal identity
- active plan identity/intent
- direction revision
- Intent Contract revision/hash
- task definition/control revision
- dependency state/receipt identity
- retrieved file hashes before dispatch

Human redirection or task control must invalidate older work before it becomes canonical.

## Provider CLI adapters

Providers remain ordinary command lines.

An adapter defines:

- name
- command
- argument template
- prompt delivery mode: prompt file, stdin, or inline when genuinely small
- optional capability/size classes
- roles it may serve: worker / critic / validator

Common placeholders may include:

- `{prompt}`
- `{promptFile}`
- `{projectRoot}`
- `{taskId}`

The preferred flow is to write the complete compiled prompt to a file and invoke a configured CLI with that path or pipe it on stdin, avoiding Windows command-line length limits.

Examples such as Codex, agy, Claude, OpenCode, Gemini, or local-model runners are configuration choices rather than hard-coded architectural dependencies.

### Provider routing

Machine-local configuration may map semantic task size and stage/role to providers.

Example concept:

```text
worker tiny   -> provider A
worker small  -> provider B
worker medium -> provider C
critic        -> provider B
validator     -> provider C
```

A task-specific provider override remains possible. The task graph should normally remain vendor-agnostic.

## Runs

A run receipt records exactly what was dispatched and what came back:

- task/provider/agent id
- semantic stage
- compilation id/fingerprint
- command/arguments/prompt path
- timing/exit code
- stdout/stderr
- context or intent escalations

A failed worker call should improve future execution rather than disappear into chat scrollback.

## Worker escalations

Workers should emit:

- `CONTEXT_REQUEST: <specific missing state>`
- `INTENT_QUESTION: <specific ambiguity>`
- `INTENT_CONFLICT: <specific contradiction>`

Each is non-advancing.

Context faults feed retrieval/decomposition improvements. Intent questions/conflicts return to the orchestrator/human authority.

## Proposals and transactional completion

Successful worker output is evidence for a candidate transition, not accepted completion.

```text
state N
  -> compile against N
  -> provider CLI worker result
  -> freshness/context/intent gate
  -> candidate proposal
  -> critic / validator evidence
  -> authority revalidation
  -> COMMIT -> state N+1
       or
     REJECT/STOP
```

Manual completion remains explicit human authority.

## Critic and validator

These answer different questions.

Critic: **What looks wrong, incomplete, risky, contradictory, or poorly reasoned?**

Validator: **Do the observable acceptance conditions pass from the available evidence?**

Neither rewrites worker output or the Intent Contract.

Both should judge against the same compiled context snapshot that drove the work plus the worker receipt.

## Dependencies and invalidation

`dependsOn` has scheduling semantics. Typed relations preserve other causal structure without serializing unrelated work.

If accepted upstream work loses authority, dependent completion must be invalidated or marked stale while preserving old receipts as historical evidence.

## Concurrency

Ready tasks with independent dependency closures may run concurrently in isolated git worktrees.

The main checkout retains canonical durable state. Worktrees isolate code changes; accepted work is committed and merged back. Textual merge success is not semantic validation, so project-level review/validation remains important after multi-branch integration.

Cross-process access to canonical state must remain serialized. Distributed multi-writer authority is not claimed yet.

## Specialists

A specialist is primarily a reusable project context profile:

- specialist name/role
- durable notes
- preferred retrieval selectors
- preferred provider size/class
- suitable task categories

A provider-specific persistent session may be reused as an optimization when helpful, but specialist semantics must not depend on that session existing.

## Progress vs activity

A run means compute happened. A progress record says whether accepted project state advanced.

Track both.

Repeated non-advancing attempts against the same effective input should trigger stagnation/replanning rather than blind retries.

## Desktop telemetry

The Windows application should expose project-scoped telemetry for the currently selected project, including:

- active worker/critic/validator processes
- worker sessions spawned
- critic/validator sessions
- commits/merges
- task counts by state
- retries/non-advancing attempts
- latest review verdicts
- context faults
- intent questions/conflicts
- provider failures

The app is primarily an observation/configuration surface. Planning/direction normally stays conversational through MCP.

## MCP transports

The target architecture has one resident semantic authority.

### Streamable HTTP

The running Windows app owns the loopback Streamable HTTP endpoint.

### stdio

Clients that require stdio launch a thin bridge/shim that talks to the resident host through local IPC, preferably a named pipe.

The stdio process must not become an independent project authority with divergent active-project state.

During migration, the current independent PowerShell MCP hosts remain compatibility implementations.

## External effects

StatefulClanker does not yet claim exactly-once semantics for arbitrary external effects such as email, cloud provisioning, purchases, or deployments.

Git-backed coding work is comparatively recoverable. Irreversible/costly effects require a future effect ledger with idempotency, authorization, reconciliation, and compensation semantics.

## Experiential memory boundary

Reusable cross-project expertise is not canonical project state.

External memory such as Toaster may provide candidate lessons to the compiler, but those lessons must be checked against current project state and never become authority merely because they were retrieved.

## Migration strategy

Do not require a flag-day rewrite.

1. keep the working PowerShell execution engine
2. make Windows-first/control-plane documents and planner behavior authoritative
3. add human-source capture
4. add compact plan import while preserving JSON compatibility
5. add machine-local project registry and active-project semantics
6. build the native Windows host taking structural/UI cues from Toaster
7. move the long-lived MCP HTTP endpoint into the host
8. make stdio a bridge to the host
9. move machine-local provider/integration config into the host
10. retire duplicated orchestration authority from independent processes

## Invariants

1. Durable project state is authoritative over model recollection.
2. Material human wording remains recoverable as source evidence.
3. The Intent Contract is orchestrator-owned and read-only to workers.
4. Semantic planning/decomposition belongs to the conversational plane.
5. Mechanical chunking is retrieval tooling, not task planning.
6. Model-visible context is a compiled projection, not canonical state.
7. Every worker packet stands alone and is traceable to a compilation receipt.
8. Workers cannot self-certify task completion.
9. Required review stages fail closed.
10. Older compiled work cannot overwrite newer human/intent/task authority.
11. Invalidated upstream authority invalidates dependent completion.
12. Provider execution remains CLI-based and provider-agnostic by default.
13. Consumer/provider CLI compatibility is a first-class feature.
14. The Windows app has an explicit active project; no silent default-project substitution.
15. Desktop telemetry is scoped to the selected project.
16. Persistent provider sessions are optional optimizations, not authority.
17. JSON may remain for APIs/internal receipts; repeatedly consumed task/plan artifacts optimize for compact retrieval/model context.
18. Activity and progress remain separately observable.
19. Cross-project memory is not canonical project state.
20. Exactly-once external-effect safety is not claimed until explicitly implemented.

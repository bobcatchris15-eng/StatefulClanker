# Compact plan/task record format

StatefulClanker needs two different kinds of serialization:

- API/RPC/settings/receipts may continue using JSON where it is useful.
- plan/task records that are repeatedly read by humans, conversational orchestrators, workers, and command-line tools should minimize syntactic overhead and be trivial to inspect with `Get-Content`, `Select-String`, `rg`, or `findstr`.

This document defines the target compact format. The existing JSON plan importer remains a compatibility path until the runtime parser for this format is fully landed.

## Goals

The format should be:

- line-oriented
- explicit rather than indentation-sensitive
- easy to grep
- cheap in model context
- easy to generate correctly
- easy to parse in PowerShell/C# without a YAML dependency
- tolerant of fields being added later
- readable as a durable project artifact

It is **not** intended to replace JSON-RPC or every internal receipt.

## File header

A plan file begins with:

```text
SCPLAN 1
```

Optional plan metadata follows:

```text
plan windows-first-host
summary Make the resident Windows application the orchestration authority.
source human:h-0007#L1-L22
intent REQ-001
intent REQ-003
```

Repeated fields are allowed where documented.

## Task records

A task begins with `task <id>` and ends with `end`.

Example:

```text
SCPLAN 1
plan active-project-host
summary Replace default-project semantics with an explicit active project.
source human:h-0012#L3-L18
intent REQ-ACTIVE-PROJECT

task t-021
size small
title persist machine-local project registry
instruction Add a machine-local registry of known project roots and stable project ids. Do not alter project-local state semantics.
source human:h-0012#L3-L18
intent REQ-ACTIVE-PROJECT
retrieve desktop/*
retrieve lib/StatefulClanker.Integrations.ps1
accept project roots can be added and removed without editing project state
accept registry survives application restart
accept missing paths remain explicit rather than silently redirecting
end

task t-022
size small
title restore last active project
instruction Restore the last selected project on app launch after resolving it through the registry.
depends t-021
source human:h-0012#L3-L18
intent REQ-ACTIVE-PROJECT
retrieve desktop/*
accept last active project is restored when its path exists
accept missing last-active path produces a no-active-project state
accept another project is never silently substituted
end
```

## Core fields

### `task <id>`

Stable task identifier. Required.

### `title <text>`

Short bounded outcome. Required.

### `instruction <text>`

Cold-start instruction. Required. Keep it one logical line; persist large supporting prose as a referenced artifact rather than embedding it here.

### `size <class>`

Planning/routing hint:

- `tiny`
- `small`
- `medium`
- `large`

The conversational-plane planner assigns this semantically. The runtime must not infer it from file count, line count, regexes, or token thresholds.

### `source <ref>`

Stable reference to material human input or another durable source artifact. Repeatable.

Examples:

```text
source human:h-0007#L4-L12
source docs:docs/windows-host-spec.md#active-project
source file:requirements/project-selection.md
```

A source reference does not automatically become authority; it records provenance. The Intent Contract remains the normalized specification authority.

### `intent <ref>`

Reference to governing intent requirement/constraint/invariant/decision identifiers. Repeatable.

### `depends <task-id>`

Scheduling dependency. Repeatable.

### `relation <type> <target>`

Semantic relationship that does not necessarily block execution. Repeatable.

Example:

```text
relation derived_from t-013
relation evidence_for REQ-017
```

### `retrieve <selector>`

Project evidence/context selector. Repeatable.

### `evidence <selector>`

Known evidence selector that should carry stronger evidentiary semantics than ordinary context. Repeatable.

### `accept <criterion>`

Observable acceptance criterion. Repeatable.

### `provider <name>`

Optional explicit provider CLI override. Normally omit this and let machine-local routing choose a provider.

### `role <role>`

Defaults to `worker`. May identify a specialist/task role where useful.

### `human-gate true|false`

Defaults to `false`.

## Why size is semantic

A task should be considered small when a cold-start worker can understand the requested outcome, relevant constraints, and verification boundary from a bounded packet.

The following are useful reasons to split work:

- independently verifiable outcomes
- different expertise or specialist context
- different prerequisite state
- materially different intent constraints
- distinct risk boundaries
- distinct validation methods

The following are **not** sufficient reasons by themselves:

- a file is long
- a diff exceeds N lines
- a prompt exceeds an arbitrary token threshold
- a directory contains many files

Token/character budgets are legitimate context-compilation concerns. They are not substitutes for semantic work decomposition.

## Human-source references

When a task derives from direct human wording, preserve that provenance.

The preferred pattern is:

1. conversational orchestrator records the relevant human input as a durable source artifact
2. Intent Contract cites or is traceable to that source
3. plan/task record contains the relevant `source` and `intent` references
4. compiler resolves those references into the worker packet, including the excerpt when cheap and useful

This makes the chain auditable:

```text
human wording -> source artifact -> intent -> task -> worker packet
```

## Worker lookup

The format is intentionally friendly to simple shell tools.

PowerShell examples:

```powershell
Select-String -Path .statefulclanker\plans\*.scplan -Pattern '^task t-043$' -Context 0,30
Select-String -Path .statefulclanker\plans\*.scplan -Pattern '^intent REQ-017$'
Get-Content .statefulclanker\plans\active.scplan
```

Workers should normally receive a compiled packet rather than grep the entire plan themselves, but specialists and debugging tools must be able to locate records cheaply.

## Parser behavior

Target parser rules:

- UTF-8 text
- ignore blank lines
- ignore lines whose first non-whitespace character is `#`
- keyword is the first whitespace-delimited token
- remainder of the line is the value unless otherwise defined
- unknown fields are preserved or ignored with a warning rather than causing catastrophic parse failure
- repeated fields preserve order
- duplicate task ids are fatal
- missing task title/instruction is fatal
- invalid size values produce a warning or parse error, never silent coercion

## Compatibility

During migration:

- `.json` plans remain importable
- `.scplan` becomes the preferred planner output when runtime support is available
- internal task JSON may remain as canonical runtime storage initially
- the compact plan can therefore be treated as an efficient authoring/import format before task persistence itself migrates

This allows the execution engine to evolve without a flag-day state migration.

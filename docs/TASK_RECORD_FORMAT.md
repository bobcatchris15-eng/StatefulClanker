# Compact plan/task record format

`SCPLAN 1` is the preferred human/model authoring format for semantic plans. JSON remains appropriate for RPC, settings, internal receipts, and compatibility imports.

The format is line-oriented, grep-friendly, explicit rather than indentation-sensitive, and intentionally cheap for repeated model consumption.

## Header

```text
SCPLAN 1
plan windows-first-host
summary Make the resident Windows application the orchestration authority.
source human:h-0007#L1-L22
intent REQ-001
```

## Task example

```text
SCPLAN 1
plan capability-aware-task
summary Run bounded research with read-only external knowledge access.

task t-021
size small
title inspect provider behavior
instruction Inspect the current implementation and report the bounded change required.
source human:h-0012#L3-L18
intent REQ-PROVIDER
retrieve lib/*
capability-profile research-readonly
tool-allow builtin.read_file
tool-allow builtin.search_text
tool-allow intent.*
tool-allow mcp.toaster.search
tool-deny builtin.run_command
accept conclusion cites current project evidence
accept no project files are modified
end
```

## Core fields

### `task <id>`
Stable task id. Required.

### `title <text>`
Short bounded outcome. Required.

### `instruction <text>`
Cold-start instruction. Required.

### `size tiny|small|medium|large`
Semantic planning/routing hint assigned by the conversational plane. It is never inferred from file count, line count, regexes, or an arbitrary token threshold.

### `source <ref>`
Repeatable durable provenance reference, commonly `human:<id>` or `human:<id>#Lx-Ly`.

A source is evidence, not automatically current authority. Current Human Directives determine which direct human wording is active.

### `intent <ref>`
Repeatable governing normalized Intent identifier.

### `depends <task-id>`
Repeatable scheduling dependency.

### `relation <type> <target>`
Repeatable semantic relationship that need not block scheduling.

### `retrieve <selector>` / `evidence <selector>`
Repeatable bounded context/evidence selectors.

### `accept <criterion>`
Repeatable observable acceptance criterion.

### `provider <backend-name>`
Optional explicit worker-backend override. Normally omit and allow semantic routing.

### `role <role>`
Defaults to `worker`.

### `human-gate true|false`
Defaults to `false`.

## Capability fields

Capability policy is part of task semantics and participates in the task-definition hash.

### `capability-profile <name>`

Selects an optional machine-defined reusable capability profile. Profiles are **narrowing layers only**. A profile cannot grant anything absent from the machine allow-list.

Typical profile names might be:

```text
capability-profile coding
capability-profile research-readonly
capability-profile critic-safe
```

The task fails closed at dispatch if the named profile does not exist on the machine.

### `tool-allow <pattern>`

Repeatable task-local allow pattern. If any `tool-allow` is present, the task is restricted to capabilities matching those patterns after all earlier policy layers.

Examples:

```text
tool-allow builtin.read_file
tool-allow intent.*
tool-allow mcp.toaster.search
```

### `tool-deny <pattern>`

Repeatable task-local deny pattern. Deny always wins.

```text
tool-deny builtin.run_command
tool-deny mcp.toaster.write_lesson
tool-deny mcp.*
```

Task policy can only narrow inherited access. It cannot use `tool-allow` to create a capability the machine/profile/project/role/stage layers did not already permit.

Effective inherent-worker authorization is:

```text
machine grants
  -> optional capability profile
  -> project policy
  -> role policy
  -> stage policy
  -> task-local allow/deny
```

Provider-owned CLI harnesses manage their own internal tool permissions; these fields govern StatefulClanker's inherent/direct-model worker harness.

## Why capability policy belongs in the task hash

Tool availability can materially change what a worker is capable of doing. A task compiled with shell access is not semantically identical to the same task later restricted to read-only tools.

Therefore changes to:

- `capability-profile`
- `tool-allow`
- `tool-deny`

change the task-definition hash and invalidate older compilations/results before acceptance.

## Human authority chain

Current execution authority is:

```text
verbatim human source
  -> Current Human Directives
  -> reconciled Intent
  -> plan
  -> task
  -> compiled truth packet
```

Workers may inspect the human source and normalized interpretation when policy permits, but neither is writable by workers.

## Parser rules

- UTF-8 text;
- blank lines and `#` comments ignored;
- first whitespace-delimited token is the keyword;
- repeated fields preserve order;
- duplicate task ids are fatal;
- missing title/instruction is fatal;
- size outside `tiny|small|medium|large` is fatal;
- `capability-profile` accepts one profile name;
- `tool-allow` and `tool-deny` are repeatable;
- unknown fields are retained in parser diagnostics/warnings rather than silently changing semantics.

## Compatibility

- `.json` plans remain importable;
- `.scplan` is the preferred planner output;
- internal task persistence remains JSON;
- CLI `task add` exposes matching `-CapabilityProfile`, `-ToolAllow`, and `-ToolDeny` parameters;
- MCP `task_add` exposes matching `capabilityProfile`, `toolAllow`, and `toolDeny` properties.

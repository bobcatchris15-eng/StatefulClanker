# Remove Evil Mode Design

## Goal

Remove StatefulClanker's persistent evil-mode subsystem. Safety validation
remains, but a validation failure is limited to the operation that caused it
and cannot disable later project work.

## Scope

The removal covers the `EVIL` sentinel, all functions that create, clear, or
read that sentinel, the `evil` CLI command, dispatch gates, worker runtime
latching, event types, tray indicator state, tests, and user-facing
documentation that describe evil mode.

Existing `.statefulclanker/EVIL` files are intentionally left on disk. Once
the subsystem is gone they are inert, avoiding an unnecessary destructive
cleanup of project state.

## Architecture

Validation at worker and dispatch boundaries remains local. A command path,
control-state value, or tool request that violates its existing rule returns
the normal error for that call. The error path must neither create persistent
state nor affect readiness, task dispatch, subsequent worker calls, or tray
display.

`StatefulClanker.Core.ps1` will no longer expose evil-mode sentinel helpers.
Callers in execution, autofill, and worker runtime will no longer check a
global evil latch. Worker validation code will report its own errors directly
instead of calling a trip helper.

The tray inspector will no longer deserialize, display, or colorize an evil
state. Event handling will no longer recognize `clanker.evil` or
`clanker.evil_cleared`; these historic events may still exist in old log files
and will be ignored by the normal unknown-event path.

## Components

- `StatefulClanker.ps1`: remove the `evil` status/clear command route.
- `lib/StatefulClanker.Core.ps1`: remove evil sentinel lifecycle and assertion
  helpers.
- `lib/StatefulClanker.Execution.ps1` and
  `lib/StatefulClanker.Autofill.ps1`: remove global evil-latch dispatch
  checks.
- `lib/StatefulClanker.WorkerRuntime.ps1`: preserve per-operation validation,
  but remove calls that trip or consult global evil state.
- `src/StatefulClanker.Tray/Program.cs`: remove the inspector evil flag,
  blinkenlights red mode, and evil event escalation/clear handling.
- tests and documentation: remove evil-mode-specific coverage and references;
  retain or add focused tests proving rejected operations do not create a
  persistent latch or prevent later valid operations.

## Error Handling

Validation failures continue to be actionable exceptions or command failures
at the precise boundary that rejects them. No replacement state file, warning
mode, automatic hold, or task-level disablement is introduced.

Classic Windows slash switches remain accepted as command arguments. They are
not paths and must not be treated as validation failures.

## Testing

Automated tests will prove that:

1. Valid work proceeds without any evil-mode API or sentinel dependency.
2. A rejected path or worker control-state mutation fails that call only and
   does not create `.statefulclanker/EVIL` or block a later valid call.
3. Classic slash switches such as `dir /s /b` remain permitted.
4. The tray project builds after removing evil-mode presentation and event
   handling.

The existing PowerShell test suite, tray build, and whitespace check will be
run as final verification.

## Non-Goals

- Deleting historic `EVIL` files or historical event-log entries.
- Relaxing project-root, path traversal, mutation authority, or other
  operation-level safety validation.
- Changing the already-pending target-pool overview layout work.

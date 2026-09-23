# Capacity and Control-Event Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Permit five concurrent router leases only for explicit auto-routing endpoints, preserve the global worker cap, prevent Connections-grid reentrancy, and restrict orchestrator attention to plan-repair or genuine authority events.

**Architecture:** Endpoint catalog rows carry an explicit `leaseCapacity`; discovery assigns five only to recognized auto-router model IDs, while all other rows default to one. The router counts live leases per route. UI catalog notifications are queued through the WinForms message loop. The control event classifier emits completed, ordinary rejected, and retry events as `fyi`; only plan repair, human authority, intent, and stalled-control conditions require attention.

**Tech Stack:** .NET 8 / WinForms, C# compiled router, PowerShell control plane, PowerShell regression tests.

**Spec:** Approved in the operator conversation on 2026-09-23.

## Global Constraints

- Explicit auto-routing endpoints have capacity 5; fixed-model endpoints have capacity 1.
- Project `maxConcurrent` remains the absolute active-worker cap.
- Catalog writes remain immediate and atomic.
- Ordinary completion, rejection, and retry do not inject orchestrator work.

---

### Task 1: Route lease capacity

**Files:**
- Modify: `src/StatefulClanker.Router/Models.cs`
- Modify: `src/StatefulClanker.Router/RouterEngine.cs`
- Modify: `tests/CompiledRouter.Tests.ps1`

**Interfaces:**
- Produces `EndpointEntry.leaseCapacity` and route-level live-lease counting.

- [ ] Write router tests that acquire five leases on an auto-router fixture, reject a sixth, and retain one-lease behavior for a fixed model.
- [ ] Run `pwsh -NoProfile -File tests/CompiledRouter.Tests.ps1` and confirm the capacity assertions fail before the router change.
- [ ] Add `leaseCapacity` with default 1, count leases by route, and replace exclusive checks in acquire and snapshot selection with capacity checks.
- [ ] Re-run `pwsh -NoProfile -File tests/CompiledRouter.Tests.ps1` and confirm all router assertions pass.

### Task 2: Auto-router catalog classification

**Files:**
- Modify: `src/StatefulClanker.Tray/ApiConnectionsUi.cs`
- Modify: `src/StatefulClanker.Router/FreeCapacityManager.cs`
- Test: `tests/TargetPoolSelection.Tests.ps1`

**Interfaces:**
- Produces `leaseCapacity=5` only when model IDs identify OpenRouter/Kilo auto routes.

- [ ] Write a selection/catalog test proving `kilo-auto/free` receives capacity 5 and an ordinary model receives 1.
- [ ] Run the test and confirm the new expectations fail before classification exists.
- [ ] Add a shared auto-route classifier at catalog construction points without changing operator-selected fixed routes.
- [ ] Re-run the target-pool test and confirm it passes.

### Task 3: Deferred catalog UI refresh

**Files:**
- Modify: `src/StatefulClanker.Tray/Program.cs`
- Test: `tests/TargetPoolChangeDispatcher.Tests.ps1`

**Interfaces:**
- Produces one queued refresh for one or more synchronous catalog changes.

- [ ] Write a test that proves a catalog notification queues—not invokes—the refresh inline and coalesces duplicate requests.
- [ ] Run it and confirm it fails against the synchronous handler.
- [ ] Queue target-pool dependent view updates with `BeginInvoke`, preserving the immediate atomic catalog write.
- [ ] Re-run the dispatcher and overview tests and confirm they pass.

### Task 4: Orchestrator attention filtering

**Files:**
- Modify: `lib/StatefulClanker.Eventing.ps1`
- Test: `tests/TerminalEscalation.Tests.ps1`

**Interfaces:**
- Produces `fyi` levels for ordinary `task.completed`, `state.proposal_rejected`, and retry events; retains `attention` for `task.plan_repair_required`, `autofill.stalled`, and failed validator infrastructure.

- [ ] Write classifier assertions for normal completion/rejection/retry and plan-repair escalation.
- [ ] Run the focused test and confirm ordinary lifecycle events currently produce attention.
- [ ] Narrow `Get-SCControlEventLevel` to promote only events requiring orchestration action.
- [ ] Re-run the focused event test and confirm it passes.

### Task 5: Verify and package

**Files:**
- Verify: `tests/CompiledRouter.Tests.ps1`, `tests/TargetPoolSelection.Tests.ps1`, `tests/TargetPoolChangeDispatcher.Tests.ps1`, `tests/OverviewUi.Tests.ps1`, `tests/TerminalEscalation.Tests.ps1`
- Build: `src/StatefulClanker.Tray/StatefulClanker.Tray.csproj`

- [ ] Run all focused tests and a clean tray build.
- [ ] Run `git diff --check` and inspect the working tree.
- [ ] Commit the behavior and build the next installer only after verification is clean.

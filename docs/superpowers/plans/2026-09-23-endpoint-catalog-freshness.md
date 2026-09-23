# Endpoint Catalog Freshness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep operator endpoint selections and Route Doctor's model catalog immediately usable by the router.

**Architecture:** The Connections UI persists an individual checkbox change to the machine endpoint catalog instead of holding it behind a separate save action. The router already reloads that catalog for each acquire request. Route Doctor's catalog loop caps successful model-list refreshes at 15 minutes while retaining a shorter retry on failures.

**Tech Stack:** C#/.NET 8 WinForms, compiled router, PowerShell regression scripts.

**Spec:** User-approved in-chat design, 2026-09-23.

## Global Constraints

- Preserve the existing atomic `endpoints.json` store write.
- Never perform synthetic inference as a catalog probe.
- Do not expose credentials in diagnostics or tests.

---

### Task 1: Restore and validate the Connections UI

**Files:**
- Modify: `src/StatefulClanker.Tray/ApiConnectionsUi.cs`
- Test: `dotnet build src/StatefulClanker.Tray/StatefulClanker.Tray.csproj --no-restore`

- [ ] Restore the missing tracked UI source.
- [ ] Run the tray build and verify the missing connection/target-pool types compile.

### Task 2: Persist model selection immediately

**Files:**
- Modify: `src/StatefulClanker.Tray/ApiConnectionsUi.cs`
- Test: `tests/ApiConnectionsSelection.Tests.ps1`

- [ ] Write an integration-style test that runs the selection persistence seam against a temporary endpoint catalog.
- [ ] Run it and observe the current deferred-save behavior fail.
- [ ] Move the row-to-target-pool mutation into a reusable persistence method and invoke it on checkbox changes.
- [ ] Verify the test passes and the tray builds.

### Task 3: Cap catalog freshness

**Files:**
- Modify: `src/StatefulClanker.Router/FreeCapacityManager.cs`
- Modify: `tests/ProviderProbeCatalog.Tests.ps1`

- [ ] Add a failing assertion for a catalog-only provider's maximum silent refresh interval.
- [ ] Cap catalog refresh cadence at 15 minutes without changing failure retry behavior.
- [ ] Run the provider catalog and compiled-router regression tests.

### Task 4: Verify the full repair

**Files:**
- Test: `tests/GeminiAdapter.Tests.ps1`
- Test: `tests/CompiledRouter.Tests.ps1`

- [ ] Run the tray build and all focused regressions.
- [ ] Confirm AI Studio transport tests remain green; report the live HTTP 429 as quota exhaustion rather than a protocol failure.

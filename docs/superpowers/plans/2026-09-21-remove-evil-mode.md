# Remove Evil Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the persistent evil-mode safety subsystem while preserving local validation failures and ship it as version 0.8.13.

**Architecture:** Worker and dispatch validation will continue to reject invalid operations in place, but no code will write or inspect an `EVIL` sentinel. CLI, tray, events, tests, and documentation will have their obsolete evil-mode contracts removed. The release is built only from the verified removal commit.

**Tech Stack:** PowerShell 7, .NET WinForms / C#, Pester-style PowerShell tests, Inno Setup, GitHub CLI.

**Spec:** `docs/superpowers/specs/2026-09-21-remove-evil-mode-design.md`

## Global Constraints

- Preserve project-root, path traversal, mutation authority, and control-state validation.
- A validation failure must not create persistent project state or block later valid work.
- Existing `.statefulclanker/EVIL` files remain untouched and inert.
- Retain classic Windows slash command switches such as `dir /s /b`.
- Do not include unrelated pending target-pool layout changes in this release unless they are already intentionally part of the working tree commit.
- Release as `0.8.13` only after the PowerShell tests, tray build, and whitespace check succeed.

---

### Task 1: Replace evil-mode tests with local-validation regression coverage

**Files:**
- Modify: `tests/EvilMode.Tests.ps1`
- Modify: `lib/StatefulClanker.WorkerRuntime.ps1:100-250`

**Interfaces:**
- Consumes: `Assert-SCWorkerMutablePath`, `Assert-SCWorkerCommandSafe`, and a temporary project task.
- Produces: tests proving rejected worker operations throw locally, do not depend on `Test-SCEvilLatched`, and do not prevent a following valid command.

- [ ] **Step 1: Write failing local-validation tests**

Replace latch assertions with a helper that asserts an operation throws its existing path/control error. Cover an outside file, an orchestration control path, `dir /s /b`, and a subsequent safe in-project command. Assert no `EVIL` file is created in the temporary project.

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `pwsh -NoProfile -File .\tests\EvilMode.Tests.ps1`

Expected: FAIL while worker validation still calls evil-mode helpers.

- [ ] **Step 3: Remove worker runtime latching**

Remove each `Set-SCEvilTrip` call from `Assert-SCWorkerPath`,
`Assert-SCWorkerMutablePath`, and `Assert-SCWorkerCommandSafe`; leave their
existing `throw` statements intact. Remove `Assert-SCNotEvil` at worker tool
entry and model-loop boundaries, plus post-tool `Test-SCEvilLatched` halts.

- [ ] **Step 4: Run focused test to verify it passes**

Run: `pwsh -NoProfile -File .\tests\EvilMode.Tests.ps1`

Expected: PASS, with invalid operations rejected only at their own boundary.

- [ ] **Step 5: Commit the tested worker changes**

Run: `git add tests/EvilMode.Tests.ps1 lib/StatefulClanker.WorkerRuntime.ps1 && git commit -m "Remove worker evil mode latch"`

### Task 2: Remove global evil-mode runtime and CLI contracts

**Files:**
- Modify: `lib/StatefulClanker.Core.ps1:116-153`
- Modify: `lib/StatefulClanker.Execution.ps1:201`
- Modify: `lib/StatefulClanker.Autofill.ps1:109`
- Modify: `StatefulClanker.ps1:62`

**Interfaces:**
- Consumes: normal initialization, hold, readiness, dispatch-authority, and validation contracts.
- Produces: no exported evil-mode sentinel lifecycle, assertion, or CLI route.

- [ ] **Step 1: Write a source-level regression check**

Extend `tests/EvilMode.Tests.ps1` to read these four files and assert the evil-mode symbols `Get-SCEvilPath`, `Test-SCEvilLatched`, `Set-SCEvilTrip`, `Clear-SCEvilTrip`, `Assert-SCNotEvil`, and the CLI route `'evil'` are absent.

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `pwsh -NoProfile -File .\tests\EvilMode.Tests.ps1`

Expected: FAIL because the core helpers and CLI route still exist.

- [ ] **Step 3: Delete the global contracts**

Delete the evil sentinel helper block from Core, remove `Assert-SCNotEvil` from execution and autofill dispatch gates, and delete the CLI `evil` switch route. Do not delete or modify existing `EVIL` files.

- [ ] **Step 4: Run the focused test to verify it passes**

Run: `pwsh -NoProfile -File .\tests\EvilMode.Tests.ps1`

Expected: PASS.

- [ ] **Step 5: Commit the core and CLI removal**

Run: `git add StatefulClanker.ps1 lib/StatefulClanker.Core.ps1 lib/StatefulClanker.Execution.ps1 lib/StatefulClanker.Autofill.ps1 tests/EvilMode.Tests.ps1 && git commit -m "Remove persistent evil mode controls"`

### Task 3: Remove tray visual and event handling

**Files:**
- Modify: `src/StatefulClanker.Tray/Program.cs:344-720,1167-1438,1961-1964,2918-2921`
- Test: `src/StatefulClanker.Tray/StatefulClanker.Tray.csproj`

**Interfaces:**
- Consumes: `ProjectMetrics`, active agent data, normal event refresh, and `BlinkenRack.SyncAgents`.
- Produces: tray metrics and lights with no evil-mode field, scanner, color override, or event escalation.

- [ ] **Step 1: Add a textual tray regression assertion**

Add assertions in `tests/EvilMode.Tests.ps1` that `Program.cs` contains none of `IsEvil`, `SetEvil`, `EvilMode`, `clanker.evil`, or `clanker.evil.cleared`.

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `pwsh -NoProfile -File .\tests\EvilMode.Tests.ps1`

Expected: FAIL because the tray currently reads the sentinel/events and paints the red override.

- [ ] **Step 3: Remove tray evil state**

Delete `ProjectMetrics.Evil`, its population, `IsEvil`, per-bank `EvilMode`,
the `BlinkenRack` evil field and `SetEvil`, red rendering branches, evil event
types, and the snapshot call. Keep normal active-agent display and refresh
behavior intact.

- [ ] **Step 4: Run focused test and build**

Run: `pwsh -NoProfile -File .\tests\EvilMode.Tests.ps1; dotnet build .\src\StatefulClanker.Tray\StatefulClanker.Tray.csproj --no-restore`

Expected: tests PASS and build succeeds with zero errors.

- [ ] **Step 5: Commit the tray removal**

Run: `git add src/StatefulClanker.Tray/Program.cs tests/EvilMode.Tests.ps1 && git commit -m "Remove evil mode tray indicator"`

### Task 4: Remove docs, set release version, and verify source

**Files:**
- Modify: `README.md` and any file returned by `rg -n -i evil --glob '!docs/superpowers/**'`
- Modify: `install/Build-Installer.ps1`, `install/StatefulClanker.iss`, `src/StatefulClanker.Tray/StatefulClanker.Tray.csproj`
- Test: `tests/EvilMode.Tests.ps1`, `tests/ReflexiveKnowledge.Tests.ps1`, `src/StatefulClanker.Tray/StatefulClanker.Tray.csproj`

**Interfaces:**
- Consumes: project release version convention (current `0.8.12`) and installer build scripts.
- Produces: user-facing version `0.8.13`, no live evil-mode docs, and verified source tree.

- [ ] **Step 1: Search for remaining references**

Run: `rg -n -i evil --glob '!docs/superpowers/**' --glob '!bin/**' --glob '!obj/**'`

Expected: only test names may remain temporarily; no runtime, tray, CLI, or documentation contract remains.

- [ ] **Step 2: Update remaining docs and version fields**

Remove user-facing evil-mode text. Change each established release version field from `0.8.12` to `0.8.13` consistently.

- [ ] **Step 3: Run complete source verification**

Run: `pwsh -NoProfile -File .\tests\EvilMode.Tests.ps1; pwsh -NoProfile -File .\tests\ReflexiveKnowledge.Tests.ps1; dotnet build .\src\StatefulClanker.Tray\StatefulClanker.Tray.csproj --no-restore; git diff --check`

Expected: all tests and build succeed; whitespace check reports no errors.

- [ ] **Step 4: Commit the release-ready change**

Run: `git add README.md install/Build-Installer.ps1 install/StatefulClanker.iss src/StatefulClanker.Tray/StatefulClanker.Tray.csproj tests/EvilMode.Tests.ps1 && git commit -m "Release 0.8.13 without evil mode"`

### Task 5: Build, publish, and install version 0.8.13

**Files:**
- Create: `install/output/StatefulClankerSetup-0.8.13.exe` (generated, not committed)

**Interfaces:**
- Consumes: verified release commit, release tag, Inno Setup build script, configured Git remote, and GitHub CLI authentication.
- Produces: pushed `main`, pushed annotated tag `v0.8.13`, GitHub release with installer asset, and locally installed 0.8.13 application.

- [ ] **Step 1: Verify repository state and build installer**

Run: `pwsh -ExecutionPolicy Bypass -File .\install\Build-Installer.ps1`

Expected: `install/output/StatefulClankerSetup-0.8.13.exe` exists and the script reports success.

- [ ] **Step 2: Hash the installer**

Run: `Get-FileHash .\install\output\StatefulClankerSetup-0.8.13.exe -Algorithm SHA256`

Expected: a non-empty SHA-256 value for the release notes.

- [ ] **Step 3: Push the verified release source and tag**

Run: `git push origin main; git tag -a v0.8.13 -m "StatefulClanker 0.8.13"; git push origin v0.8.13`

Expected: remote `main` and `v0.8.13` resolve to the verified release commit.

- [ ] **Step 4: Create hosted release and attach installer**

Run: `gh release create v0.8.13 .\install\output\StatefulClankerSetup-0.8.13.exe --title "StatefulClanker 0.8.13" --notes "Removes the persistent evil-mode latch while retaining operation-level validation."`

Expected: GitHub returns a release URL with the installer asset.

- [ ] **Step 5: Install and verify the local application**

Run the installer silently, then inspect `C:\Users\chris\AppData\Local\Programs\StatefulClanker\StatefulClanker.exe` version information.

Expected: installed product/file version is `0.8.13`.

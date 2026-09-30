# StatefulClanker 0.9.2 verification

Baseline: published v0.9.1 at `eb9d9ff662d4a94911c1a18fe800277851264f25`. Audit corrections are committed separately in the audit checkout at `16aa6be`; this release carries a corrected evidence-ledger snapshot and explicit source/runtime identities.

## Passed checks

Each script was executed in a separate `pwsh -NoProfile` process against isolated test projects. All 24 exited 0:

- CandidatePreservation
- WorkerSearch
- CompactPlanInstruction
- RetrievalHealth
- ExecutionProjection
- CompletionManifest
- PacketCompilation
- Concurrency
- AcceptanceGate
- CommitGateFreshness
- WorkerSession
- WorkerRuntimeProtocol
- WorkerPolicy
- BoundaryViolation
- RecoveryEvidence
- ControlPlaneRecovery
- ExecutionSignalShadow
- SignalEnvelope
- DirectivesEventing
- ControlEventLevel
- PlanStartupGuard
- PiStartupDelivery
- TransparentInferenceFailover
- Mcp (10 scenarios)

Run form: `pwsh -NoProfile -File tests/<name>.Tests.ps1`. Local logs are under `scratch/verification-0.9.2/`. CandidatePreservation was also rerun after adding the integrated-but-uncredited case and passed.

The router Debug build passed with zero warnings and errors. The installer build is a separate packaging gate; its final result, source tag, asset size, and checksum are recorded in the GitHub release.

## Reproduced cases

- A worker commits its own validated artifact before integration; the existing commit merges and task completion is credited.
- A committed failed candidate and a dirty artifact before a transient failure both retain addressable Git recovery references.
- Rebuilding and cleaning the same task's worktree does not delete its earlier preserved candidate.
- Empty validated candidates are not integrated; evidence-only bytes survive without automatically becoming a merged change.
- A merged candidate with failed task credit remains recorded as integrated but uncredited.
- Failure to save a candidate keeps the worktree instead of deleting its bytes.
- Nested worktree searches find legitimate files and exclude control files relative to the worker root; literal/no-match coverage is explicit.
- Retrieval distinguishes absent selectors, unmatched selectors, delivered content, and boundary exclusion.
- Both plan parsers preserve full instruction and acceptance text, refuting the audit's truncation claim.
- Actual candidate submission preserves bounded advisory warnings, uncertainty, and negative findings.
- Manifests preserve those notes and producing-source identity; dependency projections reject manifests made stale by a task retry.
- ERROR does not imply substantive rejection; PASS retires earlier correction; explicit retry removes old active feedback.
- Compiled packets and continuation messages expose current infrastructure feedback and the task's own preserved candidate identity.
- Legacy dependency text obeys small and zero budgets while keeping available structured error/validation evidence.

## Limits

This is focused regression and packaging verification, not the entire repository test suite or an installed UI playthrough. Test providers and local servers exercise the harness deterministically; they do not demonstrate behavior across every remote model/provider. The running installation was not restarted, modified, or replaced. Experimental lateral communication, model diversity, and an authority-sensitive RPK schema migration remain outside this release.

# Collective-intelligence audit corrections and release applicability

This is a follow-up to the completed audit in `E:\sc-0828-clean\experiments\collective-intelligence-audit`, whose pre-correction HEAD is `a188c1476bca90009d1a43c0e28d2c726a04f140`. Original reports remain historical evidence. These corrections supersede the cited assertions; they are not additional independent worker votes. The user authorized implementation after the audit ended.

## Corrections to the evidence ledger

| Claim | Correct disposition and evidence |
|---|---|
| C-303, C-205c: compact-plan reader truncates instruction values, forcing whole-plan reads | Refuted as a parser diagnosis. Both Plan and CapabilityTasks split at whitespace into at most two parts: keyword and the full remainder. Other recognized task fields are parsed separately. Observed workers reading shared plans may still expose sibling frames, but the parser does not force that read. `tests/CompactPlanInstruction.Tests.ps1` exercises both definitions. |
| Five contaminated C reports; “6+ uncontaminated” support including C04 | Unsupported count. The C scope and operating log identify C02 and C04. The retrospective's five-report figure is unreconciled. C06–C08 truncation in the synthesis does not establish either contamination or their findings. Use named reports and provenance, not the disputed count. |
| G03: worktrees share one index and every Git operation contends on a repository-global lock | Refuted as stated. Worktrees share common objects/refs but have distinct index paths. Serial dispatch and integration observations remain separate evidence; universal lock contention was not measured. |
| 24,000 characters / 274,934 bytes = 8.73% of required reading | Invalid units. A–F measured 273,872 .NET string characters at review time: approximately 8.76% startup packet coverage. This is not total accessible reading through tools. Other byte-denominated percentages remain unverified until counted in comparable units. |
| Incident 64 repeats “validator-approved” incident 62 exactly | Narrowed. Both record committed artifacts becoming orphaned while task state reads needs_rework. The retrospective task/run checked had null latestValidationId and null candidatePreflight. Validation approval for the second case is not established by those receipts. |
| Lateral content mechanisms cannot ever be useful | Scoped to this independent audit and its observed batch/integration constraints. Coverage counts, silence, and shared framing do not prove a universal product prohibition. No new lateral channel is introduced in this release. |

## Version identities

Three identities must be kept separate: the source inspected by a report; the installed harness that executed the experiment; and the published release receiving a repair. The audit dossier sampled eight differing library files. This does not invalidate source inspection, but it prevents attributing runtime behavior to those lines without verification.

The release baseline is v0.9.1, commit `eb9d9ff662d4a94911c1a18fe800277851264f25`. It already includes worker-root retrieval allowance, retrieval-health counters/signals, completion manifests, execution projections, a lesson writer, and compiled-router inference/failure verbs. The old absent-feature recommendations are not reapplied wholesale.

`AUDIT_VERSION_IDENTITIES_2026-09-30.json` records the audit checkout, published baseline, and read-only installed-runtime identity captured during this work. Paths describe this machine; SHA-256 values and commits are the durable evidence. A file hash is explicitly a hash of bytes on disk, not proof of the bytes already loaded in another process.

New compilation receipts contain `runtimeIdentity`: harness home, source commit when the harness is a repository root, harness/library file hashes, and effective function origins. This metadata remains outside semantic task read sets. Completion manifests retain the producing compilation's identity. Missing identities stay null rather than being guessed from the consuming runtime.

## Implemented repairs and verification

- Worktree integration distinguishes a worker's existing commits from absence of changes. Teardown saves dirty bytes, protects committed candidates with unique recovery refs and durable records, and retains the worktree if preservation fails. Recovery records identify actual task/validation/integration state; preservation never grants acceptance.
- Own preserved candidates are projected to replacement workers. No sibling branch discovery is added.
- Search exclusions use paths relative to the worker root, preserving legitimate files beneath `.statefulclanker/worktrees`. Results disclose literal matching, coverage, exclusions, read/enumeration errors, and result limits.
- Retrieval diagnoses not-requested, unmatched, boundary-excluded, budget-exhausted, partial, and delivered outcomes. Worker-local Git/control files remain excluded.
- Current acceptance ERROR is distinct from substantive rejection. PASS retires earlier corrective feedback. Explicit retry invalidates old active corrections and clears obsolete validation/routing fields while durable history remains available.
- Dependency manifests with mismatched task definition/control revision are not delivered as current. Legacy fallback projects available validation and run evidence; its total text allocation cannot exceed the configured budget.
- Candidate finish accepts bounded advisory successor warnings, uncertainties, and negative findings; manifests and dependency projections preserve them alongside provenance. The lesson prompt uses the registered `record_lesson` name.
- Exercising finish exposed the reserved PowerShell `$Args` parameter discarding candidate arguments; it is renamed and tested through persisted sessions. Feedback ordering casts date values directly rather than converting them to culture-formatted strings that lose sub-second precision.

Focused tests exercise candidate preservation, nested search/retrieval, parser behavior, handoff provenance/limitations, stale dependencies, and corrective lifecycle. Existing concurrency, acceptance/freshness, recovery, signal, and worker protocol tests provide regression coverage. Release notes record the actual final test results; this document does not claim live-installation verification.

Remaining experimental questions include lateral event filtering, model diversity, authority-sensitive RPK schema migration, and independent-run retry-base policy. They are not silently implemented by this repair release.

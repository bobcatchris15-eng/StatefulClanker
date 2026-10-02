# Provider campaign harness prelive audit

## Finding

The harness is cleared for the preregistered, bounded campaign after a fresh campaign freeze. The reviewed harness now preserves the distinction between model output and deterministic protocol wrapping, rejects stale or altered frozen inputs before dispatch/evaluation, and accounts for failed payload slots without inventing content. This audit made no provider inference requests. The current run directory remains undispatched.

## Independent verification

The focused offline suite passed 11/11 tests in 74.9 seconds:

```powershell
python -m unittest research.external-cognition.router.tests.test_provider_experiment -v
```

I also ran a separate fake-dispatch probe over one model family and both representation conditions. It made 12 fixture dispatches and no network calls. The public problem object matched byte-decoded structure for all 12 corresponding role/seed prompt pairs. For all six reviewer/shared-integrator payload roles, the compiled read references matched the role's saved pre-dispatch compiler context.

The selected allowlist map currently has four distinct Kilo Free routes: Liquid, North Mini Code, Laguna XS, and Nemotron 3 Nano Omni. Each requested model ID is an exact `:free` ID and its pinned catalog digest matches current bytes. Gemma remains outside this campaign's selected map; its readiness failure and the pre-freeze replacement are recorded in the preregistration. The separate setup probes are not experimental outcomes.

## Contract checks

The full and payload arms each create an isolated protocol workspace for both public cases. The generator includes the same complete public packet in the paired prompts; payload prompts request role-specific JSON only. The payload compiler enforces duplicate-free strict JSON, exact role schemas, integer residues, and allowed fields. It copies participant coefficient/assessment/coordinate values into a fixed envelope, supplies protocol identity and pre-pinned references, and keeps reviewer corrections as uncommitted candidates. Invalid payload bytes are retained and submitted unchanged for structural rejection. The evaluator is called only by the offline evaluation path after all eight conditions have complete 12-slot records; it has no live participant feedback path.

The 96-slot schedule and frozen condition order are explicit. Each role request is saved before launch with one user message, requested token/temperature/timeout settings, and request/prompt hashes. Two calls per phase are dispatched in parallel, and each phase completes before the next starts. The live adapter path invokes the frozen dispatcher DLL directly, not `dotnet run`; its implementation makes one provider send, disables redirects, and does not retry or migrate. A condition cannot resume after it has started. Every transport error consumes a durable slot; payload transport failures receive a compiler receipt with `payload_valid: null`, distinct from an invalid returned payload.

The campaign manifest pins generator, tests, pilot, protocol, Lab 3 dependency, dispatcher source, and the built dispatcher package. The selection map, preregistration, allowlists, catalogs, and initial payload compile contexts are frozen inputs. Loading a campaign verifies source, runtime-package, catalog/input, condition identity, and initial-prompt hashes. The command-path test verifies that the frozen DLL and colocated allowlist/catalog are used. Evaluation verifies all 96 outcomes, each 12-slot condition digest, and required payload receipts; the tamper regression confirms altered slot results are refused.

Dispatcher receipts retain request/response/content hashes, returned model ID, provider request ID, usage fields, finish reason, status, and timing. Slot metadata copies provider ID and reported token counts while preserving missing usage as null. Raw provider response bodies, extracted content, model payload bytes, compiled envelopes, and protocol submissions remain separate artifacts.

## Limits

The 11 tests and fixture probe establish local structural and accounting behavior; they do not test provider availability, quota, live alias behavior, or remote completion latency. Four free-provider setup probes were reported separately as successful by the coordinator; no experiment slot has been dispatched at the time of this audit. The output-path guard in the underlying dispatcher uses lexical path containment and does not resolve Windows junction/symlink targets, so use direct, non-linked research output directories outside the router root.

# Independent pre-live audit

Date: 2026-10-01. Reviewer: independent cycle-2 validator. This review covered the frozen task rules and current `core.py` / `lab.py`, their tests, and the command-line workflow. No subjects were used during validation.

## Findings and disposition

- The first audit pass found two release-blocking defects: run initialization rejected its own newly created lock file, and a checked transition could continue from a prior frontier whose costs had been changed while retaining a valid checksum, problem hash, and structurally consistent history. Both defects were corrected before dispatch. The second finding now has regression coverage at both the core transition and checked prompt boundary; checked prompt generation fails closed on semantically corrupt persisted state.
- Submission recovery was also hardened after review identified a crash window between state commit and receipt creation. The final runtime journals the accepted state and receipt together and records an evaluator receipt for an orphaned raw response after interruption. An injected state-write interruption recovers to one accepted transition without losing the exact raw output.
- A stale-version or malformed/rejected response leaves `state.bin` byte-for-byte unchanged while retaining the raw response. Valid checked transitions increment the version and preserve their history. The unchecked arm continues to enforce structural/version rules without inferring the mathematically correct frontier, as specified.
- A final prompt review caught a subject-facing semantic error: the legality expression `(b+x+y) mod 2` had been labeled as the next boundary. In fact, it is the parity test; the next boundary is `y`. The stage and calibration prompts now state these separately, and a regression uses a legal case where parity is 1 while outgoing boundary is 0. No subjects had been launched before this correction.
- Cost-update checks confirm exact prefix reuse and suffix recomputation. The registered intervention is material: for seed 1101 and four stages, the original optimum is cost 11 / `10000001`; changing zero-based stage 1 `wx` from 3 to 1 yields cost 11 / `01100001`.
- The vector and record prompts expose numeric frontier rows. The JSON and packed codecs round-trip the same state; packed bytes are compressed/checksummed storage, not a learned latent representation. Calibration and stage prompts do not include an oracle answer or hidden key. The calibration scorer enforces the registered `{cost,bits}` answer schema.
- CLI smoke covered initialization, prompt emission, checked submission, malformed-response rejection with unchanged store bytes, cost invalidation, summary, and calibration prompt generation. Subject-facing prompts are local to the requested task and do not expose scoring artifacts.

## Verification

The full suite completed with **27 tests passing and one platform skip** (`test_reject_paths_outside_run_and_response_id_paths`, because this Windows environment does not permit symlink creation). After the final prompt correction, all 14 runtime tests passed with the same one platform skip. Independent probes enumerated every frontier prefix for 45 generated tasks (1–6 stages, five seeds each) and compared them with exhaustive search. They also changed every possible stage in 15 fully computed tasks (1–5 stages, three seeds each), checked the exact preserved prefix, recomputed suffix, and compared the final frontier and optimum against exhaustive enumeration.

## Scope limits

This audit establishes implementation behavior on the specified synthetic task family and local CLI. It does not establish subject performance, a native capacity limit, a general reasoning benefit, or access to learned hidden-state representations. Those remain live-experiment or future-backend questions under the preregistered interpretation limits.

# Lab4 External Reasoning Protocol Implementation Plan

> **For agentic workers:** Execute the scoped plan task by task, keeping tests ahead of implementation. The protocol is structural only; no module may judge mathematical correctness during submission or replay.

**Goal:** Build a reproducible SQLite event-log protocol and nativepilot harness for a bounded two-case test of external proposals, challenges, evidence, retractions, and conclusions.

**Architecture:** `protocol.py` owns canonical integer-only JSON, immutable received-message and event storage, transactional append, claims projection, directed inbox reads, and deterministic replay. `pilot.py` owns the separate Lab3 case adapter, frozen participant prompts, raw-byte receipts, CLI stages, and offline arithmetic evaluator. Tests use only the standard library and temporary databases; pilot imports Lab3 by known path without modifying it.

**Tech Stack:** Python standard library, SQLite, unittest, subprocess/multiprocessing.

**Spec:** `DESIGN.md`, `PROTOCOL.md`, and `PREREGISTRATION.md` in this directory.

## Global Constraints

- Use the standard library only; do not install a provider framework.
- Do not alter Lab3 or its live-cycle artifacts.
- Envelopes contain exactly `schema_version`, `problem_id`, `message_id`, `sender`, `recipients`, `intent`, `read_refs`, `payload`, and `reply_to`; version 1 has six allowed intents.
- Read refs pin `{resource_id, revision, state_revision}`; claim records also carry value/state revisions and dependencies pin `{resource_id, claim_revision}`.
- Accept arbitrary structured JSON payloads, but reject duplicate keys, floats, non-UTF8, unknown top-level fields, and malformed structural references.
- Persist append-only immutable messages/events and reconstruct claims deterministically by replay.
- Message IDs are idempotent for exact original bytes and rejected for different bytes.
- Reject stale reads on non-PROPOSE intents. Retain structurally valid stale PROPOSE messages as potential forks only when all pinned refs share a reconstructable historical snapshot.
- Preserve challenged claims and candidate corrections; retractions/replacements operationally invalidate declared dependents.
- Record structural statuses only; do not encode semantic belief or claim truth.
- Preserve exact prompt and raw response bytes before parsing, with model/route metadata and hashes.
- Freeze prompt templates, fields, and read references before participant calls.
- Pilot uses seeds 4201 and 4202, two proposers, two peer reviewers, and two integrators per case; 12 fresh calls total.
- Evaluator runs offline and checks arithmetic only after submissions are saved.

### Task 1: Freeze interface plan against architecture contract

**Files:**
- Read: `DESIGN.md`, `PROTOCOL.md`, `PREREGISTRATION.md`
- Modify: `PLAN.md`

- [x] Copy the exact v1 envelope and claim fields from `PROTOCOL.md` into global constraints.
- [x] Reconcile the frozen prompt schedule and file outputs with `PREREGISTRATION.md` before implementing pilot behavior.
- [x] Send the public Python API and CLI contract to the coordinating agent.

### Task 2: Specify canonical envelopes and immutable event behavior with tests

**Files:**
- Create: `tests/test_protocol.py`
- Create: `protocol.py`

**Interfaces:**
- `canonical_bytes(value)` returns deterministic UTF-8 bytes or rejects unsupported values.
- `parse_envelope(raw_bytes)` strictly parses the v1 schema.
- `initialize_store(path, problem_id, participants, problem_packet)` creates the DB and immutable problem resource at revision 1.
- `submit(path, raw_bytes)` returns an accepted event receipt or stable rejection code.

- [x] Write failing tests for strict envelope keys/types, six intents, integer-only canonical JSON, stable SHA-256, idempotent exact-byte append, conflict rejection, and retained rejected raw bytes.
- [x] Run tests and confirm failures are due to missing behavior.
- [x] Implement canonicalization, schema checks, event hashes, and append-only SQLite tables with atomic conflict handling.
- [x] Run focused tests and confirm pass.

### Task 3: Specify snapshot concurrency, projection and replay with tests

**Files:**
- Modify: `tests/test_protocol.py`
- Modify: `protocol.py`

**Interfaces:**
- `get_projection(path, problem_id)` returns deterministic current claim/review state.
- `inbox(path, problem_id, recipient)` returns only messages addressed to that recipient, in event sequence order.
- `replay(path, problem_id)` rebuilds the projection solely from committed event rows.

- [x] Add tests for shared-snapshot disjoint proposals, stale proposal forks, directed mailbox isolation, challenge visibility, recursive retract/replacement invalidation, deterministic replay, and operational (non-semantic) status.
- [x] Add a true multi-process test with two disjoint proposal commits from the same immutable snapshot.
- [x] Run tests and confirm expected red failures.
- [x] Implement transactional stale-reference validation, scoped inbox queries, projection transitions, dependency invalidation, potential fork snapshots/resolution, and deterministic replay.
- [x] Run protocol tests and confirm green.

### Task 4: Specify nativepilot preparation and frozen prompt flow with tests

**Files:**
- Create: `tests/test_pilot.py`
- Create: `pilot.py`

**Interfaces:**
- `prepare(out_dir)` creates seeds 4201/4202 cases and frozen call manifest.
- `role_prompt(run_dir, case_seed, role)` returns the exact saved prompt path for a scheduled role.
- `final_prompts(run_dir, case_seed)` materializes both final-integrator prompts after reviews are committed.

- [x] Write failing tests for importing Lab3 `make_case` by known path, deterministic seeds, full-problem visibility, frozen role prompts/read references, call count/order, and raw-only/shared final prompt pairing.
- [x] Run tests and confirm expected red failures.
- [x] Implement preparation, prompts, manifest, and CLI; persist prompt bytes and hashes.
- [x] Run focused tests and confirm green.

### Task 5: Specify raw receipts, structural submission and offline evaluation

**Files:**
- Modify: `tests/test_pilot.py`
- Modify: `pilot.py`

- [x] Test byte-for-byte raw response retention before parsing, malformed response audit receipts, immutable prompt/raw hashes, and structural-only protocol interaction.
- [x] Test the final-integrator message condition and raw-only condition share identical problem facts.
- [x] Test offline arithmetic scoring uses Lab3's generated world and never affects submission or prompt construction.
- [x] Implement submission, receipt, final prompt, and offline-only evaluation APIs.
- [x] Run the full Lab4 test suite and confirm green.

### Task 6: Document run procedure and audit boundary

**Files:**
- Create: `README.md`
- Create: `ENGINE_RECEIPT.md`
- Modify: `PLAN.md`

- [x] Document exact filenames, commands, API/CLI schemas, envelope and batch schemas, participant call order, output layout, and evaluation boundary.
- [x] Record implementation/test evidence and known limitations in `ENGINE_RECEIPT.md` and `PILOT_RECEIPT.md`.
- [x] Mark plan steps complete only when corresponding evidence exists.

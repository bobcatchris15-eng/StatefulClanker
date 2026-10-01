# Lab 4 external reasoning protocol

Lab 4 is a small provider-neutral prototype for recording structured proposals and reviews in shared state. The envelope and SQLite engine enforce message shape, participant routing, revision freshness, and event history. They do not check whether a claim or conclusion is mathematically true. The two-case Luna pilot and its exact run artifacts are documented separately in [README_PILOT.md](README_PILOT.md).

The contract is in [PROTOCOL.md](PROTOCOL.md); [DESIGN.md](DESIGN.md) and [PREREGISTRATION.md](PREREGISTRATION.md) describe the pilot's scope and frozen schedule. Lab 4 imports Lab 3's deterministic `make_case` generator by path and does not modify Lab 3.

## Message envelope

Version 1 envelopes contain exactly these fields: `schema_version`, `problem_id`, `message_id`, `sender`, `recipients`, `intent`, `read_refs`, `payload`, and `reply_to`. Intents are `PROPOSE`, `CHALLENGE`, `REQUEST_EVIDENCE`, `REPORT_EVIDENCE`, `RETRACT`, and `CONCLUDE`. Read refs pin both claim value and lifecycle revisions; dependencies pin only value revisions.

```json
{
  "schema_version": 1,
  "problem_id": "affine-4201",
  "message_id": "affine-4201-u-proposal-1",
  "sender": "u-proposer",
  "recipients": ["v-reviewer", "shared-integrator"],
  "intent": "PROPOSE",
  "read_refs": [
    {"resource_id": "problem:affine-4201", "revision": 1, "state_revision": 1},
    {"resource_id": "claim:u-relation", "revision": 0, "state_revision": 0}
  ],
  "payload": {
    "claim": {
      "claim_id": "u-relation",
      "revision": 1,
      "state_revision": 1,
      "status": "active",
      "value": {"coefficients": [2, 3, 4]},
      "provenance": {"message_id": "affine-4201-u-proposal-1"},
      "dependencies": [{"resource_id": "problem:affine-4201", "claim_revision": 1}]
    }
  },
  "reply_to": null
}
```

Canonical JSON uses sorted keys, compact separators, UTF-8, and integers only. Duplicate keys, floats, non-UTF-8 input, non-scalar strings, unknown envelope fields, stale refs, and unauthorized routing are rejected. Each event hash is SHA-256 over the canonical envelope bytes. The original raw message bytes are retained independently, including for rejected submissions.

## Python API

Import `protocol.py` from the Lab 4 directory. All state changes run inside SQLite transactions.

- `canonical_bytes(value)` encodes a supported JSON value to deterministic UTF-8 bytes.
- `parse_envelope(raw_bytes)` strictly parses and validates the v1 envelope shape.
- `initialize_store(path, problem_id, participants, problem_packet)` initializes one immutable problem at revision 1 and registers participant IDs.
- `submit(path, raw_bytes)` stores the received bytes and returns a receipt. Accepted messages have `{message_id, accepted: true, event_seq}`. Rejections add a stable `code`. A stale proposal with a reconstructable historical snapshot instead returns `{message_id, accepted: false, event_seq: null, code: "STALE_READ", disposition: "forked", fork_id}`.
- `record_rejection(path, raw_bytes, code="ROLE_MISMATCH", parsed=None)` retains a raw response rejected by a pilot role gate without adding a main event.
- `get_projection(path, problem_id)` returns the current projection with `problem_id`, `problem`, `claims`, `claim_history`, `reviews`, `candidates`, and `forks`; `conclusions` appears when any CONCLUDE event exists. Claim lifecycle status is operational state, not a truth judgment.
- `inbox(path, problem_id, recipient)` returns committed events addressed to that participant in event sequence order.
- `replay(path, problem_id)` reconstructs claim/review state from committed events and adds the persisted potential-fork registry.
- `event_hashes(path, problem_id)` lists event sequence, message ID, and canonical event hash.
- `submissions(path, problem_id)` returns original raw input bytes and receipts, including malformed inputs that could not be assigned a problem ID.
- `get_fork(path, fork_id)` returns the original envelope/raw-byte encoding, pinned refs, coherent historical snapshot, and proposed branch projection.
- `export_fork_snapshot(path, fork_id, out_path=None)` returns that fork record and optionally writes canonical JSON to a file.
- `resolve_fork(path, fork_id, *, administrator, evidence_ref, prevailing_workable)` archives a potential fork as discarded only after an explicit `protocol-admin` attestation and a current accepted `event:<message_id>` reference to a `CONCLUDE` or `REPORT_EVIDENCE` whose pinned premises are still current. The engine checks event type and reference freshness; the administrator supplies the workability judgment.

A message ID is idempotent across accepted and rejected submissions when the original bytes match exactly: the first receipt is returned without adding a second received row. Reusing it with different bytes returns `MESSAGE_ID_CONFLICT`. Disjoint proposals can both commit from the same problem snapshot. A challenge preserves the proposal and changes its state revision; replacements supersede the old value and recursively invalidate dependents. Retraction records an event and keeps history.

## Potential-fork behavior

A structurally valid PROPOSE whose refs are stale is kept outside the main event stream when all of its refs coexisted at one committed historical snapshot. The branch record retains that snapshot, the exact raw envelope and refs, its base event sequence, and a structurally applied proposal view. The main projection does not change. If refs never coexisted, or cannot be reconstructed, the submission is an auditable `UNKNOWN_REFERENCE` rejection rather than an invented state.

A fork stays `potential` until an administrator explicitly resolves it. A later CONCLUDE or a structurally accepted main event never discards a fork. To continue from it, send a new PROPOSE with fresh refs and `reply_to` naming the original message. A discard cites an accepted CONCLUDE or REPORT_EVIDENCE event whose premise refs are still current, and records the admin's `prevailing_workable: true` attestation. The event supplies an auditable outcome and the admin supplies the domain judgment; the engine does not verify either one mathematically. The discard preserves both snapshots and the original message.

## Run and verify

The pilot CLI, call schedule, and per-run output files are described in [README_PILOT.md](README_PILOT.md). The protocol unit tests use only Python's standard library:

```powershell
python -m unittest discover -s research/external-cognition/lab4/tests -p 'test_protocol.py' -v
```

The implementation deliberately does not provide provider dispatch, semantic claim checking, automatic stale-message rebasing, or automatic fork resolution. Parallel commits are transactional, though their database event sequence can vary with actual commit order; replay is deterministic for any fixed sequence.

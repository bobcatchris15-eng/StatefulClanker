# Lab 4 protocol engine receipt

## Delivered

`protocol.py` implements the version 1 typed message envelope, canonical integer-only JSON and SHA-256 event hashes, an append-only SQLite event stream, transactional claim/review projections, directed inbox reads, and deterministic event replay. The projection includes per-value claim history so superseded, challenged, retracted, and invalidated states remain inspectable.

Stale `PROPOSE` messages are retained outside the main event stream only when all pinned refs coexist in a reconstructable committed snapshot. The fork record stores the original raw envelope, read refs, base event sequence, historical projection, and proposed branch projection. Its receipt is non-accepted with `disposition: "forked"` and `code: "STALE_READ"`. Forks remain potential through later conclusions or accepted events. Explicit discard requires the designated administrator, `prevailing_workable: true`, and an accepted `CONCLUDE` or `REPORT_EVIDENCE` event whose nonempty premise refs are still current. The engine records this decision and does not judge the evidence mathematically.

All received messages with a usable message ID share idempotency behavior, including rejected messages: exact byte repeats return the first receipt without adding another submission row, and different bytes with the same ID produce `MESSAGE_ID_CONFLICT`. A separate `record_rejection` API preserves role-gated pilot responses without adding an event. Review candidates must identify the current review message as provenance and cite dependencies that are both present in read refs and structurally resolvable.

## Verification

Ran from the repository root:

```text
python -m unittest discover -s research/external-cognition/lab4/tests -v
Ran 22 tests ... OK
```

The protocol tests cover strict envelope parsing, duplicate keys and float rejection, canonical hashes, accepted and rejected ID idempotency, disjoint proposals in parallel processes, stale proposal snapshot retention, incoherent-history rejection, evidence-gated fork archival, candidate provenance/dependency checks, directed inbox isolation, challenge visibility, recursive retraction invalidation, and projection replay. Pilot tests cover the frozen two-case schedule, raw bytes and hashes, role prompt/ref wiring, shared versus raw-only final prompts, and offline scoring of saved fixture responses.

No model calls were made. The pilot's parallel dispatch groups are frozen schedule metadata; the CLI does not start concurrent provider calls. The event sequence for concurrently submitted messages reflects SQLite commit order and may differ between runs; replay is deterministic for a fixed event sequence. The protocol validates structure and references only and makes no semantic-belief or cognition claim.

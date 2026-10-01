# Lab 4 message and state protocol

## Envelope, version 1

Every model-produced message is one JSON object with this shape:

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
      "dependencies": [
        {"resource_id": "problem:affine-4201", "claim_revision": 1}
      ]
    }
  },
  "reply_to": null
}
```

The top-level fields are all required. `schema_version` is integer `1`; `problem_id`, `message_id`, `sender`, and resource IDs are nonempty strings; `recipients` is a nonempty array of unique strings; `read_refs` is an array of `{resource_id, revision, state_revision}` objects; `payload` is any JSON value; `reply_to` is either null or a prior `message_id`. `intent` is one of the six values below. The parser rejects unknown top-level fields in version 1, duplicate object keys, floats, non-UTF-8 input, and non-integer revisions. A later incompatible change increments `schema_version`.

`revision` pins a claim's value revision; `state_revision` pins its lifecycle/projection revision. Both begin at 1 when a claim is created. A challenge, retraction, invalidation, or supersession changes the lifecycle and advances `state_revision` even if the underlying value is unchanged. Replacing a value advances `revision` by one and also advances `state_revision`. The immutable problem resource has revisions 1/1. A claim ID that does not yet exist has revisions 0/0. Both read-ref values are validated atomically; a changed status therefore makes an earlier snapshot stale.

No natural-language field is required. An agent may put domain-specific strings or structures inside `payload`, but the pilot's standard output uses the structured forms below. Nothing in the transport depends on prose or a universal ontology.

### Intents

| Intent | Meaning | Required payload content |
|---|---|---|
| `PROPOSE` | Add a new claim or a new revision of an existing claim. | `claim` record. |
| `CHALLENGE` | Record a structured objection to a referenced claim. | `target` exact claim reference and `assessment` object; an optional `corrected_claim` is an uncommitted candidate. |
| `REQUEST_EVIDENCE` | Ask a named participant for an evidence item or clarification. | `target` claim/reference and structured `request`. |
| `REPORT_EVIDENCE` | Supply evidence, an assessment, or a candidate correction in response to a request/review. | Structured `report`; optional `corrected_claim`. |
| `RETRACT` | Withdraw the sender's claim revision. | `target` exact claim reference and a stable `reason_code`. |
| `CONCLUDE` | Submit a final task answer or close a workflow. | `conclusion` object with domain-defined answer/status. |

Intent meaning is operational, not epistemic: `CHALLENGE` does not prove a claim false and `REPORT_EVIDENCE` does not certify its truth. A reviewer-provided `corrected_claim` is recorded as a candidate with provenance and must be explicitly proposed before becoming active. For this pilot, reviewer messages may use `CHALLENGE` with an `assessment` and optional candidate correction in the same envelope, or `REPORT_EVIDENCE` with the corresponding report; do not emit extra calls to clarify.

## Claim record

The shared-state projection treats a claim as a versioned record:

```json
{
  "claim_id": "u-relation",
  "revision": 1,
  "state_revision": 1,
  "status": "active",
  "value": {"coefficients": [2, 3, 4]},
  "provenance": {"message_id": "affine-4201-u-proposal-1"},
  "dependencies": [
    {"resource_id": "problem:affine-4201", "claim_revision": 1}
  ]
}
```

`claim_id` is stable across revisions; `revision` starts at 1 and increments by one for each accepted replacement. `state_revision` starts at 1 and increments by one for each lifecycle transition. `status` is one of `active`, `challenged`, `candidate`, `retracted`, `invalidated`, or `superseded`. A `candidate` appears only as a reviewer's nested `corrected_claim`; it is visible in the review projection but is not promoted or inserted as active state by the store. `value` is any JSON value. `provenance` records the producing message and may include structured evidence locators. `dependencies` is a list of `{resource_id, claim_revision}` references pinning value content (problem resources use claim revision 1 here). A claim may depend on problem facts or other claims. The store validates references and status transitions, not the correctness or sufficiency of a claim's value or cited evidence.

Claim writes require a read reference to the resource being revised. New claims may use a non-existing claim ID with revisions 0/0 in `read_refs`; these denote absence at the snapshot. Accepted creation writes value/state revisions 1/1. An accepted update must name both current revisions and creates the next value revision and next state revision. A caller cannot directly submit `retracted`, `invalidated`, or `superseded` status: those are produced by `RETRACT`, dependency propagation, or replacement. Challenges may change a claim's projected status to `challenged` without deleting its current value; this advances `state_revision` and makes earlier read snapshots stale. A later accepted replacement marks the prior value superseded and creates a new claim revision.

## Read snapshots, commit, and replay

Each `read_refs` item pins both the observed value revision and state revision. The engine checks all refs inside one SQLite transaction immediately before appending the event. If either is stale, a structurally valid PROPOSE with a coherent reconstructable historical read snapshot is held as a potential fork rather than merged into the main projection. Other stale intents remain noncommitting rejections; all bytes are retained. Rebasing is a new message with fresh refs; the pilot prohibits repair calls. For resource creation, 0/0 names an absent claim ID. The immutable problem packet is 1/1.

Two new proposals that both read the same immutable problem revision and write different claim IDs are disjoint; both are accepted even when they started from the same snapshot. Two updates that both target the same claim revision conflict: the first accepted update advances the state revision and the other becomes stale. A `CHALLENGE` also advances the target's state revision, so a PROPOSE based on the earlier active snapshot is held as a potential fork when its historical snapshot can be reconstructed. Events receive a database-assigned increasing sequence number. The event table is append-only; a deterministic projector rebuilds claim status and current value/state revisions from the committed sequence.

For a `RETRACT`, the sender must own the target claim or be the protocol's designated state administrator. Retraction appends an event, marks that target value revision retracted, advances its state revision, and recursively marks active claims depending on that value revision invalidated (advancing their state revisions too). No event or raw message is deleted. A `CHALLENGE` records its assessment and marks the target challenged, advancing state revision without changing value revision; it does not trigger invalidation. An accepted replacement supersedes the previous value revision and invalidates claims that depend specifically on the superseded value.

## Durability and idempotency

The reference implementation should use only Python standard-library `sqlite3`. Store the original received bytes, parsed envelope, validation result, receipt/rejection code, event sequence, and current projection in a transaction. A `message_id` is an idempotency key: an exact duplicate of an already received message returns its original receipt and does not append a second event; the same ID with different bytes is rejected as `MESSAGE_ID_CONFLICT`. Rejected bytes remain auditable but do not enter the committed event stream.

## Deterministic encoding

For generated messages and persisted hashes, serialize UTF-8 JSON with sorted object keys and compact separators; reject duplicate keys and all floating-point numbers. Integers are allowed. Strings are Unicode scalar values normalized only if the domain adapter explicitly specifies a normalization before constructing the message; the transport does not silently rewrite strings. This constrained encoding supports repeatable local runs but is not represented as full RFC 8785/JCS canonicalization.

## Lab 4 affine pilot payload conventions

The domain adapter exposes the full public problem packet to every participant: modulus 11, three labeled observations, the declared affine family, observed target image `(u,v)`, and answer requirements. Only true coefficient triples, target answer `(x,y)`, and evaluator are excluded. The problem packet is immutable at value/state revision 1/1.

Proposers submit one relation claim apiece, with IDs `u-relation` and `v-relation`. The value is a `coefficients` array of three integer residues. Each proposal is routed to its assigned peer reviewer and the registered `shared-integrator`. The cross mapping is fixed: u-reviewer inspects v-relation, and v-reviewer inspects u-relation. Each receives the whole problem and only that peer claim. Its `assessment` is one of `supported`, `challenge`, or `underdetermined`, plus structured `basis_refs` and optional `corrected_claim`; the corrected claim carries a candidate value and provenance for the reviewer and remains a candidate until explicitly proposed. Each review is routed to `shared-integrator`. The store exposes candidates alongside original claims and reviews and does not choose one. The integrator answer payload has a domain-defined `status` and, when solved, `x` and `y` integer residues. The adapter scores these outputs offline by enumerating all 121 coordinate pairs. The shared-state integrator gets the complete raw facts plus the projected claims, candidate values, and reviews. The raw-only control gets the same complete raw facts and answer instructions, without shared intermediate state.

## Receipts and stable rejection codes

The engine returns a receipt separate from the model envelope. It includes `message_id`, `accepted` boolean, `event_seq` or null, and one stable rejection code when rejected. Minimum rejection codes: `INVALID_JSON`, `INVALID_SCHEMA`, `UNKNOWN_SENDER`, `INVALID_RECIPIENT`, `UNKNOWN_REFERENCE`, `STALE_READ`, `INVALID_TRANSITION`, `MESSAGE_ID_CONFLICT`, and `DATABASE_ERROR`. Receipt text is fixed and must not reveal hidden answers or offer semantic hints.

## Potential forks: user refinement, authoritative v1 contract

A stale PROPOSE is not silently discarded. If every pinned read reference coexists in a historical committed snapshot, retain a deterministic fork_id, source_message_id, original raw envelope, exact read_refs, base_event_seq, historical projection, and structurally applied proposed projection. The main branch is unchanged. Receipt: accepted=false, disposition="forked", code="STALE_READ", fork_id. get_fork exports the held snapshot for later work. Unknown or incoherent historical references do not authorize inventing a premise state; their failed submissions remain auditable.

Fork status begins potential. No CONCLUDE, syntactic acceptance, or other main event automatically discards it. resolve_fork requires the designated administrator, prevailing_workable=true, and a current accepted evidence reference. It records the explicit decision and attestation, then archives the fork as discarded while retaining its historical/proposed snapshots and original envelope. Workability is an operator/domain judgment represented by evidence and attestation, not a mathematical conclusion made by the structural store. Leaving a fork potential keeps it available. Rebase or promotion uses a new PROPOSE with current refs and reply_to naming the original message; automatic fork merging is outside this prototype.

The native twelve-call pilot does not provoke stale forks; independent executable tests cover retention, exported snapshots, unchanged main state, and evidence-gated archival. Replay determinism concerns a fixed committed event sequence. Parallel arrival and commit order may differ between runs.

# Lab 4 pre-live review

Reviewed 2026-10-01 against `HUMAN_HANDOFF.md` and current Lab 4 design, plan, preregistration, protocol, and executable sources. Core and adapter were reviewed with temporary/offline probes only; no subject call was made. The run is **not cleared for live calls** pending the material blockers below.

## What aligns

The proposed pilot has a coherent bounded structure: two disjoint relation claims are proposed from a common immutable problem snapshot; peer reviewers receive the complete public problem plus one assigned claim; a shared-state integrator receives claims, reviews, and candidate corrections; and a raw-only integrator gets the same task facts without the state projection. The SQLite event log, canonical structured messages, directed inboxes, stale-read checks, replay, and recursive invalidation address the requested repeatable external representation and auditable coordination mechanics. The design appropriately says the store will not decide truth or choose a winning claim, and limits claims to two synthetic cases.

## Initial document-review gaps (subsequently addressed in the contract)

1. **The new stale-proposal instruction is not represented yet.** The current claim model has stable-ID replacement, superseded history, and nested uncommitted `corrected_claim` candidates. It does not specify a separate potential-fork object that captures its premise/read snapshot while leaving the prevailing main claim unchanged, nor an explicit discard decision that cites the workable prevailing state and preserves the fork record. Add a concrete fork/disposition envelope or equivalent claim/event fields, prompt instructions, projection/replay behavior, and tests. A candidate correction alone does not define the requested lifecycle.

2. **Reviewer routing needs an explicit mapping.** The docs say “peer claim assigned” and “cross-reviewer,” but do not name which reviewer receives which claim. Freeze `u-reviewer → v-relation` and `v-reviewer → u-relation` (or the intended assignment) consistently in the manifest, prompts, recipients, and access tests.

3. **Pilot runtime is not implemented or ready to freeze.** `protocol.py` and `pilot.py` are absent; `PLAN.md` still has the implementation, reconciliation, and pilot-test steps unchecked. The current protocol provides general intent descriptions, but exact per-role envelope payloads, message IDs, mailbox views, and prompts must be materialized and tested before participants run.

## Scope boundary

This pilot uses two small synthetic mod-11 cases and the native Luna-low route. The design explicitly excludes local models and makes no harder-problem or research-source claim. It is a useful protocol-mechanics pilot, but should not be reported as fulfilling the broader direction in the handoff to use local/smaller models on harder problems or to research scholarly, forum, and other technical sources. That broader objective remains follow-up work after a concrete local runtime and research-task protocol are selected.

## Executable audit findings

The fork lifecycle, exact historical/proposed snapshots, unchanged main projection, stale-read replay, raw byte retention, idempotency, candidate validation, and peer mapping now appear aligned with the current contract. The public task packet contains the complete observations and target image, but not generated coefficients or target input. Adapter prompts use the fixed cross mapping. I found three remaining pre-live issues:

1. **Fork archive evidence is still not outcome evidence.** `resolve_fork` accepts the current immutable `problem:<id>` reference as its `evidence_ref`; it also accepts any current active claim reference. Neither proves that the prevailing branch has a recorded workable outcome. The protocol tests currently use an ordinary active claim as the evidence reference. Requiring an administrator boolean plus a current resource pin is weaker than the documented requirement for an accepted outcome/workability evidence record tied to the prevailing state. Require the reference to identify an accepted `CONCLUDE`/`REPORT_EVIDENCE` (or equivalent explicit outcome-evidence event) and pin its current premise snapshot; keep the admin attestation as a separate field.

2. **Final prompt envelope template contradicts the underdetermined option.** Both final prompts allow `{"status":"underdetermined"}`, but then tell the model to “edit only the conclusion answer values” in a template whose status is fixed to `solved`. An agent following that exact-copy instruction cannot choose the permitted underdetermined status. Either provide separate solved/underdetermined envelope templates or explicitly allow changing the conclusion status and removing `x`/`y` when underdetermined.

3. **Offline outcome score is not conditioned on the protocol receipt.** `evaluate` parses the raw envelope and sets `true_world_correct` from its answer even when the saved receipt says `accepted: false` (for example, a parseable correct CONCLUDE addressed to an unregistered recipient is rejected by `submit` but still receives a correct score). It also does not verify that the envelope sender matches the scheduled role. Keep raw-answer accuracy if desired, but separately mark protocol-valid outcome and gate the primary outcome on accepted receipt plus expected sender/intent/recipient/read-ref contract. Otherwise malformed or misrouted output can count as a successful subject outcome.

4. **Current test run exposes replay/public-projection mismatch.** I ran `python -m unittest discover -s research/external-cognition/lab4/tests -v` against the shared tree: 19/21 pass. `test_retract_recursively_invalidates_dependent_claims_and_replay_matches` fails because `replay` exposes an internal `_event_ids` key absent from `get_projection`; `test_stale_reference_rejected_without_projection_change` fails because replay also omits `conclusions` while `get_projection` includes them. This appeared during recent core changes and should be fixed before freeze, since callers need a stable equivalence between replayed and current exported state.

The run manifest hashes the public packet and policy, while rendered prompt hashes are written as each stage is materialized. At the time of the first adapter review, it did not pin adapter/protocol source or template hashes. The frozen `runs/campaign1/run.json` now records hashes for `pilot.py`, `protocol.py`, and the Lab 3 generator, and independently recomputing those values plus the manifest hash matched.

## Final narrow recheck

Rechecked the stable, frozen source and pre-live `runs/campaign1` after the fixes. The previous three blockers are resolved:

- Fork archival accepts only a current `event:<message_id>` reference to an accepted `CONCLUDE` or `REPORT_EVIDENCE` event with nonempty premise refs; it verifies those premises remain current and requires the protocol administrator's explicit `prevailing_workable=True` attestation. Regression coverage rejects bare problem/claim refs, non-outcome events, and stale premises.
- Rejected message IDs are retained, exact retries return their original receipt, and reusing an ID with different bytes is rejected. Candidate provenance and dependencies are checked against the submitting message and readable current refs.
- The final prompt now spells out the full underdetermined conclusion replacement (including removing `x`/`y`). The adapter role gate checks sender, problem, message ID, intent, recipients, and access scope before commit; rejected raw bytes are preserved without adding an event. Evaluation keeps raw answer match separate and requires accepted receipt plus scheduled identity/intent for `protocol_valid` and `true_world_correct`.

Targeted tests passed for rejected-ID idempotency, evidence-gated fork resolution, candidate provenance/dependency validation, role/recipient rejection, CLI round trip, and final underdetermined wording (6 targeted tests total). An additional fresh temporary CLI campaign prepared both seeds, submitted two observation-consistent proposals per case, recorded reviewer/integrator failures, then completed offline evaluation and replay. Both proposals were accepted; replay returned both claims and did not expose private `_event_ids`. No persistent run files or subject calls were created by this probe. The entire Lab 4 suite was reported by the parent as 23/23 passing after integration.

The Lab 4 executable is **cleared for the preregistered live calls**, subject to retaining the already-frozen source, docs, prompts, and public inputs before the first call. This audit does not assert that the native synthetic pilot fulfills the broader local-model/harder-research direction described above.

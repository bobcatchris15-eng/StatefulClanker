import multiprocessing
import base64
import hashlib
import tempfile
import unittest
from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import protocol


def _proposal(problem_id, message_id, sender, claim_id, refs, value, dependencies=None, revision=1):
    refs = list(refs)
    if not any(ref.get("resource_id") == f"claim:{claim_id}" for ref in refs):
        prior = revision - 1
        refs.append({"resource_id": f"claim:{claim_id}", "revision": prior, "state_revision": prior})
    return {
        "schema_version": 1,
        "problem_id": problem_id,
        "message_id": message_id,
        "sender": sender,
        "recipients": ["shared-integrator"],
        "intent": "PROPOSE",
        "read_refs": refs,
        "payload": {"claim": {
            "claim_id": claim_id,
            "revision": revision,
            "state_revision": revision,
            "status": "active",
            "value": value,
            "provenance": {"message_id": message_id},
            "dependencies": dependencies or [{"resource_id": f"problem:{problem_id}", "claim_revision": 1}],
        }},
        "reply_to": None,
    }


def _worker_submit(db, raw, output):
    output.put(protocol.submit(db, raw))


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db = str(Path(self.temp.name) / "protocol.sqlite3")
        self.problem_id = "affine-4201"
        protocol.initialize_store(
            self.db,
            self.problem_id,
            ["u-proposer", "v-proposer", "u-reviewer", "v-reviewer", "shared-integrator", "raw-integrator"],
            {"modulus": 11, "observations": []},
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_canonical_json_is_sorted_compact_integer_only(self):
        self.assertEqual(protocol.canonical_bytes({"z": [True, 2], "a": "é"}), b'{"a":"\xc3\xa9","z":[true,2]}')
        with self.assertRaises((TypeError, ValueError)):
            protocol.canonical_bytes({"x": 1.5})

    def test_parser_rejects_duplicate_keys_unknown_fields_and_float(self):
        base = _proposal(self.problem_id, "m1", "u-proposer", "u-relation", [{"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}], {"coefficients": [1, 2, 3]})
        raw = protocol.canonical_bytes(base)
        self.assertEqual(protocol.parse_envelope(raw)["message_id"], "m1")
        for bad in (
            raw[:-1] + b',"extra":1}',
            b'{"a":1,"a":2}',
            raw.replace(b'"revision":1', b'"revision":1.0', 1),
            b"\xff",
            raw.replace(b'"u-proposer"', b'"\\ud800"', 1),
        ):
            with self.subTest(bad=bad), self.assertRaises((TypeError, ValueError)):
                protocol.parse_envelope(bad)

    def test_rejected_raw_bytes_are_retained_with_structural_code(self):
        malformed = b'{"schema_version":'
        self.assertEqual(protocol.submit(self.db, malformed)["code"], "INVALID_JSON")
        schema_bad = protocol.canonical_bytes({"schema_version": 1})
        self.assertEqual(protocol.submit(self.db, schema_bad)["code"], "INVALID_SCHEMA")
        saved = protocol.submissions(self.db, self.problem_id)
        self.assertEqual(saved[0]["raw"], malformed)
        self.assertEqual(saved[1]["raw"], schema_bad)

    def test_rejected_message_ids_are_idempotent_and_cannot_be_reused(self):
        problem_ref = {"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}
        unknown = _proposal(self.problem_id, "rejected-id", "u-proposer", "u-relation", [problem_ref, {"resource_id": "claim:missing", "revision": 1, "state_revision": 1}], {"coefficients": [1, 2, 3]})
        raw = protocol.canonical_bytes(unknown)
        first = protocol.submit(self.db, raw)
        self.assertEqual(first["code"], "UNKNOWN_REFERENCE")
        before = len(protocol.submissions(self.db, self.problem_id))
        self.assertEqual(protocol.submit(self.db, raw), first)
        self.assertEqual(len(protocol.submissions(self.db, self.problem_id)), before)
        changed = _proposal(self.problem_id, "rejected-id", "u-proposer", "u-relation", [problem_ref], {"coefficients": [4, 5, 6]})
        self.assertEqual(protocol.submit(self.db, protocol.canonical_bytes(changed))["code"], "MESSAGE_ID_CONFLICT")
        self.assertFalse(protocol.get_projection(self.db, self.problem_id)["claims"])

    def test_pilot_role_rejection_preserves_raw_without_event_or_projection_change(self):
        env = _proposal(self.problem_id, "wrong-role", "v-proposer", "v-relation", [{"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}], {"coefficients": [1, 2, 3]})
        raw = protocol.canonical_bytes(env)
        before = protocol.get_projection(self.db, self.problem_id)
        receipt = protocol.record_rejection(self.db, raw, code="ROLE_MISMATCH")
        self.assertEqual(receipt["code"], "ROLE_MISMATCH")
        self.assertEqual(protocol.record_rejection(self.db, raw, code="ROLE_MISMATCH"), receipt)
        self.assertEqual(protocol.event_hashes(self.db, self.problem_id), [])
        self.assertEqual(protocol.get_projection(self.db, self.problem_id), before)
        saved = protocol.submissions(self.db, self.problem_id)
        self.assertEqual(saved[0]["raw"], raw)
        self.assertFalse(saved[0]["accepted"])

    def test_all_six_intents_are_supported_and_unknown_intent_is_rejected(self):
        common = {"schema_version": 1, "problem_id": self.problem_id, "message_id": "m", "sender": "u-proposer", "recipients": ["shared-integrator"], "read_refs": [], "reply_to": None}
        cases = {
            "PROPOSE": {"claim": {"claim_id": "x", "revision": 1, "state_revision": 1, "status": "active", "value": {}, "provenance": {"message_id": "m"}, "dependencies": []}},
            "CHALLENGE": {"target": {"resource_id": "claim:x", "revision": 1, "state_revision": 1}, "assessment": {"assessment": "challenge"}},
            "REQUEST_EVIDENCE": {"target": {"resource_id": "claim:x", "revision": 1, "state_revision": 1}, "request": {"kind": "clarification"}},
            "REPORT_EVIDENCE": {"report": {"result": "observed"}},
            "RETRACT": {"target": {"resource_id": "claim:x", "revision": 1, "state_revision": 1}, "reason_code": "withdrawn"},
            "CONCLUDE": {"conclusion": {"status": "solved", "x": 1, "y": 2}},
        }
        for intent, payload in cases.items():
            with self.subTest(intent=intent):
                value = dict(common, intent=intent, payload=payload)
                self.assertEqual(protocol.parse_envelope(protocol.canonical_bytes(value))["intent"], intent)
        with self.assertRaises((TypeError, ValueError)):
            protocol.parse_envelope(protocol.canonical_bytes(dict(common, intent="BELIEVE", payload={})))

    def test_exact_message_retry_is_idempotent_and_conflicting_id_rejected(self):
        env = _proposal(self.problem_id, "proposal-u", "u-proposer", "u-relation", [{"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}], {"coefficients": [1, 2, 3]})
        raw = protocol.canonical_bytes(env)
        first = protocol.submit(self.db, raw)
        second = protocol.submit(self.db, raw)
        self.assertTrue(first["accepted"])
        self.assertEqual(first, second)
        changed = dict(env)
        changed["payload"] = {"claim": dict(env["payload"]["claim"], value={"coefficients": [4, 5, 6]})}
        self.assertEqual(protocol.submit(self.db, protocol.canonical_bytes(changed))["code"], "MESSAGE_ID_CONFLICT")
        self.assertEqual(protocol.get_projection(self.db, self.problem_id)["claims"]["u-relation"]["revision"], 1)

    def test_disjoint_proposals_from_shared_problem_snapshot_both_commit(self):
        messages = [
            _proposal(self.problem_id, "u", "u-proposer", "u-relation", [{"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}], {"coefficients": [1, 2, 3]}),
            _proposal(self.problem_id, "v", "v-proposer", "v-relation", [{"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}], {"coefficients": [4, 5, 6]}),
        ]
        results = [protocol.submit(self.db, protocol.canonical_bytes(m)) for m in messages]
        self.assertTrue(all(r["accepted"] for r in results))

    def test_parallel_processes_commit_disjoint_claims_from_one_snapshot(self):
        messages = [
            _proposal(self.problem_id, "parallel-u", "u-proposer", "u-relation", [{"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}], {"coefficients": [1, 2, 3]}),
            _proposal(self.problem_id, "parallel-v", "v-proposer", "v-relation", [{"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}], {"coefficients": [4, 5, 6]}),
        ]
        output = multiprocessing.Queue()
        processes = [multiprocessing.Process(target=_worker_submit, args=(self.db, protocol.canonical_bytes(m), output)) for m in messages]
        for process in processes:
            process.start()
        results = [output.get(timeout=10) for _ in processes]
        for process in processes:
            process.join(timeout=10)
            self.assertEqual(process.exitcode, 0)
        self.assertTrue(all(r["accepted"] for r in results), results)
        self.assertEqual(set(protocol.get_projection(self.db, self.problem_id)["claims"]), {"u-relation", "v-relation"})

    def test_stale_proposal_is_held_as_fork_without_changing_main_claim(self):
        problem_ref = {"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}
        initial = _proposal(self.problem_id, "u1", "u-proposer", "u-relation", [problem_ref], {"coefficients": [1, 2, 3]})
        self.assertTrue(protocol.submit(self.db, protocol.canonical_bytes(initial))["accepted"])
        v_claim = _proposal(self.problem_id, "v1", "v-proposer", "v-relation", [problem_ref], {"coefficients": [4, 5, 6]})
        self.assertTrue(protocol.submit(self.db, protocol.canonical_bytes(v_claim))["accepted"])
        challenge = {"schema_version": 1, "problem_id": self.problem_id, "message_id": "review-u", "sender": "v-reviewer", "recipients": ["shared-integrator"], "intent": "CHALLENGE", "read_refs": [{"resource_id": "claim:u-relation", "revision": 1, "state_revision": 1}], "payload": {"target": {"resource_id": "claim:u-relation", "revision": 1, "state_revision": 1}, "assessment": {"assessment": "challenge", "basis_refs": []}}, "reply_to": "u1"}
        self.assertTrue(protocol.submit(self.db, protocol.canonical_bytes(challenge))["accepted"])
        update = _proposal(self.problem_id, "u2-stale", "u-proposer", "u-relation", [problem_ref, {"resource_id": "claim:u-relation", "revision": 1, "state_revision": 1}], {"coefficients": [3, 2, 1]}, revision=2)
        receipt = protocol.submit(self.db, protocol.canonical_bytes(update))
        self.assertFalse(receipt["accepted"])
        self.assertEqual(receipt["disposition"], "forked")
        self.assertEqual(receipt["code"], "STALE_READ")
        main_claim = protocol.get_projection(self.db, self.problem_id)["claims"]["u-relation"]
        self.assertEqual(main_claim["revision"], 1)
        self.assertEqual(main_claim["state_revision"], 2)
        self.assertEqual(main_claim["status"], "challenged")
        self.assertEqual(main_claim["value"], {"coefficients": [1, 2, 3]})
        fork = protocol.get_fork(self.db, receipt["fork_id"])
        self.assertEqual(fork["status"], "potential")
        self.assertEqual(fork["base_event_seq"], 2)
        self.assertEqual(fork["read_refs"], update["read_refs"])
        self.assertEqual(fork["historical_projection"]["claims"]["u-relation"]["status"], "active")
        self.assertEqual(fork["proposed_projection"]["claims"]["u-relation"]["value"], {"coefficients": [3, 2, 1]})
        self.assertEqual(fork["proposed_projection"]["claim_history"]["u-relation"][0]["status"], "superseded")
        self.assertEqual(base64.b64decode(fork["raw_bytes_b64"]), protocol.canonical_bytes(update))
        self.assertEqual(protocol.export_fork_snapshot(self.db, receipt["fork_id"])["fork_id"], receipt["fork_id"])
        conclusion = {"schema_version": 1, "problem_id": self.problem_id, "message_id": "final", "sender": "shared-integrator", "recipients": ["shared-integrator"], "intent": "CONCLUDE", "read_refs": [], "payload": {"conclusion": {"status": "solved", "x": 0, "y": 0}}, "reply_to": None}
        self.assertTrue(protocol.submit(self.db, protocol.canonical_bytes(conclusion))["accepted"])
        self.assertEqual(protocol.get_fork(self.db, receipt["fork_id"])["status"], "potential")
        self.assertEqual(protocol.replay(self.db, self.problem_id), protocol.get_projection(self.db, self.problem_id))

    def test_fork_requires_explicit_admin_workable_evidence_to_discard(self):
        problem_ref = {"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}
        u = _proposal(self.problem_id, "u1", "u-proposer", "u-relation", [problem_ref], {"coefficients": [1, 2, 3]})
        v = _proposal(self.problem_id, "v1", "v-proposer", "v-relation", [problem_ref], {"coefficients": [4, 5, 6]})
        protocol.submit(self.db, protocol.canonical_bytes(u))
        protocol.submit(self.db, protocol.canonical_bytes(v))
        challenge = {"schema_version": 1, "problem_id": self.problem_id, "message_id": "review-u", "sender": "v-reviewer", "recipients": ["shared-integrator"], "intent": "CHALLENGE", "read_refs": [{"resource_id": "claim:u-relation", "revision": 1, "state_revision": 1}], "payload": {"target": {"resource_id": "claim:u-relation", "revision": 1, "state_revision": 1}, "assessment": {"assessment": "challenge", "basis_refs": []}}, "reply_to": "u1"}
        protocol.submit(self.db, protocol.canonical_bytes(challenge))
        stale = _proposal(self.problem_id, "u2-stale", "u-proposer", "u-relation", [problem_ref, {"resource_id": "claim:u-relation", "revision": 1, "state_revision": 1}], {"coefficients": [3, 2, 1]}, revision=2)
        fork_id = protocol.submit(self.db, protocol.canonical_bytes(stale))["fork_id"]
        v_ref = {"resource_id": "claim:v-relation", "revision": 1, "state_revision": 1}
        outcome1 = {"schema_version": 1, "problem_id": self.problem_id, "message_id": "outcome-1", "sender": "shared-integrator", "recipients": ["shared-integrator"], "intent": "CONCLUDE", "read_refs": [problem_ref, v_ref], "payload": {"conclusion": {"status": "solved", "x": 1, "y": 2}}, "reply_to": None}
        self.assertTrue(protocol.submit(self.db, protocol.canonical_bytes(outcome1))["accepted"])
        outcome_evidence = {"resource_id": "event:outcome-1", "revision": 1, "state_revision": 1}
        rejected = protocol.resolve_fork(self.db, fork_id, administrator="protocol-admin", evidence_ref=outcome_evidence, prevailing_workable=False)
        self.assertFalse(rejected["accepted"])
        self.assertEqual(protocol.get_fork(self.db, fork_id)["status"], "potential")
        unauthorized = protocol.resolve_fork(self.db, fork_id, administrator="u-proposer", evidence_ref=outcome_evidence, prevailing_workable=True)
        self.assertFalse(unauthorized["accepted"])
        proposal_evidence = protocol.resolve_fork(self.db, fork_id, administrator="protocol-admin", evidence_ref={"resource_id": "event:v1", "revision": 1, "state_revision": 1}, prevailing_workable=True)
        self.assertFalse(proposal_evidence["accepted"])
        challenge_v = {"schema_version": 1, "problem_id": self.problem_id, "message_id": "review-v", "sender": "u-reviewer", "recipients": ["shared-integrator"], "intent": "CHALLENGE", "read_refs": [v_ref], "payload": {"target": v_ref, "assessment": {"assessment": "challenge", "basis_refs": []}}, "reply_to": "v1"}
        self.assertTrue(protocol.submit(self.db, protocol.canonical_bytes(challenge_v))["accepted"])
        stale_evidence = protocol.resolve_fork(self.db, fork_id, administrator="protocol-admin", evidence_ref=outcome_evidence, prevailing_workable=True)
        self.assertFalse(stale_evidence["accepted"])
        self.assertEqual(stale_evidence["code"], "STALE_READ")
        fresh_v_ref = {"resource_id": "claim:v-relation", "revision": 1, "state_revision": 2}
        outcome2 = dict(outcome1, message_id="outcome-2", read_refs=[problem_ref, fresh_v_ref])
        self.assertTrue(protocol.submit(self.db, protocol.canonical_bytes(outcome2))["accepted"])
        fresh_evidence = {"resource_id": "event:outcome-2", "revision": 1, "state_revision": 1}
        discarded = protocol.resolve_fork(self.db, fork_id, administrator="protocol-admin", evidence_ref=fresh_evidence, prevailing_workable=True)
        self.assertTrue(discarded["accepted"])
        self.assertEqual(discarded["status"], "discarded")
        archived = protocol.get_fork(self.db, fork_id)
        self.assertEqual(archived["resolution"]["evidence_ref"], fresh_evidence)
        self.assertTrue(archived["resolution"]["prevailing_workable"])

    def test_stale_proposal_with_no_coherent_joint_snapshot_is_not_forked(self):
        problem_ref = {"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}
        u = _proposal(self.problem_id, "u1", "u-proposer", "u-relation", [problem_ref], {"coefficients": [1, 2, 3]})
        self.assertTrue(protocol.submit(self.db, protocol.canonical_bytes(u))["accepted"])
        old_u_ref = {"resource_id": "claim:u-relation", "revision": 1, "state_revision": 1}
        challenge = {"schema_version": 1, "problem_id": self.problem_id, "message_id": "review-u", "sender": "v-reviewer", "recipients": ["shared-integrator"], "intent": "CHALLENGE", "read_refs": [old_u_ref], "payload": {"target": old_u_ref, "assessment": {"assessment": "challenge", "basis_refs": []}}, "reply_to": "u1"}
        self.assertTrue(protocol.submit(self.db, protocol.canonical_bytes(challenge))["accepted"])
        v = _proposal(self.problem_id, "v1", "v-proposer", "v-relation", [problem_ref], {"coefficients": [4, 5, 6]})
        self.assertTrue(protocol.submit(self.db, protocol.canonical_bytes(v))["accepted"])
        impossible = _proposal(self.problem_id, "cross-time", "u-proposer", "w-relation", [problem_ref, old_u_ref, {"resource_id": "claim:v-relation", "revision": 1, "state_revision": 1}], {"coefficients": [7, 8, 9]})
        receipt = protocol.submit(self.db, protocol.canonical_bytes(impossible))
        self.assertFalse(receipt["accepted"])
        self.assertEqual(receipt["code"], "UNKNOWN_REFERENCE")
        self.assertNotIn("disposition", receipt)

    def test_directed_inbox_only_returns_events_addressed_to_recipient(self):
        env = _proposal(self.problem_id, "proposal-u", "u-proposer", "u-relation", [{"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}], {"coefficients": [1, 2, 3]})
        protocol.submit(self.db, protocol.canonical_bytes(env))
        self.assertEqual([e["message_id"] for e in protocol.inbox(self.db, self.problem_id, "shared-integrator")], ["proposal-u"])
        self.assertEqual(protocol.inbox(self.db, self.problem_id, "v-reviewer"), [])

    def test_challenge_preserves_claim_value_and_exposes_challenged_status(self):
        proposal = _proposal(self.problem_id, "u1", "u-proposer", "u-relation", [{"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}], {"coefficients": [1, 2, 3]})
        protocol.submit(self.db, protocol.canonical_bytes(proposal))
        challenge = {"schema_version": 1, "problem_id": self.problem_id, "message_id": "review", "sender": "u-reviewer", "recipients": ["shared-integrator"], "intent": "CHALLENGE", "read_refs": [{"resource_id": "claim:u-relation", "revision": 1, "state_revision": 1}], "payload": {"target": {"resource_id": "claim:u-relation", "revision": 1, "state_revision": 1}, "assessment": {"assessment": "challenge", "basis_refs": []}, "corrected_claim": {"claim_id": "u-candidate", "revision": 1, "state_revision": 1, "status": "candidate", "value": {"coefficients": [8, 8, 8]}, "provenance": {"message_id": "review"}, "dependencies": []}}, "reply_to": "u1"}
        self.assertTrue(protocol.submit(self.db, protocol.canonical_bytes(challenge))["accepted"])
        current = protocol.get_projection(self.db, self.problem_id)["claims"]["u-relation"]
        self.assertEqual(current["status"], "challenged")
        self.assertEqual(current["value"], {"coefficients": [1, 2, 3]})
        self.assertEqual(len(protocol.inbox(self.db, self.problem_id, "shared-integrator")), 2)

    def test_review_candidates_must_cite_current_readable_dependencies_and_self_provenance(self):
        problem_ref = {"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}
        proposal = _proposal(self.problem_id, "u1", "u-proposer", "u-relation", [problem_ref], {"coefficients": [1, 2, 3]})
        protocol.submit(self.db, protocol.canonical_bytes(proposal))
        claim_ref = {"resource_id": "claim:u-relation", "revision": 1, "state_revision": 1}
        for intent in ("CHALLENGE", "REPORT_EVIDENCE"):
            message_id = f"candidate-{intent}"
            candidate = {"claim_id": "u-candidate", "revision": 1, "state_revision": 1, "status": "candidate", "value": {"coefficients": [3, 2, 1]}, "provenance": {"message_id": message_id}, "dependencies": [{"resource_id": "claim:ghost", "claim_revision": 9}]}
            if intent == "CHALLENGE":
                payload = {"target": claim_ref, "assessment": {"assessment": "challenge", "basis_refs": []}, "corrected_claim": candidate}
            else:
                payload = {"report": {"assessment": "candidate offered"}, "corrected_claim": candidate}
            missing_ref = {"schema_version": 1, "problem_id": self.problem_id, "message_id": message_id, "sender": "v-reviewer", "recipients": ["shared-integrator"], "intent": intent, "read_refs": [problem_ref, claim_ref], "payload": payload, "reply_to": "u1"}
            receipt = protocol.submit(self.db, protocol.canonical_bytes(missing_ref))
            self.assertEqual(receipt["code"], "INVALID_TRANSITION")
            with_ghost = dict(missing_ref, message_id=f"ghost-{intent}", read_refs=[problem_ref, claim_ref, {"resource_id": "claim:ghost", "revision": 9, "state_revision": 9}])
            ghost_candidate = dict(candidate, provenance={"message_id": with_ghost["message_id"]})
            with_ghost["payload"] = dict(payload, corrected_claim=ghost_candidate)
            receipt = protocol.submit(self.db, protocol.canonical_bytes(with_ghost))
            self.assertEqual(receipt["code"], "UNKNOWN_REFERENCE")
            wrong_provenance = dict(missing_ref, message_id=f"wrong-provenance-{intent}")
            mismatched_candidate = dict(candidate, provenance={"message_id": "another-message"}, dependencies=[])
            wrong_provenance["payload"] = dict(payload, corrected_claim=mismatched_candidate)
            self.assertEqual(protocol.submit(self.db, protocol.canonical_bytes(wrong_provenance))["code"], "INVALID_SCHEMA")
        self.assertEqual(protocol.get_projection(self.db, self.problem_id)["claims"]["u-relation"]["status"], "active")

    def test_retract_recursively_invalidates_dependent_claims_and_replay_matches(self):
        problem_ref = [{"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}]
        u = _proposal(self.problem_id, "u1", "u-proposer", "u-relation", problem_ref, {"coefficients": [1, 2, 3]})
        protocol.submit(self.db, protocol.canonical_bytes(u))
        v = _proposal(self.problem_id, "v1", "v-proposer", "v-relation", problem_ref + [{"resource_id": "claim:u-relation", "revision": 1, "state_revision": 1}], {"coefficients": [4, 5, 6]})
        v["payload"]["claim"]["dependencies"] = [{"resource_id": "claim:u-relation", "claim_revision": 1}]
        protocol.submit(self.db, protocol.canonical_bytes(v))
        retract = {"schema_version": 1, "problem_id": self.problem_id, "message_id": "withdraw-u", "sender": "u-proposer", "recipients": ["shared-integrator"], "intent": "RETRACT", "read_refs": [{"resource_id": "claim:u-relation", "revision": 1, "state_revision": 1}], "payload": {"target": {"resource_id": "claim:u-relation", "revision": 1, "state_revision": 1}, "reason_code": "withdrawn"}, "reply_to": None}
        receipt = protocol.submit(self.db, protocol.canonical_bytes(retract))
        self.assertTrue(receipt["accepted"])
        projection = protocol.get_projection(self.db, self.problem_id)
        self.assertEqual(projection["claims"]["u-relation"]["status"], "retracted")
        self.assertEqual(projection["claims"]["v-relation"]["status"], "invalidated")
        self.assertEqual(protocol.replay(self.db, self.problem_id), projection)

    def test_event_hashes_cover_canonical_envelope_bytes(self):
        env = _proposal(self.problem_id, "hash-me", "u-proposer", "u-relation", [{"resource_id": f"problem:{self.problem_id}", "revision": 1, "state_revision": 1}], {"coefficients": [1, 2, 3]})
        canonical = protocol.canonical_bytes(env)
        self.assertTrue(protocol.submit(self.db, canonical)["accepted"])
        self.assertEqual(protocol.event_hashes(self.db, self.problem_id)[0]["event_hash"], hashlib.sha256(canonical).hexdigest())


if __name__ == "__main__":
    unittest.main()


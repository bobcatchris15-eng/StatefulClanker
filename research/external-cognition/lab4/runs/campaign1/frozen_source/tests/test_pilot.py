import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


LAB4 = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LAB4))
import pilot  # noqa: E402
import protocol  # noqa: E402


def lab3_case(seed):
    path = LAB4.parent / "lab3" / "experiment.py"
    spec = importlib.util.spec_from_file_location("lab3_experiment_for_lab4_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.make_case(seed)


def cli(*args):
    return subprocess.run(
        [sys.executable, str(LAB4 / "pilot.py"), *map(str, args)],
        cwd=LAB4,
        check=True,
        capture_output=True,
        text=True,
    )


def envelope(problem_id, message_id, sender, recipients, intent, refs, payload, reply_to=None):
    return {
        "schema_version": 1,
        "problem_id": problem_id,
        "message_id": message_id,
        "sender": sender,
        "recipients": recipients,
        "intent": intent,
        "read_refs": refs,
        "payload": payload,
        "reply_to": reply_to,
    }


def write_response(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(protocol.canonical_bytes(value))
    return path


class PilotTests(unittest.TestCase):
    def test_public_packet_uses_lab3_seed_but_withholds_hidden_coefficients_and_answer(self):
        for seed in (4201, 4202):
            case = lab3_case(seed)
            packet = pilot.public_problem(seed)
            self.assertEqual(packet["modulus"], 11)
            self.assertEqual([{k: v for k, v in row.items() if k != "observation_id"} for row in packet["observations"]], case["observations"])
            self.assertEqual(packet["target_uv"], case["target"]["uv"])
            self.assertEqual(packet["problem_id"], f"affine-{seed}")
            serialized = json.dumps(packet, sort_keys=True)
            self.assertNotIn("relation", packet)
            self.assertNotIn("target_xy", packet)
            self.assertNotIn("target_xy", serialized)
            self.assertNotIn("true_coefficients", serialized)
            self.assertEqual(packet["affine_family"], "u=(a*x+b*y+c) mod 11; v=(d*x+e*y+f) mod 11")

    def test_prepare_freezes_twelve_role_prompts_and_exact_read_snapshots(self):
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "run"
            manifest = pilot.prepare(run_dir)
            self.assertEqual(manifest["planned_calls"], 12)
            self.assertEqual(set(manifest["seeds"]), {4201, 4202})
            self.assertEqual(len(manifest["schedule"]), 12)
            for seed in (4201, 4202):
                run = run_dir / "cases" / str(seed)
                self.assertTrue((run / "problem.json").is_file())
                self.assertTrue((run / "store.sqlite").is_file())
                for role in ("u-proposer", "v-proposer"):
                    prompt_path = pilot.role_prompt(run_dir, seed, role)
                    prompt = prompt_path.read_text(encoding="utf-8")
                    case = lab3_case(seed)
                    self.assertIn('"observation_id": "observation-1"', prompt)
                    for observation in pilot.public_problem(seed)["observations"]:
                        for value in observation["xy"] + observation["uv"]:
                            self.assertIn(str(value), prompt)
                    for value in case["target"]["uv"]:
                        self.assertIn(str(value), prompt)
                    self.assertNotIn(json.dumps(case["relation"]["u"]), prompt)
                    self.assertNotIn(json.dumps(case["target"]["xy"]), prompt)
                    self.assertIn('"resource_id": "problem:affine-', prompt)
                    self.assertIn('"revision": 0', prompt)
                hash_manifest = json.loads((run_dir / "prompt_hashes.json").read_text(encoding="utf-8"))
                for role in ("u-proposer", "v-proposer"):
                    data = (run_dir / "prompts" / str(seed) / f"{role}.txt").read_bytes()
                    self.assertEqual(hash_manifest[f"{seed}/{role}"], hashlib.sha256(data).hexdigest())

    def test_role_prompts_map_peer_claim_and_review_read_refs_to_exact_state(self):
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "run"
            pilot.prepare(run_dir)
            seed = 4201
            case = lab3_case(seed)
            problem_id = f"affine-{seed}"
            db = run_dir / "cases" / str(seed) / "store.sqlite"
            for coord, reviewer in (("u", "v-reviewer"), ("v", "u-reviewer")):
                claim_id = f"{coord}-relation"
                msg_id = f"{problem_id}-{coord}-proposal"
                refs = [
                    {"resource_id": f"problem:{problem_id}", "revision": 1, "state_revision": 1},
                    {"resource_id": f"claim:{claim_id}", "revision": 0, "state_revision": 0},
                ]
                claim = {
                    "claim_id": claim_id, "revision": 1, "state_revision": 1, "status": "active",
                    "value": {"coefficients": case["relation"][coord]},
                    "provenance": {"message_id": msg_id},
                    "dependencies": [{"resource_id": f"problem:{problem_id}", "claim_revision": 1}],
                }
                msg = envelope(problem_id, msg_id, f"{coord}-proposer", [reviewer, "shared-integrator"], "PROPOSE", refs, {"claim": claim})
                result = pilot.submit_response(run_dir, seed, f"{coord}-proposer", protocol.canonical_bytes(msg))
                self.assertTrue(result["accepted"])
            u_review = pilot.role_prompt(run_dir, seed, "u-reviewer").read_text(encoding="utf-8")
            v_review = pilot.role_prompt(run_dir, seed, "v-reviewer").read_text(encoding="utf-8")
            self.assertIn('"claim_id": "v-relation"', u_review)
            self.assertNotIn('"claim_id": "u-relation"', u_review)
            self.assertIn('"claim_id": "u-relation"', v_review)
            self.assertNotIn('"claim_id": "v-relation"', v_review)
            self.assertIn('"resource_id": "claim:v-relation",\n      "revision": 1,\n      "state_revision": 1', u_review)
            self.assertIn('"resource_id": "claim:u-relation",\n      "revision": 1,\n      "state_revision": 1', v_review)

    def test_final_prompts_share_public_facts_candidates_but_only_shared_sees_state(self):
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "run"
            pilot.prepare(run_dir)
            seed = 4201
            problem_id = f"affine-{seed}"
            case = lab3_case(seed)
            db = run_dir / "cases" / str(seed) / "store.sqlite"
            refs_base = {"resource_id": f"problem:{problem_id}", "revision": 1, "state_revision": 1}
            proposal_ids = {}
            for coord, reviewer in (("u", "v-reviewer"), ("v", "u-reviewer")):
                claim_id = f"{coord}-relation"
                msg_id = f"{problem_id}-{coord}-proposal"
                proposal_ids[coord] = msg_id
                refs = [refs_base, {"resource_id": f"claim:{claim_id}", "revision": 0, "state_revision": 0}]
                claim = {
                    "claim_id": claim_id, "revision": 1, "state_revision": 1, "status": "active",
                    "value": {"coefficients": case["relation"][coord]},
                    "provenance": {"message_id": msg_id},
                    "dependencies": [{"resource_id": f"problem:{problem_id}", "claim_revision": 1}],
                }
                msg = envelope(problem_id, msg_id, f"{coord}-proposer", [reviewer, "shared-integrator"], "PROPOSE", refs, {"claim": claim})
                self.assertTrue(pilot.submit_response(run_dir, seed, f"{coord}-proposer", protocol.canonical_bytes(msg))["accepted"])
            for reviewer in ("u-reviewer", "v-reviewer"):
                pilot.role_prompt(run_dir, seed, reviewer)
            for reviewer, coord, reviewed_coord in (("u-reviewer", "v", "v"), ("v-reviewer", "u", "u")):
                claim_id = f"{reviewed_coord}-relation"
                review_id = f"{problem_id}-{reviewer}-report"
                claim = protocol.get_projection(db, problem_id)["claims"][claim_id]
                ref = {"resource_id": f"claim:{claim_id}", "revision": claim["revision"], "state_revision": claim["state_revision"]}
                corrected = {
                    "claim_id": claim_id, "revision": 1, "state_revision": 1, "status": "candidate",
                    "value": {"coefficients": case["relation"][reviewed_coord]},
                    "provenance": {"message_id": review_id},
                    "dependencies": [{"resource_id": f"problem:{problem_id}", "claim_revision": 1}],
                }
                msg = envelope(problem_id, review_id, reviewer, ["shared-integrator"], "CHALLENGE", [refs_base, ref],
                    {"target": ref, "assessment": {"assessment": "supported", "basis_refs": ["observation-1", "observation-2", "observation-3"]}, "corrected_claim": corrected},
                    reply_to=proposal_ids[reviewed_coord])
                self.assertTrue(pilot.submit_response(run_dir, seed, reviewer, protocol.canonical_bytes(msg))["accepted"])
            paths = pilot.final_prompts(run_dir, seed)
            shared = paths["shared-integrator"].read_text(encoding="utf-8")
            raw = paths["raw-integrator"].read_text(encoding="utf-8")
            public = json.dumps(pilot.public_problem(seed), sort_keys=True, indent=2)
            self.assertIn(public, shared)
            self.assertIn(public, raw)
            self.assertIn('"candidate"', shared)
            self.assertIn('"reviews"', shared)
            self.assertNotIn('"candidate"', raw)
            self.assertNotIn('"claims"', raw)
            self.assertIn('"resource_id": "claim:u-relation"', shared)
            self.assertIn('"resource_id": "claim:v-relation"', shared)
            shared_final_task = shared.split("FINAL ANSWER TASK", 1)[1].split("CONDITION-SPECIFIC", 1)[0]
            raw_final_task = raw.split("FINAL ANSWER TASK", 1)[1].split("CONDITION-SPECIFIC", 1)[0]
            self.assertEqual(shared_final_task, raw_final_task)
            self.assertIn('{"status":"underdetermined"}', shared_final_task)
            self.assertIn("omit x and y", shared_final_task)
            self.assertEqual(pilot.final_prompts(run_dir, seed), paths)

    def test_cli_round_trip_preserves_raw_before_parse_and_scores_only_saved_final_outputs(self):
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "run"
            cli("prepare", "--out-dir", run_dir)
            for seed in (4201, 4202):
                case = lab3_case(seed)
                problem_id = f"affine-{seed}"
                base_refs = [{"resource_id": f"problem:{problem_id}", "revision": 1, "state_revision": 1}]
                for coord, reviewer in (("u", "v-reviewer"), ("v", "u-reviewer")):
                    claim_id = f"{coord}-relation"
                    msg_id = f"{problem_id}-{coord}-proposal"
                    refs = base_refs + [{"resource_id": f"claim:{claim_id}", "revision": 0, "state_revision": 0}]
                    claim = {
                        "claim_id": claim_id, "revision": 1, "state_revision": 1, "status": "active",
                        "value": {"coefficients": case["relation"][coord]},
                        "provenance": {"message_id": msg_id},
                        "dependencies": [{"resource_id": f"problem:{problem_id}", "claim_revision": 1}],
                    }
                    msg = envelope(problem_id, msg_id, f"{coord}-proposer", [reviewer, "shared-integrator"], "PROPOSE", refs, {"claim": claim})
                    raw_path = write_response(Path(td) / f"{seed}-{coord}.raw", msg)
                    result = json.loads(cli("submit", "--run-dir", run_dir, "--seed", seed, "--role", f"{coord}-proposer", "--raw", raw_path).stdout)
                    self.assertTrue(result["accepted"])
                for reviewer in ("u-reviewer", "v-reviewer"):
                    cli("prompt", "--run-dir", run_dir, "--seed", seed, "--role", reviewer)
                projection = protocol.get_projection(run_dir / "cases" / str(seed) / "store.sqlite", problem_id)
                self.assertEqual(set(projection["claims"]), {"u-relation", "v-relation"})
                for reviewer, coord in (("u-reviewer", "v"), ("v-reviewer", "u")):
                    claim_id = f"{coord}-relation"
                    claim = projection["claims"][claim_id]
                    ref = {"resource_id": f"claim:{claim_id}", "revision": claim["revision"], "state_revision": claim["state_revision"]}
                    review_id = f"{problem_id}-{reviewer}-report"
                    corrected = {
                        "claim_id": claim_id, "revision": 1, "state_revision": 1, "status": "candidate",
                        "value": {"coefficients": case["relation"][coord]},
                    "provenance": {"message_id": review_id},
                    "dependencies": [{"resource_id": f"problem:{problem_id}", "claim_revision": 1}],
                    }
                    msg = envelope(problem_id, review_id, reviewer, ["shared-integrator"], "REPORT_EVIDENCE", base_refs + [ref],
                    {"report": {"assessment": "supported", "basis_refs": ["observation-1", "observation-2", "observation-3"], "target": ref}, "corrected_claim": corrected},
                        reply_to=f"{problem_id}-{coord}-proposal")
                    raw_path = write_response(Path(td) / f"{seed}-{reviewer}.raw", msg)
                    result = json.loads(cli("submit", "--run-dir", run_dir, "--seed", seed, "--role", reviewer, "--raw", raw_path).stdout)
                    self.assertTrue(result["accepted"])
                cli("final-prompts", "--run-dir", run_dir, "--seed", seed)
                answer = case["target"]["xy"]
                for role in ("shared-integrator", "raw-integrator"):
                    mid = f"{problem_id}-{role}-conclusion"
                    refs = base_refs
                    if role == "shared-integrator":
                        refs = refs + [
                            {"resource_id": f"claim:u-relation", "revision": 1, "state_revision": 1},
                            {"resource_id": f"claim:v-relation", "revision": 1, "state_revision": 1},
                        ]
                    msg = envelope(problem_id, mid, role, ["shared-integrator"], "CONCLUDE", refs,
                        {"conclusion": {"status": "solved", "x": answer[0], "y": answer[1]}})
                    raw_path = write_response(Path(td) / f"{seed}-{role}.raw", msg)
                    result = json.loads(cli("submit", "--run-dir", run_dir, "--seed", seed, "--role", role, "--raw", raw_path).stdout)
                    self.assertTrue(result["accepted"])
            stored = run_dir / "responses" / "4201" / "u-proposer.raw"
            self.assertEqual(stored.read_bytes(), (Path(td) / "4201-u.raw").read_bytes())
            report = json.loads(cli("evaluate", "--run-dir", run_dir).stdout)
            self.assertTrue(report["offline_only"])
            self.assertEqual(set(report["cases"]), {"4201", "4202"})
            for seed in (4201, 4202):
                for role in ("raw-integrator", "shared-integrator"):
                    self.assertTrue(report["cases"][str(seed)]["conditions"][role]["true_world_correct"])
                self.assertEqual([row["intent"] for row in report["cases"][str(seed)]["reviews"]],
                                 ["REPORT_EVIDENCE", "REPORT_EVIDENCE"])
                self.assertTrue(all(row["receipt"]["accepted"] for row in report["cases"][str(seed)]["reviews"]))
            stored_4201 = run_dir / "responses" / "4201" / "u-proposer.raw"
            metadata = json.loads((run_dir / "call_metadata" / "4201" / "u-proposer.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["raw_sha256"], hashlib.sha256(stored_4201.read_bytes()).hexdigest())
            self.assertIsNotNone(metadata["prompt_sha256"])

            bad_dir = Path(td) / "malformed-run"
            cli("prepare", "--out-dir", bad_dir)
            malformed = b'{"schema_version":1,"bad":'
            raw_path = Path(td) / "malformed.raw"
            raw_path.write_bytes(malformed)
            result = json.loads(cli("submit", "--run-dir", bad_dir, "--seed", 4201, "--role", "u-proposer", "--raw", raw_path).stdout)
            self.assertFalse(result["accepted"])
            self.assertEqual((bad_dir / "responses" / "4201" / "u-proposer.raw").read_bytes(), malformed)
            self.assertEqual(result["code"], "INVALID_JSON")
            with self.assertRaises(subprocess.CalledProcessError):
                cli("evaluate", "--run-dir", bad_dir)

    def test_role_identity_and_recipient_gate_preserves_bytes_without_committing(self):
        with tempfile.TemporaryDirectory() as td:
            wrong_sender_dir = Path(td) / "wrong-sender"
            cli("prepare", "--out-dir", wrong_sender_dir)
            seed = 4201
            problem_id = f"affine-{seed}"
            case = lab3_case(seed)
            refs = [
                {"resource_id": f"problem:{problem_id}", "revision": 1, "state_revision": 1},
                {"resource_id": "claim:u-relation", "revision": 0, "state_revision": 0},
            ]
            wrong_sender = envelope(problem_id, f"{problem_id}-u-proposal", "v-proposer",
                ["v-reviewer", "shared-integrator"], "PROPOSE", refs,
                {"claim": {"claim_id": "u-relation", "revision": 1, "state_revision": 1, "status": "active",
                 "value": {"coefficients": case["relation"]["u"]}, "provenance": {"message_id": f"{problem_id}-u-proposal"},
                 "dependencies": [{"resource_id": f"problem:{problem_id}", "claim_revision": 1}]}})
            wrong_sender_raw = protocol.canonical_bytes(wrong_sender)
            wrong_sender_path = Path(td) / "wrong-sender.raw"
            wrong_sender_path.write_bytes(wrong_sender_raw)
            receipt = json.loads(cli("submit", "--run-dir", wrong_sender_dir, "--seed", seed,
                "--role", "u-proposer", "--raw", wrong_sender_path).stdout)
            self.assertEqual(receipt["code"], "ROLE_MISMATCH")
            self.assertEqual((wrong_sender_dir / "responses" / str(seed) / "u-proposer.raw").read_bytes(), wrong_sender_raw)
            db = wrong_sender_dir / "cases" / str(seed) / "store.sqlite"
            self.assertEqual(protocol.event_hashes(db, problem_id), [])
            self.assertEqual(protocol.get_projection(db, problem_id)["claims"], {})
            audit = protocol.submissions(db, problem_id)
            self.assertEqual(audit[-1]["raw"], wrong_sender_raw)
            self.assertFalse(audit[-1]["accepted"])

            wrong_recipient_dir = Path(td) / "wrong-recipient"
            cli("prepare", "--out-dir", wrong_recipient_dir)
            for current_seed in (4201, 4202):
                current_id = f"affine-{current_seed}"
                current_case = lab3_case(current_seed)
                for role in ("u-proposer", "v-proposer"):
                    pilot.record_failure(wrong_recipient_dir, current_seed, role, "fixture omitted")
                for role in ("u-reviewer", "v-reviewer"):
                    pilot.role_prompt(wrong_recipient_dir, current_seed, role)
                    pilot.record_failure(wrong_recipient_dir, current_seed, role, "fixture omitted")
                pilot.final_prompts(wrong_recipient_dir, current_seed)
                pilot.record_failure(wrong_recipient_dir, current_seed, "shared-integrator", "fixture omitted")
                answer = current_case["target"]["xy"]
                wrong_recipient = envelope(current_id, f"{current_id}-raw-integrator-conclusion", "raw-integrator",
                    ["raw-integrator"], "CONCLUDE",
                    [{"resource_id": f"problem:{current_id}", "revision": 1, "state_revision": 1}],
                    {"conclusion": {"status": "solved", "x": answer[0], "y": answer[1]}})
                raw_path = Path(td) / f"wrong-recipient-{current_seed}.raw"
                raw_path.write_bytes(protocol.canonical_bytes(wrong_recipient))
                receipt = json.loads(cli("submit", "--run-dir", wrong_recipient_dir, "--seed", current_seed,
                    "--role", "raw-integrator", "--raw", raw_path).stdout)
                self.assertEqual(receipt["code"], "ROLE_MISMATCH")
            report = json.loads(cli("evaluate", "--run-dir", wrong_recipient_dir).stdout)
            raw_score = report["cases"]["4201"]["conditions"]["raw-integrator"]
            self.assertTrue(raw_score["raw_answer_matches_true_target"])
            self.assertFalse(raw_score["accepted_by_store"])
            self.assertFalse(raw_score["true_world_correct"])


if __name__ == "__main__":
    unittest.main()

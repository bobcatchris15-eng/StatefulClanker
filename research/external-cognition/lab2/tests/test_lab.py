"""Runtime integration tests; no provider calls are made."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

import core
import lab


class LabRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.run = self.root / "run"
        lab.init_chain(self.run, seed=1101, blocks=4, codec="packed",
                       representation="vector", arm="checked")

    def tearDown(self):
        self.tmp.cleanup()

    def next_patch(self):
        manifest = lab.load_manifest(self.run)
        state = lab.load_state(self.run)
        stage = manifest["problem"]["stages"][state["next_stage"]]
        expected = core.frontier_step(stage, state["frontier"])
        return {"base_version": state["version"], "stage": state["next_stage"],
                "frontier": [[r["boundary"], r["cost"], r["bits"]] for r in expected]}

    def test_prompt_is_local_explicit_and_has_no_oracle_answer(self):
        prompt = lab.make_prompt(self.run)
        state = lab.load_state(self.run)
        manifest = lab.load_manifest(self.run)
        body = json.loads(prompt.split("\n", 1)[1])
        self.assertEqual(body["base_version"], 0)
        self.assertEqual(body["frontier_representation"], "vector")
        self.assertEqual(body["stage"], manifest["problem"]["stages"][0])
        self.assertEqual(body["frontier"], [[0, 0, ""]])
        self.assertEqual(body["required_output"]["format"], "one JSON object and nothing else; no markdown or prose")
        # Independent counterexample: legality parity can be 1 while the outgoing y boundary is 0.
        incoming_boundary, x, y, parity = 1, 0, 0, 1
        self.assertEqual(body["task"]["boundary_after_stage"], "y")
        self.assertEqual(body["task"]["legality_condition"],
                         "(incoming_boundary + x + y) mod 2 == stage.parity")
        self.assertEqual((incoming_boundary + x + y) % 2, parity)
        self.assertEqual(y, 0)
        self.assertNotEqual(y, parity)
        self.assertNotIn('"bits": "01010101"', prompt)
        self.assertEqual(state["next_stage"], 0)

    def test_valid_vector_transition_and_duplicate_id_refusal(self):
        raw = json.dumps(self.next_patch(), separators=(",", ":")).encode()
        receipt = lab.submit_patch(self.run, "resp-1", raw)
        self.assertTrue(receipt["accepted"], receipt)
        self.assertEqual(lab.load_state(self.run)["version"], 1)
        self.assertEqual((self.run / "responses" / "resp-1.raw").read_bytes(), raw)
        with self.assertRaises(lab.DuplicateResponseError):
            lab.submit_patch(self.run, "resp-1", b"{}")

    def test_malformed_and_stale_raw_are_preserved_store_unchanged(self):
        before = (self.run / "state.bin").read_bytes()
        malformed = b"{ bad exact bytes\x00"
        r = lab.submit_patch(self.run, "malformed", malformed)
        self.assertFalse(r["accepted"])
        self.assertEqual((self.run / "responses" / "malformed.raw").read_bytes(), malformed)
        self.assertEqual((self.run / "state.bin").read_bytes(), before)
        stale = self.next_patch()
        stale["base_version"] = 91
        stale_raw = json.dumps(stale).encode()
        r = lab.submit_patch(self.run, "stale", stale_raw)
        self.assertFalse(r["accepted"])
        self.assertEqual((self.run / "responses" / "stale.raw").read_bytes(), stale_raw)
        self.assertEqual((self.run / "state.bin").read_bytes(), before)

    def test_exact_response_is_installed_before_validation_and_rejection(self):
        raw = json.dumps(self.next_patch()).encode()
        before = (self.run / "state.bin").read_bytes()

        def fail_after_capture(*args, **kwargs):
            self.assertEqual((self.run / "responses" / "ordered.raw").read_bytes(), raw)
            raise ValueError("injected validation interruption")

        with mock.patch.object(core, "apply_patch", side_effect=fail_after_capture):
            receipt = lab.submit_patch(self.run, "ordered", raw)
        self.assertFalse(receipt["accepted"])
        self.assertEqual((self.run / "responses" / "ordered.raw").read_bytes(), raw)
        self.assertEqual((self.run / "state.bin").read_bytes(), before)

    def test_commit_journal_recovers_interrupted_state_write(self):
        raw = json.dumps(self.next_patch()).encode()
        real_write = lab._atomic_write

        def interrupt_state(path, payload):
            if path.name == "state.bin":
                raise OSError("injected interruption after commit journal")
            return real_write(path, payload)

        with mock.patch.object(lab, "_atomic_write", side_effect=interrupt_state):
            with self.assertRaises(OSError):
                lab.submit_patch(self.run, "recoverable", raw)
        self.assertTrue((self.run / ".submit-journal.json").exists())
        summary = lab.summarize(self.run)
        self.assertEqual(summary["accepted_transitions"], 1)
        self.assertEqual(lab.load_state(self.run)["version"], 1)
        self.assertFalse((self.run / ".submit-journal.json").exists())
        self.assertEqual((self.run / "responses" / "recoverable.raw").read_bytes(), raw)

    def test_orphan_raw_after_interrupted_validation_gets_evaluator_receipt(self):
        raw = b"exact interrupted bytes\x00"
        (self.run / "responses" / "orphan.raw").write_bytes(raw)
        summary = lab.summarize(self.run)
        receipt = json.loads((self.run / "receipts" / "orphan.json").read_text())
        self.assertEqual(summary["calls"], 1)
        self.assertTrue(receipt["interrupted"])
        self.assertEqual(receipt["raw_sha256"], __import__("hashlib").sha256(raw).hexdigest())

    def test_checked_prompt_fails_closed_on_checksummed_semantic_state_corruption(self):
        raw = json.dumps(self.next_patch()).encode()
        self.assertTrue(lab.submit_patch(self.run, "good", raw)["accepted"])
        state = core.decode_state((self.run / "state.bin").read_bytes())
        state["history"][0]["frontier"][0]["cost"] += 100
        (self.run / "state.bin").write_bytes(core.encode_state(state, "packed"))
        with self.assertRaisesRegex(lab.LabError, "history fails stage"):
            lab.make_prompt(self.run)

    def test_rejected_frontier_preserves_store_and_feedback_has_no_answer(self):
        patch = self.next_patch()
        patch["frontier"][0][1] += 1
        raw = json.dumps(patch).encode()
        before = (self.run / "state.bin").read_bytes()
        receipt = lab.submit_patch(self.run, "wrong", raw)
        self.assertFalse(receipt["accepted"])
        self.assertEqual((self.run / "state.bin").read_bytes(), before)
        self.assertNotIn("expected_frontier", json.dumps(receipt))
        self.assertEqual((self.run / "responses" / "wrong.raw").read_bytes(), raw)

    def test_unchecked_arm_still_checks_version_and_shape(self):
        run2 = self.root / "unchecked"
        lab.init_chain(run2, seed=1101, blocks=4, codec="json",
                       representation="records", arm="unchecked")
        bad = {"base_version": 0, "stage": 0, "frontier": "not rows"}
        receipt = lab.submit_patch(run2, "bad-shape", json.dumps(bad).encode())
        self.assertFalse(receipt["accepted"])
        self.assertEqual(lab.load_state(run2)["version"], 0)
        # Unchecked accepts a shape-valid, correctly sized but mathematically wrong proposal.
        manifest2, state2 = lab.load_manifest(run2), lab.load_state(run2)
        expected = core.frontier_step(manifest2["problem"]["stages"][0], state2["frontier"])
        good = {"base_version": 0, "stage": 0,
                "frontier": [{**row, "cost": row["cost"] + 13} for row in expected]}
        receipt = lab.submit_patch(run2, "unchecked", json.dumps(good).encode())
        self.assertTrue(receipt["accepted"], receipt)

    def test_change_cost_truncates_suffix_reuses_prefix(self):
        for i in range(2):
            lab.submit_patch(self.run, f"step{i}", json.dumps(self.next_patch()).encode())
        before = lab.load_state(self.run)
        stage = lab.load_manifest(self.run)["problem"]["stages"][1]
        r = lab.change_cost(self.run, stage=1, field="wx", delta=1)
        after = lab.load_state(self.run)
        self.assertTrue(r["accepted"], r)
        self.assertEqual(after["version"], before["version"] + 1)
        self.assertEqual(after["next_stage"], 1)
        self.assertEqual(after["frontier"], before["history"][0]["frontier"])
        self.assertEqual(len(after["history"]), 1)

    def test_calibration_generation_and_full_scoring(self):
        out = self.root / "cal"
        info = lab.prepare_calibration(out)
        self.assertEqual(len(info["cases"]), 6)
        case = info["cases"][0]
        key = lab.load_calibration_key(out, case["case_id"])
        full_prompt = (out / "prompts" / f"{case['case_id']}.txt").read_text()
        self.assertIn('"boundary_after_stage": "y"', full_prompt)
        self.assertIn("the outgoing boundary is y", full_prompt)
        receipt = lab.score_full(out, case["case_id"], json.dumps(key["answer"]).encode())
        self.assertTrue(receipt["correct"])
        self.assertTrue((out / "prompts" / f"{case['case_id']}.txt").exists())

    def test_summary_counts_raw_calls_chars_and_store_bytes(self):
        raw = json.dumps(self.next_patch()).encode()
        lab.submit_patch(self.run, "s1", raw)
        summary = lab.summarize(self.run)
        self.assertEqual(summary["calls"], 1)
        self.assertEqual(summary["raw_response_bytes"], len(raw))
        self.assertEqual(summary["raw_response_characters"], len(raw.decode()))
        self.assertEqual(summary["store_bytes"], (self.run / "state.bin").stat().st_size)
        self.assertIsNone(summary["tokens"])

    def test_repair_count_uses_submission_order_not_receipt_filename_order(self):
        lab.submit_patch(self.run, "s0", json.dumps(self.next_patch()).encode())
        valid = self.next_patch()
        wrong = json.loads(json.dumps(valid))
        wrong["frontier"][0][1] += 1
        rejected = lab.submit_patch(self.run, "s1", json.dumps(wrong).encode())
        accepted = lab.submit_patch(self.run, "s1-repair", json.dumps(valid).encode())
        self.assertFalse(rejected["accepted"])
        self.assertTrue(accepted["accepted"])
        summary = lab.summarize(self.run)
        self.assertEqual(summary["repair_attempts_after_rejection"], 1)
        self.assertLess("s1-repair.json", "s1.json")  # filenames reverse actual submission order
        self.assertLess(rejected["submission_order"], accepted["submission_order"])

        lab.change_cost(self.run, stage=1, field="wx", delta=1)
        changed_input_retry = lab.submit_patch(self.run, "update-s1", json.dumps(self.next_patch()).encode())
        self.assertTrue(changed_input_retry["accepted"])
        self.assertNotEqual(changed_input_retry["base_version"], rejected["base_version"])
        self.assertEqual(lab.summarize(self.run)["repair_attempts_after_rejection"], 1)

    def test_custom_calibration_axes_are_validated_and_match_core_schemas(self):
        out = self.root / "custom-calibration"
        info = lab.prepare_calibration(out, sizes=[3, 5], seeds=[17, -2])
        self.assertEqual(len(info["cases"]), 4)
        for case in info["cases"]:
            self.assertIn(case["blocks"], {3, 5})
            self.assertIn(case["seed"], {17, -2})
            key = lab.load_calibration_key(out, case["case_id"])
            self.assertEqual(key["problem"], core.generate_problem(case["seed"], case["blocks"]))
            self.assertEqual(key["answer"], core.oracle(key["problem"]))
            prompt = json.loads((out / case["prompt_file"]).read_text().split("\n", 1)[1])
            self.assertEqual(prompt["schema"], "cycle2-full-answer-v1")
            self.assertEqual(prompt["problem"], key["problem"])
            self.assertEqual(prompt["required_output"]["schema"], {"cost": "integer", "bits": "string"})
        for sizes, seeds in (([0], [1]), ([2, 2], [1]), ([2], [1, 1]), ([2], [1.5])):
            with self.subTest(sizes=sizes, seeds=seeds):
                with self.assertRaises(ValueError):
                    lab.prepare_calibration(self.root / f"invalid-{len(list(self.root.iterdir()))}",
                                            sizes=sizes, seeds=seeds)

    def test_legacy_repair_order_uses_mtime_without_rewriting_receipts(self):
        run = self.root / "legacy-run"
        lab.init_chain(run, seed=1101, blocks=4, codec="packed",
                       representation="vector", arm="checked")
        rejected = {"response_id": "s1", "accepted": False, "stage": 1,
                    "base_version": 1, "issues": ["legacy rejection"]}
        accepted = {"response_id": "s1-repair", "accepted": True, "stage": 1,
                    "base_version": 1, "issues": []}
        reject_path = run / "receipts" / "s1.json"
        repair_path = run / "receipts" / "s1-repair.json"
        reject_path.write_text(json.dumps(rejected))
        repair_path.write_text(json.dumps(accepted))
        os.utime(reject_path, ns=(1_000_000_000, 1_000_000_000))
        os.utime(repair_path, ns=(2_000_000_000, 2_000_000_000))
        originals = {p.name: p.read_bytes() for p in (reject_path, repair_path)}
        summary = lab.summarize(run)
        self.assertEqual(summary["repair_attempts_after_rejection"], 1)
        self.assertEqual(summary["repair_order_basis"], "legacy_mtime_ns_fallback")
        self.assertEqual(summary["legacy_receipts_without_submission_order"], 2)
        self.assertEqual({p.name: p.read_bytes() for p in (reject_path, repair_path)}, originals)

    def test_reject_paths_outside_run_and_response_id_paths(self):
        with self.assertRaises((ValueError, lab.UnsafePathError)):
            lab.submit_patch(self.run, "../escape", b"{}")
        outside = self.root / "outside"
        outside.mkdir()
        link = self.root / "link"
        try:
            link.symlink_to(outside, target_is_directory=True)
        except OSError:
            self.skipTest("symlink creation unavailable")
        with self.assertRaises(lab.UnsafePathError):
            lab.init_chain(link / "run", seed=1, blocks=2, codec="packed",
                           representation="vector", arm="checked")

    def test_cli_end_to_end_in_temporary_run(self):
        run = self.root / "cli-run"
        script = Path(lab.__file__)

        def cli(*args):
            return subprocess.run([sys.executable, str(script), *map(str, args)],
                                  cwd=script.parent, capture_output=True, text=True,
                                  check=True)

        cli("init-chain", "--run-dir", run, "--seed", 1101, "--blocks", 2,
            "--codec", "packed", "--representation", "records", "--arm", "checked")
        custom_cal = self.root / "cli-calibration"
        cli("prepare-calibration", "--out-dir", custom_cal, "--sizes", 3, 7,
            "--seeds", 29)
        cases = json.loads((custom_cal / "calibration.json").read_text())["cases"]
        self.assertEqual([(c["blocks"], c["seed"]) for c in cases], [(3, 29), (7, 29)])
        prompt = cli("prompt", "--run-dir", run).stdout
        self.assertEqual(json.loads(prompt.split("\n", 1)[1])["schema"], "cycle2-stage-patch-v1")
        response = self.root / "response.json"
        response.write_bytes(b"not json \x00 exact")
        receipt = json.loads(cli("submit", "--run-dir", run, "--response-id", "cli-bad",
                                 "--response-file", response).stdout)
        self.assertFalse(receipt["accepted"])
        self.assertEqual((run / "responses" / "cli-bad.raw").read_bytes(), response.read_bytes())
        summary = json.loads(cli("summary", "--run-dir", run).stdout)
        self.assertEqual(summary["calls"], 1)
        self.assertEqual(summary["malformed_responses"], 1)


if __name__ == "__main__":
    unittest.main()

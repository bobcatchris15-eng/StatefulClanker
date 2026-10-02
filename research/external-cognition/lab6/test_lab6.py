"""Unit tests for Lab 6 16-variable ring CSP pilot, cases, and evaluator."""
import json
import shutil
import tempfile
import unittest
from pathlib import Path

import sys
LAB6_DIR = Path(__file__).resolve().parent
if str(LAB6_DIR) not in sys.path:
    sys.path.insert(0, str(LAB6_DIR))

import offline_evaluate
import pilot
CASES_DIR = LAB6_DIR / "cases"
KEY_FILE = LAB6_DIR / "private" / "case-key.json"


class TestLab6CasesAndKey(unittest.TestCase):
    def test_seeds_and_constants(self):
        self.assertEqual(pilot.SEEDS, (6112, 6135, 6412, 6432, 6459, 6582))
        self.assertEqual(len(pilot.SEEDS), 6)
        self.assertEqual(len(pilot.PROPOSERS), 4)
        self.assertEqual(len(pilot.REVIEWERS), 4)
        self.assertEqual(len(pilot.FINALS), 2)
        self.assertEqual(len(pilot.ROLES), 10)

    def test_cases_and_key_integrity(self):
        self.assertTrue(KEY_FILE.is_file(), "case-key.json must exist")
        key_data = json.loads(KEY_FILE.read_text(encoding="utf-8"))
        self.assertIn("cases", key_data)

        for seed in pilot.SEEDS:
            case_file = CASES_DIR / f"{seed}.json"
            self.assertTrue(case_file.is_file(), f"Case file for seed {seed} must exist")
            case = json.loads(case_file.read_text(encoding="utf-8"))

            # Check variables
            variables = case["variables"]
            self.assertEqual(len(variables), 16)
            expected_vars = [chr(ord("a") + i) for i in range(16)]
            self.assertEqual(sorted(variables), expected_vars)
            self.assertEqual(case["domain"], [0, 1, 2, 3])

            # Check components
            components = case["components"]
            self.assertEqual(len(components), 4)
            self.assertEqual(components["c1"], ["a", "b", "c", "d"])
            self.assertEqual(components["c2"], ["e", "f", "g", "h"])
            self.assertEqual(components["c3"], ["i", "j", "k", "l"])
            self.assertEqual(components["c4"], ["m", "n", "o", "p"])

            # Check constraints count: 16 internal + 4 bridge = 20
            constraints = case["constraints"]
            self.assertEqual(len(constraints), 20)

            # Check key secrets
            secret = key_data["cases"][str(seed)]
            self.assertEqual(len(secret["global_solutions"]), 1, f"Seed {seed} must have exactly 1 global solution")
            sol = secret["global_solutions"][0]
            self.assertEqual(len(sol), 16)

            for comp in ("c1", "c2", "c3", "c4"):
                local_tuples = secret["local_solutions"][comp]
                count = len(local_tuples)
                self.assertTrue(
                    3 <= count <= 8,
                    f"Seed {seed} component {comp} local solution count {count} not in [3, 8]",
                )


class TestLab6PilotAndEvaluation(unittest.TestCase):
    def setUp(self):
        self.temp_dir = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_prepare_campaign(self):
        run_dir = self.temp_dir / "test_run"
        pilot.prepare(run_dir)

        self.assertTrue((run_dir / "run.json").is_file())
        manifest = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["schema"], pilot.SCHEMA)
        self.assertEqual(manifest["families"], list(pilot.FAMILIES))
        self.assertEqual(len(manifest["case_hashes"]), len(pilot.SEEDS))

        for seed in pilot.SEEDS:
            case_path = run_dir / "cases" / str(seed)
            self.assertTrue((case_path / "problem.json").is_file())
            for fam in pilot.FAMILIES:
                self.assertTrue((case_path / fam / "store.sqlite").is_file())

    def test_offline_evaluate_synthetic(self):
        run_dir = self.temp_dir / "synth_run"
        pilot.prepare(run_dir)
        key_data = json.loads(KEY_FILE.read_text(encoding="utf-8"))

        # Create synthetic responses for one seed (6112)
        seed = 6112
        fam = "north"
        slot_dir = run_dir / "responses" / str(seed) / fam
        slot_dir.mkdir(parents=True, exist_ok=True)

        secret = key_data["cases"][str(seed)]

        problem = json.loads((run_dir / "cases" / str(seed) / "problem.json").read_text(encoding="utf-8"))

        # Proposers: provide perfect tuples
        for comp in ("c1", "c2", "c3", "c4"):
            role = f"{comp}-proposer"
            payload = {
                "claim": {
                    "component": comp,
                    "variables": problem["components"][comp],
                    "value": {"tuples": secret["local_solutions"][comp]},
                }
            }
            env = {"intent": "PROPOSE", "payload": payload}
            raw = json.dumps(env).encode("utf-8")
            (slot_dir / f"{role}.raw").write_bytes(raw)
            (slot_dir / f"{role}.receipt.json").write_text(
                json.dumps({"protocol_receipt": {"accepted": True}}), encoding="utf-8"
            )

        # Reviewers
        for r in pilot.REVIEWERS:
            env = {"intent": "REVIEW", "payload": {"assessment": {"assessment": "CONFIRMED"}}}
            raw = json.dumps(env).encode("utf-8")
            (slot_dir / f"{r}.raw").write_bytes(raw)
            (slot_dir / f"{r}.receipt.json").write_text(
                json.dumps({"protocol_receipt": {"accepted": True}}), encoding="utf-8"
            )

        # Final Integrators: shared is correct, raw is incorrect
        correct_sol = secret["global_solutions"][0]
        wrong_sol = {k: (v + 1) % 4 for k, v in correct_sol.items()}

        shared_env = {"intent": "CONCLUDE", "payload": {"conclusion": {"assignment": correct_sol}}}
        (slot_dir / "shared-integrator.raw").write_bytes(json.dumps(shared_env).encode("utf-8"))
        (slot_dir / "shared-integrator.receipt.json").write_text(
            json.dumps({"protocol_receipt": {"accepted": True}}), encoding="utf-8"
        )

        raw_env = {"intent": "CONCLUDE", "payload": {"conclusion": {"assignment": wrong_sol}}}
        (slot_dir / "raw-integrator.raw").write_bytes(json.dumps(raw_env).encode("utf-8"))
        (slot_dir / "raw-integrator.receipt.json").write_text(
            json.dumps({"protocol_receipt": {"accepted": True}}), encoding="utf-8"
        )

        # For other seeds, write dummy failure files so all slots have outcomes
        for s in pilot.SEEDS:
            if s == seed:
                continue
            s_dir = run_dir / "responses" / str(s) / fam
            s_dir.mkdir(parents=True, exist_ok=True)
            for r in pilot.ROLES:
                (s_dir / f"{r}.failure.json").write_text(json.dumps({"error": "test failure"}), encoding="utf-8")

        summary = offline_evaluate.evaluate_frozen_run(run_dir, KEY_FILE)
        fam_summary = summary["families"]["north"]
        self.assertEqual(fam_summary["total_slots"], 60)
        self.assertEqual(fam_summary["responses"], 10)
        self.assertEqual(fam_summary["failures"], 50)
        self.assertEqual(fam_summary["shared_solution_correct"], 1)
        self.assertEqual(fam_summary["raw_solution_correct"], 0)


if __name__ == "__main__":
    unittest.main()

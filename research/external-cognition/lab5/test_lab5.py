"""Unit tests for Lab 5 finite CSP pilot and offline evaluator."""
import tempfile
import unittest
from pathlib import Path
import sys

LAB5_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(LAB5_DIR))

import pilot
import offline_evaluate


class Lab5Tests(unittest.TestCase):
    def test_seeds_and_constants(self):
        self.assertEqual(len(pilot.SEEDS), 6)
        self.assertEqual(len(pilot.ROLES), 6)
        self.assertEqual(len(pilot.FAMILIES), 2)
        self.assertEqual(len(pilot._expected_roles()), 72)

    def test_case_keys_match_seeds(self):
        key = offline_evaluate._read_json(offline_evaluate.PRIVATE_KEY_PATH)
        for seed in pilot.SEEDS:
            self.assertIn(str(seed), key["cases"])
            case = key["cases"][str(seed)]
            self.assertEqual(len(case["global_solutions"]), 1)
            self.assertTrue(3 <= len(case["local_solutions"]["left"]) <= 10)
            self.assertTrue(3 <= len(case["local_solutions"]["right"]) <= 10)

    def test_prepare_creates_freeze(self):
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "run"
            manifest = pilot.prepare(run_dir)
            self.assertEqual(manifest["schema"], "lab5-finite-csp-pilot-v1")
            self.assertEqual(manifest["planned_calls"], 72)
            self.assertTrue((run_dir / "run.json").is_file())
            self.assertTrue((run_dir / "transport" / "north.json").is_file())
            self.assertTrue((run_dir / "transport" / "gemini.json").is_file())
            for seed in pilot.SEEDS:
                self.assertTrue((run_dir / "cases" / str(seed) / "problem.json").is_file())
                self.assertTrue((run_dir / "cases" / str(seed) / "store.sqlite").is_file())
                self.assertTrue((run_dir / "prompts" / str(seed) / "left-proposer.txt").is_file())
    def test_evaluation_locked_until_all_72_outcomes(self):
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "run"
            pilot.prepare(run_dir)
            with self.assertRaises(pilot.PilotError) as ctx:
                pilot.evaluate(run_dir)
            self.assertIn("evaluation locked until all 72 outcomes exist", str(ctx.exception))

    def test_offline_evaluate_synthetic_run(self):
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "run"
            pilot.prepare(run_dir)
            # Record failures phase by phase to respect prompt gating:
            for seed in pilot.SEEDS:
                for fam in pilot.FAMILIES:
                    for role in pilot.PROPOSERS:
                        pilot.record_failure(run_dir, seed, fam, role, "TEST_FAILURE", "synthetic failure")
                    for role in pilot.REVIEWERS:
                        pilot.record_failure(run_dir, seed, fam, role, "TEST_FAILURE", "synthetic failure")
                    for role in pilot.FINALS:
                        pilot.record_failure(run_dir, seed, fam, role, "TEST_FAILURE", "synthetic failure")
            res = pilot.evaluate(run_dir)
            self.assertEqual(res["total_slots"], 72)
            self.assertIn("north", res["families"])
            self.assertIn("gemini", res["families"])
            self.assertEqual(res["families"]["north"]["failures"], 36)
            self.assertEqual(res["families"]["gemini"]["failures"], 36)


if __name__ == "__main__":
    unittest.main()

"""Independent adversarial checks for Lab 2's store and transition invariants.

These tests are deliberately kept separate from the engine's happy-path suite.
"""
import copy
import itertools
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import core
import lab


def exhaustive_frontier(stages):
    """Enumerate all complete witnesses for a prefix, then retain each boundary optimum."""
    best = {}
    for choices in itertools.product("01", repeat=2 * len(stages)):
        bits = "".join(choices)
        boundary, cost, valid = 0, 0, True
        for i, stage in enumerate(stages):
            x, y = int(bits[2 * i]), int(bits[2 * i + 1])
            if (boundary + x + y) % 2 != stage["parity"]:
                valid = False
                break
            cost += stage["wx"] * x + stage["wy"] * y
            boundary = y
        if not valid:
            continue
        row = {"boundary": boundary, "cost": cost, "bits": bits}
        if boundary not in best or (cost, bits) < (best[boundary]["cost"], best[boundary]["bits"]):
            best[boundary] = row
    return [best[b] for b in sorted(best)]


class IndependentAuditTests(unittest.TestCase):
    def test_generated_frontiers_match_exhaustive_prefix_enumeration(self):
        # Independent enumeration of every feasible prefix catches transition and
        # tie-breaking errors beyond checking only the final chosen boundary.
        for n in range(1, 7):
            for seed in (0, 1, 7, 91, 1101):
                problem = core.generate_problem(seed, n)
                frontier = core.initial_frontier()
                for i, stage in enumerate(problem["stages"], 1):
                    frontier = core.frontier_step(stage, frontier)
                    self.assertEqual(frontier, exhaustive_frontier(problem["stages"][:i]),
                                     (n, seed, i))

    def test_checked_patch_rejects_validly_checksummed_semantic_state_corruption(self):
        problem = core.generate_problem(1101, 3)
        state = core.initial_state(problem)
        wrong_prior = core.frontier_step(problem["stages"][0], state["frontier"])
        # Keep shape, witnesses, problem hash, history consistency, and encoding
        # valid; corrupt only the committed math in a way a byte checksum cannot detect.
        for row in wrong_prior:
            row["cost"] += 17
        forged = {**state, "version": 1, "next_stage": 1,
                  "frontier": copy.deepcopy(wrong_prior),
                  "history": [{"stage": 0, "frontier": copy.deepcopy(wrong_prior)}]}
        payload = core.encode_state(forged, "packed")
        recovered = core.decode_state(payload)
        self.assertEqual(recovered, forged)
        proposed = core.frontier_step(problem["stages"][1], recovered["frontier"])
        returned, receipt = core.apply_patch(
            problem, recovered,
            {"base_version": 1, "stage": 1, "frontier": proposed}, verify=True)
        self.assertFalse(receipt["accepted"],
                         "checked transition must refuse a state whose prior math is corrupt")
        self.assertEqual(returned, recovered)

    def test_checked_prompt_fails_closed_on_semantically_corrupt_store(self):
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            run = pathlib.Path(directory) / "checked"
            lab.init_chain(run, seed=1101, blocks=3, codec="packed",
                           representation="vector", arm="checked")
            manifest = lab.load_manifest(run)
            state = core.initial_state(manifest["problem"])
            rows = core.frontier_step(manifest["problem"]["stages"][0], state["frontier"])
            for row in rows:
                row["cost"] += 17
            forged = {**state, "version": 1, "next_stage": 1,
                      "frontier": copy.deepcopy(rows),
                      "history": [{"stage": 0, "frontier": copy.deepcopy(rows)}]}
            (run / "state.bin").write_bytes(core.encode_state(forged, "packed"))
            with self.assertRaises(lab.LabError):
                lab.make_prompt(run)

    def test_cost_changes_preserve_exact_prefix_and_recompute_to_full_oracle(self):
        for blocks in range(1, 6):
            for seed in (3, 29, 1101):
                problem = core.generate_problem(seed, blocks)
                state = core.initial_state(problem)
                for i, stage in enumerate(problem["stages"]):
                    state, receipt = core.apply_patch(
                        problem, state,
                        {"base_version": state["version"], "stage": i,
                         "frontier": core.frontier_step(stage, state["frontier"])})
                    self.assertTrue(receipt["accepted"])
                for changed in range(blocks):
                    updated = copy.deepcopy(problem)
                    field = "wx" if (seed + changed) % 2 else "wy"
                    updated["stages"][changed][field] += 2
                    replay = core.replace_problem(problem, state, updated, changed)
                    self.assertEqual(replay["frontier"],
                                     exhaustive_frontier(updated["stages"][:changed]))
                    for i in range(changed, blocks):
                        replay, receipt = core.apply_patch(
                            updated, replay,
                            {"base_version": replay["version"], "stage": i,
                             "frontier": core.frontier_step(updated["stages"][i], replay["frontier"])})
                        self.assertTrue(receipt["accepted"])
                    self.assertEqual(replay["frontier"], exhaustive_frontier(updated["stages"]))
                    final = min((r for r in exhaustive_frontier(updated["stages"])
                                 if r["boundary"] == updated["final_boundary"]),
                                key=lambda r: (r["cost"], r["bits"]))
                    self.assertEqual(core.oracle(updated),
                                     {"cost": final["cost"], "bits": final["bits"]})


if __name__ == "__main__":
    unittest.main()

import copy
import itertools
import unittest
import pathlib
import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import core


def brute(problem):
    best = None
    for bits in itertools.product('01', repeat=len(problem['stages']) * 2):
        cost = 0
        boundary = 0
        valid = True
        for i, stage in enumerate(problem['stages']):
            x, y = map(int, bits[2*i:2*i+2])
            if (boundary + x + y) % 2 != stage['parity']:
                valid = False
                break
            cost += stage['wx'] * x + stage['wy'] * y
            boundary = y
        if valid and boundary == problem['final_boundary']:
            candidate = (cost, ''.join(bits))
            if best is None or candidate < best:
                best = candidate
    if best is None:
        raise ValueError('no solution')
    return {'cost': best[0], 'bits': best[1]}


class CoreTests(unittest.TestCase):
    def test_small_generated_problems_match_independent_exhaustive_oracle(self):
        for n in range(1, 5):
            for seed in range(20):
                p = core.generate_problem(seed * 37 + n, n)
                self.assertEqual(core.oracle(p), brute(p))

    def test_frontier_step_is_exact_sorted_immutable_and_tie_lexical(self):
        f = [{'boundary': 0, 'cost': 0, 'bits': ''}]
        snapshot = copy.deepcopy(f)
        out = core.frontier_step({'parity': 0, 'wx': 1, 'wy': 1}, f)
        self.assertEqual(f, snapshot)
        self.assertEqual(out, [{'boundary': 0, 'cost': 0, 'bits': '00'},
                               {'boundary': 1, 'cost': 2, 'bits': '11'}])
        self.assertEqual(core.frontier_step({'parity': 1, 'wx': 1, 'wy': 1}, f),
                         [{'boundary': 0, 'cost': 1, 'bits': '10'},
                          {'boundary': 1, 'cost': 1, 'bits': '01'}])

    def test_stale_and_bad_proposals_reject_without_mutating_state(self):
        p = core.generate_problem(4, 2)
        s = core.initial_state(p)
        good = core.frontier_step(p['stages'][0], s['frontier'])
        s1, r = core.apply_patch(p, s, {'base_version': 0, 'stage': 0, 'frontier': good})
        self.assertTrue(r['accepted'])
        before = copy.deepcopy(s1)
        rejected, receipt = core.apply_patch(p, s1, {'base_version': 0, 'stage': 1, 'frontier': []})
        self.assertFalse(receipt['accepted'])
        self.assertEqual(rejected, before)
        self.assertEqual(s1, before)
        rejected, receipt = core.apply_patch(p, s1, {'base_version': 1, 'stage': 1, 'frontier': []})
        self.assertFalse(receipt['accepted'])
        self.assertEqual(rejected, before)

    def test_checked_patch_rejects_forged_prior_history(self):
        p = core.generate_problem(17, 2)
        state = core.initial_state(p)
        first = core.frontier_step(p['stages'][0], state['frontier'])
        state, receipt = core.apply_patch(p, state, {'base_version': 0, 'stage': 0, 'frontier': first})
        self.assertTrue(receipt['accepted'])
        forged = copy.deepcopy(state)
        for row in forged['frontier']:
            row['cost'] += 17
        forged['history'][0]['frontier'] = copy.deepcopy(forged['frontier'])
        proposed = core.frontier_step(p['stages'][1], forged['frontier'])
        result, receipt = core.apply_patch(p, forged, {'base_version': forged['version'], 'stage': 1, 'frontier': proposed}, verify=True)
        self.assertFalse(receipt['accepted'])
        self.assertIn('history', receipt['issues'][0].lower())
        self.assertEqual(result, forged)

    def test_replacement_rejects_forged_prefix_that_would_be_reused(self):
        p = core.generate_problem(19, 2)
        state = core.initial_state(p)
        first = core.frontier_step(p['stages'][0], state['frontier'])
        state, receipt = core.apply_patch(p, state, {'base_version': 0, 'stage': 0, 'frontier': first})
        self.assertTrue(receipt['accepted'])
        forged = copy.deepcopy(state)
        for row in forged['frontier']:
            row['cost'] += 2
        forged['history'][0]['frontier'] = copy.deepcopy(forged['frontier'])
        updated = copy.deepcopy(p)
        updated['stages'][1]['wx'] += 1
        with self.assertRaisesRegex(ValueError, 'history transition mismatch'):
            core.replace_problem(p, forged, updated, 1)

    def test_unchecked_patch_accepts_shape_without_inferencing_frontier(self):
        p = core.generate_problem(8, 1)
        s = core.initial_state(p)
        bogus = [{'boundary': 0, 'cost': 999, 'bits': '00'}]
        s2, receipt = core.apply_patch(p, s, {'base_version': 0, 'stage': 0, 'frontier': bogus}, verify=False)
        self.assertTrue(receipt['accepted'])
        self.assertEqual(s2['frontier'], bogus)
        self.assertNotEqual(s2['frontier'], core.frontier_step(p['stages'][0], s['frontier']))

    def test_arbitrary_precision_costs(self):
        p = {'schema_version': 1, 'seed': 1,
             'stages': [{'index': 0, 'parity': 1, 'wx': 10**100, 'wy': 10**120}],
             'final_boundary': 0}
        self.assertEqual(core.oracle(p), {'cost': 10**100, 'bits': '10'})

    def test_replacement_preserves_prefix_and_invalidates_suffix(self):
        p = core.generate_problem(91, 4)
        s = core.initial_state(p)
        for i, stage in enumerate(p['stages']):
            s, _ = core.apply_patch(p, s, {'base_version': s['version'], 'stage': i,
                                            'frontier': core.frontier_step(stage, s['frontier'])})
        updated = copy.deepcopy(p)
        updated['stages'][1]['wx'] += 3
        s2 = core.replace_problem(p, s, updated, 1)
        self.assertEqual(s2['next_stage'], 1)
        self.assertEqual(s2['frontier'], s['history'][0]['frontier'])
        self.assertEqual(len(s2['history']), 1)
        self.assertEqual(s2['version'], s['version'] + 1)
        for i in range(1, len(updated['stages'])):
            s2, _ = core.apply_patch(updated, s2, {'base_version': s2['version'], 'stage': i,
                                                    'frontier': core.frontier_step(updated['stages'][i], s2['frontier'])})
        self.assertEqual(core.oracle(updated), brute(updated))
        self.assertEqual(s2['frontier'], self._frontier(updated))

    @staticmethod
    def _frontier(p):
        f = core.initial_frontier()
        for stage in p['stages']:
            f = core.frontier_step(stage, f)
        return f

    def test_json_and_packed_roundtrip_and_corruption(self):
        p = core.generate_problem(101, 3)
        s = core.initial_state(p)
        for codec in ('json', 'packed'):
            payload = core.encode_state(s, codec)
            self.assertIsInstance(payload, bytes)
            self.assertEqual(core.decode_state(payload), s)
            corrupted = payload[:-1] + bytes([payload[-1] ^ 1])
            with self.assertRaises((ValueError, TypeError)):
                core.decode_state(corrupted)
        with self.assertRaises((ValueError, TypeError)):
            core.decode_state(b'not a valid state')

    def test_hash_stable_and_problem_validation(self):
        p = core.generate_problem(5, 3)
        self.assertEqual(core.problem_hash(p), core.problem_hash(copy.deepcopy(p)))
        p['final_boundary'] = 2
        with self.assertRaises((ValueError, TypeError)):
            core.oracle(p)


if __name__ == '__main__':
    unittest.main()





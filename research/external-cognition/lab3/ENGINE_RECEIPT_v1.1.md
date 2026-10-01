# Engine receipt v1.1 — post-campaign evaluator correction

This update changes only the working evaluator and its tests. It does not alter frozen source, raw responses, campaign records, or evaluation hashes.

The legacy `consumer_true_world_correct` remains and compares with the original world. The new `consumer_intended_revised_world_correct` compares a submitted revised-consumer coordinate pair against the solution set for the intended revised relation (original relation with u intercept +2 mod 11, original v) and the same original target `(u,v)`. This distinguishes following a structurally accepted but incorrect revision from solving the intended revised world.

Regression coverage includes seed 3103's intended revised result `(4,10)` (intended revised true, original-world false) and a wrong accepted seed 3101 revision whose follower returns `(6,2)` (agreement with submitted revision true, intended revised-world false). The tests were first run red against the existing evaluator, then passed after the field was implemented.

Verification: `python -m unittest discover -s research/external-cognition/lab3/tests -v` — 11 tests passed. `python -m py_compile research/external-cognition/lab3/experiment.py` — passed.

# Lab 3 engine receipt

Implemented the engine-owned scope in `experiment.py`, `tests/`, `README.md`, and this receipt. No lab2 files were changed.

The initial test run was red because the APIs did not exist. Five focused tests now pass: deterministic mod-11 worlds, noncollinear observations, independent brute-force enumeration of all 121 coordinate pairs, false-but-well-formed state acceptance, atomic malformed/stale rejection, revision cache invalidation, strict consumer shape, omission without fabricated relation, and dependency-valid schedule.

The store checks schema, integer residues, versions, known cases/arms, and explicit invalidation reference only. It does not check determinant, inferred truth, preservation of v, target correctness, or answer correctness. The schedule uses deterministic shuffling of case blocks and consumer arms while preserving within-case dependencies. Prompt and raw-response bytes are immutable and SHA-256 recorded in `hashes.json`. CLI response bytes are saved before parsing, including malformed outputs.

Core commands (run from this directory):

```powershell
python experiment.py prepare --out-dir DIR
python experiment.py producer-prompt --campaign DIR\campaign.json --case 3101
python experiment.py submit-producer --campaign DIR\campaign.json --case 3101 --response PATH_OR_JSON
python experiment.py consumer-prompts --campaign DIR\campaign.json --case 3101
python experiment.py submit-consumer --campaign DIR\campaign.json --case 3101 --arm intact --response PATH_OR_JSON
python experiment.py submit-consumer --campaign DIR\campaign.json --case 3101 --arm omitted --response PATH_OR_JSON
python experiment.py submit-consumer --campaign DIR\campaign.json --case 3101 --arm altered --response PATH_OR_JSON
python experiment.py submit-consumer --campaign DIR\campaign.json --case 3101 --arm raw --response PATH_OR_JSON
python experiment.py revision-prompt --campaign DIR\campaign.json --case 3101
python experiment.py submit-revision --campaign DIR\campaign.json --case 3101 --response PATH_OR_JSON
python experiment.py consumer-prompts --campaign DIR\campaign.json --case 3101
python experiment.py submit-consumer --campaign DIR\campaign.json --case 3101 --arm revised --response PATH_OR_JSON
python experiment.py summary --campaign DIR\campaign.json
python experiment.py evaluate --campaign DIR\campaign.json
```

Offline evaluator enumerates the full mod-11 domain and scores submitted producer relation against the generated relation, answers against true-world coordinates, altered answers conditionally under altered relation, omission classification, revision coefficient/preservation/invalidation, and revised-consumer true-world result. It is separate from every submit function and prompt builder. No subject calls were made.

Conditional scoring enumerates the solution set implied by the exact presented relation and target, then reports response agreement separately from true-world correctness. Revised consumers retain the original target `(u,v)`; the updated relation therefore implies changed coordinates. Regression tests cover altered and intentionally wrong accepted revision maps where a response agrees conditionally but is wrong in the true world.

Verification: `python -m unittest discover -s research/external-cognition/lab3/tests -v` — 8 passed. `python -m py_compile research/external-cognition/lab3/experiment.py` — passed. An end-to-end temporary-directory CLI smoke was attempted but the shell execution layer rejected the multi-command invocation; API tests cover submission, prompt emission, and evaluation paths.

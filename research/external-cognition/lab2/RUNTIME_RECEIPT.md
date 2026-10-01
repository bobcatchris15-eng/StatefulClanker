# Runtime implementation receipt

Scope completed: `lab.py`, `tests/test_lab.py`, and `README.md`, using the fixed
API in `core.py`. No provider/model calls were made.

## Runtime behavior

- Added calibration generation for blocks 2, 4, and 8 with seeds 1101 and
  1102; subject prompts are separated from private evaluator keys. Full-answer
  scoring compares exact cost and bits and retains the source response file
  unchanged.
- Added checked/unchecked per-run chains with packed or JSON state encoding and
  vector or records subject presentations. The prompt provides the next local
  stage, frontier, version, transition rule, and exact output schema without
  an oracle answer. It distinguishes the parity legality test from the
  outgoing boundary, which is the current stage's `y` bit.
- `submit` installs exact response bytes before parsing, uses exclusive IDs,
  records hash/byte/character lengths and diagnostics, and commits accepted
  state atomically. Rejection leaves `state.bin` unchanged. Commit journals
  recover interrupted commits, and orphan raw responses receive an explicit
  not-evaluated receipt on the next runtime read.
- Checked prompts fail closed if the checksummed store contains a semantically
  invalid history. Unchecked runs still enforce schema, stage, and version
  rules without inferring frontier correctness.
- `change-cost` records the exact input delta and atomically versions the
  problem/state pair while preserving the verified prefix. `summary` reports
  outcome, transitions, malformed/rejected/repair counts, hashes and lengths,
  store bytes, and unavailable token/sampling values as `null`.

## CLI

```text
python lab.py prepare-calibration --out-dir PATH
python lab.py submit-full --calibration-dir PATH --case-id ID --response-file PATH
python lab.py init-chain --run-dir PATH --seed INT --blocks INT --codec packed|json --representation vector|records --arm checked|unchecked
python lab.py prompt --run-dir PATH
python lab.py submit --run-dir PATH --response-id ID --response-file PATH
python lab.py change-cost --run-dir PATH --stage INT --field wx|wy --delta INT
python lab.py summary --run-dir PATH
```

## Validation

The integration tests were first written before `lab.py` existed. The initial
red run could not import `core.py` because the engine implementation was still
in progress. After the core API landed, integration runs exposed and fixed
init-lock directory handling, pretty-printed prompt assertions, receipt
failure handling, Windows nested locking, and interrupted-commit recovery.

Final command, run from `lab2`:

```powershell
python -m unittest discover -s tests -v
```

Result: **27 passed, 1 skipped (28 tests run)**. The symlink-path test skipped
because this Windows environment did not permit symlink creation. The other
path/ID checks ran. A pre-subject audit caught and corrected the prompt's
outgoing-boundary label; the regression uses a case where parity is 1 while
the outgoing `y` boundary is 0, and this full suite was rerun after the fix.
Coverage includes actual temporary-run CLI flow, malformed and stale output,
byte preservation, rejected-store invariance, duplicate IDs, response-before-
validation ordering, commit-journal recovery, orphan-response recovery,
checked-history prompt integrity, unchecked structural acceptance, input
invalidation, calibration scoring, and summary counters.

Calibration fixtures already exist at the coordinator's `runs/campaign1/calibration`.
No subjects have been dispatched by this runtime worker.

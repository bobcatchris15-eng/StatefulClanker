# Post-campaign runtime v1.1 receipt

This is a separate, post-campaign maintenance receipt. The campaign 1 frozen
source copies and original runtime receipt remain unchanged; this version was
not used to create or score campaign 1 subject outputs. No subjects were
launched for this maintenance update.

## Changes

- New submission receipts carry a monotonically increasing `submission_order`,
  allocated while holding the run writer lock. Summary counts a repair only
  when an attempt follows a rejection for the same `(stage, base_version)`.
  Later recomputation after a changed input has a different base version and
  is a new transition, not a repair.
- Older receipts are read in filesystem modification-time order, with filename
  as a deterministic tie-break. Summary reports `repair_order_basis` and the
  number of legacy receipts. The runtime does not edit historical receipt
  files. The legacy order is a best-effort fallback, not reconstructed proof
  of event sequence.
- `prepare-calibration` accepts `--sizes` and `--seeds`. Sizes must be positive
  unique integers; seeds must be unique integers. Defaults remain sizes
  `2 4 8` and seeds `1101 1102`, preserving the original campaign inputs.

## Validation

Added a timeline regression with filenames whose lexical order reverses their
submission order, followed by an input change and a same-stage proposal at a
new base version. Added a legacy receipt test that verifies timestamp fallback
and byte-for-byte preservation. Custom calibration tests verify generation
against `core.generate_problem`, exact prompt schemas and answers against
`core.oracle`, axis validation, and CLI parsing.

Command:

```powershell
python -m unittest discover -s tests -v
```

Result: **31 tests run; 30 passed and 1 symlink test skipped** because this
Windows environment did not allow symlink creation. No other test was skipped.

Documented scaling example:

```powershell
python lab.py prepare-calibration --out-dir runs/campaign2/calibration --sizes 16 32 --seeds 1101 1102
```

Coordinator CLI smoke: custom sizes 1, 16, 32 with seeds 7, 8 generated six calibration fixtures successfully in a temporary directory. These were fixtures only; no subjects were dispatched.

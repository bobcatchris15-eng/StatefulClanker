# Cycle2 implementation plan
Goal: executable external reasoning laboratory with machine state and independent checks.
Architecture: core.py owns task semantics and reversible store encodings; lab.py owns prompts, durable commit/rejection, observations and receipts; native agents remain subjects. Spec: DESIGN.md. Tech: Python stdlib; Windows paths supported.
- [x] Core worker writes independent exhaustive/transition/codec tests, records failing run, implements core.py, proves tests pass.
- [x] Runtime worker reads fixed core API contract; writes integration tests with temporary run dirs, records initial missing runtime failure, implements lab.py and README.md. Doesn't change core APIs.
- [x] Methods worker preregisters arms/interpretations and challenges opaque representation and compute confounds before live outputs.
- [x] Coordinator verifies tests and CLI, independent reviewer inspects implementation with original human hypothesis, correct defects then freeze inputs.
- [x] Dispatch six fresh calibration subjects, then compact-state chain and matched records chain with preserved exact inputs/outputs. Record deviations and unavailable statistics.
- [x] Run suffix invalidation/recomputation if chain completes; score actual results and independently review before synthesis/checkpoint.

Completed first campaign: 22 fresh subjects; frozen evidence and independent result audit preserved. Native capacity calibration remains exploratory.

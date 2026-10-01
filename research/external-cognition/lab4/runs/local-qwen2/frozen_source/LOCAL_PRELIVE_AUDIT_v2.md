# Local runner v2 pre-live delta audit

Date: 2026-10-01. This is a bounded review of the configurable output budget and alternate preregistration snapshot in `local_runner.py`, against `LOCAL_PREREGISTRATION_v2.md`. No model or endpoint requests were made by this review, and the interrupted `runs/local-qwen1` run was not modified.

The v2 plan is selected by the `preregistration` argument/CLI option, copied into the new run's `frozen_inputs` under its original filename, and included in `input_hashes`. The manifest records `preregistration_file`; `_check_frozen` validates the safe basename and verifies that snapshot's hash. The original `LOCAL_PREREGISTRATION.md` remains the default when no alternate plan is supplied.

`prepare` accepts only a built-in integer budget from 1 through 4096 (`bool` is rejected by the exact type check). The chosen budget is included in the hashed manifest, validated again before a run, and used verbatim in each outgoing request, request metadata, and successful call metadata. Failure call metadata is also assigned the frozen budget before dispatch. The v2 test exercises 512 through all twelve fake requests and checks every request and successful call record; another regression rejects out-of-range and tampered caps before HTTP. The suite passed: `python -m unittest discover -s tests -q` (33 tests).

Clear for the planned v2 run when prepared with both the selected v2 preregistration and explicit `max_tokens=512` (CLI: `prepare --preregistration LOCAL_PREREGISTRATION_v2.md --max-tokens 512`). The generic API intentionally retains its default of 4096, so the caller must pass 512 for this preregistration. This review does not score the interrupted run or imply model correctness or general reasoning capacity.

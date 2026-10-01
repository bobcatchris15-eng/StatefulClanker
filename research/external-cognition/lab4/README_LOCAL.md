# Running the local Lab 4 replication

This uses the frozen `pilot.py`/`protocol.py` workflow with the local Lemonade service and makes no inference call until the explicit `run` command. Do not run against a directory containing an earlier attempt.

From `research/external-cognition/lab4`, first prepare a new run directory:

```powershell
python local_runner.py prepare --out-dir runs/local-qwen-2026-10-01
```

Preparation is network-free. The default completion cap is 4096 tokens; for a separately frozen bounded run, pass an explicit cap such as `--max-tokens 512`. The cap must be an integer from 1 through 4096 and is stored in the manifest; every outgoing request and call record uses that exact frozen value. To snapshot a distinct preregistration without replacing the default source, pass its path with `--preregistration path\to\LOCAL_PREREGISTRATION_v2.md`; the selected file is retained by its filename in `frozen_inputs/`. Each attempt must use a new output directory. Preparation writes `local-run.json` and a `frozen_inputs/` snapshot, initializes the two pilot cases and proposer prompts under `pilot/`, and records hashes for the source, selected preregistration, runtime discovery, and prompts. Review those frozen artifacts before inference. The runtime discovery must describe the already-loaded exact model and context; preparation does not change it.

Only when the local runtime is ready and the run freeze is accepted, explicitly start inference:

```powershell
python local_runner.py run --run-dir runs/local-qwen-2026-10-01
```

Example for the separate lower-cap experiment (choose a new run directory and its own preregistration first):

```powershell
python local_runner.py prepare --out-dir runs/local-qwen-512 --max-tokens 512 --preregistration LOCAL_PREREGISTRATION_v2.md
```

The runner verifies the frozen manifest/source/input hashes and performs read-only `GET /health` and `GET /models` checks. It stops with a receipt recording zero consumed slots if readiness differs. If that happens, fix readiness and invoke `run` again explicitly; no completion request has been sent. Once dispatch starts, any partial run is intentionally non-resumable to prevent duplicate calls.

Each case executes proposer, reviewer, and integrator pairs with two workers. Requests go only to `http://127.0.0.1:13305/api/v1/chat/completions`, each with one user message, the manifest-frozen `max_tokens` value (default 4096), `temperature=0`, and `stream=false`. The request policy has a 300-second timeout and no retries. A transport/HTTP/model/content failure still consumes that role's slot. A truncated response is retained as received and marked with its finish reason; it is never repaired. Provider reasoning is archived separately, never given to other roles.

The run directory records:

- `requests/<seed>/<role>.request.json` and `request-meta.json`: exact outgoing body and its prompt/request hashes.
- `transport/<seed>/<role>.response.raw`, `.http.json`, `.content.raw`, optional `.reasoning.raw`/`.reasoning.json`, and `.call.json` or `.failure.json`: transport evidence and extraction/receipt metadata. HTTP errors and incomplete response bodies are retained where available.
- `backend/preflight/`: raw read-only health/model responses and per-attempt readiness receipts; `backend/readiness.json` records successful preflight.
- `pilot/`: protocol event store, exact submitted content, and receipts.
- `evaluation.json` and `run_complete.json`: produced only after all twelve slots have outcomes; the evaluator runs offline.

The offline evaluator separates raw-answer accuracy from protocol-valid success and also reports proposal, review, candidate, and receipt evidence. Missing usage is left missing rather than treated as zero. The model returned by the server may be either the frozen Lemonade model ID or its exact frozen checkpoint name; the actual returned string is recorded. Other names fail that scheduled slot.

Unit tests use only a fake in-process transport. To run them without contacting Lemonade:

```powershell
python -m unittest discover -s tests -p 'test_local_runner.py'
```

See `LOCAL_PLAN.md` and `LOCAL_PREREGISTRATION.md` for the fixed policy and interpretation limits.

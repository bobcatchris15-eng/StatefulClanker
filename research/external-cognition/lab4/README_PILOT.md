# Lab 4 affine pilot adapter

The pilot adapter is a standard-library Python CLI around `protocol.py`. It imports `make_case(seed)` from Lab 3 by file path and builds the Lab 4 public packet without modifying Lab 3. Every participant sees modulus 11, all three labeled observations, the declared affine family, the target image, and the answer schema. Only the generated coefficient triples and target `(x,y)` are used offline by `evaluate`.

The adapter does not invoke a model. It prepares frozen prompts, stores exact response bytes, submits those bytes to the structural protocol, and evaluates only after every scheduled call has either a saved response or a recorded failure. It makes no retries and gives no evaluator feedback to participants.

Before forwarding a parseable envelope, the adapter checks the scheduled role sender, fixed message ID, problem ID, intent, recipient route, and allowed read-resource scope. A mismatch receives a stable `ROLE_MISMATCH` receipt and is retained as a rejected submission without appending an event.

## Prepare and run

From this directory, create a new output directory:

```powershell
python pilot.py prepare --out-dir runs/lab4-pilot
```

The call schedule has six fresh participants per seed and twelve calls overall:

| Phase | Roles | Access |
|---|---|---|
| Propose, parallel | `u-proposer`, `v-proposer` | Complete public problem; separate claim IDs and the same problem snapshot |
| Review, parallel | `u-reviewer`, `v-reviewer` | Complete public problem and the cross-assigned proposal (`u-reviewer` sees `v-relation`) |
| Integrate, parallel | `shared-integrator`, `raw-integrator` | Same complete public problem and final answer instructions; only the shared integrator receives the current claim/review/candidate projection |

Get proposer prompts with `python pilot.py prompt --run-dir runs/lab4-pilot --seed 4201 --role u-proposer` and the corresponding `v-proposer` command. Dispatch those two calls in parallel, save each exact response as a file, and submit once:

```powershell
python pilot.py submit --run-dir runs/lab4-pilot --seed 4201 --role u-proposer --raw path/to/u-proposer.raw --provider native --model Luna --effort low --started-at 2026-10-01T10:00:00Z --finished-at 2026-10-01T10:00:05Z
```

Submit each proposer response before requesting the reviewer prompts. Request both reviewer prompts before dispatching the two review calls; they are cross-assigned and run in parallel. A reviewer may return one `CHALLENGE` or `REPORT_EVIDENCE` envelope and may include a corrected candidate. The candidate remains uncommitted. Once both review outputs are saved, freeze both final prompts with:

```powershell
python pilot.py final-prompts --run-dir runs/lab4-pilot --seed 4201
```

Dispatch the shared and raw integrators in parallel, submit both outputs, and repeat all stages for seed 4202. If a scheduled model call fails, record the failure as its one call slot rather than retrying:

```powershell
python pilot.py failure --run-dir runs/lab4-pilot --seed 4201 --role u-proposer --reason "provider timeout"
```

The final envelope template shows a solved answer. An integrator may replace the entire conclusion with exactly `{"status":"underdetermined"}` and omit `x` and `y` when appropriate; all other envelope fields stay fixed. Both final conditions receive the same answer instructions.

When all twelve slots have been recorded, score them offline:

```powershell
python pilot.py evaluate --run-dir runs/lab4-pilot
```

`evaluate` rejects incomplete runs. It checks coefficient claims against the public observations, compares claims with generated ground truth, and enumerates all 121 possible target coordinates. `raw_answer_matches_true_target` records semantic accuracy for a parseable raw conclusion; `protocol_valid` requires a valid final schema, an accepted store receipt, and matching scheduled sender, message ID, problem ID, and intent. `true_world_correct` additionally requires the raw answer to match the hidden target. It writes `evaluation.json`; that file and its target answers must stay outside participant access.

## Python API

`public_problem(seed)` returns only the participant-visible packet. `prepare(out_dir)` initializes the two immutable problem resources and stores proposer prompts. `role_prompt(run_dir, seed, role)` returns the saved prompt path for a proposer or reviewer; reviewers are materialized after both proposer call slots are recorded. `final_prompts(run_dir, seed)` returns paths for both final prompts after both reviewer slots are recorded. `submit_response(run_dir, seed, role, raw_bytes, metadata=None)` stores the byte sequence before calling `protocol.submit`. `record_failure(...)` records a failed call without fabricating a message. `evaluate(run_dir)` is an offline-only API with the same twelve-slot gate as the CLI.

Every prompt is write-once and SHA-256 indexed in `prompt_hashes.json`; `run.json` records source and packet hashes, call schedule, role access rules, and read-reference policy before participant calls. Each response is also write-once. The `submit` command accepts a path to raw response bytes; it does not reconstruct a JSON response from decoded text. Receipts report structural acceptance, role mismatch, or a stable structural rejection code.

## Output layout

```text
runs/lab4-pilot/
  run.json
  prompt_hashes.json
  cases/4201/problem.json
  cases/4201/store.sqlite
  cases/4202/problem.json
  cases/4202/store.sqlite
  prompts/<seed>/<role>.txt
  responses/<seed>/<role>.raw
  responses/<seed>/<role>.failure.json
  receipts/<seed>/<role>.json
  call_metadata/<seed>/<role>.json
  evaluation.json
```

For returned bytes, the adapter saves `responses/<seed>/<role>.raw` before parsing; the protocol independently retains the original bytes in its submission audit table, including role-mismatch rejections. `receipts` stores the structural or role-bound receipt and `call_metadata` stores route, timing when supplied, and prompt/raw hashes. A failed call uses a failure record and has no protocol message. The two files named `.raw` and `.failure.json` are mutually exclusive per scheduled slot.

To inspect the reconstructed state for one seed, use `python pilot.py replay --run-dir runs/lab4-pilot --seed 4201`.

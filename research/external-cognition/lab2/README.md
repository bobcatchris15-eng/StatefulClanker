# Cycle 2 runtime

`lab.py` coordinates local experiment files and never contacts a model service.
The coordinator dispatches each emitted subject prompt to a fresh subject and
hands the exact returned bytes back to `submit`. The runtime does not generate
or repair subject answers. `core.py` owns the task transition rules and state
codec; see [DESIGN.md](DESIGN.md) for the fixed contract.

Run commands from this directory. Use Python 3.10+; no packages beyond the
standard library are required.

## Calibration

By default the runtime generates the six full-task cases (2, 4, and 8 blocks,
each with seeds 1101 and 1102):

```powershell
python lab.py prepare-calibration --out-dir runs/calibration
```

To scale a later capacity campaign, pass positive unique block counts and
unique integer seeds. For example, this command generates cases at 16 and 32
blocks for two seeds:

```powershell
python lab.py prepare-calibration --out-dir runs/campaign2/calibration --sizes 16 32 --seeds 1101 1102
```

The generated calibration manifest records the ordered Cartesian product.
Invalid sizes (nonpositive or duplicated) and noninteger or duplicated seeds
are rejected. The defaults preserve the original campaign fixture.

Dispatch each file under `runs/calibration/prompts/` as a complete task. A
subject must return exactly one JSON object with `cost` (integer) and `bits`
(string), with no prose. Save its unmodified response to a response file, then
score it without rewriting that file:

```powershell
python lab.py submit-full --calibration-dir runs/calibration --case-id n2_seed1101 --response-file runs/inbox/n2_seed1101.raw
```

Private evaluator keys are in `keys.json`; never include this file or its
contents in subject context. The score command returns exact expected and
actual cost/bits, exact response byte/character counts, and SHA-256.

## Incremental chain

Initialize a four-stage checked chain with packed opaque backing state and
vector observations:

```powershell
python lab.py init-chain --run-dir runs/chain-vector --seed 1101 --blocks 4 --codec packed --representation vector --arm checked
```

For the records presentation control, choose `--representation records` with
the same task inputs. To compare the storage codec, change only `--codec` to
`json`; codec and presentation are separate factors. Select `--arm unchecked`
to accept shape-valid frontier proposals without checking their mathematical
correctness. Both arms enforce exact patch keys, row shape, witness length,
problem binding, stage, and base version.

At each call, copy the output of this command verbatim to the assigned subject:

```powershell
python lab.py prompt --run-dir runs/chain-vector
```

The prompt contains only the current stage, current frontier, version, task
transition rule, and exact output schema. The parity equation is the legality
test; the outgoing boundary after each stage is exactly `y`. For `vector`, frontier rows are
`[boundary:int,cost:int,bits:string]`. For `records`, each row is an object
with exactly `boundary` (integer), `cost` (integer), and `bits` (string).
Responses are one JSON object with exactly `base_version` (integer), `stage`
(integer), and `frontier` (array in ascending boundary order); its row encoding
must match the requested representation. There is no markdown wrapper.
Submit the exact response-file bytes with a new ID for each attempt:

```powershell
python lab.py submit --run-dir runs/chain-vector --response-id stage0-attempt1 --response-file runs/inbox/stage0.raw
```

Each raw response is atomically retained at `responses/<id>.raw` before the
runtime parses or validates it. IDs are unique per run; a reused ID is refused.
Every attempt receives an evaluator receipt in `receipts/<id>.json`, including
the response hash and lengths. A rejected proposal leaves `state.bin` byte for
byte unchanged. Checked-arm diagnostics name the failed rule but never expose
the expected frontier or a correct answer. No answer is silently normalized:
the vector-to-record conversion is a lossless mapping defined by the selected
representation.

After a rejection, dispatch at most one repair prompt to a fresh subject. The
next prompt shows the same version/frontier after rejection. Keep each returned
raw response under its own new response ID. Receipts include a monotonically
increasing submission order; the run summary counts later attempts for the
same stage and base version as repairs. For pre-v1.1 receipts without order
metadata, summary uses filesystem modification time and then filename as a
best-effort fallback, labels that basis, and leaves those historical receipts
unchanged. A retry after an input update uses a new base version and does not
count as a repair of an earlier rejected transition.

When changing a stage weight after computing its prefix, update the declared
input and discard that stage's suffix:

```powershell
python lab.py change-cost --run-dir runs/chain-vector --stage 1 --field wx --delta -2
```

`--field` is `wx` or `wy`, and `--delta` must be nonzero while the resulting
weight stays positive. The change increments the state version, preserves the
unaffected prefix, and returns the next prompt stage. An interrupted two-file
input/state update is completed from its journal before the next run read.
The preregistered follow-up uses this exact stage/field/delta when the four-stage
vector chain completes.

Inspect progress and resource counters at any point:

```powershell
python lab.py summary --run-dir runs/chain-vector
```

The summary reports outcome, accepted transitions, rejected/malformed
responses, repair attempts, response characters/bytes, stored state bytes, and
token/sampling fields as `null` where unavailable. On completion the evaluator
checks the final score against the independent oracle. The packed store is an
opaque checksummed compressed encoding, not a learned latent representation;
vector-versus-records changes only the local observation encoding.

## Local validation

Run the core and runtime suites from `lab2`:

```powershell
python -m unittest discover -s tests -v
```

Integration tests use temporary directories and make no provider calls.

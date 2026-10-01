# External cognition lab — built and first campaign executed
2026-10-01. Native route gpt-6-luna, low reasoning effort.

The laboratory now supports reasoning state without requiring human-readable explanations. It stores a versioned binary state and exposes only a task-local record or compact tuple view to each fresh worker. Model proposals become state patches; the checked arm validates prior semantics and the new transition before committing. Rejections preserve the accepted store, and changed inputs invalidate dependent suffixes. The packed codec is a machine encoding, not a learned neural representation.

## What was built
- core.py: reproducible binary-chain generator, local frontier semantics, exact oracle, strict versioned patches, dependency invalidation, safe checksummed JSON/packed codecs.
- lab.py: calibration prompt generation/scoring; records/vector presentations; checked/unchecked arms; opaque persistent state; atomic commits and interrupted-write recovery; immutable raw responses, hashes and receipts; changed-input updates and resource summaries.
- tests/: independent exhaustive comparisons and transactional/corruption/stale-state regression tests.
- PREREGISTRATION.md: fixed campaign and pre-subject amendment replacing an ineffective cost change.
- runs/campaign1/: exact inputs,22 fresh subject outputs, acceptance/rejection receipts, original frozen sources and hashes, storage/unchecked replays.

## First live campaign
| Test | Observed result |
|---|---|
| Complete tasks,2 stages |2/2 exact|
| Complete tasks,4 stages |2/2 exact|
| Complete tasks,8 stages |1/2 exact|
| Repeated complete task,4 stages seed1101 |3/5 exact, including the original calibration call|
| Compact tuple chain,4 stages |4/5 exact proposed transitions; one parity rejection, successful repair, exact final solution|
| Record-form chain,4 stages |2/4 exact proposals; wrong-cost rejection and failed repair; stopped at unchanged stage2|
| Changed-input compact chain |3/3 suffix proposals exact; prefix reused; revised final witness correct|

Initial optimum cost11,bits10000001. A material change at zero-based stage1,wx3->1, changes the optimal witness to01100001 at cost11. The update preserves stage0; fresh subjects recompute stages1–3. No oracle state was inserted or incorrect state silently repaired.

Specific parity feedback enabled one repair; specific cost feedback failed on the other arm. This is an observation on these proposals, not evidence of a reliable repair method. The records/vector arms jointly vary presentation and backing codec; do not attribute their difference to either factor. Native full-task repeats show variation even at4stages.

## Machine state and external checks
A separate frozen-runtime replay holds the state and observation representation fixed while changing storage codec. The exact same accepted state is691bytes as JSON and266bytes packed; decoding yields identical values. This is a persistence/size result, not a cognitive advantage. Another deterministic replay, with checking disabled, commits the original illegal parity proposal. It has no new subjects and does not estimate live unchecked performance. See REPLAY_REPORT.md for the omitted repair-feedback context in the JSON replay.

## Limits and evidence status
This campaign is exploratory, not a calibrated native capacity curve. Six complete-task cases cannot establish that a model cannot internally hold the representation. Stored frontiers encode useful prior computation; the checker itself performs task-specific computation, including replay of prior history. The coupled system, not the model alone, is responsible for the checked result. Repeated full-task controls match some call counts but not measured token/compute budgets; no changed-input full-task controls were run. Byte sizes and character counts are not token counts. Exact sampler/token statistics unavailable. Subject file isolation is procedural, not an enforced sandbox.

Literal repair feedback wrappers were composed after rejection from predeclared issue classes, rather than frozen as exact strings. Preflight and unused generated prompts were not subject calls. Original historical repair-counter summaries contain a reporting bug: alphabetical receipt order missed the successful repair, and a later changed-input stage accidentally counted it. Raw outputs, acceptance decisions and original summaries are preserved; post-campaign runtime hardening corrects telemetry separately.

Human inspectability is optional. Machine access and measurable transition behavior are necessary for this experiment. Numeric tuples sent as text are not direct latent tensors. See REPRESENTATION_NOTES.md for primary literature and the backend boundary.

## Use and continuation
Start with README.md for commands. Default calibration recreates the registered small campaign; the revised runtime also accepts configured sizes/seeds for larger repeated held-out runs. Each stage prompt is dispatched to a fresh native subject; submit its exact output using a unique ID. Keep the model route and available budgets recorded. Larger experiments should separate presentation from codec, hold checking constant or explicitly ablate it, randomize/repeat enough cases to estimate reliability, and calibrate limits independently before selecting test instances.

Independent implementation and result review: AUDIT.md and RESULTS_AUDIT.md. Frozen original source and test hashes verified13/13. Post-campaign runtime v1.1: 31 tests run, 30 passed, one skipped because Windows symlink permission was unavailable. Corrected summaries report one repair in each chain; all historical receipts use an explicitly labeled timestamp fallback. New receipts record submission order. See RUNTIME_RECEIPT_v1.1.md; these changes were tested after the campaign and had no new live subjects.

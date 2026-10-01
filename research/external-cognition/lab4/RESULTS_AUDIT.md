# Independent audit of Lab 4 campaign 1

I independently audited the completed twelve-call campaign using only each frozen public problem packet, saved prompts and raw outputs, receipts, dispatch metadata, SQLite event/state records, replay files, and freeze snapshots. I independently enumerated affine coefficient triples that satisfy the three public observations and then enumerated all 121 possible target inputs. I did not use the evaluator's `true_target_xy` or generated hidden coefficients to derive the answers.

## Public-data recomputation and outcomes

| Seed | Unique u relation | Unique v relation | Public target solution | Submitted proposals | Shared final | Raw final |
|---|---|---|---|---|---|---|
| 4201 | (3, 5, 4) | (7, 2, 10) | (2, 10) | u correct; v=(1, 2, 3) does not fit | (2, 10), correct | (2, 10), correct |
| 4202 | (6, 10, 10) | (10, 5, 8) | (8, 4) | u correct; v=(8, 5, 4) does not fit | (8, 4), correct | (8, 4), correct |

Both public relation systems have one coefficient triple per coordinate and a unique target solution. The original submitted relation pairs instead imply (6, 1) for seed 4201 and (1, 6) for seed 4202. Thus the four final outputs match the public-data solutions, not the answer implied by the two original proposal pairs.

Across the two cases, the u proposals were correct 2/2 and the v proposals 0/2, for 2/4 correct initial relations. Both u-reviewers challenged the incorrect v claim; both v-reviewers supported the correct u claim. One reviewer supplied a corrected candidate for seed 4202, (10, 5, 8), which matches all public observations and remained an unpromoted candidate. In both cases, the v claim remained at revision 1 with lifecycle state `challenged`; each u claim remained active. Both final conditions were correct on both cases (2/2 each).

This supports the narrow cooperative-feasibility interpretation: structured claims and reviews carried useful correction context while every participant retained the full public task, and the scheduled workflow produced correct final answers without retries or evaluator feedback. It does not show that shared state caused the final answers or improved accuracy over raw access: both conditions answered both cases correctly, and shared participants could recompute from the same public facts. Comparative superiority is not required for the stated goal; this small native pilot also does not establish useful performance on harder tasks or with local models.

## Protocol and record checks

- All 12 dispatch slots have distinct participant IDs, use gpt-6-luna low, and have saved prompts, raw outputs, receipts, and call metadata. All 12 raw outputs parse as the expected role's message and have accepted receipts. No call failed, retried, or received semantic evaluator feedback.
- I recomputed every prompt and output SHA-256. Prompt hashes match `prompt_hashes.json` and `dispatches.json`; output hashes match both dispatch records and retained inbox bytes; inbox bytes equal the response files; call metadata hashes match the same bytes. All twelve role bindings, recipients, intent types, read references, and reviewer target/reply references match their scheduled scopes.
- Each case has six accepted events in sequence: u proposal, v proposal, u-reviewer message, v-reviewer message, shared conclusion, and raw conclusion. I recomputed each event hash from its canonical envelope and verified each event's raw bytes equal the corresponding retained response. There are no native stale forks.
- Both saved replay files match the independently recorded verification result. The current claim states and candidate projection preserve the challenged v proposals and the one separate candidate without promoting it.
- All 16 entries in `VERIFICATION.json` independently match their recorded source hash and frozen snapshot hash, covering executable sources, docs, tests, public inputs, run manifest, and initial proposer prompts.

## Deviations and limits

The first two dispatch timestamps were scheduled before a context compaction and actual spawning resumed afterward; treat recorded times as coordinator scheduling/receipt observations, not provider inference latency. Dispatch 03's initial empty staging file was overwritten with the final envelope before collection; the final raw output is retained and hashed, and the record indicates one model call with no feedback or semantic retry. Assigned-file-only access was procedural rather than enforced by an OS sandbox. Token and sampler statistics were unavailable.

This was two easy synthetic modulo-11 cases on the native Luna-low route. No native stale-fork behavior was exercised; fork retention and archival were tested mechanically. The pilot provides no evidence about local-model performance, harder tasks, token efficiency, or scaling.

Machine-readable checks and independently derived values are in [RESULTS_AUDIT_DATA.json](RESULTS_AUDIT_DATA.json). The original run artifacts remain in [campaign1](runs/campaign1).

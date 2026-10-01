# Bounded-view CSP pilot run log

Do not fill this before freezing. Save each exact assembled input and raw response under this directory before scoring. Do not store hidden oracle output in subject-visible files.

## Freeze record

- Protocol: `PROTOCOL.md`
- Subject prompt files: `subject_1.txt`, `subject_2.txt`, `subject_3.txt`
- Oracle/scorer: `score.py`
- Freeze hashes (SHA-256, recorded before subject runs):
  - `PROTOCOL.md`: `ad9f8b38d7434a092400ab3f529157f4e61b92535b071010821c9395dc237b6a`
  - `subject_1.txt`: `eb3053c116560b5e75a1b076cb97165b2eb37cce93429bc29f98e1da27efcbef`
  - `subject_2.txt`: `1f41f18935adbc6e53eb5aa988123126c2a3617e20062cdf27199374783b6ad4`
  - `subject_3.txt`: `2973bdda5fb06e02f478d9cdeb6a255d10419c877e249f430685a4465850664c`
  - `score.py`: `9937ed275a2855d0cbe510501cde6b5fbbd50429b92d4adec338d5a5f8b36907`

## Subject records

| Stage | Model/version and settings | Fresh context confirmed? | Exact assembled input saved? | Raw response saved? | Protocol violations | Scorer result |
|---|---|---|---|---|---|---|
| 1 | TBD | TBD | TBD | TBD | TBD | TBD |
| 2 | TBD | TBD | TBD | TBD | TBD | TBD |
| 3 | TBD | TBD | TBD | TBD | TBD | TBD |

## Artifacts / interpretation

- Stage 1 assembled input: pending
- Stage 1 raw response: pending
- Stage 2 assembled input: pending
- Stage 2 raw response: pending
- Stage 3 assembled input: pending
- Stage 3 raw response: pending
- End-to-end success: pending
- This procedural slice restriction does not establish native model capacity limits.

## Executed original chain
All three subjects: gpt-6-luna low; fork_turns none; read only assigned input and write assigned raw response; no tool computation/browse allowed; procedural cap20000 characters. No deviations self-reported.
Exact inputs input_1.txt input_2.txt input_3.txt. Raw responses response_1.json response_2.json response_3.json. Pre-run row-schema clarification v1.1 hashes in freeze_v1_1.txt supersede initial hash list. Initial clarification contains harmless literal `n prefix; no post-response edits to prompts/scorer.
Scoring: stage1 ACCEPT; stage2 REJECT; stage3 REJECT. Scorer output score_1.txt score_2.txt score_3.txt. Stage2 E1 frontier uses C1D0E1 (even, violates odd constraint) and cost1 despite E1 cost3. Stage3 copied incorrect frontier and chose final cost2; exact global optimum cost4. Original frozen run ended after3 subjects with no retries.
Checker reports rejection and policy to preserve prior accepted state; it does not itself implement a durable transactional state store. No invalid frontier promoted to accepted project knowledge. Raw rejected responses remain diagnostic evidence.

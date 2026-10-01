# Lab 4 pilot adapter receipt

## Implemented

`pilot.py` creates immutable public packets for seeds 4201 and 4202 from the existing Lab 3 `make_case` function. It freezes proposer prompts at preparation, materializes reviewer prompts only after both proposer call slots have been recorded, and materializes final prompts only after both reviewer slots have been recorded. The role schedule is six calls per case and twelve total, with each phase marked as a parallel dispatch group.

Every response is stored byte-for-byte before parsing. Envelopes with valid JSON are checked against the scheduled sender, fixed message ID, problem, role intent, recipients, and read-resource scope. A mismatch receives `ROLE_MISMATCH`, is retained in both adapter files and the protocol submission audit, and creates no main event. Other outputs are passed to `protocol.submit`; malformed and rejected outputs remain auditable. The adapter provides a one-slot failure record so provider/runtime failures count without a retry. Prompt files and response files are write-once, and prompt/raw SHA-256 values are recorded with per-call metadata. No mathematical correctness is checked during submission.

The public packet contains three labeled observations, modulus, affine family, target image, and answer requirements. The reviewer map is cross-assigned (`u-reviewer` reads `v-relation`; `v-reviewer` reads `u-relation`); reports and candidate corrections identify the exact claim/problem resources, and candidates depend on the immutable problem resource. Both final conditions use the same public packet and final answer instructions; only the shared prompt includes the projected workspace. The solved template explicitly allows the underdetermined conclusion shape with `x` and `y` omitted. Offline evaluation waits for all twelve raw outputs or failure records, checks relation claims against public observations, and enumerates all 121 target pairs. It reports raw semantic answer match separately; primary correctness also requires an accepted receipt and the scheduled sender/problem identity.

## Verification

Ran from `research/external-cognition/lab4`:

```text
python -m unittest tests.test_pilot
Ran 6 tests ... OK

python -m unittest tests.test_protocol
Ran 17 tests ... OK
```

The pilot test suite includes a temporary-directory CLI round trip with fixture envelopes for both seeds, verifies the raw-only and shared integrators against the generated target, checks the saved raw bytes and hashes, confirms malformed raw JSON is retained with an `INVALID_JSON` receipt, and verifies registered-but-wrong sender and recipient headers are rejected without a main event. A correct answer behind a role-mismatch receipt remains a raw semantic match but is not counted as an accepted correct outcome. It also checks that evaluation refuses an incomplete call schedule. These are implementation fixtures, not subject outputs.

## Limits

No model calls were made. The native Luna-low route is recorded as the planned route but was not invoked or independently verified by this adapter. The parallel groups are schedule metadata; this CLI does not launch concurrent provider calls. This pilot adapter does not conduct stale-proposal fork trials. No empirical claim can be drawn from its fixture tests.

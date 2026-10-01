# Bounded-view recovery follow-up — preregistration

Status: frozen before recovery subject 2 is launched. This is a separate adaptive follow-up to the original pilot, conducted because original Stage 2 was rejected. It must not be pooled with the original pilot as a confirmatory run.

## Objective and scope

Test whether one fresh Stage 2 agent can repair the rejected Stage 2 transition using the same local prompt, the accepted Stage 1 frontier, and generic exact-oracle-mismatch feedback. It receives the original rejected Stage 2 response as a draft. No oracle-correct state, field-level diagnosis, or final answer is supplied. A second fresh agent then solves original Stage 3 from the repaired raw Stage 2 response. This is a two-subject recovery chain, not a retry by either original subject.

This follow-up adapts after observing failure. It is diagnostic, task-specific, and cannot establish natural context-capacity limits. The bounded local slices remain procedural restrictions from the original protocol. Any successful recovery could result from the second attempt, extra reasoning, or feedback-triggered rechecking; the design does not isolate persistence as a cause.

## Frozen inputs and subjects

- Use exactly two new fresh gpt-6-luna low contexts, one for repaired Stage 2 and one for Stage 3. Use the same settings/model route as the original run where available.
- Recovery subject 2 receives only `repair_input2.txt`; it includes the unchanged Stage 2 task prompt and accepted Stage 1 frontier from `response_1.json`, the original rejected `response_2.json`, and generic rejection feedback. It must not receive `score_2.txt`, scorer source, oracle, or any other file.
- After saving the exact raw recovery response, the coordinator creates `repair_input3.txt` by copying `repair_input3.template.txt` and replacing its sole `{{REPAIRED_STAGE2_RESPONSE}}` placeholder with the verbatim contents of `repair_response2.json`. Recovery subject 3 receives only that assembled input.
- Subjects must not browse, execute code, inspect files, or ask outside information. Each gets one response opportunity; no retries or corrections after seeing a score.
- Preserve full prompts and raw outputs. Do not normalize or repair JSON.

## Outputs and exact checker

Save raw outputs at `repair_response2.json` and `repair_response3.json` in this recovery directory. Reuse the original, unchanged checker at `../score.py`:

```text
python ../score.py 2 repair_response2.json ../response_1.json
python ../score.py 3 repair_response3.json repair_response2.json
```

Acceptance is exactly the original checker’s result. Stage 2 must be accepted against the same original Stage 1 frontier; Stage 3 must be accepted with repaired Stage 2 as prior input and produce the exact global optimum. Report the raw checker output, both stage outcomes, model/settings, and any deviation. Do not revise the checker or criteria after seeing recovery responses.

## Interpretation

If Stage 2 is accepted and Stage 3 is accepted, report successful recovery in this one adaptive chain. If either is rejected, report the recovery failure. A successful recovery does not erase the original failure; report the original and recovery chains separately. This follow-up has one instance and no control, so it is not a rate estimate, confirmatory evidence, or evidence that native context was insufficient.

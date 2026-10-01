# Frozen pilot protocol: fresh-agent constraint updates with external state

**Version:** 1.1, frozen 2026-10-01 before subject runs. Version 1.1 corrects a vacuous B delta detected during pre-run validation and tightens exact row scoring. Do not change prompts, fixtures, scoring, or exclusions after inspecting any subject output. If a correction is necessary, version and rerun all conditions.

## Question and scope

Does a typed external task-state artifact help a fresh model instance update a multi-constraint solution after a context reset, compared with giving a fresh instance all the same source facts again? The target is a narrow demonstration of operational utility for this task. It does not test, and cannot establish, that a model is natively unable to hold a representation: no context-window restriction is imposed, and the full-context control is given all facts.

## Design

Run both matched puzzle fixtures (`fixtures/puzzle_a.json`, `fixtures/puzzle_b.json`) in two conditions. Each condition has two sequential fresh agents per fixture, for eight fresh-agent calls total. The first agent in both conditions receives exactly the same Phase 1 prompt and fixture. In the **state condition**, save its JSON answer as the Phase 1 artifact and give that artifact to a new Phase 2 agent. In the **full-context control**, discard the Phase 1 answer for purposes of Phase 2 and give a new Phase 2 agent the full original fixture plus the delta. The Phase 1 calls are retained and costed in both conditions; the Phase 2 control is information-equivalent, but must rederive the solution from the complete facts. No artificial context clipping is allowed.

The two puzzles are isomorphic in structure and similar in size, but have distinct values and deltas. Counterbalance order across runs if possible (A state, B control, B state, A control); use the same gpt-6-luna low route, system settings, tool permissions, output token limit, and sampling settings throughout. Use fresh contexts with no shared chat history. No browsing or code execution for subjects. Log model/route, settings, prompt and response verbatim, token counts if exposed, and any truncation/error. Keep Phase 1 answers even for the control as audit data, but do not show them to its Phase 2 agent.

**Blinding limitation:** This is procedural prompt-only blinding. Native agents can read the workspace, so they may inspect fixtures, evaluator files, or keys. Do not claim cryptographic or access-controlled blinding. The coordinator should dispatch only the exact listed prompt and input payload, without volunteering evaluator paths. Record any apparent leakage or tool access. The key/evaluator is physically separate from the subject prompt files, but workspace visibility prevents a strong secrecy guarantee.

## Task and outputs

Each puzzle asks for a maximum-value subset of projects subject to a budget, mandatory inclusion, dependency closure, pairwise incompatibilities, and (in Phase 2) one new exclusion. Candidate sets are scored exactly by a deterministic enumerator. Phase 1 must produce a useful state representation, not merely a final answer: preserve source facts, list every feasible candidate explicitly, state the winning set/value, and preserve dependency/conflict rules. Phase 2 must apply the delta and emit both a complete current state and a patch with provenance, so that stale-state errors are observable. The delta is fixed in the fixture before any subjects run; it is not generated adaptively after Phase 1.

Subject output must be valid JSON with the exact schemas in the prompts. Save the raw model response at the specified output path. If it is invalid JSON, preserve it unchanged and score JSON validity as zero; do not repair it silently.

## Exact prompts

Substitute only the `{FIXTURE_JSON}` placeholder with the literal contents of the named fixture. Do not include the evaluator/key. The fixture itself includes a Phase 2 delta; hide that field during Phase 1 by passing only the top-level `problem` object. Phase 2 state condition receives the Phase 1 artifact plus only the `delta`; full-context control receives the full `problem` and `delta` objects.

### Phase 1 prompt (both conditions)

> Solve the maximum-value project-selection problem in the input. A selected project costs its listed cost and contributes its listed value. Total cost must not exceed the budget. All mandatory projects must be selected. If a selected project has dependencies, every dependency must also be selected. No incompatible pair may both be selected. Find the feasible selection with the greatest total value; break ties by lower total cost, then lexicographically smallest sorted project-ID list.
>
> Return only valid JSON using this schema:
> `{ "schema_version": 1, "problem_id": "...", "source_facts": {"projects": [{"id":"...","cost":0,"value":0}], "budget":0, "mandatory":[], "dependencies":{}, "incompatible_pairs":[]}, "candidate_ledger": [{"selected":[],"cost":0,"value":0}], "winner": {"selected":[],"cost":0,"value":0}, "reasoning_note":"briefly state how completeness/feasibility was checked" }`
>
> `candidate_ledger` must contain every feasible selection explicitly, sorted lexicographically by the sorted selected-ID list. Compression is not accepted in this pilot because the exact evaluator checks each row. Use numeric costs/values and sorted IDs. Do not include the Phase 2 change: it has not happened yet.
>
> Input problem: `{FIXTURE_JSON}`

### Phase 2 prompt (state condition)

> A prior fresh agent left the external state below. Apply the supplied delta as a new fact, preserving provenance and revising any derived candidate set and winner that are no longer valid. Recompute if needed. Use the original tie-break rule: greatest value, then lower cost, then lexicographically smallest sorted selected-ID list. Return only valid JSON using this schema:
> `{ "schema_version": 1, "problem_id": "...", "applied_delta": {"type":"project_unavailable","project_id":"..."}, "current_state": {"source_facts":{},"candidate_ledger":[{"selected":[],"cost":0,"value":0}],"winner":{"selected":[],"cost":0,"value":0}}, "patch": {"removed_candidates":[],"added_candidates":[],"changed_facts":[],"winner_before":{"selected":[],"cost":0,"value":0},"winner_after":{"selected":[],"cost":0,"value":0},"provenance":"name the delta and explain which invariant was rechecked"}, "reasoning_note":"briefly state how the updated result was checked" }`
>
> The ledger must contain every currently feasible selection in lexicographic order. `removed_candidates` lists old selections made invalid by the delta; `added_candidates` lists newly feasible selections (normally empty for an added exclusion). Set `changed_facts` to `[{{"project_id":"...","availability":"unavailable"}}]` for this delta. Do not claim a candidate is removed merely because it is no longer optimal.
>
> External state from Phase 1: `{STATE_JSON}`
>
> New delta: `{DELTA_JSON}`

### Phase 2 prompt (full-context control)

> Re-solve the maximum-value project-selection problem from the complete source facts below after applying the supplied new fact. A selected project costs its listed cost and contributes its listed value. Total cost must not exceed the budget. All mandatory projects must be selected. If a selected project has dependencies, every dependency must also be selected. No incompatible pair may both be selected. The new fact makes one project unavailable. Break ties by greatest value, then lower cost, then lexicographically smallest sorted project-ID list.
>
> Return only valid JSON using the same Phase 2 schema: `{ "schema_version": 1, "problem_id": "...", "applied_delta": {"type":"project_unavailable","project_id":"..."}, "current_state": {"source_facts":{},"candidate_ledger":[{"selected":[],"cost":0,"value":0}],"winner":{"selected":[],"cost":0,"value":0}}, "patch": {"removed_candidates":[],"added_candidates":[],"changed_facts":[],"winner_before":{"selected":[],"cost":0,"value":0},"winner_after":{"selected":[],"cost":0,"value":0},"provenance":"name the delta and explain which invariant was rechecked"}, "reasoning_note":"briefly state how the updated result was checked" }`
>
> The ledger must contain every feasible selection after the delta, in lexicographic order. `removed_candidates` lists feasible selections under the original facts that the delta invalidates; `added_candidates` lists newly feasible selections (normally empty). Do not claim a candidate is removed merely because it is no longer optimal. The pre-delta winner is the optimum under the original facts.
>
> Complete original problem facts: `{PROBLEM_JSON}`
>
> New delta: `{DELTA_JSON}`

## Scoring, endpoints, and decision rule

The primary score is Phase 2 **solution score out of 100**: 40 points for exact post-delta ledger rows (selected IDs, cost, value; set equality, with order checked separately), 30 for exact winner, 10 for source-fact fidelity including applied delta and availability, 10 only when both the exact removed-candidate set and empty added set match, 5 for correct winner-before, and 5 for correct winner-after. Within each component, award the full component only on exact match; no partial credit. Invalid/missing fields score zero for that component. Ledger ordering is an additional binary diagnostic, not included in the primary score. Phase 1 artifact quality is an additional 0–100 diagnostic: 50 points exact ledger rows, 40 exact winner, and 10 source-fact fidelity. The scorer is deterministic; see `score.py` and `private/answer_key.json`.

Primary contrast: average Phase 2 solution score for the two matched puzzles in state versus full-context control. Also report exact-winner rate and exact-ledger rate by fixture and condition, state-file validity, patch-invariant errors, response length/token count where exposed, and all deviations. No significance test is warranted at n=2 matched puzzles. Treat any difference as descriptive only.

**Predeclared failure condition:** The proposed benefit is not demonstrated if the state condition fails to exceed the full-context control on the mean Phase 2 score, or if either state-condition Phase 2 result violates the basic validity invariant (no over-budget, dependency-broken, conflicting, or unavailable selected project). A state artifact that cannot be parsed as valid JSON is a treatment failure. A higher state score with materially greater total token/compute use is inconclusive about representation benefit.

## Interpretation and validity limits

The full-context control controls access to the original facts but not the informational compression, ordering, or intermediate search work in the state artifact. Phase 1 is run in both arms, but Phase 2 in the state arm receives its derived ledger; therefore this pilot estimates the value of handing off a typed derived state to a fresh solver, including the work it encodes. It does not isolate storage from extra useful computation. Record token counts and treat unbalanced resource use as a confound. No shuffled/corrupted-state arm, large-state scaling curve, random post-freeze generation, repeated seeds, or human baseline is included in this quick pilot. Two fixtures are insufficient for general claims. Native agents' workspace access weakens blinding. Artificial context limits, if added later, would show performance under that imposed limit only—not native inability.

## Execution checklist

1. Freeze this file and fixtures before launching subjects; preserve a copy/hash if practical.
2. Run each Phase 1 prompt in a fresh gpt-6-luna low context; save raw response exactly to the file in the table below.
3. Run each Phase 2 prompt in another fresh context. State arm receives the saved Phase 1 JSON; control receives full problem JSON. Save exact response to the file in the table below.
4. Score only after all subject responses are saved, with `python score.py outputs` from this directory. Keep malformed responses for audit; never hand-correct.
5. Report the protocol deviations, route/settings, output/token records, score file, and the fact that the pilot is a demonstration rather than evidence of native incapacity.

| Fixture/condition | Phase 1 prompt | Phase 1 response | Phase 2 prompt | Phase 2 response |
|---|---|---|---|---|
| A/state | `prompts/a_phase1.txt` | `outputs/a_state_phase1.json` | `prompts/a_phase2_state.txt` with exact saved P1 response pasted into placeholder | `outputs/a_state_phase2.json` |
| A/control | `prompts/a_phase1.txt` | `outputs/a_control_phase1.json` | `prompts/a_phase2_control.txt` | `outputs/a_control_phase2.json` |
| B/state | `prompts/b_phase1.txt` | `outputs/b_state_phase1.json` | `prompts/b_phase2_state.txt` with exact saved P1 response pasted into placeholder | `outputs/b_state_phase2.json` |
| B/control | `prompts/b_phase1.txt` | `outputs/b_control_phase1.json` | `prompts/b_phase2_control.txt` | `outputs/b_control_phase2.json` |

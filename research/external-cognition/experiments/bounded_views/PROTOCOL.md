# Bounded-view CSP pilot — preregistration / frozen protocol

Status: frozen before any subject response. Date: 2026-10-01.

## Question and scope

Can three fresh-context workers, each given only one local slice of a linked constraint problem plus a compact frontier from the prior worker, produce a globally optimal solution while preserving the exact frontier invariant? This is a small procedural demonstration. The slice restriction is imposed by the protocol; it does **not** establish that a model naturally cannot hold the whole problem.

The task is a finite binary CSP with seven variables `A..G`, domains `{0,1}`, and three disjoint local neighborhoods linked by one boundary variable each: slice 1 owns `A,B,C`; slice 2 owns `C,D,E`; slice 3 owns `E,F,G`. Costs are additive and local constraints are enumerated in the frozen subject files. A frontier is a dynamic-programming summary: for each boundary value, retain the minimum accumulated cost and a witness assignment. Ties must be retained as all witnesses or deterministically broken lexicographically; use lexicographically smallest witness to keep the output compact and reproducible.

## Subject isolation and execution

- Use exactly three separate fresh subjects, one per stage, with the same model/version/settings where available. No subject sees another subject's answer except the prior-stage handoff JSON.
- Stage 1 receives only `subject_1.txt`. Stage 2 receives only `subject_2.txt` and the verbatim Stage 1 response. Stage 3 receives only `subject_3.txt` and the verbatim Stage 2 response. Do not provide the oracle/scorer or other slices.
- To prepare stages 2/3, append a clear delimiter and the full, unedited prior response to that stage's prompt in the subject UI. Save the exact assembled input before sending it.
- Each subject may reason and write its assigned response, but must not browse, execute code, or inspect other files. Record model identifier, settings, exact prompt, exact response, and any protocol violation in the run log before scoring.
- A human coordinator copies outputs between subjects. Do not repair or normalize them before saving; scorer rejects malformed output.
- If a stage is rejected, still preserve and pass its verbatim response to the next fresh subject for this fixed three-subject run. The scorer will mark downstream state as unaccepted; do not silently substitute an oracle frontier or repair the chain.
- The stage 2/3 prompt includes local costs/constraints only for that slice. Prior frontier necessarily summarizes prior slices, not their raw facts.

## Frozen response schema

Each response must be one JSON object (no markdown fences, no extra prose):

```json
{
  "stage": 1,
  "input_frontier": null,
  "frontier_variable": "C",
  "frontier": [],
  "final": null
}
```

The empty array above is only a shape placeholder. Stage 2 and 3 must echo the exact incoming frontier in `input_frontier`. Stage 2 emits `frontier_variable: "E"`, cumulative cost, and complete witness over `A..E`; Stage 3 emits `frontier_variable: null`, `frontier: []`, and final `{"cost": integer, "assignment": {"A"..."G"}}`.

For each possible frontier value, include exactly one row if feasible; omit it if infeasible. The witness must include all variables assigned so far and agree with the boundary. The cost is the sum over assigned slices, with shared boundary variables' costs charged only in the slice that introduces them (rules in prompts). Stage 3 final must be the lexicographically smallest complete assignment among minimum-cost feasible assignments.

## Invariants and acceptance

The evaluator independently enumerates the full global problem. A patch is accepted only if JSON parses; stage and echoed input match; frontier rows are complete, feasible, and have exact minimum costs/witnesses under the relevant processed slices; all prior assignments persist unchanged; shared values agree; and final output equals the exact global optimum. Invalid output is rejected as a whole. The evaluator preserves the prior accepted state unchanged after rejection and does not ask that subject to repair it during this pilot.

Score each stage separately: schema validity, incoming-frontier fidelity, local feasibility, exact frontier values/costs/witnesses, and (stage 3) exact global optimum. Report end-to-end success separately from stage success. No retries.

## Interpretation and limits

There is no baseline arm in this three-subject pilot; it tests whether this simple protocol can carry a correct frontier across slices/resets. It does not isolate benefits against a compute-matched baseline, test generalization, or establish native capacity. The problem is intentionally small enough for manual exhaustive reasoning. Follow-up should add randomized instances, multiple runs, matched compute controls, and seeded stale/corrupt frontiers.
Pre-run revision v1.1: specify exact frontier row keys value/cost/witness in all prompts; initial prompt omitted row key names although checker required them. No subjects launched under v1.0.

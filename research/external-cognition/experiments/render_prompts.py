"""Render the frozen literal subject prompts from the frozen fixtures."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "prompts"
OUT.mkdir(exist_ok=True)

P1 = '''Solve the maximum-value project-selection problem in the input. A selected project costs its listed cost and contributes its listed value. Total cost must not exceed the budget. All mandatory projects must be selected. If a selected project has dependencies, every dependency must also be selected. No incompatible pair may both be selected. Find the feasible selection with the greatest total value; break ties by lower total cost, then lexicographically smallest sorted project-ID list.

Return only valid JSON using this schema:
{{ "schema_version": 1, "problem_id": "...", "source_facts": {{"projects": [{{"id":"...","cost":0,"value":0}}], "budget":0, "mandatory":[], "dependencies":{{}}, "incompatible_pairs":[]}}, "candidate_ledger": [{{"selected":[],"cost":0,"value":0}}], "winner": {{"selected":[],"cost":0,"value":0}}, "reasoning_note":"briefly state how completeness/feasibility was checked" }}

candidate_ledger must contain every feasible selection explicitly, sorted lexicographically by the sorted selected-ID list. Compression is not accepted in this pilot because the evaluator checks each row. Use numeric costs/values and sorted IDs. Do not include the Phase 2 change: it has not happened yet.

Input problem:
{problem}'''

P2_STATE = '''A prior fresh agent left the external state below. Apply the supplied delta as a new fact, preserving provenance and revising any derived candidate set and winner that are no longer valid. Recompute if needed. Use the original tie-break rule: greatest value, then lower cost, then lexicographically smallest sorted project-ID list. Return only valid JSON using this schema:
{{ "schema_version": 1, "problem_id": "...", "applied_delta": {{"type":"project_unavailable","project_id":"..."}}, "current_state": {{"source_facts":{{}},"candidate_ledger":[{{"selected":[],"cost":0,"value":0}}],"winner":{{"selected":[],"cost":0,"value":0}}}}, "patch": {{"removed_candidates":[],"added_candidates":[],"changed_facts":[],"winner_before":{{"selected":[],"cost":0,"value":0}},"winner_after":{{"selected":[],"cost":0,"value":0}},"provenance":"name the delta and explain which invariant was rechecked"}}, "reasoning_note":"briefly state how the updated result was checked" }}

The ledger must contain every currently feasible selection in lexicographic order. removed_candidates lists old selections made invalid by the delta; added_candidates lists newly feasible selections (normally empty for an added exclusion). Set changed_facts to [{{"project_id":"...","availability":"unavailable"}}] for this delta. Do not claim a candidate is removed merely because it is no longer optimal.

External state from Phase 1:
{state}

New delta:
{delta}'''

P2_CONTROL = '''Re-solve the maximum-value project-selection problem from the complete source facts below after applying the supplied new fact. A selected project costs its listed cost and contributes its listed value. Total cost must not exceed the budget. All mandatory projects must be selected. If a selected project has dependencies, every dependency must also be selected. No incompatible pair may both be selected. The new fact makes one project unavailable. Break ties by greatest value, then lower cost, then lexicographically smallest sorted project-ID list.

Return only valid JSON using this schema: {{ "schema_version": 1, "problem_id": "...", "applied_delta": {{"type":"project_unavailable","project_id":"..."}}, "current_state": {{"source_facts":{{}},"candidate_ledger":[{{"selected":[],"cost":0,"value":0}}],"winner":{{"selected":[],"cost":0,"value":0}}}}, "patch": {{"removed_candidates":[],"added_candidates":[],"changed_facts":[],"winner_before":{{"selected":[],"cost":0,"value":0}},"winner_after":{{"selected":[],"cost":0,"value":0}},"provenance":"name the delta and explain which invariant was rechecked"}}, "reasoning_note":"briefly state how the updated result was checked" }}

The ledger must contain every feasible selection after the delta, in lexicographic order. removed_candidates lists feasible selections under the original facts that the delta invalidates; added_candidates lists newly feasible selections (normally empty). Set changed_facts to [{{"project_id":"...","availability":"unavailable"}}] for this delta. Do not claim a candidate is removed merely because it is no longer optimal. The pre-delta winner is the optimum under the original facts.

Complete original problem facts:
{problem}

New delta:
{delta}'''

for fname in ("puzzle_a.json", "puzzle_b.json"):
    data = json.loads((ROOT / "fixtures" / fname).read_text(encoding="utf-8"))
    p = data["problem"]
    d = data["delta"]
    letter = p["problem_id"].lower()
    (OUT / f"{letter}_phase1.txt").write_text(P1.format(problem=json.dumps(p, indent=2)), encoding="utf-8")
    (OUT / f"{letter}_phase2_control.txt").write_text(P2_CONTROL.format(problem=json.dumps(p, indent=2), delta=json.dumps(d)), encoding="utf-8")
    (OUT / f"{letter}_phase2_state.txt").write_text(P2_STATE.format(state="{PASTE THE EXACT SAVED PHASE 1 RESPONSE HERE}", delta=json.dumps(d)), encoding="utf-8")

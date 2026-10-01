"""Independent exhaustive oracle and strict response checker for the frozen pilot."""
from __future__ import annotations

import hashlib
import itertools
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
VARS = "ABCDEFG"


def cost(assign: dict[str, int], names: str) -> int:
    weights = {"A": 1, "B": 2, "C": 0, "D": 1, "E": 3, "F": 2, "G": 1}
    return sum(weights[v] * assign[v] for v in names)


def assignments(names: str):
    for bits in itertools.product((0, 1), repeat=len(names)):
        yield dict(zip(names, bits))


def feasible(stage: int, a: dict[str, int]) -> bool:
    if stage == 1:
        return a["A"] ^ a["B"] == a["C"]
    if stage == 2:
        return (a["C"] + a["D"] + a["E"]) % 2 == 1
    return a["E"] + a["F"] + a["G"] == 2


def tuple_key(a: dict[str, int], names: str) -> tuple[int, ...]:
    return tuple(a[x] for x in names)


def frontier_for_stage(stage: int, incoming: list[dict[str, Any]] | None):
    names = {1: "ABC", 2: "CDE", 3: "EFG"}[stage]
    fullnames = {1: "ABC", 2: "ABCDE", 3: "ABCDEFG"}[stage]
    boundary = {1: "C", 2: "E"}.get(stage)
    candidates: list[dict[str, Any]] = []
    if stage == 1:
        for local in assignments(names):
            if feasible(1, local):
                candidates.append({"cost": cost(local, names), "witness": local})
    else:
        assert incoming is not None
        for row in incoming:
            for local in assignments(names):
                shared = "C" if stage == 2 else "E"
                if local[shared] != row["value"] or not feasible(stage, local):
                    continue
                witness = dict(row["witness"])
                for v in names:
                    if v not in witness:
                        witness[v] = local[v]
                new_names = "DE" if stage == 2 else "FG"
                candidates.append({"cost": row["cost"] + cost(local, new_names), "witness": witness})

    if stage < 3:
        rows = []
        for b in (0, 1):
            options = [x for x in candidates if x["witness"][boundary] == b]
            if options:
                best = min(options, key=lambda x: (x["cost"], tuple_key(x["witness"], fullnames)))
                rows.append({"value": b, "cost": best["cost"], "witness": {v: best["witness"][v] for v in fullnames}})
        return rows
    best = min(candidates, key=lambda x: (x["cost"], tuple_key(x["witness"], fullnames)))
    return {"cost": best["cost"], "assignment": {v: best["witness"][v] for v in fullnames}}


def oracle():
    front1 = frontier_for_stage(1, None)
    front2 = frontier_for_stage(2, front1)
    # Independent whole-instance exhaustive enumeration is the final-answer oracle.
    feasible_global = []
    for a in assignments(VARS):
        if feasible(1, a) and feasible(2, a) and feasible(3, a):
            feasible_global.append({"cost": cost(a, VARS), "assignment": a})
    final = min(feasible_global, key=lambda x: (x["cost"], tuple_key(x["assignment"], VARS)))
    # Guard the DP/frontier composition against an implementation inconsistency.
    assert frontier_for_stage(3, front2) == final
    return [front1, front2, final]


def load(path: str) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--seal":
        files = [ROOT / "PROTOCOL.md", *(ROOT / f"subject_{i}.txt" for i in (1, 2, 3)), Path(__file__)]
        for p in files:
            digest = hashlib.sha256(p.read_bytes()).hexdigest()
            print(f"{digest}  {p.name}")
        return 0
    if len(sys.argv) not in (3, 4) or sys.argv[1] not in ("1", "2", "3"):
        print("Usage: python score.py --seal | python score.py STAGE RESPONSE.json [PRIOR_RESPONSE.json]", file=sys.stderr)
        return 2
    stage = int(sys.argv[1])
    try:
        response = load(sys.argv[2])
        prior = load(sys.argv[3]) if len(sys.argv) == 4 else None
    except Exception as e:
        print(f"REJECT: invalid JSON/input: {e}")
        return 1

    valid = True
    issues = []
    if response.get("stage") != stage:
        valid = False; issues.append("wrong stage")
    if stage == 1:
        if prior is not None or response.get("input_frontier") is not None:
            valid = False; issues.append("stage 1 input must be null")
        expected = oracle()[0]
    else:
        if prior is None or prior.get("stage") != stage - 1:
            valid = False; issues.append("missing or wrong prior response")
            expected = None
        else:
            prev_rows = prior.get("frontier")
            if response.get("input_frontier") != prev_rows:
                valid = False; issues.append("incoming frontier not echoed exactly")
            if prior.get("stage") == 1:
                expected_prev = oracle()[0]
            else:
                expected_prev = oracle()[1]
            if prev_rows != expected_prev:
                valid = False; issues.append("prior frontier was not accepted/correct")
            expected = oracle()[stage - 1]

    if stage < 3:
        expected_obj = {
            "stage": stage,
            "input_frontier": None if stage == 1 else (prior.get("frontier") if prior else None),
            "frontier_variable": "C" if stage == 1 else "E",
            "frontier": expected,
            "final": None,
        }
    else:
        expected_obj = {
            "stage": 3,
            "input_frontier": prior.get("frontier") if prior else None,
            "frontier_variable": None,
            "frontier": [],
            "final": expected,
        }
    if response != expected_obj:
        valid = False; issues.append("response differs from exact stage oracle (includes schema, costs, frontier, witness, and final checks)")
    if valid:
        print(f"ACCEPT stage {stage}: exact frontier/transition matches exhaustive oracle")
        if stage == 3:
            print("End-to-end exact global optimum confirmed.")
        return 0
    print("REJECT stage {}: {}".format(stage, "; ".join(issues)))
    print("Evaluator action: preserve prior accepted state unchanged; commit no patch.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

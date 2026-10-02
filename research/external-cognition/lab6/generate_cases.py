"""Deterministic 16-variable finite-CSP instance builder for Lab 6. Never imported by pilot.py."""
from __future__ import annotations

import itertools
import json
import random
from pathlib import Path

VARIABLES = tuple("abcdefghijklmnop")
C1 = tuple("abcd")
C2 = tuple("efgh")
C3 = tuple("ijkl")
C4 = tuple("mnop")
COMPONENTS = {"c1": list(C1), "c2": list(C2), "c3": list(C3), "c4": list(C4)}

INTERNAL_EDGES = (
    ("a", "b"), ("b", "c"), ("c", "d"), ("d", "a"),
    ("e", "f"), ("f", "g"), ("g", "h"), ("h", "e"),
    ("i", "j"), ("j", "k"), ("k", "l"), ("l", "i"),
    ("m", "n"), ("n", "o"), ("o", "p"), ("p", "m"),
)
BRIDGE_EDGES = (
    ("b", "e"), ("f", "i"), ("j", "m"), ("n", "a"),
)
ALL_EDGES = INTERNAL_EDGES + BRIDGE_EDGES
SEEDS = (6112, 6135, 6412, 6432, 6459, 6582)


def _satisfies(values: dict[str, int], constraint: dict) -> bool:
    return [values[v] for v in constraint["variables"]] in constraint["allowed_pairs"]


def enumerate_component(packet: dict, component: str) -> list[list[int]]:
    names = packet["components"][component]
    constraints = [c for c in packet["constraints"] if set(c["variables"]).issubset(names)]
    rows = []
    for tup in itertools.product(packet["domain"], repeat=len(names)):
        vals = dict(zip(names, tup))
        if all(_satisfies(vals, c) for c in constraints):
            rows.append(list(tup))
    return rows


def enumerate_global(packet: dict, locals_sol: dict[str, list[list[int]]]) -> list[dict[str, int]]:
    constraints = packet["constraints"]
    b12 = next(c["allowed_pairs"] for c in constraints if c["variables"] == ["b", "e"])
    b23 = next(c["allowed_pairs"] for c in constraints if c["variables"] == ["f", "i"])
    b34 = next(c["allowed_pairs"] for c in constraints if c["variables"] == ["j", "m"])
    b41 = next(c["allowed_pairs"] for c in constraints if c["variables"] == ["n", "a"])

    globals_sol = []
    for t1 in locals_sol["c1"]:
        for t2 in locals_sol["c2"]:
            if [t1[1], t2[0]] not in b12:
                continue
            for t3 in locals_sol["c3"]:
                if [t2[1], t3[0]] not in b23:
                    continue
                for t4 in locals_sol["c4"]:
                    if [t3[1], t4[0]] not in b34:
                        continue
                    if [t4[1], t1[0]] not in b41:
                        continue
                    globals_sol.append(dict(zip(VARIABLES, t1 + t2 + t3 + t4)))
    return globals_sol


def make_candidate(seed: int) -> tuple[dict, dict]:
    rng = random.Random(seed)
    planted = {name: rng.randrange(4) for name in VARIABLES}
    constraints = []
    all_pairs = list(itertools.product(range(4), repeat=2))
    for i, edge in enumerate(ALL_EDGES):
        planted_pair = [planted[edge[0]], planted[edge[1]]]
        k = 5 if i < len(INTERNAL_EDGES) else 1
        distractors = rng.sample([list(p) for p in all_pairs if list(p) != planted_pair], k)
        constraints.append({
            "constraint_id": f"c{i+1}",
            "variables": list(edge),
            "allowed_pairs": [planted_pair, *distractors],
        })
    packet = {
        "schema": "lab6-finite-csp-v1",
        "problem_id": f"csp-{seed}",
        "seed": seed,
        "variables": list(VARIABLES),
        "domain": [0, 1, 2, 3],
        "components": {k: list(v) for k, v in COMPONENTS.items()},
        "constraints": constraints,
        "bridges": [
            {"from_component": "c1", "to_component": "c2", "variables": ["b", "e"], "constraint_id": "c17"},
            {"from_component": "c2", "to_component": "c3", "variables": ["f", "i"], "constraint_id": "c18"},
            {"from_component": "c3", "to_component": "c4", "variables": ["j", "m"], "constraint_id": "c19"},
            {"from_component": "c4", "to_component": "c1", "variables": ["n", "a"], "constraint_id": "c20"},
        ],
        "answer_requirements": {
            "local": "Enumerate every satisfying tuple for your assigned component, in variable order.",
            "global": "Give one complete assignment for a through p satisfying all twenty constraints.",
            "format": "Return the requested JSON object only. Integers must be JSON integers.",
        },
    }
    locals_sol = {side: enumerate_component(packet, side) for side in ("c1", "c2", "c3", "c4")}
    globals_sol = enumerate_global(packet, locals_sol)
    key = {
        "seed": seed,
        "planted": planted,
        "local_solutions": locals_sol,
        "global_solutions": globals_sol,
    }
    return packet, key


def selected_cases() -> tuple[list[dict], dict]:
    packets, key = [], {"schema": "lab6-private-key-v1", "cases": {}}
    for seed in SEEDS:
        packet, secret = make_candidate(seed)
        for side in ("c1", "c2", "c3", "c4"):
            assert 3 <= len(secret["local_solutions"][side]) <= 10, f"seed {seed} {side} count out of bounds"
        assert len(secret["global_solutions"]) == 1, f"seed {seed} global count != 1"
        packets.append(packet)
        key["cases"][str(seed)] = secret
    return packets, key


def write_cases(root: Path) -> None:
    packets, key = selected_cases()
    (root / "cases").mkdir(parents=True, exist_ok=True)
    (root / "private").mkdir(parents=True, exist_ok=True)
    for packet in packets:
        (root / "cases" / f"{packet['seed']}.json").write_text(
            json.dumps(packet, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    (root / "private" / "case-key.json").write_text(
        json.dumps(key, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    write_cases(Path(__file__).resolve().parent)

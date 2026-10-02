"""Deterministic finite-CSP instance builder. Never imported by pilot.py."""
from __future__ import annotations

import itertools
import json
import random
from pathlib import Path

VARIABLES = tuple("abcdefgh")
LEFT = tuple("abcd")
RIGHT = tuple("efgh")
EDGES = (("a", "b"), ("b", "c"), ("c", "d"), ("d", "a"),
         ("e", "f"), ("f", "g"), ("g", "h"), ("h", "e"), ("b", "e"), ("d", "g"))
SEEDS = (5103, 5110, 5115, 5121, 5122, 5129)


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


def enumerate_global(packet: dict) -> list[dict[str, int]]:
    return [dict(zip(VARIABLES, row)) for row in itertools.product(packet["domain"], repeat=8)
            if all(_satisfies(dict(zip(VARIABLES, row)), c) for c in packet["constraints"])]


def make_candidate(seed: int) -> tuple[dict, dict]:
    rng = random.Random(seed)
    planted = {name: rng.randrange(4) for name in VARIABLES}
    constraints = []
    for i, edge in enumerate(EDGES):
        planted_pair = [planted[v] for v in edge]
        all_pairs = list(itertools.product(range(4), repeat=2))
        if i < 8:
            additions = rng.sample([p for p in all_pairs if list(p) != planted_pair], 4)
        else:
            additions = rng.sample([p for p in all_pairs if list(p) != planted_pair], 1)
        constraints.append({"constraint_id": f"c{i+1}", "variables": list(edge),
                            "allowed_pairs": [planted_pair, *[list(p) for p in additions]]})
    packet = {
        "schema": "lab5-finite-csp-v1", "problem_id": f"csp-{seed}", "seed": seed,
        "variables": list(VARIABLES), "domain": [0, 1, 2, 3],
        "components": {"left": list(LEFT), "right": list(RIGHT)},
        "constraints": constraints,
        "answer_requirements": {
            "local": "Enumerate every satisfying tuple for your assigned component, in variable order.",
            "global": "Give one complete assignment for a through h satisfying all ten constraints.",
            "format": "Return the requested JSON object only. Integers must be JSON integers.",
        },
    }
    key = {"seed": seed, "planted": planted,
           "local_solutions": {side: enumerate_component(packet, side) for side in ("left", "right")},
           "global_solutions": enumerate_global(packet)}
    return packet, key


def selected_cases() -> tuple[list[dict], dict]:
    packets, key = [], {"schema": "lab5-private-key-v1", "cases": {}}
    for seed in SEEDS:
        packet, secret = make_candidate(seed)
        assert 3 <= len(secret["local_solutions"]["left"]) <= 10
        assert 3 <= len(secret["local_solutions"]["right"]) <= 10
        assert len(secret["global_solutions"]) == 1
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

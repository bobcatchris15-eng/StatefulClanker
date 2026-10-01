"""Exact finite-state solver and safe state codecs for lab2."""
from __future__ import annotations

import hashlib
import json
import random
import struct
import zlib


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def _validate_problem(problem):
    if not isinstance(problem, dict) or set(problem) != {"schema_version", "seed", "stages", "final_boundary"}:
        raise ValueError("invalid problem shape")
    if type(problem["schema_version"]) is not int or problem["schema_version"] != 1:
        raise ValueError("unsupported problem schema")
    if type(problem["seed"]) is not int or type(problem["final_boundary"]) is not int or problem["final_boundary"] not in (0, 1):
        raise ValueError("invalid seed or final boundary")
    stages = problem["stages"]
    if not isinstance(stages, list):
        raise ValueError("stages must be a list")
    for i, stage in enumerate(stages):
        if not isinstance(stage, dict) or set(stage) != {"index", "parity", "wx", "wy"}:
            raise ValueError("invalid stage shape")
        if type(stage["index"]) is not int or stage["index"] != i:
            raise ValueError("stage indexes must be contiguous")
        if type(stage["parity"]) is not int or stage["parity"] not in (0, 1):
            raise ValueError("parity must be 0 or 1")
        if any(type(stage[k]) is not int or stage[k] < 0 for k in ("wx", "wy")):
            raise ValueError("weights must be nonnegative integers")


def generate_problem(seed: int, blocks: int) -> dict:
    if type(seed) is not int or type(blocks) is not int or blocks < 1:
        raise ValueError("seed must be an integer and blocks positive")
    rng = random.Random(seed)
    stages = [{"index": i, "parity": rng.randrange(2), "wx": rng.randint(1, 9), "wy": rng.randint(1, 9)} for i in range(blocks)]
    return {"schema_version": 1, "seed": seed, "stages": stages, "final_boundary": rng.randrange(2)}


def initial_frontier() -> list:
    return [{"boundary": 0, "cost": 0, "bits": ""}]


def frontier_step(stage: dict, frontier: list) -> list:
    if not isinstance(stage, dict) or set(stage) != {"index", "parity", "wx", "wy"}:
        # Standalone transition callers commonly pass a stage without its index.
        if not isinstance(stage, dict) or set(stage) != {"parity", "wx", "wy"}:
            raise ValueError("invalid stage")
    parity, wx, wy = stage["parity"], stage["wx"], stage["wy"]
    if type(parity) is not int or parity not in (0, 1) or any(type(v) is not int or v < 0 for v in (wx, wy)):
        raise ValueError("invalid stage values")
    _validate_frontier(frontier)
    best = {}
    for row in frontier:
        b = row["boundary"]
        for x in (0, 1):
            y = parity ^ b ^ x
            candidate = {"boundary": y, "cost": row["cost"] + wx*x + wy*y, "bits": row["bits"] + str(x) + str(y)}
            prior = best.get(y)
            if prior is None or (candidate["cost"], candidate["bits"]) < (prior["cost"], prior["bits"]):
                best[y] = candidate
    return [best[b] for b in sorted(best)]


def _validate_frontier(frontier):
    if not isinstance(frontier, list):
        raise ValueError("frontier must be a list")
    seen = set()
    for row in frontier:
        if not isinstance(row, dict) or set(row) != {"boundary", "cost", "bits"}:
            raise ValueError("invalid frontier row")
        b, cost, bits = row["boundary"], row["cost"], row["bits"]
        if type(b) is not int or b not in (0, 1) or b in seen or type(cost) is not int or cost < 0 or not isinstance(bits, str) or any(c not in "01" for c in bits):
            raise ValueError("invalid frontier values")
        seen.add(b)
    if [r["boundary"] for r in frontier] != sorted(seen):
        raise ValueError("frontier must be sorted")


def oracle(problem: dict) -> dict:
    _validate_problem(problem)
    frontier = initial_frontier()
    for stage in problem["stages"]:
        frontier = frontier_step(stage, frontier)
    choices = [r for r in frontier if r["boundary"] == problem["final_boundary"]]
    if not choices:
        raise ValueError("no feasible solution")
    row = min(choices, key=lambda r: (r["cost"], r["bits"]))
    return {"cost": row["cost"], "bits": row["bits"]}


def problem_hash(problem: dict) -> str:
    _validate_problem(problem)
    return hashlib.sha256(_canonical(problem)).hexdigest()


def initial_state(problem: dict) -> dict:
    _validate_problem(problem)
    return {"schema_version": 1, "problem_hash": problem_hash(problem), "version": 0,
            "next_stage": 0, "frontier": initial_frontier(), "history": []}


def _state_shape(problem, state):
    _validate_problem(problem)
    if not isinstance(state, dict) or set(state) != {"schema_version", "problem_hash", "version", "next_stage", "frontier", "history"}:
        raise ValueError("invalid state shape")
    if state["schema_version"] != 1 or state["problem_hash"] != problem_hash(problem):
        raise ValueError("state problem/schema mismatch")
    n = len(problem["stages"])
    if type(state["version"]) is not int or state["version"] < 0 or type(state["next_stage"]) is not int or not 0 <= state["next_stage"] <= n:
        raise ValueError("invalid state version or stage")
    if not isinstance(state["history"], list) or len(state["history"]) != state["next_stage"] or state["version"] < state["next_stage"]:
        raise ValueError("invalid state history")
    _validate_frontier(state["frontier"])
    for i, entry in enumerate(state["history"]):
        if not isinstance(entry, dict) or set(entry) != {"stage", "frontier"} or type(entry["stage"]) is not int or entry["stage"] != i:
            raise ValueError("invalid history entry")
        _validate_frontier(entry["frontier"])
        if any(len(r["bits"]) != 2*(i+1) for r in entry["frontier"]):
            raise ValueError("invalid history witness length")
    if (state["history"][-1]["frontier"] if state["history"] else initial_frontier()) != state["frontier"]:
        raise ValueError("current frontier does not match history")


def _validate_history_transitions(problem, state, upto=None):
    limit = state["next_stage"] if upto is None else min(upto, state["next_stage"])
    frontier = initial_frontier()
    for i in range(limit):
        frontier = frontier_step(problem["stages"][i], frontier)
        if state["history"][i]["frontier"] != frontier:
            raise ValueError("history transition mismatch at stage " + str(i))


def apply_patch(problem: dict, state: dict, patch: dict, verify: bool = True) -> tuple:
    issues = []
    try:
        _state_shape(problem, state)
        if verify:
            _validate_history_transitions(problem, state)
        if not isinstance(patch, dict) or set(patch) != {"base_version", "stage", "frontier"}:
            raise ValueError("invalid patch shape")
        if type(patch["base_version"]) is not int or patch["base_version"] != state["version"]:
            raise ValueError("stale base version")
        i = state["next_stage"]
        if type(patch["stage"]) is not int or patch["stage"] != i or i >= len(problem["stages"]):
            raise ValueError("unexpected stage")
        _validate_frontier(patch["frontier"])
        if any(len(r["bits"]) != 2*(i+1) for r in patch["frontier"]):
            raise ValueError("frontier witness length mismatch")
        if verify:
            expected = frontier_step(problem["stages"][i], state["frontier"])
            actual = patch["frontier"]
            expected_by_boundary = {r["boundary"]: r for r in expected}
            actual_by_boundary = {r["boundary"]: r for r in actual}
            if set(actual_by_boundary) != set(expected_by_boundary):
                raise ValueError("omitted-boundary: frontier must contain exactly each reachable boundary")
            old_by_bits = {r["bits"]: r for r in state["frontier"]}
            stage = problem["stages"][i]
            for row in actual:
                bits = row["bits"]
                prev = old_by_bits.get(bits[:-2])
                if prev is None:
                    raise ValueError("path-not-derived: witness does not extend the prior frontier")
                x, y = int(bits[-2]), int(bits[-1])
                if (prev["boundary"] + x + y) % 2 != stage["parity"]:
                    raise ValueError("parity: local transition violates stage parity")
                if row["cost"] != prev["cost"] + stage["wx"]*x + stage["wy"]*y:
                    raise ValueError("cost: cumulative cost does not match local transition")
                if row != expected_by_boundary[row["boundary"]]:
                    raise ValueError("nonminimal-or-tiebreak: frontier row is not the minimum-cost lexical witness")
        new = {**state, "version": state["version"]+1, "next_stage": i+1,
               "frontier": [dict(r) for r in patch["frontier"]],
               "history": state["history"] + [{"stage": i, "frontier": [dict(r) for r in patch["frontier"]]}]}
        _state_shape(problem, new)
        return new, {"accepted": True, "issues": []}
    except (ValueError, TypeError, KeyError) as exc:
        issues.append(str(exc))
        return state, {"accepted": False, "issues": issues}


def replace_problem(problem: dict, state: dict, updated_problem: dict, changed_stage: int) -> dict:
    _state_shape(problem, state)
    _validate_problem(updated_problem)
    if type(changed_stage) is not int or not 0 <= changed_stage <= len(problem["stages"]):
        raise ValueError("invalid changed stage")
    if len(problem["stages"]) != len(updated_problem["stages"]) or problem["final_boundary"] != updated_problem["final_boundary"]:
        raise ValueError("replacement must preserve task shape and final boundary")
    if problem["stages"][:changed_stage] != updated_problem["stages"][:changed_stage]:
        raise ValueError("declared unchanged prefix differs")
    if state["next_stage"] < changed_stage:
        raise ValueError("cannot preserve an uncomputed prefix")
    _validate_history_transitions(problem, state, changed_stage)
    hist = [{"stage": e["stage"], "frontier": [dict(r) for r in e["frontier"]]} for e in state["history"][:changed_stage]]
    frontier = hist[-1]["frontier"] if hist else initial_frontier()
    return {"schema_version": 1, "problem_hash": problem_hash(updated_problem),
            "version": state["version"]+1, "next_stage": changed_stage,
            "frontier": [dict(r) for r in frontier], "history": hist}


def encode_state(state: dict, codec: str) -> bytes:
    if not isinstance(state, dict):
        raise TypeError("state must be a dict")
    raw = _canonical(state)
    if codec == "json":
        return b"L2J1" + hashlib.sha256(raw).digest() + raw
    if codec == "packed":
        body = zlib.compress(raw, 9)
        return b"L2P1" + struct.pack(">Q", len(raw)) + hashlib.sha256(raw).digest() + body
    raise ValueError("codec must be json or packed")


def decode_state(payload: bytes) -> dict:
    if not isinstance(payload, bytes):
        raise TypeError("payload must be bytes")
    try:
        if payload.startswith(b"L2J1") and len(payload) >= 36:
            raw = payload[36:]
            if hashlib.sha256(raw).digest() != payload[4:36]:
                raise ValueError("json state checksum mismatch")
        elif payload.startswith(b"L2P1") and len(payload) >= 44:
            size = struct.unpack(">Q", payload[4:12])[0]
            raw = zlib.decompress(payload[44:])
            if len(raw) != size or hashlib.sha256(raw).digest() != payload[12:44]:
                raise ValueError("packed state checksum/length mismatch")
        else:
            raise ValueError("unknown state codec")
        value = json.loads(raw.decode("ascii"))
        if not isinstance(value, dict) or _canonical(value) != raw:
            raise ValueError("noncanonical or invalid state payload")
        return value
    except (zlib.error, UnicodeError, json.JSONDecodeError, struct.error) as exc:
        raise ValueError("invalid encoded state") from exc

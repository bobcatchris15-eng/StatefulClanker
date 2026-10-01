"""Deterministic exact scoring for the frozen external-state pilot."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
KEY = json.loads((ROOT / "private" / "answer_key.json").read_text(encoding="utf-8"))

def json_file(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        return None

def selected_tuple(row):
    try:
        return tuple(sorted(row["selected"]))
    except Exception:
        return None

def ledger_set(rows):
    if not isinstance(rows, list):
        return None
    result = []
    for row in rows:
        tup = selected_tuple(row)
        if tup is None:
            return None
        result.append(tup)
    return set(result) if len(result) == len(set(result)) else None

def ledger_rows_exact(rows, expected_rows):
    if not isinstance(rows, list):
        return False
    want = {tuple(r["selected"]): r for r in expected_rows}
    got = {}
    for row in rows:
        tup = selected_tuple(row)
        if tup is None or tup in got:
            return False
        got[tup] = row
    if set(got) != set(want):
        return False
    return all(got[k].get("cost") == want[k]["cost"] and got[k].get("value") == want[k]["value"] for k in want)

def ledger_ordered(rows):
    if not isinstance(rows, list):
        return False
    try:
        return [selected_tuple(r) for r in rows] == sorted(selected_tuple(r) for r in rows)
    except Exception:
        return False

def row_exact(got, expected):
    return isinstance(got, dict) and selected_tuple(got) == tuple(expected["selected"]) and got.get("cost") == expected["cost"] and got.get("value") == expected["value"]

def facts_exact(got, expected):
    if not isinstance(got, dict):
        return False
    try:
        projects = sorted((x["id"], x["cost"], x["value"]) for x in got["projects"])
        want_projects = sorted((x["id"], x["cost"], x["value"]) for x in expected["projects"])
        deps = {k: sorted(v) for k, v in got["dependencies"].items()}
        want_deps = {k: sorted(v) for k, v in expected["dependencies"].items()}
        pairs = sorted(tuple(sorted(x)) for x in got["incompatible_pairs"])
        want_pairs = sorted(tuple(sorted(x)) for x in expected["incompatible_pairs"])
        if (projects, got["budget"], sorted(got["mandatory"]), deps, pairs) != (want_projects, expected["budget"], sorted(expected["mandatory"]), want_deps, want_pairs):
            return False
        if "unavailable" in expected:
            return sorted(got.get("unavailable", [])) == sorted(expected["unavailable"])
        return "unavailable" not in got
    except Exception:
        return False

def score_phase1(response, puzzle_id):
    truth = KEY[puzzle_id]
    if not isinstance(response, dict):
        return {"score": 0, "ledger_exact": False, "winner_exact": False, "facts_exact": False, "ledger_ordered": False}
    le = ledger_rows_exact(response.get("candidate_ledger"), truth["before"]["ledger"])
    we = row_exact(response.get("winner"), truth["before"]["winner"])
    fe = facts_exact(response.get("source_facts"), truth["problem"]) and response.get("problem_id") == puzzle_id
    score = (50 if le else 0) + (40 if we else 0) + (10 if fe else 0)
    return {"score": score, "ledger_exact": le, "winner_exact": we, "facts_exact": fe, "ledger_ordered": ledger_ordered(response.get("candidate_ledger"))}

def score_phase2(response, puzzle_id):
    truth = KEY[puzzle_id]
    if not isinstance(response, dict):
        return {"score": 0, "ledger_exact": False, "winner_exact": False, "facts_exact": False, "removed_exact": False, "added_exact": False, "before_winner_exact": False, "after_winner_exact": False, "ledger_ordered": False}
    state = response.get("current_state") if isinstance(response.get("current_state"), dict) else {}
    patch = response.get("patch") if isinstance(response.get("patch"), dict) else {}
    le = ledger_rows_exact(state.get("candidate_ledger"), truth["after"]["ledger"])
    we = row_exact(state.get("winner"), truth["after"]["winner"])
    fe = (facts_exact(state.get("source_facts"), truth["after_facts"])
          and response.get("problem_id") == puzzle_id
          and response.get("applied_delta") == truth["delta"]
          and patch.get("changed_facts") == [{"project_id":truth["delta"]["project_id"],"availability":"unavailable"}])
    want_removed = {tuple(x) for x in truth["removed"]}
    got_removed = {tuple(sorted(x)) for x in patch.get("removed_candidates", [])} if isinstance(patch.get("removed_candidates"), list) else None
    re = got_removed == want_removed
    ae = patch.get("added_candidates") == []
    be = row_exact(patch.get("winner_before"), truth["before"]["winner"])
    afe = row_exact(patch.get("winner_after"), truth["after"]["winner"])
    score = 40*le + 30*we + 10*fe + 10*(re and ae) + 5*be + 5*afe
    return {"score": score, "ledger_exact": le, "winner_exact": we, "facts_exact": fe, "removed_exact": re, "added_exact": ae, "before_winner_exact": be, "after_winner_exact": afe, "ledger_ordered": ledger_ordered(state.get("candidate_ledger"))}

def main():
    if len(sys.argv) != 2 or sys.argv[1] == "--self-check":
        if len(sys.argv) == 2:
            for pid in ("A", "B"):
                t = KEY[pid]
                p1 = {"source_facts": t["problem"], "candidate_ledger": t["before"]["ledger"], "winner": t["before"]["winner"]}
                p2 = {"current_state":{"source_facts":t["after_facts"],"candidate_ledger":t["after"]["ledger"],"winner":t["after"]["winner"]},"patch":{"removed_candidates":t["removed"],"added_candidates":[],"winner_before":t["before"]["winner"],"winner_after":t["after"]["winner"]}}
                p1["problem_id"] = pid
                p2.update({"problem_id":pid,"applied_delta":t["delta"]})
                p2["patch"]["changed_facts"] = [{"project_id":t["delta"]["project_id"],"availability":"unavailable"}]
                assert score_phase1(p1,pid)["score"] == 100
                assert score_phase2(p2,pid)["score"] == 100
                bad = dict(p2)
                bad["current_state"] = dict(p2["current_state"], winner={"selected":[],"cost":0,"value":0})
                assert score_phase2(bad,pid)["score"] < 100
                bad_ledger = dict(p1)
                bad_ledger["candidate_ledger"] = [dict(t["before"]["ledger"][0], cost=999)] + t["before"]["ledger"][1:]
                assert score_phase1(bad_ledger,pid)["score"] < 100
            print("self-check passed: exact truth scores 100; intentionally wrong winner scores below 100")
            return
        raise SystemExit("Usage: python score.py OUTPUT_DIRECTORY | python score.py --self-check")
    out = Path(sys.argv[1])
    results = {}
    for pid in ("A", "B"):
        p = pid.lower()
        for condition in ("state", "control"):
            p1 = json_file(out / f"{p}_{condition}_phase1.json")
            p2 = json_file(out / f"{p}_{condition}_phase2.json")
            results[f"{p}_{condition}"] = {"phase1":score_phase1(p1,pid),"phase2":score_phase2(p2,pid)}
    print(json.dumps(results, indent=2))

if __name__ == "__main__":
    main()

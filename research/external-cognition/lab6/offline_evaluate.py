"""Independent offline evaluator for frozen Lab 6 runs.

This module reads the private key and independently scores frozen run responses
only after all scheduled call slots have durable outcomes.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
PRIVATE_KEY_PATH = ROOT / "private" / "case-key.json"
SEEDS = (6112, 6135, 6412, 6432, 6459, 6582)
FAMILIES = ("north",)
PROPOSERS = ("c1-proposer", "c2-proposer", "c3-proposer", "c4-proposer")
REVIEWERS = ("c1-reviewer", "c2-reviewer", "c3-reviewer", "c4-reviewer")
FINALS = ("shared-integrator", "raw-integrator")
ROLES = (*PROPOSERS, *REVIEWERS, *FINALS)


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def evaluate_frozen_run(run_dir: str | Path, key_path: str | Path = PRIVATE_KEY_PATH) -> dict[str, Any]:
    run = Path(run_dir).resolve()
    key_data = _read_json(Path(key_path).resolve())
    cases_key = key_data["cases"]

    outcomes_by_family: dict[str, list[dict[str, Any]]] = {fam: [] for fam in FAMILIES}
    summary: dict[str, Any] = {
        "schema": "lab6-evaluation-v1",
        "total_slots": len(SEEDS) * len(FAMILIES) * len(ROLES),
        "families": {},
    }

    for seed in SEEDS:
        secret = cases_key[str(seed)]
        global_sol = secret["global_solutions"][0]
        local_sols = {
            side: [list(t) for t in secret["local_solutions"][side]]
            for side in ("c1", "c2", "c3", "c4")
        }

        for fam in FAMILIES:
            slot_dir = run / "responses" / str(seed) / fam
            for role in ROLES:
                raw_file = slot_dir / f"{role}.raw"
                fail_file = slot_dir / f"{role}.failure.json"
                receipt_file = slot_dir / f"{role}.receipt.json"

                record: dict[str, Any] = {
                    "seed": seed,
                    "family": fam,
                    "role": role,
                    "has_response": raw_file.is_file(),
                    "is_failure": fail_file.is_file(),
                    "protocol_accepted": False,
                    "sound": None,
                    "complete": None,
                    "correct": None,
                }

                if fail_file.is_file():
                    record["failure"] = _read_json(fail_file)
                elif raw_file.is_file():
                    raw_bytes = raw_file.read_bytes()
                    receipt = _read_json(receipt_file) if receipt_file.is_file() else {}
                    p_receipt = receipt.get("protocol_receipt", {})
                    record["protocol_accepted"] = bool(p_receipt.get("accepted"))

                    try:
                        text = raw_bytes.decode("utf-8").strip()
                        if text.startswith("```"):
                            lines = text.splitlines()
                            if lines and lines[0].startswith("```"):
                                lines = lines[1:]
                            if lines and lines[-1].startswith("```"):
                                lines = lines[:-1]
                            text = "\n".join(lines).strip()
                        env = json.loads(text)
                    except Exception:
                        env = None

                    if env and isinstance(env, dict):
                        payload = env.get("payload", {})
                        if role in PROPOSERS:
                            side = role.split("-")[0]
                            claim = payload.get("claim", {})
                            submitted_tuples = claim.get("value", {}).get("tuples")
                            if isinstance(submitted_tuples, list) and all(isinstance(r, list) for r in submitted_tuples):
                                expected = local_sols[side]
                                is_sound = all(r in expected for r in submitted_tuples)
                                is_complete = all(r in submitted_tuples for r in expected)
                                record["sound"] = is_sound
                                record["complete"] = is_complete
                                record["submitted_count"] = len(submitted_tuples)
                                record["expected_count"] = len(expected)
                        elif role in REVIEWERS:
                            record["assessment"] = payload.get("assessment", {}).get("assessment") or payload.get("report", {}).get("assessment")
                        elif role in FINALS:
                            conclusion = payload.get("conclusion", {})
                            assignment = conclusion.get("assignment")
                            if isinstance(assignment, dict):
                                record["assignment"] = assignment
                                is_correct = (assignment == global_sol)
                                record["correct"] = is_correct

                outcomes_by_family[fam].append(record)

    # Summarize per family
    for fam in FAMILIES:
        records = outcomes_by_family[fam]
        finals = [r for r in records if r["role"] in FINALS]
        shared_finals = [r for r in finals if r["role"] == "shared-integrator"]
        raw_finals = [r for r in finals if r["role"] == "raw-integrator"]

        shared_correct = sum(1 for r in shared_finals if r.get("correct") is True)
        raw_correct = sum(1 for r in raw_finals if r.get("correct") is True)

        proposals = [r for r in records if r["role"] in PROPOSERS]
        accepted_proposals = sum(1 for r in proposals if r.get("protocol_accepted") is True)
        sound_complete_proposals = sum(1 for r in proposals if r.get("sound") is True and r.get("complete") is True)

        summary["families"][fam] = {
            "total_slots": len(records),
            "responses": sum(1 for r in records if r["has_response"]),
            "failures": sum(1 for r in records if r["is_failure"]),
            "shared_solution_correct": shared_correct,
            "raw_solution_correct": raw_correct,
            "shared_success_rate": f"{shared_correct}/{len(shared_finals)}",
            "raw_success_rate": f"{raw_correct}/{len(raw_finals)}",
            "proposals_accepted": f"{accepted_proposals}/{len(proposals)}",
            "proposals_sound_and_complete": f"{sound_complete_proposals}/{len(proposals)}",
            "records": records,
        }

    return summary

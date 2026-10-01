"""Frozen, provider-neutral Lab 4 affine pilot adapter.

This module constructs participant-visible packets and prompts, retains each raw
response before parsing, sends the response bytes through the structural protocol,
and scores the saved outcomes offline. It deliberately contains no oracle-assisted
submission path.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import itertools
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import protocol

SEEDS = (4201, 4202)
MODULUS = 11
ROLES = (
    "u-proposer", "v-proposer", "u-reviewer", "v-reviewer",
    "shared-integrator", "raw-integrator",
)
COORDS = {"u-proposer": "u", "v-proposer": "v"}
REVIEWED_COORD = {"u-reviewer": "v", "v-reviewer": "u"}
SCHEMA = "lab4-affine-pilot-v1"


class PilotError(ValueError):
    """A frozen-run or pilot-stage error."""


def _lab3_module():
    source = Path(__file__).resolve().parents[1] / "lab3" / "experiment.py"
    if not source.is_file():
        raise PilotError(f"Lab 3 generator is missing: {source}")
    spec = importlib.util.spec_from_file_location("lab3_experiment_for_lab4", source)
    if spec is None or spec.loader is None:
        raise PilotError("could not load the Lab 3 case generator")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _ground_truth(seed: int) -> dict[str, Any]:
    if seed not in SEEDS:
        raise PilotError(f"unknown seed: {seed}")
    return _lab3_module().make_case(seed)


def public_problem(seed: int) -> dict[str, Any]:
    """Return the complete participant-visible problem and no evaluator fields."""
    case = _ground_truth(seed)
    problem_id = f"affine-{seed}"
    observations = [
        {"observation_id": f"observation-{i}", "xy": row["xy"], "uv": row["uv"]}
        for i, row in enumerate(case["observations"], 1)
    ]
    return {
        "problem_id": problem_id,
        "modulus": MODULUS,
        "observations": observations,
        "affine_family": "u=(a*x+b*y+c) mod 11; v=(d*x+e*y+f) mod 11",
        "target_uv": case["target"]["uv"],
        "answer_requirements": {
            "status_solved": {"status": "solved", "x": "integer residue 0..10", "y": "integer residue 0..10"},
            "status_underdetermined": {"status": "underdetermined"},
            "instruction": "Infer the two affine relations, then solve for the unique target input (x,y) modulo 11.",
        },
    }


def _json_text(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n"


def _sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def _run_dir(path: str | Path) -> Path:
    run = Path(path).resolve()
    if not (run / "run.json").is_file():
        raise PilotError(f"not a prepared Lab 4 run: {run}")
    return run


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PilotError(f"cannot read JSON file {path}: {exc}") from exc


def _save_immutable(path: Path, raw: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        if path.read_bytes() != raw:
            raise PilotError(f"frozen artifact differs; refusing overwrite: {path}")
        return
    with path.open("xb") as stream:
        stream.write(raw)


def _record_prompt_hash(run: Path, seed: int, role: str, raw: bytes) -> None:
    path = run / "prompt_hashes.json"
    rows = _read_json(path) if path.exists() else {}
    key = f"{seed}/{role}"
    digest = _sha(raw)
    if key in rows and rows[key] != digest:
        raise PilotError(f"prompt hash conflict for {key}")
    rows[key] = digest
    temp = path.with_suffix(".json.tmp")
    temp.write_text(_json_text(rows), encoding="utf-8")
    temp.replace(path)


def _save_prompt(run: Path, seed: int, role: str, prompt: str) -> Path:
    raw = (prompt.rstrip() + "\n").encode("utf-8", errors="strict")
    path = run / "prompts" / str(seed) / f"{role}.txt"
    _save_immutable(path, raw)
    _record_prompt_hash(run, seed, role, raw)
    return path


def _participants() -> list[str]:
    return list(ROLES)


def _schedule() -> list[dict[str, Any]]:
    schedule = []
    for seed in SEEDS:
        sid = str(seed)
        schedule.extend([
            {"seed": seed, "phase": "propose", "parallel_group": f"{sid}-proposers", "role": "u-proposer"},
            {"seed": seed, "phase": "propose", "parallel_group": f"{sid}-proposers", "role": "v-proposer"},
            {"seed": seed, "phase": "review", "parallel_group": f"{sid}-reviewers", "role": "u-reviewer"},
            {"seed": seed, "phase": "review", "parallel_group": f"{sid}-reviewers", "role": "v-reviewer"},
            {"seed": seed, "phase": "integrate", "parallel_group": f"{sid}-integrators", "role": "shared-integrator"},
            {"seed": seed, "phase": "integrate", "parallel_group": f"{sid}-integrators", "role": "raw-integrator"},
        ])
    return schedule


def prepare(out_dir: str | Path) -> dict[str, Any]:
    """Create the immutable public cases, databases, run manifest and proposer prompts."""
    run = Path(out_dir).resolve()
    if (run / "run.json").exists():
        raise PilotError(f"run already exists: {run}")
    run.mkdir(parents=True, exist_ok=True)
    problem_hashes: dict[str, str] = {}
    for seed in SEEDS:
        case_dir = run / "cases" / str(seed)
        case_dir.mkdir(parents=True, exist_ok=True)
        packet = public_problem(seed)
        packet_raw = (_json_text(packet)).encode("utf-8")
        _save_immutable(case_dir / "problem.json", packet_raw)
        problem_hashes[str(seed)] = _sha(packet_raw)
        protocol.initialize_store(
            case_dir / "store.sqlite", packet["problem_id"], _participants(), packet,
        )
    manifest: dict[str, Any] = {
        "schema": SCHEMA,
        "planned_calls": 12,
        "call_ceiling": 12,
        "seeds": list(SEEDS),
        "route": {"provider": "native", "model": "Luna", "effort": "low"},
        "schedule": _schedule(),
        "problem_hashes": problem_hashes,
        "source_hashes": {
            "pilot.py": _sha(Path(__file__).read_bytes()),
            "protocol.py": _sha(Path(protocol.__file__).read_bytes()),
            "lab3/experiment.py": _sha((Path(__file__).resolve().parents[1] / "lab3" / "experiment.py").read_bytes()),
        },
        "frozen_policy": {
            "envelope_schema_version": 1,
            "participants_per_case": list(ROLES),
            "prompt_templates": {
                "revision": 1,
                "proposer": "Complete public problem + assigned coordinate + fixed PROPOSE envelope; replace only three coefficient integers.",
                "reviewer": "Complete public problem + cross-assigned accepted proposal when available + fixed CHALLENGE and REPORT_EVIDENCE envelopes; reviewer supplies assessment/basis references and may retain a candidate correction.",
                "final": "Same public problem and final solve instructions for both conditions; shared condition adds projection; raw condition has problem-only refs.",
            },
            "read_refs": {
                "proposer": "problem 1/1 and own claim absence 0/0",
                "reviewer": "problem 1/1 and assigned peer claim current exact value/state revisions when present",
                "shared_integrator": "problem 1/1 and every current claim exact value/state revision",
                "raw_integrator": "problem 1/1 only",
            },
            "u_reviewer_receives": "v-relation",
            "v_reviewer_receives": "u-relation",
            "proposer_recipients": ["assigned-cross-reviewer", "shared-integrator"],
            "reviewer_recipient": "shared-integrator",
            "final_shared_reads": "problem plus current claims and exact value/lifecycle revisions",
            "final_raw_reads": "problem only",
            "prompt_materialization": "immutable; phase prompts are saved before their participant call",
            "raw_response_policy": "save exact bytes before structural parsing; no retries or semantic feedback",
            "evaluator_policy": "offline after all twelve call slots are completed or recorded failed",
            "evaluation": "claims are checked against all public observations; target answers are scored after submission by brute-force enumeration of all 121 coordinate pairs modulo 11",
            "rejection_policy": "retain rejected raw bytes and fixed protocol receipt; no automatic repair or resubmission",
        },
    }
    # The prompt content itself is captured and hashed; policy text is also fixed in
    # the run manifest before any participant output exists.
    manifest["manifest_hash"] = _sha(protocol.canonical_bytes(manifest))
    _save_immutable(run / "run.json", (_json_text(manifest)).encode("utf-8"))
    _save_immutable(run / "prompt_hashes.json", b"{}\n")
    for seed in SEEDS:
        role_prompt(run, seed, "u-proposer")
        role_prompt(run, seed, "v-proposer")
    return manifest


def _case_dir(run: Path, seed: int) -> Path:
    if seed not in SEEDS:
        raise PilotError(f"unknown seed: {seed}")
    return run / "cases" / str(seed)


def _problem_ref(problem_id: str) -> dict[str, Any]:
    return {"resource_id": f"problem:{problem_id}", "revision": 1, "state_revision": 1}


def _claim_ref(claim_id: str, claim: dict[str, Any]) -> dict[str, Any]:
    return {"resource_id": f"claim:{claim_id}", "revision": claim["revision"], "state_revision": claim["state_revision"]}


def _role_message_id(problem_id: str, role: str) -> str:
    if role in COORDS:
        return f"{problem_id}-{COORDS[role]}-proposal"
    if role in REVIEWED_COORD:
        return f"{problem_id}-{role}-report"
    return f"{problem_id}-{role}-conclusion"


def _common_task(problem: dict[str, Any]) -> str:
    return (
        "This is the complete public problem packet. Every participant receives the same raw observations and target image. "
        "All arithmetic is modulo 11. The declared family is u=(a*x+b*y+c) mod 11 and v=(d*x+e*y+f) mod 11.\n\n"
        "PUBLIC PROBLEM (immutable):\n" + _json_text(problem) +
        "\nReturn exactly one JSON envelope using the supplied schema and references. Do not add prose outside the JSON.\n"
    )


def _envelope_template(problem_id: str, message_id: str, sender: str, recipients: list[str], intent: str,
                       read_refs: list[dict[str, Any]], payload: dict[str, Any], reply_to: str | None = None) -> dict[str, Any]:
    return {
        "schema_version": 1, "problem_id": problem_id, "message_id": message_id,
        "sender": sender, "recipients": recipients, "intent": intent,
        "read_refs": read_refs, "payload": payload, "reply_to": reply_to,
    }


def _proposer_prompt(run: Path, seed: int, role: str) -> str:
    problem = _read_json(_case_dir(run, seed) / "problem.json")
    problem_id = problem["problem_id"]
    coord = COORDS[role]
    claim_id = f"{coord}-relation"
    reviewer = "v-reviewer" if coord == "u" else "u-reviewer"
    message_id = _role_message_id(problem_id, role)
    refs = [_problem_ref(problem_id), {"resource_id": f"claim:{claim_id}", "revision": 0, "state_revision": 0}]
    claim = {
        "claim_id": claim_id, "revision": 1, "state_revision": 1, "status": "active",
        "value": {"coefficients": [0, 0, 0]},
        "provenance": {"message_id": message_id},
        "dependencies": [{"resource_id": f"problem:{problem_id}", "claim_revision": 1}],
    }
    env = _envelope_template(problem_id, message_id, role, [reviewer, "shared-integrator"], "PROPOSE", refs, {"claim": claim})
    return (
        _common_task(problem) + f"Your assigned relation is {coord}. Solve only its three coefficients from all three observations.\n"
        "Copy this envelope exactly. Edit only the three integer entries in payload.claim.value.coefficients; "
        "each must be a residue from 0 through 10. Keep every ID, reference, recipient, revision, and other field unchanged.\n\n"
        + _json_text(env)
    )


def _submission_paths(run: Path, seed: int, role: str) -> tuple[Path, Path, Path]:
    return (
        run / "responses" / str(seed) / f"{role}.raw",
        run / "responses" / str(seed) / f"{role}.failure.json",
        run / "prompts" / str(seed) / f"{role}.txt",
    )


def _outcome_saved(run: Path, seed: int, role: str) -> bool:
    raw, failure, _ = _submission_paths(run, seed, role)
    return raw.exists() or failure.exists()


def _all_outcomes_saved(run: Path, seed: int, roles: tuple[str, ...]) -> bool:
    return all(_outcome_saved(run, seed, role) for role in roles)


def _proposal_for_reviewer(db: Path, problem_id: str, reviewer: str) -> dict[str, Any] | None:
    target = f"{REVIEWED_COORD[reviewer]}-relation"
    for event in protocol.inbox(db, problem_id, reviewer):
        if event["intent"] == "PROPOSE" and event["payload"].get("claim", {}).get("claim_id") == target:
            return event
    return None


def _reviewer_prompt(run: Path, seed: int, role: str) -> str:
    if not _all_outcomes_saved(run, seed, ("u-proposer", "v-proposer")):
        raise PilotError("review prompts are available after both proposer call slots are saved")
    problem = _read_json(_case_dir(run, seed) / "problem.json")
    problem_id = problem["problem_id"]
    coord = REVIEWED_COORD[role]
    claim_id = f"{coord}-relation"
    db = _case_dir(run, seed) / "store.sqlite"
    proposal = _proposal_for_reviewer(db, problem_id, role)
    lines = [_common_task(problem), f"You are {role}; independently review the peer claim for coordinate {coord}.\n"]
    refs = [_problem_ref(problem_id)]
    target_ref = None
    proposal_id = None
    if proposal is None:
        lines.append(
            "No structurally accepted peer claim is available in your directed mailbox. The proposer call may have failed "
            "or been rejected. Use REPORT_EVIDENCE with no corrected_claim to report evidence from the full observations; "
            "do not invent a target claim or read reference.\n"
        )
    else:
        peer_claim = proposal["payload"]["claim"]
        proposal_id = proposal["message_id"]
        projected = protocol.get_projection(db, problem_id)["claims"].get(claim_id)
        if projected is None:
            raise PilotError("directed proposal is missing from current projection")
        target_ref = _claim_ref(claim_id, projected)
        refs.append(target_ref)
        lines.append(
            "Assigned peer proposal (read this exact value and state revision):\n" + _json_text(peer_claim) + "\n"
            "Assess the proposed coefficients against the complete public observations. Use observation IDs as basis_refs. "
            "Return either one CHALLENGE envelope with assessment, or one REPORT_EVIDENCE envelope with report.assessment. "
            "assessment is one of supported, challenge, underdetermined. A corrected_claim is optional; if supplied it "
            "must have status candidate and remains an uncommitted proposal. Never state that a structurally recorded claim "
            "has been chosen automatically.\n"
        )
    common_payload = {
        "assessment": "supported|challenge|underdetermined",
        "basis_refs": ["observation-1", "observation-2", "observation-3"],
    }
    corrected_claim = {
        "claim_id": claim_id, "revision": 1, "state_revision": 1, "status": "candidate",
        "value": {"coefficients": [0, 0, 0]},
        "provenance": {"message_id": _role_message_id(problem_id, role)},
        "dependencies": [{"resource_id": f"problem:{problem_id}", "claim_revision": 1}],
    }
    if proposal is None:
        report_payload = {**common_payload, "target": _problem_ref(problem_id)}
        report_env = _envelope_template(problem_id, _role_message_id(problem_id, role), role,
            ["shared-integrator"], "REPORT_EVIDENCE", refs, {"report": report_payload})
        lines.append("Copy this exact envelope and fill assessment/basis_refs from your review; leave other fields unchanged.\n\n")
        lines.append(_json_text(report_env))
    else:
        assert target_ref is not None and proposal_id is not None
        challenge_payload = {"target": target_ref, "assessment": common_payload, "corrected_claim": corrected_claim}
        report_payload = {"report": {**common_payload, "target": target_ref}, "corrected_claim": corrected_claim}
        challenge_env = _envelope_template(problem_id, _role_message_id(problem_id, role), role,
            ["shared-integrator"], "CHALLENGE", refs, challenge_payload, proposal_id)
        report_env = _envelope_template(problem_id, _role_message_id(problem_id, role), role,
            ["shared-integrator"], "REPORT_EVIDENCE", refs, report_payload, proposal_id)
        lines.append(
            "Copy exactly one envelope below. Use CHALLENGE only to record an objection; use REPORT_EVIDENCE for a "
            "supported or underdetermined review. If you use a corrected_claim, edit only its three coefficients and keep "
            "status=candidate; otherwise remove the corrected_claim field. Edit assessment and basis_refs to reflect your "
            "evidence, then copy every other field exactly.\n\n"
            "CHALLENGE template:\n" + _json_text(challenge_env) + "\n"
            "REPORT_EVIDENCE template:\n" + _json_text(report_env)
        )
    return "".join(lines)


def role_prompt(run_dir: str | Path, case_seed: int, role: str) -> Path:
    """Return the exact immutable prompt file for a scheduled role."""
    run = _run_dir(run_dir)
    if role not in ROLES:
        raise PilotError(f"unknown role: {role}")
    _case_dir(run, case_seed)
    if role in COORDS:
        prompt = _proposer_prompt(run, case_seed, role)
    elif role in REVIEWED_COORD:
        prompt = _reviewer_prompt(run, case_seed, role)
    elif role in ("shared-integrator", "raw-integrator"):
        if not _all_outcomes_saved(run, case_seed, ("u-proposer", "v-proposer", "u-reviewer", "v-reviewer")):
            raise PilotError("final prompts are available after both reviewer call slots are saved")
        paths = final_prompts(run, case_seed)
        return paths[role]
    else:  # pragma: no cover - role membership checked above
        raise PilotError(f"unsupported role: {role}")
    return _save_prompt(run, case_seed, role, prompt)


def final_prompts(run_dir: str | Path, case_seed: int) -> dict[str, Path]:
    """Freeze both final prompts at the post-review snapshot."""
    run = _run_dir(run_dir)
    _case_dir(run, case_seed)
    if not _all_outcomes_saved(run, case_seed, ("u-proposer", "v-proposer", "u-reviewer", "v-reviewer")):
        raise PilotError("final prompts are available after both reviewer call slots are saved")
    problem = _read_json(_case_dir(run, case_seed) / "problem.json")
    problem_id = problem["problem_id"]
    db = _case_dir(run, case_seed) / "store.sqlite"
    projection = protocol.get_projection(db, problem_id)
    refs = [_problem_ref(problem_id)]
    for claim_id, claim in sorted(projection["claims"].items()):
        refs.append(_claim_ref(claim_id, claim))
    shared_message = _role_message_id(problem_id, "shared-integrator")
    raw_message = _role_message_id(problem_id, "raw-integrator")
    shared_env = _envelope_template(problem_id, shared_message, "shared-integrator", ["shared-integrator"], "CONCLUDE", refs,
        {"conclusion": {"status": "solved", "x": 0, "y": 0}})
    raw_env = _envelope_template(problem_id, raw_message, "raw-integrator", ["shared-integrator"], "CONCLUDE", [_problem_ref(problem_id)],
        {"conclusion": {"status": "solved", "x": 0, "y": 0}})
    final_instructions = (
        "FINAL ANSWER TASK (identical instructions for both conditions): infer the two affine relations from the public "
        "observations and solve for the unique target input (x,y) modulo 11. Return exactly one conclusion using either "
        "{\"status\":\"solved\",\"x\":integer residue 0..10,\"y\":integer residue 0..10} or "
        "{\"status\":\"underdetermined\"}. No prose outside the envelope.\n"
        "The template shows a solved example. If the answer is underdetermined, replace the entire conclusion object with "
        "exactly {\"status\":\"underdetermined\"} and omit x and y. Otherwise replace only the x and y integers. "
        "Copy every other envelope field exactly.\n\n"
    )
    shared_prompt = (
        _common_task(problem) + final_instructions + "CONDITION-SPECIFIC SHARED STATE: you are a fresh shared-integrator. "
        "Inspect the committed workspace as recorded evidence. The store does not decide which claim or candidate is correct.\n\n"
        "CURRENT SHARED WORKSPACE (operational state; candidate corrections are not promoted):\n"
        + _json_text(projection) + "\nCopy this exact envelope and edit only the conclusion answer values.\n\n" + _json_text(shared_env)
    )
    raw_prompt = (
        _common_task(problem) + final_instructions + "CONDITION-SPECIFIC RAW ACCESS: you are a fresh raw-integrator. Use the public observations directly.\n\n"
        "Copy this exact envelope and edit only the conclusion answer values.\n\n" + _json_text(raw_env)
    )
    return {
        "shared-integrator": _save_prompt(run, case_seed, "shared-integrator", shared_prompt),
        "raw-integrator": _save_prompt(run, case_seed, "raw-integrator", raw_prompt),
    }


def _write_new(path: Path, raw: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as stream:
        stream.write(raw)


def _expected_read_refs(run: Path, seed: int, role: str) -> list[dict[str, Any]]:
    problem = _read_json(_case_dir(run, seed) / "problem.json")
    problem_id = problem["problem_id"]
    refs = [_problem_ref(problem_id)]
    db = _case_dir(run, seed) / "store.sqlite"
    if role in COORDS:
        claim_id = f"{COORDS[role]}-relation"
        refs.append({"resource_id": f"claim:{claim_id}", "revision": 0, "state_revision": 0})
    elif role in REVIEWED_COORD:
        event = _proposal_for_reviewer(db, problem_id, role)
        if event is not None:
            claim_id = f"{REVIEWED_COORD[role]}-relation"
            current = protocol.get_projection(db, problem_id)["claims"].get(claim_id)
            if current is not None:
                refs.append(_claim_ref(claim_id, current))
    elif role == "shared-integrator":
        projection = protocol.get_projection(db, problem_id)
        refs.extend(_claim_ref(cid, claim) for cid, claim in sorted(projection["claims"].items()))
    return refs


def _same_access_scope(actual: Any, expected: list[dict[str, Any]], *, require_absent_claim: bool = False) -> bool:
    if type(actual) is not list or [row.get("resource_id") for row in actual if type(row) is dict] != [row["resource_id"] for row in expected]:
        return False
    by_id = {row["resource_id"]: row for row in actual}
    if by_id.get(expected[0]["resource_id"]) != expected[0]:
        return False
    if require_absent_claim and len(expected) == 2 and by_id.get(expected[1]["resource_id"]) != expected[1]:
        return False
    return True


def _role_header_mismatch(run: Path, seed: int, role: str, env: dict[str, Any]) -> bool:
    problem = _read_json(_case_dir(run, seed) / "problem.json")
    problem_id = problem["problem_id"]
    expected_recipients = {
        "u-proposer": ["v-reviewer", "shared-integrator"],
        "v-proposer": ["u-reviewer", "shared-integrator"],
        "u-reviewer": ["shared-integrator"],
        "v-reviewer": ["shared-integrator"],
        "shared-integrator": ["shared-integrator"],
        "raw-integrator": ["shared-integrator"],
    }[role]
    expected_intents = {
        "u-proposer": {"PROPOSE"}, "v-proposer": {"PROPOSE"},
        "u-reviewer": {"CHALLENGE", "REPORT_EVIDENCE"},
        "v-reviewer": {"CHALLENGE", "REPORT_EVIDENCE"},
        "shared-integrator": {"CONCLUDE"}, "raw-integrator": {"CONCLUDE"},
    }[role]
    expected_refs = _expected_read_refs(run, seed, role)
    if (env.get("problem_id") != problem_id or env.get("sender") != role
            or env.get("message_id") != _role_message_id(problem_id, role)
            or env.get("recipients") != expected_recipients or env.get("intent") not in expected_intents
            or not _same_access_scope(env.get("read_refs"), expected_refs, require_absent_claim=role in COORDS)):
        return True
    if role in COORDS:
        claim_id = f"{COORDS[role]}-relation"
        claim = env.get("payload", {}).get("claim", {})
        return (type(claim) is not dict or claim.get("claim_id") != claim_id
                or claim.get("provenance", {}).get("message_id") != env.get("message_id"))
    if role in REVIEWED_COORD:
        claim_id = f"{REVIEWED_COORD[role]}-relation"
        peer = _proposal_for_reviewer(_case_dir(run, seed) / "store.sqlite", problem_id, role)
        expected_reply = peer["message_id"] if peer else None
        if env.get("reply_to") != expected_reply:
            return True
        payload = env.get("payload", {})
        claim_ref = next((ref for ref in env["read_refs"] if ref["resource_id"] == f"claim:{claim_id}"), None)
        if peer:
            if claim_ref is None:
                return True
            if env["intent"] == "CHALLENGE":
                if payload.get("target") != claim_ref:
                    return True
            elif payload.get("report", {}).get("target") != claim_ref:
                return True
        else:
            if env["intent"] != "REPORT_EVIDENCE" or payload.get("report", {}).get("target") != _problem_ref(problem_id):
                return True
        corrected = payload.get("corrected_claim")
        if corrected is not None:
            deps = corrected.get("dependencies", []) if type(corrected) is dict else []
            if (type(corrected) is not dict or corrected.get("claim_id") != claim_id
                    or corrected.get("provenance", {}).get("message_id") != env.get("message_id")
                    or {"resource_id": f"problem:{problem_id}", "claim_revision": 1} not in deps):
                return True
    return False


def submit_response(run_dir: str | Path, case_seed: int, role: str, raw_bytes: bytes,
                    metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    """Save exact response bytes first, then let the protocol parse/submit them."""
    run = _run_dir(run_dir)
    _case_dir(run, case_seed)
    if role not in ROLES:
        raise PilotError(f"unknown role: {role}")
    raw_path, failure_path, prompt_path = _submission_paths(run, case_seed, role)
    if not prompt_path.is_file():
        raise PilotError(f"the frozen prompt must exist before submission: {prompt_path}")
    if raw_path.exists() or failure_path.exists():
        raise PilotError(f"the scheduled call slot is already recorded: {case_seed}/{role}")
    raw = bytes(raw_bytes)
    # This write intentionally precedes protocol parsing; malformed bytes stay auditable.
    _write_new(raw_path, raw)
    problem = _read_json(_case_dir(run, case_seed) / "problem.json")
    db = _case_dir(run, case_seed) / "store.sqlite"
    try:
        parsed = protocol.parse_envelope(raw)
    except (protocol.ProtocolError, TypeError, ValueError):
        receipt = protocol.submit(db, raw)
    else:
        if _role_header_mismatch(run, case_seed, role, parsed):
            receipt = protocol.record_rejection(db, raw, code="ROLE_MISMATCH", parsed=parsed)
        else:
            receipt = protocol.submit(db, raw)
    hashes = _read_json(run / "prompt_hashes.json")
    call_metadata = {
        "seed": case_seed,
        "role": role,
        "provider": "native",
        "model": "Luna",
        "effort": "low",
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "prompt_sha256": hashes[f"{case_seed}/{role}"],
        "raw_sha256": _sha(raw),
    }
    if metadata:
        call_metadata.update(metadata)
    _write_new(run / "receipts" / str(case_seed) / f"{role}.json", (_json_text(receipt)).encode("utf-8"))
    _write_new(run / "call_metadata" / str(case_seed) / f"{role}.json", (_json_text(call_metadata)).encode("utf-8"))
    return receipt


def record_failure(run_dir: str | Path, case_seed: int, role: str, reason: str,
                   metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    """Record a failed scheduled call without retrying or inventing a protocol message."""
    run = _run_dir(run_dir)
    _case_dir(run, case_seed)
    if role not in ROLES:
        raise PilotError(f"unknown role: {role}")
    raw_path, failure_path, prompt_path = _submission_paths(run, case_seed, role)
    if not prompt_path.is_file():
        raise PilotError(f"the frozen prompt must exist before recording failure: {prompt_path}")
    if raw_path.exists() or failure_path.exists():
        raise PilotError(f"the scheduled call slot is already recorded: {case_seed}/{role}")
    record = {"seed": case_seed, "role": role, "failed": True, "reason": reason,
        "captured_at": datetime.now(timezone.utc).isoformat()}
    if metadata:
        record.update(metadata)
    _write_new(failure_path, (_json_text(record)).encode("utf-8"))
    hashes = _read_json(run / "prompt_hashes.json")
    call_metadata = {"seed": case_seed, "role": role, "provider": "native", "model": "Luna", "effort": "low",
        "captured_at": record["captured_at"], "prompt_sha256": hashes[f"{case_seed}/{role}"], "raw_sha256": None,
        "failure": reason}
    if metadata:
        call_metadata.update(metadata)
    _write_new(run / "call_metadata" / str(case_seed) / f"{role}.json", (_json_text(call_metadata)).encode("utf-8"))
    return record


def _role_submission(run: Path, seed: int, role: str) -> tuple[bytes | None, dict[str, Any] | None]:
    raw_path, failure_path, _ = _submission_paths(run, seed, role)
    if raw_path.exists():
        return raw_path.read_bytes(), None
    if failure_path.exists():
        return None, _read_json(failure_path)
    return None, None


def _parse_role_response(run: Path, seed: int, role: str) -> tuple[dict[str, Any] | None, str | None]:
    raw, failure = _role_submission(run, seed, role)
    if failure is not None:
        return None, "MODEL_FAILURE"
    if raw is None:
        return None, "MISSING"
    try:
        return protocol.parse_envelope(raw), None
    except (protocol.ProtocolError, TypeError, ValueError):
        return None, "INVALID_JSON_OR_SCHEMA"


def _coefficients(env: dict[str, Any] | None, intent_payload: tuple[str, ...]) -> list[int] | None:
    if env is None:
        return None
    payload: Any = env.get("payload")
    for key in intent_payload:
        if type(payload) is not dict:
            return None
        payload = payload.get(key)
    if type(payload) is not dict:
        return None
    coeffs = payload.get("coefficients")
    if type(coeffs) is list and len(coeffs) == 3 and all(type(c) is int and 0 <= c < MODULUS for c in coeffs):
        return coeffs
    return None


def _fits_relation(coord: str, coefficients: list[int], observations: list[dict[str, Any]]) -> bool:
    a, b, c = coefficients
    position = 0 if coord == "u" else 1
    return all((a * row["xy"][0] + b * row["xy"][1] + c) % MODULUS == row["uv"][position] for row in observations)


def _solutions(u: list[int] | None, v: list[int] | None, target: list[int]) -> list[list[int]]:
    if u is None or v is None:
        return []
    result = []
    for x, y in itertools.product(range(MODULUS), repeat=2):
        if (u[0] * x + u[1] * y + u[2]) % MODULUS == target[0] and (v[0] * x + v[1] * y + v[2]) % MODULUS == target[1]:
            result.append([x, y])
    return result


def _answer(env: dict[str, Any] | None) -> dict[str, Any]:
    if env is None or env.get("intent") != "CONCLUDE":
        return {"structurally_parseable": env is not None, "schema_valid": False, "status": None, "answer": None}
    conclusion = env.get("payload", {}).get("conclusion")
    if type(conclusion) is not dict:
        return {"structurally_parseable": True, "schema_valid": False, "status": None, "answer": None}
    status = conclusion.get("status")
    if status == "underdetermined" and set(conclusion) == {"status"}:
        return {"structurally_parseable": True, "schema_valid": True, "status": status, "answer": None}
    if (status == "solved" and set(conclusion) == {"status", "x", "y"}
            and type(conclusion.get("x")) is int and type(conclusion.get("y")) is int
            and 0 <= conclusion["x"] < MODULUS and 0 <= conclusion["y"] < MODULUS):
        return {"structurally_parseable": True, "schema_valid": True, "status": status,
            "answer": [conclusion["x"], conclusion["y"]]}
    return {"structurally_parseable": True, "schema_valid": False, "status": status, "answer": None}


def evaluate(run_dir: str | Path) -> dict[str, Any]:
    """Score only after every frozen call slot has a raw output or failure record."""
    run = _run_dir(run_dir)
    for seed in SEEDS:
        missing = [role for role in ROLES if not _outcome_saved(run, seed, role)]
        if missing:
            raise PilotError(f"offline evaluation requires all call slots for seed {seed}; missing: {', '.join(missing)}")
        for role in ("shared-integrator", "raw-integrator"):
            _, _, prompt_path = _submission_paths(run, seed, role)
            if not prompt_path.is_file():
                raise PilotError(f"final prompts were not frozen for seed {seed}")
    results: dict[str, Any] = {}
    for seed in SEEDS:
        packet = _read_json(_case_dir(run, seed) / "problem.json")
        truth = _ground_truth(seed)
        relation_truth = truth["relation"]
        target_xy = truth["target"]["xy"]
        db = _case_dir(run, seed) / "store.sqlite"
        projection = protocol.get_projection(db, packet["problem_id"])
        role_envs = {role: _parse_role_response(run, seed, role)[0] for role in ROLES}
        proposal_results = {}
        for coord in ("u", "v"):
            role = f"{coord}-proposer"
            env = role_envs[role]
            coeffs = _coefficients(env, ("claim", "value"))
            receipt_path = run / "receipts" / str(seed) / f"{role}.json"
            receipt = _read_json(receipt_path) if receipt_path.is_file() else None
            claim_identity_matches = bool(env and env.get("payload", {}).get("claim", {}).get("claim_id") == f"{coord}-relation")
            role_binding = bool(env and env.get("sender") == role and env.get("problem_id") == packet["problem_id"]
                and env.get("message_id") == _role_message_id(packet["problem_id"], role)
                and env.get("intent") == "PROPOSE" and claim_identity_matches)
            protocol_valid = bool(role_binding and receipt and receipt.get("accepted"))
            proposal_results[coord] = {
                "structurally_parseable": env is not None,
                "coefficients": coeffs,
                "relation_matches_public_observations": None if coeffs is None else _fits_relation(coord, coeffs, packet["observations"]),
                "coefficients_match_generated_world": None if coeffs is None else coeffs == relation_truth[coord],
                "claim_identity_matches_scheduled_role": claim_identity_matches,
                "message_id_matches_scheduled_role": bool(env and env.get("message_id") == _role_message_id(packet["problem_id"], role)),
                "sender_matches_scheduled_role": bool(env and env.get("sender") == role),
                "accepted_by_store": bool(receipt and receipt.get("accepted")),
                "protocol_valid": protocol_valid,
                "accepted_claim_relation_matches_observations": protocol_valid and coeffs is not None and _fits_relation(coord, coeffs, packet["observations"]),
                "core_receipt": receipt,
            }
        for coord in ("u", "v"):
            role = f"{coord}-proposer"
            env = role_envs[role]
            if env is not None:
                claim = env.get("payload", {}).get("claim", {})
                value = claim.get("value", {}) if type(claim) is dict else {}
                coefficients = value.get("coefficients") if type(value) is dict else None
                if (type(coefficients) is list and len(coefficients) == 3
                        and all(type(c) is int and 0 <= c < MODULUS for c in coefficients)):
                    proposal_results[coord]["claim_relation_match"] = _fits_relation(coord, coefficients, packet["observations"])
        candidates = []
        for row in projection.get("candidates", []):
            claim = row.get("claim", {})
            claim_id = claim.get("claim_id")
            coord = claim_id[0] if type(claim_id) is str and claim_id[:1] in ("u", "v") else None
            coeffs = claim.get("value", {}).get("coefficients") if type(claim.get("value")) is dict else None
            valid = coord in ("u", "v") and type(coeffs) is list and len(coeffs) == 3 and all(type(c) is int and 0 <= c < MODULUS for c in coeffs)
            candidates.append({
                "message_id": row.get("message_id"), "claim_id": claim_id,
                "coefficients": coeffs if valid else None,
                "matches_public_observations": _fits_relation(coord, coeffs, packet["observations"]) if valid else None,
                "matches_generated_world": coeffs == relation_truth[coord] if valid else None,
                "status": claim.get("status"),
            })
        conditions = {}
        for role in ("shared-integrator", "raw-integrator"):
            env = role_envs[role]
            scored = _answer(env)
            answer = scored["answer"]
            receipt_path = run / "receipts" / str(seed) / f"{role}.json"
            receipt = _read_json(receipt_path) if receipt_path.is_file() else None
            sender_matches = bool(env and env.get("sender") == role)
            problem_matches = bool(env and env.get("problem_id") == packet["problem_id"])
            message_id_matches = bool(env and env.get("message_id") == _role_message_id(packet["problem_id"], role))
            intent_matches = bool(env and env.get("intent") == "CONCLUDE")
            scored["raw_answer_matches_true_target"] = answer == target_xy if answer is not None else False
            scored["accepted_by_store"] = bool(receipt and receipt.get("accepted"))
            scored["sender_matches_scheduled_role"] = sender_matches
            scored["problem_id_matches_case"] = problem_matches
            scored["message_id_matches_scheduled_role"] = message_id_matches
            scored["intent_matches_scheduled_role"] = intent_matches
            scored["protocol_valid"] = bool(scored["schema_valid"] and scored["accepted_by_store"] and sender_matches
                and problem_matches and message_id_matches and intent_matches)
            scored["true_world_correct"] = bool(scored["protocol_valid"] and answer == target_xy)
            scored["true_target_xy"] = target_xy
            scored["core_receipt"] = receipt
            conditions[role] = scored
        u = proposal_results["u"]["coefficients"]
        v = proposal_results["v"]["coefficients"]
        conditions["enumerated_from_submitted_relations"] = {
            "solution_set": _solutions(u, v, packet["target_uv"]),
            "solution_count": len(_solutions(u, v, packet["target_uv"])),
        }
        reviewer_results = []
        for role in ("u-reviewer", "v-reviewer"):
            env = role_envs[role]
            report_payload = {}
            if env is not None:
                payload = env.get("payload", {})
                report_payload = payload.get("assessment", {}) if env.get("intent") == "CHALLENGE" else payload.get("report", {})
            receipt_path = run / "receipts" / str(seed) / f"{role}.json"
            reviewer_results.append({
                "role": role,
                "structurally_parseable": env is not None,
                "intent": env.get("intent") if env else None,
                "assessment": report_payload.get("assessment") if type(report_payload) is dict else None,
                "basis_refs": report_payload.get("basis_refs") if type(report_payload) is dict else None,
                "has_corrected_candidate": bool(env and "corrected_claim" in env.get("payload", {})),
                "sender_matches_scheduled_role": bool(env and env.get("sender") == role),
                "message_id_matches_scheduled_role": bool(env and env.get("message_id") == _role_message_id(packet["problem_id"], role)),
                "problem_id_matches_case": bool(env and env.get("problem_id") == packet["problem_id"]),
                "receipt": _read_json(receipt_path) if receipt_path.is_file() else None,
            })
        results[str(seed)] = {
            "proposals": proposal_results,
            "reviews": reviewer_results,
            "candidates": candidates,
            "conditions": conditions,
            "failed_calls": [role for role in ROLES if _role_submission(run, seed, role)[1] is not None],
        }
    report = {"offline_only": True, "cases": results}
    out = run / "evaluation.json"
    _save_immutable(out, (_json_text(report)).encode("utf-8"))
    return report


def replay_case(run_dir: str | Path, seed: int) -> dict[str, Any]:
    run = _run_dir(run_dir)
    problem = _read_json(_case_dir(run, seed) / "problem.json")
    return protocol.replay(_case_dir(run, seed) / "store.sqlite", problem["problem_id"])


def _cli() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare", help="freeze the two cases and proposer prompts")
    prep.add_argument("--out-dir", required=True)
    prompt = sub.add_parser("prompt", help="print a frozen prompt")
    prompt.add_argument("--run-dir", required=True)
    prompt.add_argument("--seed", required=True, type=int)
    prompt.add_argument("--role", required=True, choices=ROLES)
    submit = sub.add_parser("submit", help="retain raw response bytes, then structurally submit")
    submit.add_argument("--run-dir", required=True)
    submit.add_argument("--seed", required=True, type=int)
    submit.add_argument("--role", required=True, choices=ROLES)
    submit.add_argument("--raw", required=True, help="path to exact response bytes")
    submit.add_argument("--provider")
    submit.add_argument("--model")
    submit.add_argument("--effort")
    submit.add_argument("--started-at")
    submit.add_argument("--finished-at")
    fail = sub.add_parser("failure", help="record a failed scheduled model call")
    fail.add_argument("--run-dir", required=True)
    fail.add_argument("--seed", required=True, type=int)
    fail.add_argument("--role", required=True, choices=ROLES)
    fail.add_argument("--reason", required=True)
    final = sub.add_parser("final-prompts", help="freeze both post-review integrator prompts")
    final.add_argument("--run-dir", required=True)
    final.add_argument("--seed", required=True, type=int)
    evaluate_cmd = sub.add_parser("evaluate", help="score all saved outputs offline")
    evaluate_cmd.add_argument("--run-dir", required=True)
    replay_cmd = sub.add_parser("replay", help="rebuild the event projection")
    replay_cmd.add_argument("--run-dir", required=True)
    replay_cmd.add_argument("--seed", required=True, type=int)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            result = prepare(args.out_dir)
            print(_json_text(result), end="")
        elif args.command == "prompt":
            path = role_prompt(args.run_dir, args.seed, args.role)
            sys.stdout.write(path.read_text(encoding="utf-8"))
        elif args.command == "submit":
            raw = Path(args.raw).read_bytes()
            metadata = {key: value for key, value in {
                "provider": args.provider, "model": args.model, "effort": args.effort,
                "started_at": args.started_at, "finished_at": args.finished_at,
            }.items() if value is not None}
            result = submit_response(args.run_dir, args.seed, args.role, raw, metadata)
            print(_json_text(result), end="")
        elif args.command == "failure":
            result = record_failure(args.run_dir, args.seed, args.role, args.reason)
            print(_json_text(result), end="")
        elif args.command == "final-prompts":
            result = {key: str(value) for key, value in final_prompts(args.run_dir, args.seed).items()}
            print(_json_text(result), end="")
        elif args.command == "evaluate":
            print(_json_text(evaluate(args.run_dir)), end="")
        else:
            print(_json_text(replay_case(args.run_dir, args.seed)), end="")
    except (PilotError, protocol.ProtocolError) as exc:
        parser.exit(2, f"pilot: {exc}\n")


if __name__ == "__main__":
    _cli()

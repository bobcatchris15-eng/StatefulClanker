"""Frozen Lab 5 adapter. This module never imports the generator or offline oracle."""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
LAB4_PROTOCOL = REPO / "research" / "external-cognition" / "lab4" / "protocol.py"
ROUTER = REPO / "research" / "external-cognition" / "router"
RUNTIME = ROUTER / "setup-probes" / "runtime"
ALLOWLISTS = ROUTER / "allowlists"
SEEDS = (5103, 5110, 5115, 5121, 5122, 5129)
ROLES = ("left-proposer", "right-proposer", "left-reviewer", "right-reviewer", "shared-integrator", "raw-integrator")
PROPOSERS = ("left-proposer", "right-proposer")
REVIEWERS = ("left-reviewer", "right-reviewer")
FINALS = ("shared-integrator", "raw-integrator")
FAMILIES = ("north", "gemini")
SCHEMA = "lab5-finite-csp-pilot-v1"
CAP = 8192
TEMPERATURE = 0.6
TIMEOUT = 180


class PilotError(ValueError):
    pass


def _load_protocol():
    spec = importlib.util.spec_from_file_location("lab5_shared_protocol", LAB4_PROTOCOL)
    if spec is None or spec.loader is None:
        raise PilotError("Lab 4 structural protocol is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


protocol = _load_protocol()


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + "\n"


def _sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def _save_once(path: Path, raw: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with path.open("xb") as f:
            f.write(raw)
    except FileExistsError:
        if path.read_bytes() != raw:
            raise PilotError(f"immutable artifact conflict: {path.name}")


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _run(run_dir: str | Path) -> Path:
    p = Path(run_dir).resolve()
    if not (p / "run.json").is_file():
        raise PilotError("run is not prepared")
    return p


def _case(run: Path, seed: int) -> tuple[Path, dict]:
    if seed not in SEEDS:
        raise PilotError("unknown frozen seed")
    d = run / "cases" / str(seed)
    raw = (d / "problem.json").read_bytes()
    if _sha(raw) != _read_json(run / "run.json")["case_hashes"][str(seed)]:
        raise PilotError("frozen public case hash mismatch")
    return d, json.loads(raw)


def _ref_problem(problem_id: str) -> dict:
    return {"resource_id": f"problem:{problem_id}", "revision": 1, "state_revision": 1}


def _ref_claim(claim_id: str, claim: dict | None) -> dict:
    return {"resource_id": f"claim:{claim_id}", "revision": 0, "state_revision": 0} if claim is None else {
        "resource_id": f"claim:{claim_id}", "revision": claim["revision"], "state_revision": claim["state_revision"]}


def _message_id(problem_id: str, role: str) -> str:
    return f"{problem_id}-{role}-1"


def _env(problem_id: str, role: str, recipients: list[str], intent: str, refs: list[dict], payload: dict,
         reply_to: str | None = None) -> dict:
    return {"schema_version": 1, "problem_id": problem_id, "message_id": _message_id(problem_id, role),
            "sender": role, "recipients": recipients, "intent": intent, "read_refs": refs,
            "payload": payload, "reply_to": reply_to}


def _projection(case_dir: Path, problem_id: str) -> dict:
    return protocol.get_projection(case_dir / "store.sqlite", problem_id)


def _proposal_for(case_dir: Path, problem_id: str, component: str) -> dict | None:
    claim_id = f"{component}-tuples"
    for event in protocol.inbox(case_dir / "store.sqlite", problem_id, f"{component}-reviewer"):
        claim = event["payload"].get("claim") if event["intent"] == "PROPOSE" else None
        if claim and claim.get("claim_id") == claim_id:
            return event
    return None


def _expected_roles():
    fam_a, fam_b = FAMILIES[0], FAMILIES[1]
    return [{"seed": seed, "family": fam, "role": role,
             "parallel_group": f"{seed}-{fam}-{phase}"}
            for seed_i, seed in enumerate(SEEDS) for fam in ((fam_a, fam_b) if seed_i % 2 == 0 else (fam_b, fam_a))
            for phase, roles in (("propose", PROPOSERS), ("review", REVIEWERS), ("final", FINALS)) for role in roles]


def prepare(out_dir: str | Path, runtime_dir: str | Path = RUNTIME,
            allowlist_dir: str | Path = ALLOWLISTS, dispatch_dll: str | Path | None = None) -> dict:
    """Freeze all public run inputs and two allowlisted transport targets."""
    run = Path(out_dir).resolve()
    if run.exists() and any(run.iterdir()):
        raise PilotError("output directory must be absent or empty")
    run.mkdir(parents=True, exist_ok=True)
    runtime_dir, allowlist_dir = Path(runtime_dir).resolve(), Path(allowlist_dir).resolve()
    if not (runtime_dir / "FreeDispatch.dll").is_file():
        raise PilotError("reviewed FreeDispatch runtime package is missing")
    # Copy complete fixed runtime and both single-target allowlists; catalog pointers are
    # rewritten only to the byte-identical local snapshot that is hashed in the run.
    shutil.copytree(runtime_dir, run / "runtime")
    catalog_src = ROUTER / "kilo-free-catalog.json"
    catalog_raw = catalog_src.read_bytes()
    _save_once(run / "transport" / "kilo-free-catalog.json", catalog_raw)
    ai_studio_cat = ROUTER / "ai-studio-free-catalog.json"
    if ai_studio_cat.is_file():
        _save_once(run / "transport" / "ai-studio-free-catalog.json", ai_studio_cat.read_bytes())
    for family in FAMILIES:
        selection = _read_json(allowlist_dir / f"{family}.json")
        cat_file = "ai-studio-free-catalog.json" if selection.get("provider") == "ai-studio" else "kilo-free-catalog.json"
        selection["catalog_path"] = str((run / "transport" / cat_file).resolve())
        _save_once(run / "transport" / f"{family}.json", _json(selection).encode())
    if dispatch_dll:
        # External paths are recorded but never modified.
        dll_path = Path(dispatch_dll).resolve()
    else:
        dll_path = run / "runtime" / "FreeDispatch.dll"
    if not dll_path.is_file():
        raise PilotError("FreeDispatch DLL is unavailable")
    for seed in SEEDS:
        src = ROOT / "cases" / f"{seed}.json"
        _save_once(run / "cases" / str(seed) / "problem.json", src.read_bytes())
        problem = _read_json(run / "cases" / str(seed) / "problem.json")
        protocol.initialize_store(run / "cases" / str(seed) / "store.sqlite", problem["problem_id"], ROLES, problem)
    source_files = sorted([*ROOT.glob("*.py"), ROOT / "DESIGN.md", ROOT / "PREREGISTRATION.md",
                           LAB4_PROTOCOL, Path(__file__).resolve().parents[1] / "lab4" / "PROTOCOL.md"])
    source_hashes = {str(p.relative_to(REPO)) if p.is_relative_to(REPO) else p.name: _sha(p.read_bytes())
                     for p in source_files if p.is_file()}
    case_hashes = {str(seed): _sha((run / "cases" / str(seed) / "problem.json").read_bytes()) for seed in SEEDS}
    transport_hashes = {p.name: _sha(p.read_bytes()) for p in sorted((run / "transport").glob("*.json"))}
    runtime_hashes = {p.name: _sha(p.read_bytes()) for p in sorted((run / "runtime").iterdir()) if p.is_file()}
    manifest = {"schema": SCHEMA, "planned_calls": 72, "call_ceiling": 72, "seeds": list(SEEDS),
                "families": list(FAMILIES), "roles": list(ROLES), "schedule": _expected_roles(),
                "case_hashes": case_hashes, "source_hashes": source_hashes,
                "transport_hashes": transport_hashes, "runtime_hashes": runtime_hashes,
                "dispatch_dll": str(dll_path), "policy": {"maxOutputTokens": CAP, "temperature": str(TEMPERATURE),
                    "timeoutSeconds": TIMEOUT, "one_attempt_per_role": True, "retries": 0,
                    "public_problem_full_access": True, "evaluator_gate": "all 72 outcomes saved"}}
    manifest["freeze_hash"] = _sha(protocol.canonical_bytes(manifest))
    _save_once(run / "run.json", _json(manifest).encode())
    _save_once(run / "initial_prompt_hashes.json", b"{}\n")
    # initial prompts compiled before any participant response and pinned in run manifest
    for seed in SEEDS:
        for role in PROPOSERS:
            _prompt(run, seed, role)
    prompt_hashes = _read_json(run / "initial_prompt_hashes.json")
    # Separate write-once frozen hash artifact, so later mutable run artifacts cannot
    # silently bless altered proposer prompts.
    manifest["initial_prompt_hashes"] = prompt_hashes
    manifest.pop("freeze_hash", None)
    manifest["freeze_hash"] = _sha(protocol.canonical_bytes(manifest))
    # rewrite once: manifest initially staged to make source/case hashes available;
    # preparation is still pre-dispatch, and this is its sole write.
    (run / "run.json").unlink()
    _save_once(run / "run.json", _json(manifest).encode())
    return manifest


def _task(problem: dict) -> str:
    return ("Solve the finite constraint task from the complete immutable public packet below. "
            "Return exactly one JSON protocol envelope matching the supplied template; no prose outside JSON.\n\n"
            "PUBLIC PROBLEM:\n" + _json(problem))


def _role_payload(run: Path, seed: int, role: str) -> tuple[str, dict]:
    cdir, problem = _case(run, seed)
    pid = problem["problem_id"]
    projection = _projection(cdir, pid)
    refs = [_ref_problem(pid)]
    candidate: dict
    if role in PROPOSERS:
        side = role.split("-")[0]
        cid = f"{side}-tuples"
        refs.append(_ref_claim(cid, None))
        claim = {"claim_id": cid, "revision": 1, "state_revision": 1, "status": "active",
                 "value": {"component": side, "variables": problem["components"][side], "tuples": [[0, 0, 0, 0]]},
                 "provenance": {"message_id": _message_id(pid, role)},
                 "dependencies": [{"resource_id": f"problem:{pid}", "claim_revision": 1}]}
        reviewer = "right-reviewer" if side == "left" else "left-reviewer"
        candidate = _env(pid, role, [reviewer, "shared-integrator"], "PROPOSE", refs, {"claim": claim})
        task = f"Enumerate ALL and ONLY satisfying assignments for component {side}, sorted lexicographically. " \
               "Edit only payload.claim.value.tuples in the envelope. Each row contains exactly four domain integers in the listed variable order."
    elif role in REVIEWERS:
        side = "right" if role == "left-reviewer" else "left"
        event = _proposal_for(cdir, pid, side)
        claim = projection["claims"].get(f"{side}-tuples")
        if event is not None and claim is not None:
            refs.append(_ref_claim(f"{side}-tuples", claim))
            peer_env = event
            reply_to = event["message_id"]
            target = _ref_claim(f"{side}-tuples", claim)
        else:
            peer_env, reply_to, target = None, None, _ref_problem(pid)
        data = {"assessment": "supported", "basis_refs": [x["constraint_id"] for x in problem["constraints"]
                if (set(x["variables"]).issubset(problem["components"][side]) if peer_env else True)]}
        cid = f"{side}-tuples"
        corrected = {"claim_id": cid, "revision": 1, "state_revision": 1, "status": "candidate",
                     "value": {"component": side, "variables": problem["components"][side], "tuples": [[0, 0, 0, 0]]},
                     "provenance": {"message_id": _message_id(pid, role)},
                     "dependencies": [{"resource_id": f"problem:{pid}", "claim_revision": 1}]}
        if peer_env:
            candidate = _env(pid, role, ["shared-integrator"], "CHALLENGE", refs,
                             {"target": target, "assessment": data, "corrected_claim": corrected}, reply_to)
        else:
            candidate = _env(pid, role, ["shared-integrator"], "REPORT_EVIDENCE", refs,
                             {"report": {**data, "target": target}})
        task = (f"Independently check the {side} component tuple enumeration against the public constraints. "
                "Use CHALLENGE only if you found a specific issue; otherwise REPORT_EVIDENCE with supported or underdetermined. "
                "An optional corrected_claim is an uncommitted candidate, not a replacement. Edit assessment, basis_refs, and candidate tuples only.\n"
                + ("PEER PROPOSAL:\n" + _json(peer_env) if peer_env else "No accepted peer proposal is available; report that state without inventing one."))
    elif role in FINALS:
        if role == "shared-integrator":
            for cid, claim in sorted(projection["claims"].items()):
                refs.append(_ref_claim(cid, claim))
        candidate = _env(pid, role, ["shared-integrator"], "CONCLUDE", refs,
                         {"conclusion": {"assignment": {v: 0 for v in problem["variables"]}}})
        task = ("Return a complete assignment of all eight variables satisfying the public CSP. The shared integrator may inspect "
                "the following protocol projection; challenged claims and reviewer candidates remain visible and are not automatically selected. "
                "The raw integrator must solve using only the public facts. Edit only the eight integer values in conclusion.assignment.\n"
                + ("SHARED PROJECTION:\n" + _json(projection) if role == "shared-integrator" else ""))
    else:
        raise PilotError("unknown role")
    prompt = _task(problem) + "\n\nROLE TASK:\n" + task + "\n\nENVELOPE TEMPLATE:\n" + _json(candidate)
    return prompt, candidate


def _prompt(run: Path, seed: int, role: str) -> Path:
    raw = (_role_payload(run, seed, role)[0]).encode("utf-8", errors="strict")
    path = run / "prompts" / str(seed) / f"{role}.txt"
    _save_once(path, raw)
    hashes_path = run / "initial_prompt_hashes.json"
    hashes = _read_json(hashes_path)
    key = f"{seed}/{role}"
    digest = _sha(raw)
    if role in PROPOSERS:
        if key in hashes:
            if hashes[key] != digest:
                raise PilotError("initial prompt hash mismatch")
        else:
            hashes[key] = digest
            # At prepare time only; later writes of the same digest are idempotent.
            temp = hashes_path.with_name(f"initial_prompt_hashes_{seed}_{role}.tmp")
            temp.write_text(_json(hashes), encoding="utf-8")
            try:
                temp.replace(hashes_path)
            except OSError:
                if temp.exists():
                    temp.unlink()
    return path


def role_prompt(run_dir: str | Path, seed: int, role: str, family: str = "liquid") -> Path:
    run = _run(run_dir)
    if role not in ROLES:
        raise PilotError("unknown role")
    if role in FINALS and not all(_outcome(run, seed, r, family) for r in (*PROPOSERS, *REVIEWERS)):
        raise PilotError("final prompts are gated on all proposer and reviewer outcomes")
    if role in REVIEWERS and not all(_outcome(run, seed, r, family) for r in PROPOSERS):
        raise PilotError("review prompts are gated on both proposer outcomes")
    return _prompt(run, seed, role)


def final_prompts(run_dir: str | Path, seed: int, family: str = "liquid") -> dict[str, Path]:
    return {r: role_prompt(run_dir, seed, r, family) for r in FINALS}


def _outcome(run: Path, seed: int, role: str, family: str | None = None) -> bool:
    if family:
        d = run / "responses" / str(seed) / family
        return (d / f"{role}.raw").is_file() or (d / f"{role}.failure.json").is_file()
    for fam in FAMILIES:
        d = run / "responses" / str(seed) / fam
        if (d / f"{role}.raw").is_file() or (d / f"{role}.failure.json").is_file():
            return True
    return False


def _verify_frozen(run: Path, seed: int, family: str, role: str) -> tuple[Path, Path]:
    manifest = _read_json(run / "run.json")
    if family not in FAMILIES or role not in ROLES:
        raise PilotError("unregistered family or role")
    for rel, digest in manifest["source_hashes"].items():
        path = REPO / Path(rel)
        if not path.is_file() or _sha(path.read_bytes()) != digest:
            raise PilotError("frozen source hash mismatch")
    prompt_path = role_prompt(run, seed, role, family)
    expected_prompt, _ = _role_payload(run, seed, role)
    prompt_bytes = prompt_path.read_bytes()
    if prompt_bytes != expected_prompt.encode("utf-8"):
        raise PilotError("prompt differs from pinned state snapshot")
    if role in PROPOSERS and manifest["initial_prompt_hashes"].get(f"{seed}/{role}") != _sha(prompt_bytes):
        raise PilotError("initial prompt hash differs from frozen manifest")
    transport = run / "transport" / f"{family}.json"
    if _sha(transport.read_bytes()) != manifest["transport_hashes"][transport.name]:
        raise PilotError("transport allowlist hash mismatch")
    request = {"messages": [{"role": "user", "content": prompt_bytes.decode("utf-8")}], "tools": [],
               "toolMode": "text", "maxOutputTokens": CAP, "temperature": TEMPERATURE,
               "timeoutSeconds": TIMEOUT}
    path = run / "requests" / str(seed) / family / f"{role}.json"
    _save_once(path, _json(request).encode())
    return path, transport


def _expected_headers(env: dict, role: str, seed: int, family: str) -> bool:
    pid = f"csp-{seed}"
    if (env.get("problem_id") != pid or env.get("message_id") != _message_id(pid, role)
            or env.get("sender") != role):
        return False
    # Match the exact pre-call envelope shell and snapshot refs; payload values stay model-authored.
    template = _role_payload(_run_current, seed, role)[1]
    return all(env.get(k) == template.get(k) for k in ("schema_version", "problem_id", "message_id", "sender", "recipients", "intent", "read_refs", "reply_to"))


_run_current: Path


def submit_response(run_dir: str | Path, seed: int, family: str, role: str, raw_bytes: bytes,
                    dispatcher_receipt: dict | None = None) -> dict:
    run = _run(run_dir)
    _verify_frozen(run, seed, family, role)
    slot = run / "responses" / str(seed) / family
    raw_path = slot / f"{role}.raw"
    if raw_path.exists() or (slot / f"{role}.failure.json").exists():
        raise PilotError("role slot already consumed")
    _save_once(raw_path, bytes(raw_bytes))
    cdir, problem = _case(run, seed)
    result = {"schema_version": 1, "seed": seed, "family": family, "role": role,
              "raw_sha256": _sha(bytes(raw_bytes)), "captured_at": datetime.now(timezone.utc).isoformat(),
              "dispatcher": dispatcher_receipt or {}}
    try:
        env = protocol.parse_envelope(bytes(raw_bytes))
    except (protocol.ProtocolError, TypeError, ValueError):
        receipt = protocol.submit(cdir / "store.sqlite", bytes(raw_bytes))
    else:
        global _run_current
        _run_current = run
        if not _expected_headers(env, role, seed, family):
            receipt = protocol.record_rejection(cdir / "store.sqlite", bytes(raw_bytes), code="ROLE_MISMATCH", parsed=env)
        else:
            receipt = protocol.submit(cdir / "store.sqlite", bytes(raw_bytes))
    result["protocol_receipt"] = receipt
    _save_once(slot / f"{role}.receipt.json", _json(result).encode())
    return result


def record_failure(run_dir: str | Path, seed: int, family: str, role: str, code: str, detail: str = "") -> dict:
    run = _run(run_dir)
    _verify_frozen(run, seed, family, role)
    slot = run / "responses" / str(seed) / family
    if (slot / f"{role}.raw").exists() or (slot / f"{role}.failure.json").exists():
        raise PilotError("role slot already consumed")
    receipt = {"schema_version": 1, "seed": seed, "family": family, "role": role,
               "outcome": "no_response", "failure_code": code, "safe_detail": detail[:300],
               "attempted_at": datetime.now(timezone.utc).isoformat()}
    _save_once(slot / f"{role}.failure.json", _json(receipt).encode())
    return receipt


def dispatch_role(run_dir: str | Path, seed: int, family: str, role: str) -> dict:
    run = _run(run_dir)
    request, allowlist = _verify_frozen(run, seed, family, role)
    output = run / "dispatch" / str(seed) / family / role
    if output.exists():
        raise PilotError("dispatch output already exists")
    dll = _read_json(run / "run.json")["dispatch_dll"]
    cmd = ["dotnet", dll, "dispatch", "--request", str(request), "--allowlist", str(allowlist),
           "--out-dir", str(output), "--timeout-seconds", str(TIMEOUT)]
    try:
        completed = subprocess.run(cmd, check=False, capture_output=True, timeout=TIMEOUT + 60, text=True)
    except subprocess.TimeoutExpired:
        rec = record_failure(run, seed, family, role, "LAUNCHER_TIMEOUT")
        return rec
    receipt_path = output / "receipt.json"
    if not receipt_path.is_file():
        rec = record_failure(run, seed, family, role, "DISPATCHER_NO_RECEIPT", f"exit={completed.returncode}")
        return rec
    external = _read_json(receipt_path)
    content = output / "content.raw"
    if external.get("status") == "success" and content.is_file():
        return submit_response(run, seed, family, role, content.read_bytes(), external)
    # Every attempted dispatch consumes its role slot, even transport/provider failure.
    return record_failure(run, seed, family, role, external.get("failureCode") or "DISPATCH_FAILED",
                          f"sent={external.get('sent')} httpStatus={external.get('httpStatus')}")


def dispatch_pair(run_dir: str | Path, seed: int, family: str, roles: tuple[str, str]) -> list[dict]:
    if roles not in (PROPOSERS, REVIEWERS, FINALS):
        raise PilotError("only preregistered two-role phase pairs may be dispatched")
    # Capture each role's own immutable request and output path before scheduling threads.
    jobs = [(seed, family, role) for role in tuple(roles)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(dispatch_role, run_dir, s, f, r) for s, f, r in jobs]
        return [f.result() for f in futures]


def evaluate(run_dir: str | Path) -> dict:
    run = _run(run_dir)
    if not all(_outcome(run, seed, family_role[0]) for seed in SEEDS for family_role in []):
        pass
    expected = [(s, f, r) for s in SEEDS for f in FAMILIES for r in ROLES]
    missing = [(s, f, r) for s, f, r in expected if not _outcome(run, s, r, f)]
    # Access the hidden key only by delegating after the complete-slot gate.
    if missing:
        raise PilotError(f"evaluation locked until all 72 outcomes exist ({len(missing)} missing)")
    from offline_evaluate import evaluate_frozen_run
    return evaluate_frozen_run(run)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare"); p.add_argument("--out-dir", required=True); p.add_argument("--runtime-dir", default=str(RUNTIME)); p.add_argument("--allowlist-dir", default=str(ALLOWLISTS)); p.add_argument("--dispatch-dll")
    for name in ("prompt", "dispatch"):
        p = sub.add_parser(name); p.add_argument("--run-dir", required=True); p.add_argument("--seed", required=True, type=int); p.add_argument("--family", choices=FAMILIES, required=True); p.add_argument("--role", choices=ROLES, required=True)
    p = sub.add_parser("evaluate"); p.add_argument("--run-dir", required=True)
    args = ap.parse_args(argv)
    if args.cmd == "prepare":
        print(_json(prepare(args.out_dir, args.runtime_dir, args.allowlist_dir, args.dispatch_dll)), end="")
    elif args.cmd == "prompt":
        print(role_prompt(args.run_dir, args.seed, args.role))
    elif args.cmd == "dispatch":
        print(_json(dispatch_role(args.run_dir, args.seed, args.family, args.role)), end="")
    else:
        print(_json(evaluate(args.run_dir)), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

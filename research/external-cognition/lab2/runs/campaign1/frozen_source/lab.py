"""Durable, provider-free orchestration for the cycle 2 external-state lab.

Run from this directory with ``python lab.py --help``. Subject responses are
always captured byte-for-byte before parsing; checked and unchecked arms share
the same structural/version checks and differ only in frontier verification.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import json
import os
import re
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any, Iterator

import core


class LabError(Exception):
    """Expected command/runtime error suitable for a concise CLI message."""


class DuplicateResponseError(LabError):
    pass


class UnsafePathError(LabError):
    pass


def _json_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"),
                        ensure_ascii=False) + "\n").encode("utf-8")


def _atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with open(temp, "xb") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temp.unlink()


def _inside(root: Path, candidate: Path) -> Path:
    """Resolve an output path and reject traversal or symlink escapes."""
    root = root.resolve()
    # Reject symlinked path components below root, including existing leaves.
    lexical = candidate if candidate.is_absolute() else root / candidate
    try:
        rel = lexical.absolute().relative_to(root)
    except ValueError as exc:
        raise UnsafePathError(f"output path is outside run directory: {candidate}") from exc
    cursor = root
    for part in rel.parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise UnsafePathError(f"symlink in output path: {cursor}")
    resolved = lexical.resolve(strict=False)
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise UnsafePathError(f"output path resolves outside run directory: {candidate}") from exc
    return resolved


def _run_path(run_dir: str | Path) -> Path:
    p = Path(run_dir).expanduser().absolute()
    # A run root itself may not be a symlink.
    if p.is_symlink():
        raise UnsafePathError("run directory cannot be a symlink")
    return p


@contextlib.contextmanager
def _writer_lock(run: Path) -> Iterator[None]:
    lock_path = _inside(run, run / ".writer.lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "a+b") as handle:
        if os.name == "nt":
            import msvcrt
            handle.seek(0)
            if handle.read(1) == b"":
                handle.seek(0)
                handle.write(b"\0")
                handle.flush()
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
            try:
                yield
            finally:
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _manifest_path(run: Path) -> Path:
    return _inside(run, run / "manifest.json")


def _state_path(run: Path) -> Path:
    return _inside(run, run / "state.bin")


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise LabError(f"cannot read valid JSON at {path.name}: {exc}") from exc


def load_manifest(run_dir: str | Path) -> dict:
    run = _run_path(run_dir)
    _recover_change(run)
    data = _read_json(_manifest_path(run))
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        raise LabError("unsupported or malformed run manifest")
    return data


def load_state(run_dir: str | Path) -> dict:
    run = _run_path(run_dir)
    with _writer_lock(run):
        _recover_runtime(run)
        return _load_state_unlocked(run)


def _load_state_unlocked(run: Path) -> dict:
    manifest = load_manifest(run)
    try:
        state = core.decode_state(_state_path(run).read_bytes())
    except Exception as exc:
        raise LabError(f"cannot decode state.bin: {exc}") from exc
    if not isinstance(state, dict) or state.get("problem_hash") != manifest["problem_hash"]:
        raise LabError("state and manifest problem hashes do not match")
    if manifest.get("arm") == "checked":
        replay = core.initial_state(manifest["problem"])
        history = state.get("history")
        if not isinstance(history, list) or len(history) != state.get("next_stage"):
            raise LabError("checked state history is malformed")
        for i, entry in enumerate(history):
            if not isinstance(entry, dict) or entry.get("stage") != i:
                raise LabError("checked state history stage sequence is malformed")
            replay, receipt = core.apply_patch(
                manifest["problem"], replay,
                {"base_version": replay["version"], "stage": i,
                 "frontier": entry.get("frontier")}, verify=True)
            if not receipt.get("accepted"):
                raise LabError(f"checked state history fails stage {i} validation: {receipt.get('issues', [])}")
        if (state.get("frontier") != replay["frontier"] or
                state.get("history") != replay["history"] or
                type(state.get("version")) is not int or state["version"] < replay["version"]):
            raise LabError("checked state does not match its verified history")
    return state


def init_chain(run_dir: str | Path, *, seed: int, blocks: int, codec: str,
               representation: str, arm: str) -> dict:
    run = _run_path(run_dir)
    if codec not in {"packed", "json"}:
        raise ValueError("codec must be packed or json")
    if representation not in {"vector", "records"}:
        raise ValueError("representation must be vector or records")
    if arm not in {"checked", "unchecked"}:
        raise ValueError("arm must be checked or unchecked")
    with _writer_lock(run):
        if run.exists() and any(x.name != ".writer.lock" for x in run.iterdir()):
            raise LabError("run directory already exists and is not empty")
        run.mkdir(parents=True, exist_ok=True)
        problem = core.generate_problem(seed, blocks)
        state = core.initial_state(problem)
        manifest = {"schema_version": 1, "run_id": run.name,
                    "problem": problem, "problem_hash": core.problem_hash(problem),
                    "codec": codec, "representation": representation,
                    "arm": arm, "seed": seed, "blocks": blocks,
                    "created_utc": __import__("datetime").datetime.now(
                        __import__("datetime").timezone.utc).isoformat()}
        _atomic_write(_manifest_path(run), _json_bytes(manifest))
        _atomic_write(_state_path(run), core.encode_state(state, codec))
        for name in ("responses", "receipts"):
            _inside(run, run / name).mkdir(exist_ok=True)
        return {"run_dir": str(run), "problem_hash": manifest["problem_hash"],
                "codec": codec, "representation": representation, "arm": arm}


def _row_view(rows: list[dict], representation: str) -> list:
    if representation == "vector":
        return [[r["boundary"], r["cost"], r["bits"]] for r in rows]
    return [{"boundary": r["boundary"], "cost": r["cost"], "bits": r["bits"]}
            for r in rows]


def make_prompt(run_dir: str | Path) -> str:
    run = _run_path(run_dir)
    with _writer_lock(run):
        _recover_runtime(run)
        return _make_prompt_locked(run)


def _make_prompt_locked(run: Path) -> str:
    manifest, state = load_manifest(run), _load_state_unlocked(run)
    stage_index = state["next_stage"]
    if stage_index >= len(manifest["problem"]["stages"]):
        raise LabError("chain is complete; there is no next-stage prompt")
    stage = manifest["problem"]["stages"][stage_index]
    representation = manifest["representation"]
    prompt = {
        "schema": "cycle2-stage-patch-v1",
        "task": {
            "kind": "binary_chain_frontier",
            "rule": "For each prior frontier row with boundary b and each x,y in {0,1}, keep the choice only when (b+x+y) mod 2 equals stage.parity. The resulting boundary is y. Add wx*x + wy*y to cost and append x then y to bits. For each resulting boundary, retain the row with minimum cumulative cost; break ties by lexicographically smallest complete bits string.",
            "legality_condition": "(incoming_boundary + x + y) mod 2 == stage.parity",
            "boundary_after_stage": "y",
            "bit_order": "append x then y for each stage",
            "frontier_order": "ascending boundary",
        },
        "base_version": state["version"],
        "stage": stage,
        "frontier_representation": representation,
        "frontier_schema": (["boundary:int", "cost:int", "bits:string"]
                            if representation == "vector" else
                            {"boundary": "integer", "cost": "integer", "bits": "string"}),
        "frontier": _row_view(state["frontier"], representation),
        "required_output": {
            "format": "one JSON object and nothing else; no markdown or prose",
            "schema": {"base_version": "integer", "stage": "integer",
                       "frontier": (["[boundary:int,cost:int,bits:string]"]
                                    if representation == "vector" else
                                    [{"boundary": "integer", "cost": "integer",
                                      "bits": "string"}])},
            "frontier_order": "ascending boundary",
        },
    }
    return ("Compute the next frontier from only the supplied task facts. Return exactly the required JSON object.\n"
            + json.dumps(prompt, sort_keys=True, ensure_ascii=False, indent=2) + "\n")


def _patch_from_raw(raw: bytes, representation: str) -> tuple[dict | None, str | None]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        return None, f"response is not valid UTF-8 JSON: {exc}"
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        return None, f"response is not valid JSON: {exc.msg} at line {exc.lineno} column {exc.colno}"
    if not isinstance(value, dict):
        return None, "response must be one JSON object"
    if set(value) != {"base_version", "stage", "frontier"}:
        return None, "patch schema rule: required keys are exactly base_version, stage, frontier"
    rows = value.get("frontier")
    if not isinstance(rows, list):
        return None, "frontier schema rule: frontier must be a JSON array"
    converted = []
    for i, row in enumerate(rows):
        if representation == "vector":
            if not isinstance(row, list) or len(row) != 3:
                return None, f"frontier schema rule: vector row {i} must be [boundary,cost,bits]"
            converted.append({"boundary": row[0], "cost": row[1], "bits": row[2]})
        else:
            if not isinstance(row, dict) or set(row) != {"boundary", "cost", "bits"}:
                return None, f"frontier schema rule: record row {i} must have exactly boundary,cost,bits"
            converted.append(row)
    return {"base_version": value["base_version"], "stage": value["stage"],
            "frontier": converted}, None


def _response_id(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,99}", value) or value in {".", ".."}:
        raise UnsafePathError("response-id must be 1-100 safe filename characters")
    return value


def _receipt_paths(run: Path, response_id: str) -> tuple[Path, Path]:
    rid = _response_id(response_id)
    return (_inside(run, run / "responses" / f"{rid}.raw"),
            _inside(run, run / "receipts" / f"{rid}.json"))


def _recover_runtime(run: Path) -> None:
    """Finish a journaled commit or account for a raw capture interrupted pre-check."""
    journal_path = _inside(run, run / ".submit-journal.json")
    if journal_path.exists():
        journal = _read_json(journal_path)
        raw_path, receipt_path = _receipt_paths(run, journal["response_id"])
        if not raw_path.exists():
            raise LabError("submission journal has no corresponding immutable raw response")
        if journal.get("state") is not None:
            _atomic_write(_state_path(run), base64.b64decode(journal["state"]))
        _atomic_write(receipt_path, base64.b64decode(journal["receipt"]))
        journal_path.unlink()

    response_dir = _inside(run, run / "responses")
    if not response_dir.exists():
        return
    for raw_path in response_dir.glob("*.raw"):
        safe_raw = _inside(run, raw_path)
        rid = safe_raw.stem
        response_path, receipt_path = _receipt_paths(run, rid)
        if receipt_path.exists():
            continue
        raw = response_path.read_bytes()
        receipt = {"schema_version": 1, "response_id": rid, "accepted": False,
                   "interrupted": True, "issues": [
                       "processing interrupted after immutable raw capture; answer was not evaluated"],
                   "arm": None, "base_version": None, "stage": None,
                   "resulting_version": None,
                   "raw_sha256": hashlib.sha256(raw).hexdigest(),
                   "raw_response_bytes": len(raw),
                   "raw_response_characters": len(raw.decode("utf-8", errors="replace")),
                   "store_bytes": _state_path(run).stat().st_size if _state_path(run).exists() else 0,
                   "tokens": None}
        _atomic_write(receipt_path, _json_bytes(receipt))


def submit_patch(run_dir: str | Path, response_id: str, raw: bytes) -> dict:
    run = _run_path(run_dir)
    response_path, receipt_path = _receipt_paths(run, response_id)
    if not isinstance(raw, bytes):
        raise TypeError("raw response must be bytes")
    with _writer_lock(run):
        _recover_runtime(run)
        if response_path.exists() or receipt_path.exists():
            raise DuplicateResponseError(f"response id already used: {response_id}")
        response_path.parent.mkdir(parents=True, exist_ok=True)
        # Immutable exact response is durably installed before any parsing/checking.
        _atomic_write(response_path, raw)
        manifest = load_manifest(run)
        try:
            state = core.decode_state(_state_path(run).read_bytes())
        except Exception as exc:
            raise LabError(f"cannot decode state.bin: {exc}") from exc
        issues: list[str] = []
        new_state = state
        patch, parse_issue = _patch_from_raw(raw, manifest["representation"])
        if parse_issue:
            issues.append(parse_issue)
            accepted = False
            new_state = state
        else:
            try:
                new_state, core_receipt = core.apply_patch(
                    manifest["problem"], state, patch,
                    verify=(manifest["arm"] == "checked"))
                accepted = bool(core_receipt.get("accepted"))
                issues.extend(str(x) for x in core_receipt.get("issues", []))
            except Exception as exc:
                accepted = False
                issues.append(f"patch validation rule: {type(exc).__name__}: {exc}")
        receipt = {"schema_version": 1, "response_id": response_id,
                   "accepted": accepted, "issues": issues,
                   "arm": manifest["arm"], "base_version": (patch or {}).get("base_version"),
                   "stage": (patch or {}).get("stage"),
                   "resulting_version": new_state.get("version", state.get("version")),
                   "raw_sha256": hashlib.sha256(raw).hexdigest(),
                   "raw_response_bytes": len(raw),
                   "raw_response_characters": len(raw.decode("utf-8", errors="replace")),
                   "store_bytes": _state_path(run).stat().st_size,
                   "tokens": None}
        state_payload = core.encode_state(new_state, manifest["codec"]) if accepted else None
        if state_payload is not None:
            receipt["store_bytes"] = len(state_payload)
        journal = {"response_id": response_id,
                   "receipt": base64.b64encode(_json_bytes(receipt)).decode("ascii"),
                   "state": base64.b64encode(state_payload).decode("ascii") if state_payload is not None else None}
        journal_path = _inside(run, run / ".submit-journal.json")
        _atomic_write(journal_path, _json_bytes(journal))
        if accepted:
            _atomic_write(_state_path(run), base64.b64decode(journal["state"]))
        _atomic_write(receipt_path, base64.b64decode(journal["receipt"]))
        journal_path.unlink()
        return receipt


def _case_id(blocks: int, seed: int) -> str:
    return f"n{blocks}_seed{seed}"


def prepare_calibration(out_dir: str | Path) -> dict:
    out = Path(out_dir).expanduser().absolute()
    if out.is_symlink():
        raise UnsafePathError("calibration output directory cannot be a symlink")
    if out.exists() and any(out.iterdir()):
        raise LabError("calibration output directory already exists and is not empty")
    out.mkdir(parents=True, exist_ok=True)
    prompts = out / "prompts"
    prompts.mkdir(exist_ok=True)
    keys = {}
    cases = []
    for n in (2, 4, 8):
        for seed in (1101, 1102):
            cid = _case_id(n, seed)
            problem = core.generate_problem(seed, n)
            answer = core.oracle(problem)
            keys[cid] = {"problem": problem, "answer": answer}
            cases.append({"case_id": cid, "blocks": n, "seed": seed,
                          "prompt_file": f"prompts/{cid}.txt"})
            prompt = {
                "schema": "cycle2-full-answer-v1",
                "task": "Find the minimum-cost complete bit string for this binary chain.",
                "rules": {
                    "initial": {"boundary": 0, "cost": 0, "bits": ""},
                    "stage_transition": "For prior boundary b and choice x,y in {0,1}, require (b+x+y) mod 2 == stage.parity; the outgoing boundary is y; add wx*x + wy*y and append x then y.",
                    "boundary_after_stage": "y",
                    "final": "Ending boundary must equal final_boundary.",
                    "ties": "choose lexicographically smallest complete bits string among minimum-cost solutions.",
                },
                "problem": problem,
                "required_output": {"format": "one JSON object only; no prose",
                                    "schema": {"cost": "integer", "bits": "string"}},
            }
            (prompts / f"{cid}.txt").write_text(
                "Solve the complete task. Return exactly the required JSON object.\n" +
                json.dumps(prompt, sort_keys=True, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8")
    _atomic_write(_inside(out, out / "keys.json"), _json_bytes(keys))
    _atomic_write(_inside(out, out / "calibration.json"),
                  _json_bytes({"schema_version": 1, "cases": cases}))
    return {"out_dir": str(out), "cases": cases}


def load_calibration_key(out_dir: str | Path, case_id: str) -> dict:
    out = Path(out_dir).expanduser().absolute()
    return _read_json(_inside(out, out / "keys.json"))[case_id]


def score_full(calibration_dir: str | Path, case_id: str, raw: bytes) -> dict:
    key = load_calibration_key(calibration_dir, case_id)
    expected = key["answer"]
    issue = None
    actual = None
    try:
        parsed = json.loads(raw.decode("utf-8"))
        if not isinstance(parsed, dict) or set(parsed) != {"cost", "bits"}:
            issue = "answer schema rule: required keys are exactly cost and bits"
        elif isinstance(parsed["cost"], bool) or not isinstance(parsed["cost"], int) or not isinstance(parsed["bits"], str):
            issue = "answer type rule: cost must be integer and bits must be string"
        else:
            actual = parsed
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        issue = f"response parse rule: {exc}"
    correct = actual == expected
    return {"schema_version": 1, "case_id": case_id, "correct": correct,
            "actual": actual, "expected": expected, "issues": ([issue] if issue else []),
            "raw_sha256": hashlib.sha256(raw).hexdigest(),
            "raw_response_bytes": len(raw),
            "raw_response_characters": len(raw.decode("utf-8", errors="replace")),
            "tokens": None}


def change_cost(run_dir: str | Path, *, stage: int, field: str, delta: int) -> dict:
    run = _run_path(run_dir)
    if field not in {"wx", "wy"}:
        raise ValueError("field must be wx or wy")
    if isinstance(delta, bool) or not isinstance(delta, int) or delta == 0:
        raise ValueError("delta must be a nonzero integer")
    with _writer_lock(run):
        _recover_runtime(run)
        manifest = load_manifest(run)
        state = core.decode_state(_state_path(run).read_bytes())
        problem = json.loads(json.dumps(manifest["problem"]))
        if isinstance(stage, bool) or not isinstance(stage, int) or not (0 <= stage < len(problem["stages"])):
            raise ValueError("stage is outside the problem")
        changed = problem["stages"][stage]
        old_value = changed[field]
        changed[field] += delta
        if changed[field] < 1:
            raise ValueError("updated weight must remain positive")
        try:
            new_state = core.replace_problem(manifest["problem"], state, problem, stage)
        except Exception as exc:
            raise LabError(f"input change rejected: {exc}") from exc
        new_manifest = dict(manifest)
        new_manifest["problem"] = problem
        new_manifest["problem_hash"] = core.problem_hash(problem)
        # Journal makes the two-file problem/state update recoverable after interruption.
        journal = {"manifest": base64.b64encode(_json_bytes(new_manifest)).decode("ascii"),
                   "state": base64.b64encode(core.encode_state(new_state, manifest["codec"])).decode("ascii")}
        journal_path = _inside(run, run / ".change-journal.json")
        _atomic_write(journal_path, _json_bytes(journal))
        try:
            _atomic_write(_manifest_path(run), base64.b64decode(journal["manifest"]))
            _atomic_write(_state_path(run), base64.b64decode(journal["state"]))
            journal_path.unlink()
        except Exception:
            raise
        return {"accepted": True, "stage": stage, "field": field,
                "old_value": old_value, "new_value": changed[field],
                "version": new_state["version"], "next_stage": new_state["next_stage"],
                "problem_hash": new_manifest["problem_hash"]}


def _recover_change(run: Path) -> None:
    journal_path = _inside(run, run / ".change-journal.json")
    if not journal_path.exists():
        return
    journal = _read_json(journal_path)
    _atomic_write(_manifest_path(run), base64.b64decode(journal["manifest"]))
    _atomic_write(_state_path(run), base64.b64decode(journal["state"]))
    journal_path.unlink()


def summarize(run_dir: str | Path) -> dict:
    run = _run_path(run_dir)
    with _writer_lock(run):
        _recover_runtime(run)
        _recover_change(run)
        manifest, state = load_manifest(run), _load_state_unlocked(run)
        receipt_dir = _inside(run, run / "receipts")
        receipts = []
        if receipt_dir.exists():
            for path in sorted(receipt_dir.glob("*.json")):
                if path.is_file():
                    receipts.append(_read_json(path))
        raw_bytes = sum(r.get("raw_response_bytes", 0) for r in receipts)
        raw_chars = sum(r.get("raw_response_characters", 0) for r in receipts)
        complete = state["next_stage"] == len(manifest["problem"]["stages"])
        outcome = "incomplete"
        score = None
        if complete:
            candidates = [r for r in state["frontier"] if r["boundary"] == manifest["problem"]["final_boundary"]]
            if not candidates:
                outcome = "complete_without_final_boundary"
            else:
                score = {"cost": candidates[0]["cost"], "bits": candidates[0]["bits"]}
                optimum = core.oracle(manifest["problem"])
                outcome = "complete_correct" if score == optimum else "complete_incorrect"
        malformed = sum(any(("JSON" in str(i) or "schema" in str(i)) for i in r.get("issues", []))
                        for r in receipts)
        rejected = sum(not r.get("accepted", False) for r in receipts)
        seen_rejected_stages = set()
        repair_attempts = 0
        for r in receipts:
            stage = r.get("stage")
            if stage is None:
                continue
            if stage in seen_rejected_stages:
                repair_attempts += 1
            if not r.get("accepted", False):
                seen_rejected_stages.add(stage)
        return {"schema_version": 1, "run_id": manifest["run_id"], "outcome": outcome,
                "arm": manifest["arm"], "codec": manifest["codec"],
                "representation": manifest["representation"],
                "version": state["version"], "next_stage": state["next_stage"],
                "stages": len(manifest["problem"]["stages"]),
                "calls": len(receipts), "accepted_transitions": sum(bool(r.get("accepted")) for r in receipts),
                "rejected_responses": rejected, "malformed_responses": malformed,
                "repair_attempts_after_rejection": repair_attempts,
                "raw_response_bytes": raw_bytes, "raw_response_characters": raw_chars,
                "store_bytes": _state_path(run).stat().st_size,
                "final_score": score,
                "tokens": None, "resource_counters": {"tokens": None, "sampling_settings": None}}


def _read_response_file(path: str) -> bytes:
    try:
        return Path(path).expanduser().read_bytes()
    except OSError as exc:
        raise LabError(f"cannot read response source: {exc}") from exc


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Cycle 2 external cognition lab runtime")
    sub = p.add_subparsers(dest="command", required=True)
    q = sub.add_parser("prepare-calibration", help="generate six full-task prompts and private keys")
    q.add_argument("--out-dir", required=True)
    q = sub.add_parser("submit-full", help="score one exact full-task JSON response")
    q.add_argument("--calibration-dir", required=True)
    q.add_argument("--case-id", required=True)
    q.add_argument("--response-file", required=True)
    q = sub.add_parser("init-chain", help="create a binary chain run and opaque state.bin")
    q.add_argument("--run-dir", required=True)
    q.add_argument("--seed", required=True, type=int)
    q.add_argument("--blocks", required=True, type=int)
    q.add_argument("--codec", required=True, choices=("packed", "json"))
    q.add_argument("--representation", required=True, choices=("vector", "records"))
    q.add_argument("--arm", required=True, choices=("checked", "unchecked"))
    q = sub.add_parser("prompt", help="emit the next local stage, frontier, version, and schema")
    q.add_argument("--run-dir", required=True)
    q = sub.add_parser("submit", help="preserve raw output, validate, and atomically commit if accepted")
    q.add_argument("--run-dir", required=True)
    q.add_argument("--response-id", required=True)
    q.add_argument("--response-file", required=True)
    q = sub.add_parser("change-cost", help="change one stage weight and invalidate its suffix")
    q.add_argument("--run-dir", required=True)
    q.add_argument("--stage", type=int, required=True)
    q.add_argument("--field", choices=("wx", "wy"), required=True)
    q.add_argument("--delta", type=int, required=True)
    q = sub.add_parser("summary", help="report run outcome and exact available resource counters")
    q.add_argument("--run-dir", required=True)
    return p


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "prepare-calibration":
            result = prepare_calibration(args.out_dir)
        elif args.command == "submit-full":
            result = score_full(args.calibration_dir, args.case_id, _read_response_file(args.response_file))
        elif args.command == "init-chain":
            result = init_chain(args.run_dir, seed=args.seed, blocks=args.blocks, codec=args.codec,
                                representation=args.representation, arm=args.arm)
        elif args.command == "prompt":
            sys.stdout.write(make_prompt(args.run_dir))
            return 0
        elif args.command == "submit":
            result = submit_patch(args.run_dir, args.response_id, _read_response_file(args.response_file))
        elif args.command == "change-cost":
            result = change_cost(args.run_dir, stage=args.stage, field=args.field, delta=args.delta)
        else:
            result = summarize(args.run_dir)
        sys.stdout.write(json.dumps(result, sort_keys=True, ensure_ascii=False, indent=2) + "\n")
        return 0
    except (LabError, ValueError, OSError, KeyError) as exc:
        sys.stderr.write(f"lab: {exc}\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

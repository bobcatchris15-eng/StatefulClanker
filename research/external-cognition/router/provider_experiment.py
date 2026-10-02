"""Bounded free-provider breadth campaign over the frozen Lab 4 protocol."""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import shutil
import shlex
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Callable

LAB4 = Path(__file__).resolve().parents[1] / "lab4"
ROOT = Path(__file__).resolve().parent
PILOT_SOURCE = LAB4 / "pilot.py"
PREREG_DEFAULT = ROOT / "PROVIDER_PREREGISTRATION.md"
DISPATCH_PROJECT = ROOT / "FreeDispatch" / "FreeDispatch.csproj"
MODEL_KEYS = ("liquid", "north", "laguna", "nemotron", "inkling", "qwen", "gemma31b", "ultra")
CONDITIONS = ("full", "payload")
SEEDS = (4201, 4202)
ROLES = ("u-proposer", "v-proposer", "u-reviewer", "v-reviewer", "shared-integrator", "raw-integrator")
MAX_TOKENS = 4096
TEMPERATURE = 0.6
TIMEOUT_SECONDS = 180
PARALLEL_PER_PHASE = 2
ORIGIN_BY_PROVIDER = {
    "openrouter": "https://openrouter.ai/api/v1",
    "kilo-free": "https://api.kilo.ai/api/gateway",
    "ai-studio": "https://generativelanguage.googleapis.com/v1beta",
}
ALLOWLIST_FIELDS = {"schema_version", "provider", "connection_id", "endpoint_id", "model", "base_url", "catalog_path", "catalog_sha256"}

# The Lab 4 adapter imports `protocol` as a sibling module.
if str(LAB4) not in sys.path:
    sys.path.insert(0, str(LAB4))


class ExperimentError(RuntimeError):
    pass


class PayloadSchemaError(ValueError):
    pass


def _utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


def _sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def _json_bytes(value: Any, *, pretty: bool = False) -> bytes:
    if pretty:
        return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + "\n").encode("utf-8")
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ExperimentError(f"cannot read JSON file {path}: {exc}") from exc


def _write_once(path: Path, raw: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        if path.read_bytes() == raw:
            raise ExperimentError(f"write-once artifact already exists: {path}")
        raise ExperimentError(f"refusing to overwrite immutable artifact: {path}")
    with path.open("xb") as stream:
        stream.write(raw)


def _write_or_verify(path: Path, raw: bytes) -> None:
    if path.exists():
        if path.read_bytes() != raw:
            raise ExperimentError(f"frozen artifact conflict: {path}")
        return
    _write_once(path, raw)


def _safe_parse_json(raw: bytes) -> Any:
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise PayloadSchemaError("payload is not UTF-8") from exc

    def pairs_hook(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for key, value in pairs:
            if key in out:
                raise PayloadSchemaError(f"duplicate field: {key}")
            out[key] = value
        return out

    def invalid_constant(value: str) -> None:
        raise PayloadSchemaError(f"non-JSON numeric constant: {value}")

    try:
        return json.loads(text, object_pairs_hook=pairs_hook, parse_constant=invalid_constant)
    except (json.JSONDecodeError, TypeError) as exc:
        raise PayloadSchemaError(f"payload is not one JSON value: {exc}") from exc


def _residue_list(value: Any) -> bool:
    return type(value) is list and len(value) == 3 and all(type(item) is int and 0 <= item <= 10 for item in value)


def parse_payload(raw: bytes, role: str) -> dict[str, Any]:
    value = _safe_parse_json(raw)
    if type(value) is not dict:
        raise PayloadSchemaError("payload must be a JSON object")
    if role.endswith("proposer"):
        if set(value) != {"coefficients"} or not _residue_list(value.get("coefficients")):
            raise PayloadSchemaError("proposer payload requires only three integer coefficient residues")
    elif role.endswith("reviewer"):
        allowed = {"assessment", "corrected_coefficients"}
        if not {"assessment"} <= set(value) <= allowed:
            raise PayloadSchemaError("review payload has missing or unknown fields")
        if type(value["assessment"]) is not str or value["assessment"] not in {"supported", "challenge", "underdetermined"}:
            raise PayloadSchemaError("review assessment is outside the preregistered vocabulary")
        if "corrected_coefficients" in value and not _residue_list(value["corrected_coefficients"]):
            raise PayloadSchemaError("corrected_coefficients must be three integer residues")
    elif role in ("shared-integrator", "raw-integrator"):
        if set(value) == {"status"} and value["status"] == "underdetermined":
            return value
        if set(value) != {"status", "x", "y"} or value.get("status") != "solved":
            raise PayloadSchemaError("final payload must be a solved coordinate or underdetermined status")
        if any(type(value.get(axis)) is not int or not 0 <= value[axis] <= 10 for axis in ("x", "y")):
            raise PayloadSchemaError("solved x and y must be integer residues")
    else:
        raise PayloadSchemaError(f"unknown scheduled role: {role}")
    return value


def _catalog_zero(row: Any, provider: str) -> bool:
    if type(row) is not dict:
        return False
    # AI Studio models declare free-tier access via a boolean field rather than zero pricing.
    if provider == "ai-studio":
        return row.get("free_tier") is True
    pricing = row.get("pricing")
    if type(pricing) is not dict:
        return False
    try:
        prompt = Decimal(str(pricing.get("prompt")))
        completion = Decimal(str(pricing.get("completion")))
    except (InvalidOperation, ValueError):
        return False
    if prompt != 0 or completion != 0:
        return False
    return provider != "kilo-free" or row.get("isFree") is True


def _load_allowlist(path: Path) -> tuple[dict[str, Any], bytes, bytes]:
    raw = path.read_bytes()
    try:
        allow = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ExperimentError(f"allowlist is not UTF-8 JSON: {path}") from exc
    if type(allow) is not dict or set(allow) != ALLOWLIST_FIELDS or allow.get("schema_version") != 1:
        raise ExperimentError(f"allowlist does not match schema version 1: {path}")
    provider = allow.get("provider")
    if provider not in ORIGIN_BY_PROVIDER or allow.get("base_url") != ORIGIN_BY_PROVIDER[provider]:
        raise ExperimentError("provider origin is not one of the exact free origins")
    model = allow.get("model")
    # AI Studio uses native model IDs (e.g. 'gemini-3.8-flash') without the ':free'
    # aggregator-routing suffix that OpenRouter/Kilo use to gate zero-cost access.
    if type(model) is not str or (provider != "ai-studio" and not model.endswith(":free")):
        raise ExperimentError("selected model must have an explicit :free identifier")
    catalog_path = Path(allow["catalog_path"])
    if not catalog_path.is_absolute():
        catalog_path = path.parent / catalog_path
    catalog_bytes = catalog_path.resolve().read_bytes()
    digest = _sha(catalog_bytes)
    if digest != allow.get("catalog_sha256"):
        raise ExperimentError("selected public catalog hash does not match the allowlist")
    try:
        catalog = json.loads(catalog_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ExperimentError("selected public catalog is not UTF-8 JSON") from exc
    rows = catalog.get("data") if type(catalog) is dict else None
    row = next((item for item in rows if type(item) is dict and item.get("id") == model), None) if type(rows) is list else None
    if not _catalog_zero(row, provider):
        raise ExperimentError(f"model is absent from the frozen zero-price free catalog: {model}")
    return allow, raw, catalog_bytes


def _selection_map(path: Path) -> dict[str, Any]:
    value = _read_json(path)
    if type(value) is not dict or set(value) != set(MODEL_KEYS):
        raise ExperimentError(f"allowlist map must contain exactly these model keys: {', '.join(MODEL_KEYS)}")
    selections = {}
    for key in MODEL_KEYS:
        row = value[key]
        if type(row) is str:
            row = {"allowlist": row, "allowed_returned_models": []}
        if type(row) is not dict or set(row) != {"allowlist", "allowed_returned_models"}:
            raise ExperimentError(f"selection {key} requires allowlist and allowed_returned_models")
        names = row["allowed_returned_models"]
        if type(names) is not list or any(type(name) is not str or not name for name in names) or len(names) != len(set(names)):
            raise ExperimentError(f"selection {key} has an invalid returned-model alias list")
        selections[key] = row
    return selections


def _source_files() -> dict[str, Path]:
    sources = {
        "provider_experiment.py": Path(__file__).resolve(),
        "provider_experiment_tests.py": ROOT / "tests" / "test_provider_experiment.py",
        "pilot.py": PILOT_SOURCE,
        "protocol.py": LAB4 / "protocol.py",
        "lab3/experiment.py": LAB4.parent / "lab3" / "experiment.py",
        "FreeDispatch.csproj": DISPATCH_PROJECT,
    }
    for path in sorted((ROOT / "FreeDispatch").rglob("*.cs")):
        if "bin" in path.parts or "obj" in path.parts:
            continue
        sources[path.relative_to(ROOT).as_posix()] = path
    return sources


def _dispatcher_package() -> dict[str, bytes]:
    """Return the complete built helper package, excluding transient PDB files."""
    output = DISPATCH_PROJECT.parent / "bin" / "Release" / "net8.0-windows"
    if not output.is_dir():
        output = DISPATCH_PROJECT.parent / "bin" / "Debug" / "net8.0-windows"
    required = ("FreeDispatch.dll", "FreeDispatch.deps.json", "FreeDispatch.runtimeconfig.json",
                "StatefulClanker.Router.dll", "StatefulClanker.Router.deps.json",
                "StatefulClanker.Router.runtimeconfig.json", "System.Security.Cryptography.ProtectedData.dll")
    files = {name: (output / name).read_bytes() for name in required if (output / name).is_file()}
    if set(files) != set(required):
        raise ExperimentError("build FreeDispatch before freezing the campaign; required runtime package is incomplete")
    return files


def _check_campaign_sources(manifest: dict[str, Any]) -> None:
    current = _source_files()
    if set(current) != set(manifest.get("source_hashes", {})):
        raise ExperimentError("frozen source file set changed")
    for name, path in current.items():
        if _sha(path.read_bytes()) != manifest["source_hashes"][name]:
            raise ExperimentError(f"source changed after campaign freeze: {name}")


def _load_campaign(campaign: Path) -> dict[str, Any]:
    path = campaign / "campaign.json"
    if not path.is_file():
        raise ExperimentError(f"campaign is not prepared: {campaign}")
    manifest = _read_json(path)
    frozen = dict(manifest)
    claimed_hash = frozen.pop("manifest_hash", None)
    if claimed_hash != _sha(pilot.protocol.canonical_bytes(frozen)):
        raise ExperimentError("campaign manifest hash mismatch")
    _check_campaign_sources(manifest)
    for name, digest in manifest["input_hashes"].items():
        file_path = campaign / (name if name.startswith("conditions/") else f"frozen_inputs/{name}")
        if not file_path.is_file() or _sha(file_path.read_bytes()) != digest:
            raise ExperimentError(f"frozen campaign input changed: {name}")
    package_hashes = manifest["source_manifest"].get("dispatcher_package_sha256", {})
    for name, digest in package_hashes.items():
        package_path = campaign / "frozen_inputs" / "dispatcher-package" / name
        if not package_path.is_file() or _sha(package_path.read_bytes()) != digest:
            raise ExperimentError(f"frozen dispatcher runtime changed: {name}")
    for condition_name, hashes in manifest["condition_hashes"].items():
        model_key, condition = condition_name.split("/")
        run_dir = _condition_dir(campaign, model_key, condition)
        checks = {
            "pilot_run_sha256": _sha((run_dir / "pilot" / "run.json").read_bytes()),
            "condition_doc_sha256": _sha((run_dir / "condition.json").read_bytes()),
        }
        if any(checks[key] != hashes[key] for key in checks):
            raise ExperimentError(f"frozen condition identity changed: {condition_name}")
        initial_prompts = hashes.get("initial_prompt_hashes", {})
        live_prompts = _read_json(run_dir / "prompt_hashes.json")
        for key, digest in initial_prompts.items():
            prompt_path = run_dir / "prompts" / key.split("/")[0] / f"{key.split('/')[1]}.txt"
            if live_prompts.get(key) != digest or not prompt_path.is_file() or _sha(prompt_path.read_bytes()) != digest:
                raise ExperimentError(f"frozen initial prompt changed: {condition_name} {key}")
    return manifest


def _snapshot_name(path: Path) -> str:
    if path.name in ("", ".", "..") or Path(path.name).name != path.name:
        raise ExperimentError("invalid snapshot filename")
    return path.name


def _freeze_routes(campaign: Path, source_map: Path, selections: dict[str, Any]) -> tuple[dict[str, Any], dict[str, str]]:
    routes: dict[str, Any] = {}
    hashes: dict[str, str] = {}
    frozen_inputs = campaign / "frozen_inputs"
    catalogs_dir = frozen_inputs / "catalogs"
    allowlists_dir = frozen_inputs / "allowlists"
    catalogs_dir.mkdir(parents=True, exist_ok=True)
    allowlists_dir.mkdir(parents=True, exist_ok=True)
    for key in MODEL_KEYS:
        selection = selections[key]
        allow_path = Path(selection["allowlist"])
        if not allow_path.is_absolute():
            allow_path = source_map.parent / allow_path
        allow, original_bytes, catalog_bytes = _load_allowlist(allow_path.resolve())
        returned_models = selection["allowed_returned_models"]
        # The requested identifier is always allowed. Additional observed aliases
        # must be named explicitly from a separate setup probe before freeze.
        if allow["model"] not in returned_models:
            returned_models = [allow["model"], *returned_models]
        selection["allowed_returned_models"] = returned_models
        catalog_name = f"{key}.catalog.json"
        dispatch_allow = dict(allow)
        dispatch_allow["catalog_path"] = catalog_name
        dispatch_allow_bytes = _json_bytes(dispatch_allow, pretty=True)
        original_name = f"{key}.allowlist.source.json"
        dispatch_name = f"{key}.allowlist.json"
        _write_once(allowlists_dir / original_name, original_bytes)
        _write_once(catalogs_dir / catalog_name, catalog_bytes)
        # The helper resolves catalog_path relative to its allowlist, so keep both
        # files together in the same immutable input directory.
        dispatch_allow["catalog_path"] = f"../catalogs/{catalog_name}"
        dispatch_allow_bytes = _json_bytes(dispatch_allow, pretty=True)
        _write_once(allowlists_dir / dispatch_name, dispatch_allow_bytes)
        hashes[f"allowlists/{original_name}"] = _sha(original_bytes)
        hashes[f"catalogs/{catalog_name}"] = _sha(catalog_bytes)
        hashes[f"allowlists/{dispatch_name}"] = _sha(dispatch_allow_bytes)
        routes[key] = {
            "provider": allow["provider"], "connection_id": allow["connection_id"],
            "endpoint_id": allow["endpoint_id"], "model": allow["model"],
            "base_url": allow["base_url"], "allowed_returned_models": returned_models,
            "catalog_sha256": _sha(catalog_bytes), "source_allowlist_sha256": _sha(original_bytes),
            "dispatch_allowlist": f"allowlists/{dispatch_name}",
        }
    return routes, hashes


def prepare(campaign_dir: str | Path, *, allowlist_map_path: str | Path,
            preregistration: str | Path = PREREG_DEFAULT) -> dict[str, Any]:
    """Create all eight isolated conditions, frozen targets, prompts and source identities."""
    campaign = Path(campaign_dir).resolve()
    if (campaign / "campaign.json").exists():
        raise ExperimentError(f"campaign already exists; create a new campaign directory: {campaign}")
    source_map = Path(allowlist_map_path).resolve()
    prereg = Path(preregistration).resolve()
    selections = _selection_map(source_map)
    campaign.mkdir(parents=True, exist_ok=True)
    frozen_dir = campaign / "frozen_inputs"
    frozen_dir.mkdir(parents=True, exist_ok=True)
    prereg_name = _snapshot_name(prereg)
    prereg_bytes = prereg.read_bytes()
    _write_once(frozen_dir / prereg_name, prereg_bytes)
    source_map_bytes = source_map.read_bytes()
    _write_once(frozen_dir / "allowlist-selection-map.json", source_map_bytes)
    routes, input_hashes = _freeze_routes(campaign, source_map, selections)
    input_hashes[prereg_name] = _sha(prereg_bytes)
    input_hashes["allowlist-selection-map.json"] = _sha(source_map_bytes)
    source_hashes = {name: _sha(path.read_bytes()) for name, path in _source_files().items()}
    dispatcher_package = _dispatcher_package()
    package_hashes = {name: _sha(data) for name, data in dispatcher_package.items()}
    package_dir = frozen_dir / "dispatcher-package"
    package_dir.mkdir(parents=True, exist_ok=False)
    for name, data in dispatcher_package.items():
        _write_once(package_dir / name, data)
        input_hashes[f"dispatcher-package/{name}"] = _sha(data)
    source_manifest = {
        "dispatcher_project": str(DISPATCH_PROJECT.resolve()),
        "dispatcher_project_sha256": source_hashes["FreeDispatch.csproj"],
        "dispatcher_source_hashes": {name: digest for name, digest in source_hashes.items() if name.startswith("FreeDispatch/")},
        "dispatcher_command": ["dotnet", "<frozen-package>/FreeDispatch.dll", "dispatch", "--request", "<request>", "--allowlist", "<allowlist>", "--out-dir", "<slot-dir>", "--timeout-seconds", str(TIMEOUT_SECONDS)],
        "dispatcher_package_hashes": package_hashes,
        "dispatcher_package_sha256": package_hashes,
        "dispatcher_package_manifest_sha256": _sha(_json_bytes(package_hashes)),
    }
    try:
        dotnet = shutil.which("dotnet")
        sdk_version = subprocess.run([dotnet, "--version"], check=True, capture_output=True, timeout=10).stdout.decode("utf-8", "strict").strip() if dotnet else None
    except (OSError, subprocess.SubprocessError, UnicodeDecodeError) as exc:
        sdk_version = None
        source_manifest["dotnet_version_capture_error"] = type(exc).__name__
    source_manifest["dotnet_sdk_version"] = sdk_version
    source_manifest["dotnet_executable"] = shutil.which("dotnet")
    conditions = []
    condition_hashes = {}
    schedule = []
    for model_key in MODEL_KEYS:
        for condition in CONDITIONS:
            condition_name = f"{model_key}/{condition}"
            run_dir = campaign / "conditions" / model_key / condition
            run_dir.mkdir(parents=True, exist_ok=False)
            pilot_manifest = pilot.prepare(run_dir / "pilot")
            route = routes[model_key]
            condition_doc = {
                "model_key": model_key, "condition": condition, "route": route,
                "pilot_source_hashes": pilot_manifest["source_hashes"],
                "pilot_run_manifest_sha256": _sha((run_dir / "pilot" / "run.json").read_bytes()),
                "created_at": _utcnow(),
            }
            _write_once(run_dir / "condition.json", _json_bytes(condition_doc, pretty=True))
            local_prompt_hashes: dict[str, str] = {}
            for seed in SEEDS:
                for role in ROLES[:2]:
                    full_path = pilot.role_prompt(run_dir / "pilot", seed, role)
                    prompt_text = full_path.read_text(encoding="utf-8") if condition == "full" else _payload_prompt(run_dir / "pilot", seed, role, model_key)
                    prompt_raw = (prompt_text.rstrip() + "\n").encode("utf-8", errors="strict")
                    _save_prompt(run_dir, seed, role, prompt_raw, local_prompt_hashes)
                    if condition == "payload":
                        context = _compile_context(run_dir / "pilot", seed, role)
                        context_raw = _json_bytes(context, pretty=True)
                        _write_once(run_dir / "compile_contexts" / str(seed) / f"{role}.json", context_raw)
                        input_hashes[f"conditions/{model_key}/{condition}/compile_contexts/{seed}/{role}.json"] = _sha(context_raw)
            prompt_hash_path = run_dir / "prompt_hashes.json"
            _write_once(prompt_hash_path, _json_bytes(local_prompt_hashes, pretty=True))
            conditions.append(condition_name)
            condition_hashes[condition_name] = {
                "pilot_run_sha256": _sha((run_dir / "pilot" / "run.json").read_bytes()),
                "pilot_initial_prompt_hashes_sha256": _sha((run_dir / "pilot" / "prompt_hashes.json").read_bytes()),
                "condition_doc_sha256": _sha((run_dir / "condition.json").read_bytes()),
                "prompt_hashes_sha256": _sha(prompt_hash_path.read_bytes()),
                "initial_prompt_hashes": dict(local_prompt_hashes),
            }
            for slot in pilot._schedule():
                schedule.append({"model_key": model_key, "condition": condition, **slot})
    _planned_slots = len(MODEL_KEYS) * len(CONDITIONS) * len(SEEDS) * len(ROLES)
    manifest: dict[str, Any] = {
        "schema": "provider-breadth-campaign-v1", "planned_slots": _planned_slots, "call_ceiling": _planned_slots,
        "model_keys": list(MODEL_KEYS), "conditions": conditions, "condition_order": conditions,
        "seeds": list(SEEDS), "roles": list(ROLES), "schedule": schedule,
        "routes": routes, "generation_policy": {
            "max_output_tokens": MAX_TOKENS, "temperature": "0.6",
            "timeout_seconds": TIMEOUT_SECONDS, "parallel_per_phase": PARALLEL_PER_PHASE,
            "retry_policy": "none", "one_fresh_user_message": True,
        },
        "preregistration_file": prereg_name, "source_hashes": source_hashes,
        "source_manifest": source_manifest, "input_hashes": input_hashes,
        "condition_hashes": condition_hashes,
        "run_policy": "conditions run once in frozen order; a partial condition is preserved and cannot resume",
        "evaluation_policy": f"offline only after all {_planned_slots} scheduled role slots have outcomes",
        "frozen_at": _utcnow(),
    }
    manifest["manifest_hash"] = _sha(pilot.protocol.canonical_bytes(manifest))
    _write_once(campaign / "campaign.json", _json_bytes(manifest, pretty=True))
    return manifest


def _save_prompt(run_dir: Path, seed: int, role: str, raw: bytes,
                 prompt_hashes: dict[str, str]) -> Path:
    path = run_dir / "prompts" / str(seed) / f"{role}.txt"
    _write_once(path, raw)
    key = f"{seed}/{role}"
    digest = _sha(raw)
    if key in prompt_hashes and prompt_hashes[key] != digest:
        raise ExperimentError(f"prompt hash conflict for {key}")
    prompt_hashes[key] = digest
    return path


def _problem_ref(problem_id: str) -> dict[str, Any]:
    return {"resource_id": f"problem:{problem_id}", "revision": 1, "state_revision": 1}


def _claim_ref(claim_id: str, claim: dict[str, Any]) -> dict[str, Any]:
    return {"resource_id": f"claim:{claim_id}", "revision": claim["revision"], "state_revision": claim["state_revision"]}


def _problem(pilot_run: Path, seed: int) -> dict[str, Any]:
    return _read_json(pilot_run / "cases" / str(seed) / "problem.json")


def _proposal(pilot_run: Path, seed: int, reviewer: str) -> dict[str, Any] | None:
    problem = _problem(pilot_run, seed)
    return pilot._proposal_for_reviewer(pilot_run / "cases" / str(seed) / "store.sqlite", problem["problem_id"], reviewer)


def _payload_prompt(pilot_run: Path, seed: int, role: str, model_key: str) -> str:
    problem = _problem(pilot_run, seed)
    prompt = (
        "You are a fresh participant in an affine reasoning task. Use all public facts shown below; all arithmetic is modulo 11. "
        "Return exactly one compact JSON object matching the role-specific payload schema. Do not return an envelope or prose.\n\n"
        "PUBLIC PROBLEM (immutable):\n" + pilot._json_text(problem) + "\n"
    )
    if role in ("u-proposer", "v-proposer"):
        coord = "u" if role.startswith("u-") else "v"
        return prompt + (
            f"Assigned role: {role}; infer only relation {coord} from all three observations. Output exactly "
            '{"coefficients":[integer_residue_0_to_10,integer_residue_0_to_10,integer_residue_0_to_10]}.\n'
        )
    if role in ("u-reviewer", "v-reviewer"):
        event = _proposal(pilot_run, seed, role)
        if event is None:
            state = "No structurally accepted peer proposal is available. Assess the observations directly; do not claim a peer value was accepted.\n"
        else:
            state = "Exact cross-assigned peer proposal to review:\n" + pilot._json_text(event["payload"]["claim"]) + "\n"
        return prompt + f"Assigned role: {role}. Independently inspect the full facts and peer state.\n" + state + (
            'Output exactly {"assessment":"supported|challenge|underdetermined"}, optionally with '
            '"corrected_coefficients":[three integer residues 0..10], as one JSON object. Use corrected_coefficients only for an uncommitted candidate; '
            "the wrapper records it as candidate and does not promote it. Do not include envelope metadata.\n"
        )
    if role == "shared-integrator":
        projection = pilot.protocol.get_projection(pilot_run / "cases" / str(seed) / "store.sqlite", problem["problem_id"])
        return prompt + (
            f"Fresh shared-state integrator role: {role}. The shared workspace below contains submitted evidence; do not treat it as an oracle or automatic selection.\n"
            "SHARED WORKSPACE PROJECTION:\n" + pilot._json_text(projection) + "\n"
            'Output exactly {"status":"solved","x":integer_residue_0_to_10,"y":integer_residue_0_to_10} or '
            '{"status":"underdetermined"}.\n'
        )
    if role == "raw-integrator":
        return prompt + (
            f"Fresh raw-facts integrator role: {role}. Solve from the complete public observations alone.\n"
            'Output exactly {"status":"solved","x":integer_residue_0_to_10,"y":integer_residue_0_to_10} or '
            '{"status":"underdetermined"}.\n'
        )
    raise ExperimentError(f"unknown role {role} for {model_key}")


def _condition_dir(campaign: Path, model_key: str, condition: str) -> Path:
    if model_key not in MODEL_KEYS or condition not in CONDITIONS:
        raise ExperimentError("unknown model key or representation condition")
    return campaign / "conditions" / model_key / condition


def _condition_prompt(run_dir: Path, seed: int, role: str) -> Path:
    path = run_dir / "prompts" / str(seed) / f"{role}.txt"
    if path.is_file():
        return path
    pilot_run = run_dir / "pilot"
    condition = run_dir.name
    if role in ("u-reviewer", "v-reviewer"):
        pilot.role_prompt(pilot_run, seed, role)
    elif role in ("shared-integrator", "raw-integrator"):
        pilot.final_prompts(pilot_run, seed)
    else:
        pilot.role_prompt(pilot_run, seed, role)
    prompt_hashes = _read_json(run_dir / "prompt_hashes.json")
    prompt = (pilot_run / "prompts" / str(seed) / f"{role}.txt").read_text(encoding="utf-8")
    if condition == "payload":
        model_key = run_dir.parent.name
        prompt = _payload_prompt(pilot_run, seed, role, model_key)
        context_path = run_dir / "compile_contexts" / str(seed) / f"{role}.json"
        if not context_path.exists():
            _write_once(context_path, _json_bytes(_compile_context(pilot_run, seed, role), pretty=True))
    raw = (prompt.rstrip() + "\n").encode("utf-8", errors="strict")
    hashes: dict[str, str] = dict(prompt_hashes)
    _save_prompt(run_dir, seed, role, raw, hashes)
    _replace_json_once(run_dir / "prompt_hashes.json", _json_bytes(hashes, pretty=True))
    return path


def _replace_json_once(path: Path, raw: bytes) -> None:
    # Prompt hashes grow by phase; each version is also archived immutably.
    current = _read_json(path) if path.exists() else {}
    new = json.loads(raw.decode("utf-8"))
    if any(key in current and current[key] != value for key, value in new.items()):
        raise ExperimentError("prompt hash history conflict")
    if new == current:
        return
    history = path.parent / "prompt_hash_history"
    _write_once(history / f"revision-{len(list(history.glob('revision-*.json'))) + 1:02d}.json", _json_bytes(new, pretty=True))
    temp = path.with_suffix(".json.tmp")
    temp.write_bytes(raw)
    temp.replace(path)


def get_prompt(condition_dir: str | Path, seed: int, role: str) -> Path:
    run = Path(condition_dir).resolve()
    _condition_prompt(run, seed, role)
    return run / "prompts" / str(seed) / f"{role}.txt"


def _compile_context(pilot_run: Path, seed: int, role: str) -> dict[str, Any]:
    """Capture role-specific shared reads before dispatch, never at response time."""
    problem = _problem(pilot_run, seed)
    problem_id = problem["problem_id"]
    context: dict[str, Any] = {"problem_ref": _problem_ref(problem_id)}
    if role in ("u-reviewer", "v-reviewer"):
        target_claim_id = f"{'v' if role == 'u-reviewer' else 'u'}-relation"
        event = _proposal(pilot_run, seed, role)
        projection = pilot.protocol.get_projection(pilot_run / "cases" / str(seed) / "store.sqlite", problem_id)
        context["peer_message_id"] = event["message_id"] if event else None
        context["target_ref"] = (_claim_ref(target_claim_id, projection["claims"][target_claim_id])
                                  if event and target_claim_id in projection["claims"] else _problem_ref(problem_id))
    elif role == "shared-integrator":
        projection = pilot.protocol.get_projection(pilot_run / "cases" / str(seed) / "store.sqlite", problem_id)
        context["claim_refs"] = [_claim_ref(cid, claim) for cid, claim in sorted(projection["claims"].items())]
    return context


def _compile_payload(pilot_run: Path, seed: int, role: str, payload: dict[str, Any],
                     context: dict[str, Any] | None = None) -> dict[str, Any]:
    problem = _problem(pilot_run, seed)
    problem_id = problem["problem_id"]
    message_id = pilot._role_message_id(problem_id, role)
    refs = [_problem_ref(problem_id)]
    if role in ("u-proposer", "v-proposer"):
        coord = "u" if role.startswith("u-") else "v"
        claim_id = f"{coord}-relation"
        refs.append({"resource_id": f"claim:{claim_id}", "revision": 0, "state_revision": 0})
        claim = {
            "claim_id": claim_id, "revision": 1, "state_revision": 1, "status": "active",
            "value": {"coefficients": payload["coefficients"]},
            "provenance": {"message_id": message_id},
            "dependencies": [{"resource_id": f"problem:{problem_id}", "claim_revision": 1}],
        }
        reviewer = "v-reviewer" if coord == "u" else "u-reviewer"
        return pilot._envelope_template(problem_id, message_id, role, [reviewer, "shared-integrator"], "PROPOSE", refs, {"claim": claim})
    if role in ("u-reviewer", "v-reviewer"):
        target_claim_id = f"{'v' if role == 'u-reviewer' else 'u'}-relation"
        context = context or _compile_context(pilot_run, seed, role)
        peer_message_id = context.get("peer_message_id")
        target_ref = context["target_ref"]
        if target_ref["resource_id"].startswith("claim:"):
            refs.append(target_ref)
        payload_out: dict[str, Any]
        candidate = None
        if "corrected_coefficients" in payload:
            candidate = {
                "claim_id": target_claim_id, "revision": 1, "state_revision": 1, "status": "candidate",
                "value": {"coefficients": payload["corrected_coefficients"]},
                "provenance": {"message_id": message_id},
                "dependencies": [{"resource_id": f"problem:{problem_id}", "claim_revision": 1}],
            }
        basis_refs = [row["observation_id"] for row in problem["observations"]]
        assessment = {"assessment": payload["assessment"], "basis_refs": basis_refs}
        if peer_message_id is not None and target_ref["resource_id"].startswith("claim:") and payload["assessment"] == "challenge":
            payload_out = {"target": target_ref, "assessment": assessment}
            intent = "CHALLENGE"
        else:
            payload_out = {"report": {**assessment, "target": target_ref}}
            intent = "REPORT_EVIDENCE"
        if candidate is not None:
            payload_out["corrected_claim"] = candidate
        return pilot._envelope_template(problem_id, message_id, role, ["shared-integrator"], intent,
                                        refs, payload_out, peer_message_id)
    if role in ("shared-integrator", "raw-integrator"):
        if role == "shared-integrator":
            context = context or _compile_context(pilot_run, seed, role)
            refs.extend(context["claim_refs"])
        return pilot._envelope_template(problem_id, message_id, role, ["shared-integrator"], "CONCLUDE", refs,
                                        {"conclusion": payload})
    raise ExperimentError(f"unknown role: {role}")


def compile_payload(pilot_run_dir: str | Path, seed: int, role: str, raw: bytes,
                    context: dict[str, Any] | None = None) -> dict[str, Any]:
    payload = parse_payload(raw, role)
    return _compile_payload(Path(pilot_run_dir).resolve(), seed, role, payload, context)


def _record_payload(run_dir: Path, seed: int, role: str, raw: bytes, metadata: dict[str, Any],
                    context: dict[str, Any] | None = None) -> dict[str, Any]:
    raw_path = run_dir / "model_outputs" / str(seed) / f"{role}.raw"
    _write_once(raw_path, raw)
    receipt: dict[str, Any] = {
        "seed": seed, "role": role, "payload_valid": False, "raw_payload_sha256": _sha(raw),
        "compiler_source_sha256": _sha(Path(__file__).read_bytes()), "failure": None,
    }
    try:
        payload = parse_payload(raw, role)
        if context is None:
            context = _read_json(run_dir / "compile_contexts" / str(seed) / f"{role}.json")
        compiled = _compile_payload(run_dir / "pilot", seed, role, payload, context)
        compiled_bytes = pilot.protocol.canonical_bytes(compiled)
        compiled_path = run_dir / "compiled_envelopes" / str(seed) / f"{role}.json"
        _write_once(compiled_path, compiled_bytes)
        receipt.update({"payload_valid": True, "compiled_envelope_sha256": _sha(compiled_bytes),
                       "compiled_envelope_path": compiled_path.relative_to(run_dir).as_posix()})
        core_receipt = pilot.submit_response(run_dir / "pilot", seed, role, compiled_bytes,
            metadata={**metadata, "raw_payload_sha256": _sha(raw), "compiled_envelope_sha256": _sha(compiled_bytes),
                      "compiler_source_sha256": receipt["compiler_source_sha256"]})
    except PayloadSchemaError as exc:
        receipt["failure"] = f"payload_schema_invalid: {exc}"
        # Preserve and structurally submit exactly what the participant returned.
        core_receipt = pilot.submit_response(run_dir / "pilot", seed, role, raw,
            metadata={**metadata, "raw_payload_sha256": _sha(raw), "payload_schema_valid": False,
                      "compiler_source_sha256": receipt["compiler_source_sha256"]})
    receipt["core_receipt"] = core_receipt
    _write_once(run_dir / "compile_receipts" / str(seed) / f"{role}.json", _json_bytes(receipt, pretty=True))
    return receipt


def record_model_output(condition_dir: str | Path, seed: int, role: str, raw: bytes,
                        metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    """Record a fixture or manually captured model output through the arm's fixed path."""
    run_dir = Path(condition_dir).resolve()
    _condition_prompt(run_dir, seed, role)
    metadata = metadata or {}
    if run_dir.name == "payload":
        return _record_payload(run_dir, seed, role, raw, metadata)
    raw_path = run_dir / "model_outputs" / str(seed) / f"{role}.raw"
    _write_once(raw_path, bytes(raw))
    receipt = pilot.submit_response(run_dir / "pilot", seed, role, bytes(raw), metadata=metadata)
    _write_once(run_dir / "compile_receipts" / str(seed) / f"{role}.json",
                _json_bytes({"seed": seed, "role": role, "payload_valid": None,
                             "raw_payload_sha256": _sha(raw), "core_receipt": receipt}, pretty=True))
    return receipt


def _allowed_next_condition(manifest: dict[str, Any], campaign: Path, target: str) -> None:
    target_model, target_condition = target.split("/")
    if target_model not in MODEL_KEYS or target_condition not in CONDITIONS:
        raise ExperimentError("unknown model or condition")
    for earlier_model in MODEL_KEYS[:MODEL_KEYS.index(target_model)]:
        for condition in CONDITIONS:
            row = campaign / "conditions" / earlier_model / condition
            if not (row / "condition_complete.json").is_file():
                if (row / "condition_started.json").exists():
                    raise ExperimentError(f"earlier condition is interrupted and cannot be resumed: {earlier_model}/{condition}")
                raise ExperimentError(f"conditions must follow frozen model order; next is {earlier_model}/{condition}")
    if target_condition == "payload":
        row = campaign / "conditions" / target_model / "full"
        if not (row / "condition_complete.json").is_file():
            if (row / "condition_started.json").exists():
                raise ExperimentError(f"earlier condition is interrupted and cannot be resumed: {target_model}/full")
            raise ExperimentError(f"full condition must complete before payload condition for {target_model}")
    target_dir = campaign / "conditions" / target_model / target_condition
    if (target_dir / "condition_complete.json").exists() or (target_dir / "condition_started.json").exists():
        raise ExperimentError(f"condition already started or completed: {target}")


def _request_bytes(prompt: bytes, policy: dict[str, Any]) -> bytes:
    text = prompt.decode("utf-8", errors="strict")
    request = {
        "messages": [{"role": "user", "content": text}], "tools": [], "toolMode": "text",
        "maxOutputTokens": policy["max_output_tokens"], "temperature": policy["temperature"],
        "timeoutSeconds": policy["timeout_seconds"],
    }
    return _json_bytes(request)


def _slot_metadata(campaign: Path, manifest: dict[str, Any], model_key: str, condition: str,
                   seed: int, role: str, request_raw: bytes, started_at: str, duration: float,
                   receipt: dict[str, Any]) -> dict[str, Any]:
    route = manifest["routes"][model_key]
    usage_value = {
        "reported": receipt.get("usageReported"), "promptTokens": receipt.get("promptTokens"),
        "completionTokens": receipt.get("completionTokens"), "totalTokens": receipt.get("totalTokens"),
    }
    return {
        "model_key": model_key, "condition": condition, "seed": seed, "role": role,
        "provider": route["provider"], "connection_id": route["connection_id"],
        "endpoint_id": route["endpoint_id"], "requested_model": route["model"],
        "returned_model": receipt.get("returnedModel"), "allowed_returned_models": route["allowed_returned_models"],
        "request_sha256": _sha(request_raw), "http_status": receipt.get("httpStatus"),
        "usage": usage_value, "finish_reason": receipt.get("finishReason"),
        "failure_code": receipt.get("failureCode"), "provider_error": receipt.get("providerError"),
        "adapter_success": receipt.get("adapterSuccess"), "request_id": receipt.get("providerRequestId"),
        "transport_sent": receipt.get("sent"),
        "started_at": started_at, "duration_seconds": duration,
    }


def _dispatch_command(request_path: Path, allowlist_path: Path, out_dir: Path, timeout_seconds: int) -> dict[str, Any]:
    # transport/<seed>/<role> => condition directory is three parents up.
    package = allowlist_path.parent.parent / "dispatcher-package"
    command = ["dotnet", str(package / "FreeDispatch.dll"), "dispatch",
               "--request", str(request_path), "--allowlist", str(allowlist_path),
               "--out-dir", str(out_dir), "--timeout-seconds", str(timeout_seconds)]
    try:
        result = subprocess.run(command, cwd=ROOT.parent.parent.parent, capture_output=True,
                                timeout=timeout_seconds + 30, check=False)
        stdout = result.stdout or b""
        stderr = result.stderr or b""
        receipt_path = out_dir / "receipt.json"
        receipt = _read_json(receipt_path) if receipt_path.is_file() else {}
        content_path = out_dir / "content.raw"
        return {"exit_code": result.returncode, "receipt": receipt,
                "content": content_path.read_bytes() if content_path.is_file() else None,
                "stdout": stdout, "stderr": stderr}
    except subprocess.TimeoutExpired as exc:
        return {"exit_code": None, "receipt": {}, "content": None,
                "stdout": exc.stdout or b"", "stderr": exc.stderr or b"", "launcher_timeout": True}
    except OSError as exc:
        return {"exit_code": None, "receipt": {}, "content": None,
                "stdout": b"", "stderr": f"{type(exc).__name__}: {exc}".encode("utf-8", "replace")}


Dispatcher = Callable[[Path, Path, Path, int], dict[str, Any]]


def role_from_prompt(prompt: str) -> str:
    for role in ROLES:
        if f"role: {role}" in prompt or f"role {role}" in prompt or f"Assigned role: {role}" in prompt or f"integrator role: {role}" in prompt:
            return role
    raise ExperimentError("could not identify scheduled role from frozen prompt")


def run_condition(campaign_dir: str | Path, model_key: str, condition: str,
                  *, dispatcher: Dispatcher | None = None) -> dict[str, Any]:
    campaign = Path(campaign_dir).resolve()
    manifest = _load_campaign(campaign)
    run_dir = _condition_dir(campaign, model_key, condition)
    target = f"{model_key}/{condition}"
    _allowed_next_condition(manifest, campaign, target)
    if (run_dir / "condition_started.json").exists():
        raise ExperimentError("condition already started; partial conditions are never resumed")
    route = manifest["routes"][model_key]
    allowlist_path = campaign / "frozen_inputs" / route["dispatch_allowlist"]
    if _sha(allowlist_path.read_bytes()) != manifest["input_hashes"][route["dispatch_allowlist"]]:
        raise ExperimentError("frozen dispatch allowlist hash mismatch")
    _write_once(run_dir / "condition_started.json", _json_bytes({
        "condition": target, "started_at": _utcnow(), "campaign_manifest_hash": manifest["manifest_hash"],
    }, pretty=True))
    dispatch = dispatcher or _dispatch_command
    results: list[dict[str, Any]] = []
    for seed in SEEDS:
        for phase_roles in (ROLES[:2], ROLES[2:4], ROLES[4:6]):
            prepared = []
            for role in phase_roles:
                prompt_path = _condition_prompt(run_dir, seed, role)
                prompt_raw = prompt_path.read_bytes()
                compile_context = (_read_json(run_dir / "compile_contexts" / str(seed) / f"{role}.json")
                                   if condition == "payload" else None)
                prompt_key = f"{seed}/{role}"
                prompt_hashes = _read_json(run_dir / "prompt_hashes.json")
                if prompt_hashes.get(prompt_key) != _sha(prompt_raw):
                    raise ExperimentError(f"prompt hash mismatch before dispatch: {prompt_key}")
                request_raw = _request_bytes(prompt_raw, manifest["generation_policy"])
                request_path = run_dir / "requests" / str(seed) / f"{role}.request.json"
                _write_once(request_path, request_raw)
                _write_once(request_path.with_name(f"{role}.request-meta.json"), _json_bytes({
                    "model_key": model_key, "condition": condition, "seed": seed, "role": role,
                    "model": route["model"], "endpoint_id": route["endpoint_id"],
                    "request_sha256": _sha(request_raw), "prompt_sha256": _sha(prompt_raw),
                    "maxOutputTokens": manifest["generation_policy"]["max_output_tokens"],
                    "temperature": manifest["generation_policy"]["temperature"],
                    "timeoutSeconds": manifest["generation_policy"]["timeout_seconds"],
                    "retry_policy": "none",
                }, pretty=True))
                slot_dir = run_dir / "transport" / str(seed) / role
                prepared.append((role, request_path, allowlist_path, slot_dir, request_raw, compile_context))
            dispatch_data = [(*item, time.monotonic(), _utcnow()) for item in prepared]
            with concurrent.futures.ThreadPoolExecutor(max_workers=PARALLEL_PER_PHASE, thread_name_prefix="provider-exp") as pool:
                futures = {pool.submit(dispatch, item[1], item[2], item[3], manifest["generation_policy"]["timeout_seconds"]): item for item in dispatch_data}
                for future in concurrent.futures.as_completed(futures):
                    role, request_path, slot_allowlist, slot_dir, request_raw, compile_context, start_time, started_at = futures[future]
                    try:
                        call = future.result()
                    except Exception as exc:
                        call = {"exit_code": None, "receipt": {}, "content": None, "stdout": b"",
                                "stderr": f"{type(exc).__name__}: {exc}".encode("utf-8", "replace")}
                    duration = time.monotonic() - start_time
                    slot_dir.mkdir(parents=True, exist_ok=True)
                    _write_or_verify(slot_dir / "launcher.stdout.raw", call.get("stdout") or b"")
                    _write_or_verify(slot_dir / "launcher.stderr.raw", call.get("stderr") or b"")
                    receipt = call.get("receipt") if type(call.get("receipt")) is dict else {}
                    returned_model = receipt.get("returnedModel")
                    allowed = route["allowed_returned_models"]
                    if receipt.get("sent") is True and receipt.get("status") == "completed" and returned_model not in allowed:
                        receipt = {**receipt, "status": "failed", "failureCode": "RETURNED_MODEL_MISMATCH"}
                    content = call.get("content")
                    ok_content = (call.get("exit_code") == 0 and receipt.get("status") == "completed"
                                  and type(content) is bytes and returned_model in allowed)
                    metadata = _slot_metadata(campaign, manifest, model_key, condition, seed, role,
                                              request_raw, started_at, duration, receipt)
                    if ok_content:
                        _write_once(slot_dir / "assistant-content.raw", content)
                        try:
                            if condition == "payload":
                                outcome_receipt = _record_payload(run_dir, seed, role, content, metadata, compile_context)
                            else:
                                outcome_receipt = record_model_output(run_dir, seed, role, content, metadata)
                            result_row = {**metadata, "slot_status": "recorded", "protocol_receipt": outcome_receipt}
                        except Exception as exc:
                            result_row = _record_dispatch_failure(run_dir, seed, role, metadata,
                                f"record_failure: {type(exc).__name__}: {exc}", slot_dir)
                    else:
                        if condition == "payload":
                            _record_payload_dispatch_failure(run_dir, seed, role, metadata,
                                str(receipt.get("failureCode") or receipt.get("providerError") or call.get("stderr") or "dispatch_failed"), slot_dir)
                        result_row = _record_dispatch_failure(run_dir, seed, role, metadata,
                            str(receipt.get("failureCode") or receipt.get("providerError") or call.get("stderr") or "dispatch_failed"), slot_dir)
                    _write_once(slot_dir / "slot.json", _json_bytes(result_row, pretty=True))
                    results.append(result_row)
    rows = _slot_records(run_dir)
    if len(rows) != len(SEEDS) * len(ROLES):
        raise ExperimentError("condition did not produce one durable outcome for each of twelve slots")
    complete = {
        "status": "complete", "condition": target, "finished_at": _utcnow(),
        "slot_count": len(rows), "failed_dispatches": sum(row.get("slot_status") == "failed" for row in rows),
        "slots_sha256": _sha(_json_bytes(rows, pretty=True)),
    }
    _write_once(run_dir / "condition_complete.json", _json_bytes(complete, pretty=True))
    return complete


def _record_dispatch_failure(run_dir: Path, seed: int, role: str, metadata: dict[str, Any], reason: str,
                             slot_dir: Path) -> dict[str, Any]:
    failure = {"seed": seed, "role": role, "reason": reason, "recorded_at": _utcnow(), **metadata}
    pilot.record_failure(run_dir / "pilot", seed, role, reason, metadata=metadata)
    _write_once(run_dir / "failures" / str(seed) / f"{role}.json", _json_bytes(failure, pretty=True))
    return {**metadata, "slot_status": "failed", "failure": reason}


def _record_payload_dispatch_failure(run_dir: Path, seed: int, role: str,
                                     metadata: dict[str, Any], reason: str, slot_dir: Path) -> None:
    """Represent a consumed transport slot without inventing assistant content."""
    receipt = {
        "seed": seed, "role": role, "payload_valid": None,
        "raw_payload_sha256": None, "compiled_envelope_sha256": None,
        "compiler_source_sha256": _sha(Path(__file__).read_bytes()),
        "failure": "dispatch_failed: " + reason,
        "slot_path": slot_dir.relative_to(run_dir).as_posix(),
        "transport_sent": metadata.get("transport_sent"),
    }
    _write_once(run_dir / "compile_receipts" / str(seed) / f"{role}.json", _json_bytes(receipt, pretty=True))


def _slot_records(run_dir: Path) -> list[dict[str, Any]]:
    rows = []
    for seed in SEEDS:
        for role in ROLES:
            path = run_dir / "transport" / str(seed) / role / "slot.json"
            if path.is_file():
                rows.append(_read_json(path))
    return rows


def evaluate(campaign_dir: str | Path) -> dict[str, Any]:
    """Run the existing offline evaluator only after all 96 outcomes are complete."""
    campaign = Path(campaign_dir).resolve()
    manifest = _load_campaign(campaign)
    missing = [name for name in manifest["condition_order"]
               if not (campaign / "conditions" / name.split("/")[0] / name.split("/")[1] / "condition_complete.json").is_file()]
    if missing:
        planned = manifest.get("planned_slots", "all")
        raise ExperimentError(f"offline evaluation requires all {planned} scheduled slots; incomplete conditions: {', '.join(missing)}")
    conditions: dict[str, Any] = {}
    total_slots = 0
    for name in manifest["condition_order"]:
        model_key, condition = name.split("/")
        run_dir = _condition_dir(campaign, model_key, condition)
        slots = _slot_records(run_dir)
        if len(slots) != 12:
            raise ExperimentError(f"condition {name} does not contain twelve saved slot records")
        completion = _read_json(run_dir / "condition_complete.json")
        if (completion.get("status") != "complete" or completion.get("slot_count") != 12
                or completion.get("slots_sha256") != _sha(_json_bytes(slots, pretty=True))):
            raise ExperimentError(f"condition completion manifest does not match saved slot outcomes: {name}")
        pilot_report = pilot.evaluate(run_dir / "pilot")
        payload_receipts = []
        if condition == "payload":
            for seed in SEEDS:
                for role in ROLES:
                    receipt_path = run_dir / "compile_receipts" / str(seed) / f"{role}.json"
                    payload_receipts.append(_read_json(receipt_path) if receipt_path.is_file() else {
                        "seed": seed, "role": role, "payload_valid": None,
                        "failure": "legacy-fixture-missing-compile-receipt",
                    })
        conditions[name] = {
            "slot_count": len(slots), "failed_dispatches": sum(row.get("slot_status") == "failed" for row in slots),
            "payload_valid_count": sum(row.get("payload_valid") is True for row in payload_receipts) if condition == "payload" else None,
            "payload_invalid_count": sum(row.get("payload_valid") is False for row in payload_receipts) if condition == "payload" else None,
            "payload_receipts": payload_receipts if condition == "payload" else None,
            "offline_pilot_evaluation": pilot_report,
            "slot_records": slots,
        }
        total_slots += len(slots)
    report = {
        "offline_only": True, "campaign_manifest_hash": manifest["manifest_hash"],
        "completed_slot_count": total_slots, "conditions": conditions,
        "interpretation": "descriptive two-case breadth calibration; not a general success-rate or causal superiority estimate",
        "evaluated_at": _utcnow(),
    }
    _write_once(campaign / "evaluation.json", _json_bytes(report, pretty=True))
    return report


def extract_public_problem(prompt: str) -> dict[str, Any] | None:
    marker = "PUBLIC PROBLEM (immutable):\n"
    start = prompt.find(marker)
    if start < 0:
        return None
    start += len(marker)
    try:
        value, _ = json.JSONDecoder().raw_decode(prompt[start:])
    except json.JSONDecodeError:
        return None
    return value if type(value) is dict else None


def _cli() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    prepare_cmd = sub.add_parser("prepare", help="freeze targets, source, prompts, protocol and the 96-slot schedule; no inference")
    prepare_cmd.add_argument("--campaign-dir", required=True)
    prepare_cmd.add_argument("--allowlist-map", required=True)
    prepare_cmd.add_argument("--preregistration", default=str(PREREG_DEFAULT))
    run_cmd = sub.add_parser("run-condition", help="dispatch one frozen model/representation condition once")
    run_cmd.add_argument("--campaign-dir", required=True)
    run_cmd.add_argument("--model-key", choices=MODEL_KEYS, required=True)
    run_cmd.add_argument("--condition", choices=CONDITIONS, required=True)
    evaluate_cmd = sub.add_parser("evaluate", help="offline score after all 96 slots have outcomes")
    evaluate_cmd.add_argument("--campaign-dir", required=True)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            result = prepare(args.campaign_dir, allowlist_map_path=args.allowlist_map, preregistration=args.preregistration)
        elif args.command == "run-condition":
            result = run_condition(args.campaign_dir, args.model_key, args.condition)
        else:
            result = evaluate(args.campaign_dir)
        sys.stdout.write(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
    except (ExperimentError, PayloadSchemaError, pilot.PilotError, pilot.protocol.ProtocolError) as exc:
        parser.exit(2, f"provider_experiment: {exc}\n")


import pilot  # late import keeps CLI docs easy to read while retaining shared protocol API


if __name__ == "__main__":
    _cli()

"""Local Lemonade runner for the frozen Lab 4 Qwen replication.

`prepare` freezes a local run without network access. `run` is the explicit
inference command; it uses only loopback HTTP and never loads or configures a
model through a management endpoint.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

import pilot
import protocol

LAB4_DIR = Path(__file__).resolve().parent
BASE_URL = "http://127.0.0.1:13305/api/v1"
MODEL_ID = "qwen3.5-9b-FLM"
CHECKPOINT = "qwen3.5:9b"
RECIPE = "flm"
DEVICE = "npu"
MAX_TOKENS = 4096
TEMPERATURE = 0
TIMEOUT_SECONDS = 300
MAX_PARALLEL = 2
ROLES = pilot.ROLES
SEEDS = pilot.SEEDS
CHAT_ENDPOINT = BASE_URL + "/chat/completions"


class RunnerError(RuntimeError):
    """A frozen-run, readiness, or local transport error."""


@dataclass(frozen=True)
class HTTPResponse:
    status: int
    body: bytes
    headers: dict[str, str]
    transport_error: str | None = None


Transport = Callable[[str, str, bytes | None, int], HTTPResponse]


def _utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


def _sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def _json_bytes(value: Any, *, pretty: bool = False) -> bytes:
    if pretty:
        return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8", errors="strict")


def _json_read(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RunnerError(f"cannot read JSON file {path}: {exc}") from exc


def _write_once(path: Path, raw: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        if path.read_bytes() != raw:
            raise RunnerError(f"refusing to overwrite frozen artifact {path}")
        raise RunnerError(f"artifact already exists; this call may already have been attempted: {path}")
    with path.open("xb") as stream:
        stream.write(raw)


def validate_base_url(base_url: str) -> str:
    """Allow only the configured loopback Lemonade HTTP endpoint."""
    try:
        parsed = urllib.parse.urlsplit(base_url)
        port = parsed.port
    except ValueError as exc:
        raise RunnerError(f"invalid base URL: {base_url}") from exc
    host = (parsed.hostname or "").lower()
    if (parsed.scheme != "http" or host not in {"127.0.0.1", "localhost", "::1"}
            or port != 13305 or parsed.path.rstrip("/") != "/api/v1"
            or parsed.username is not None or parsed.password is not None or parsed.query or parsed.fragment):
        raise RunnerError("only http://127.0.0.1:13305/api/v1 loopback endpoints are allowed")
    return base_url.rstrip("/")


def stdlib_transport(method: str, url: str, body: bytes | None, timeout: int) -> HTTPResponse:
    parsed = urllib.parse.urlsplit(url)
    validate_base_url(urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, "/api/v1", "", "")))
    if parsed.path not in {"/api/v1/health", "/api/v1/models", "/api/v1/chat/completions"}:
        raise RunnerError("request path is outside the frozen local API allowlist")
    request = urllib.request.Request(url, data=body, method=method, headers={"Content-Type": "application/json"} if body is not None else {})
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(request, timeout=timeout) as response:
            try:
                return HTTPResponse(response.status, response.read(), dict(response.headers.items()))
            except Exception as exc:
                return HTTPResponse(response.status, getattr(exc, "partial", b"") or b"", dict(response.headers.items()),
                                    f"{type(exc).__name__}: {exc}")
    except urllib.error.HTTPError as exc:
        # HTTPError is a completed response, so retain its status, headers and body.
        try:
            data = exc.read()
            err = None
        except Exception as read_exc:
            data = getattr(read_exc, "partial", b"") or b""
            err = f"{type(read_exc).__name__}: {read_exc}"
        return HTTPResponse(exc.code, data, dict(exc.headers.items()) if exc.headers else {}, err)


def _discovered_runtime(discovery: dict[str, Any]) -> dict[str, Any]:
    base = validate_base_url(discovery.get("base_url", ""))
    health = discovery.get("health")
    models = discovery.get("models")
    if type(health) is not dict or type(models) is not dict:
        raise RunnerError("runtime discovery must contain health and model-list objects")
    model_rows = models.get("data")
    if type(model_rows) is not list:
        raise RunnerError("runtime model list has no data array")
    model = next((row for row in model_rows if type(row) is dict and row.get("id") == MODEL_ID), None)
    loaded_rows = health.get("all_models_loaded")
    if type(loaded_rows) is not list:
        raise RunnerError("runtime health has no all_models_loaded list")
    loaded = next((row for row in loaded_rows if type(row) is dict and row.get("model_name") == MODEL_ID), None)
    if model is None or loaded is None:
        raise RunnerError(f"discovery does not contain the required loaded model {MODEL_ID}")
    context = loaded.get("recipe_options", {}).get("ctx_size") if type(loaded.get("recipe_options")) is dict else None
    if type(context) is not int:
        context = model.get("context_length")
    if type(context) is not int or context <= 0:
        raise RunnerError("could not determine the configured context length from discovery")
    return {
        "base_url": base,
        "version": health.get("version"),
        "model": MODEL_ID,
        "checkpoint": CHECKPOINT,
        "recipe": RECIPE,
        "device": DEVICE,
        "context_length": context,
        "max_context_window": loaded.get("max_context_window", model.get("max_context_window")),
        "discovered_at": discovery.get("observed_at"),
    }


def prepare(out_dir: str | Path, *, max_tokens: int = MAX_TOKENS,
            preregistration: str | Path | None = None) -> dict[str, Any]:
    """Freeze the pilot inputs, runtime discovery, and source policy without HTTP."""
    if type(max_tokens) is not int or not 1 <= max_tokens <= MAX_TOKENS:
        raise RunnerError(f"max_tokens must be an integer in [1, {MAX_TOKENS}]")
    run = Path(out_dir).resolve()
    manifest_path = run / "local-run.json"
    if manifest_path.exists():
        raise RunnerError(f"local run already prepared: {run}")
    plan_source = Path(preregistration).resolve() if preregistration is not None else LAB4_DIR / "LOCAL_PREREGISTRATION.md"
    discovery_source = LAB4_DIR / "LOCAL_RUNTIME_DISCOVERY.json"
    if not plan_source.is_file() or not discovery_source.is_file():
        raise RunnerError("the selected preregistration and LOCAL_RUNTIME_DISCOVERY.json must exist before freeze")
    plan_bytes = plan_source.read_bytes()
    plan_snapshot_name = plan_source.name
    discovery_bytes = discovery_source.read_bytes()
    try:
        discovery = json.loads(discovery_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RunnerError(f"runtime discovery is not UTF-8 JSON: {exc}") from exc
    runtime = _discovered_runtime(discovery)
    run.mkdir(parents=True, exist_ok=True)
    frozen = run / "frozen_inputs"
    _write_once(frozen / plan_snapshot_name, plan_bytes)
    _write_once(frozen / "LOCAL_RUNTIME_DISCOVERY.json", discovery_bytes)
    pilot_run = run / "pilot"
    pilot.prepare(pilot_run)
    pilot_manifest_bytes = (pilot_run / "run.json").read_bytes()
    initial_prompt_hashes_bytes = (pilot_run / "prompt_hashes.json").read_bytes()
    _write_once(frozen / "pilot-run.json", pilot_manifest_bytes)
    _write_once(frozen / "pilot-prompt-hashes.json", initial_prompt_hashes_bytes)
    source_paths = {
        "local_runner.py": Path(__file__),
        "pilot.py": LAB4_DIR / "pilot.py",
        "protocol.py": LAB4_DIR / "protocol.py",
        "lab3/experiment.py": LAB4_DIR.parent / "lab3" / "experiment.py",
    }
    source_hashes = {name: _sha(path.read_bytes()) for name, path in source_paths.items()}
    input_hashes = {
        plan_snapshot_name: _sha(plan_bytes),
        "LOCAL_RUNTIME_DISCOVERY.json": _sha(discovery_bytes),
        "pilot/run.json": _sha(pilot_manifest_bytes),
        "pilot/prompt_hashes.json": _sha(initial_prompt_hashes_bytes),
    }
    initial_prompt_hashes = _json_read(pilot_run / "prompt_hashes.json")
    manifest: dict[str, Any] = {
        "schema": "lab4-local-qwen-run-v1",
        "planned_calls": 12,
        "call_ceiling": 12,
        "seeds": list(SEEDS),
        "roles": list(ROLES),
        "schedule": [row for row in pilot._schedule()],
        "model": runtime,
        "request_policy": {
            "method": "POST",
            "url": runtime["base_url"] + "/chat/completions",
            "max_tokens": max_tokens,
            "temperature": TEMPERATURE,
            "stream": False,
            "timeout_seconds": TIMEOUT_SECONDS,
            "parallel_per_pair": MAX_PARALLEL,
            "fresh_context": "one user message per chat completion; no prior role or response is included",
            "response_format": "omitted",
            "retry_policy": "none; every dispatched request consumes its scheduled call slot",
            "content_policy": "save exact message.content bytes; no stripping, markdown removal, JSON repair, or reasoning substitution",
            "reasoning_policy": "preserve reasoning_content separately as raw transport evidence; never feed it to another role",
        },
        "source_hashes": source_hashes,
        "input_hashes": input_hashes,
        "initial_prompt_hashes": initial_prompt_hashes,
        "pilot_template_route": _json_read(pilot_run / "run.json").get("route"),
        "preregistration_file": plan_snapshot_name,
        "frozen_at": _utcnow(),
    }
    manifest["manifest_hash"] = _sha(protocol.canonical_bytes(manifest))
    _write_once(manifest_path, _json_bytes(manifest, pretty=True))
    return manifest


def _check_frozen(run: Path, manifest: dict[str, Any]) -> None:
    manifest_copy = dict(manifest)
    claimed_hash = manifest_copy.pop("manifest_hash", None)
    if claimed_hash != _sha(protocol.canonical_bytes(manifest_copy)):
        raise RunnerError("local run manifest hash mismatch")
    try:
        expected_url = validate_base_url(manifest.get("model", {}).get("base_url", "")) + "/chat/completions"
    except (AttributeError, RunnerError) as exc:
        raise RunnerError("manifest lacks a valid frozen local endpoint") from exc
    if manifest.get("request_policy", {}).get("url") != expected_url:
        raise RunnerError("request URL differs from the frozen loopback chat endpoint")
    frozen_policy = manifest.get("request_policy", {})
    frozen_max_tokens = frozen_policy.get("max_tokens")
    if type(frozen_max_tokens) is not int or not 1 <= frozen_max_tokens <= MAX_TOKENS:
        raise RunnerError(f"frozen max_tokens must be an integer in [1, {MAX_TOKENS}]")
    if frozen_policy.get("temperature") != TEMPERATURE or frozen_policy.get("stream") is not False:
        raise RunnerError("frozen request policy differs from the supported temperature/stream settings")
    actual_paths = {
        "local_runner.py": Path(__file__),
        "pilot.py": LAB4_DIR / "pilot.py",
        "protocol.py": LAB4_DIR / "protocol.py",
        "lab3/experiment.py": LAB4_DIR.parent / "lab3" / "experiment.py",
    }
    for name, path in actual_paths.items():
        if _sha(path.read_bytes()) != manifest["source_hashes"].get(name):
            raise RunnerError(f"frozen source changed after preparation: {name}")
    preregistration_file = manifest.get("preregistration_file")
    if type(preregistration_file) is not str or Path(preregistration_file).name != preregistration_file:
        raise RunnerError("manifest has an invalid preregistration snapshot name")
    frozen_inputs = {
        preregistration_file: run / "frozen_inputs" / preregistration_file,
        "LOCAL_RUNTIME_DISCOVERY.json": run / "frozen_inputs" / "LOCAL_RUNTIME_DISCOVERY.json",
        "pilot/run.json": run / "frozen_inputs" / "pilot-run.json",
        "pilot/prompt_hashes.json": run / "frozen_inputs" / "pilot-prompt-hashes.json",
    }
    for name, path in frozen_inputs.items():
        if _sha(path.read_bytes()) != manifest["input_hashes"].get(name):
            raise RunnerError(f"frozen input changed after preparation: {name}")
    live_inputs = {
        "pilot/run.json": run / "pilot" / "run.json",
    }
    for name, path in live_inputs.items():
        if _sha(path.read_bytes()) != manifest["input_hashes"].get(name):
            raise RunnerError(f"live pilot input changed after preparation: {name}")


def _loaded_record(health: dict[str, Any]) -> dict[str, Any] | None:
    rows = health.get("all_models_loaded")
    if type(rows) is not list:
        return None
    return next((row for row in rows if type(row) is dict and row.get("model_name") == MODEL_ID), None)


def _model_record(models: dict[str, Any]) -> dict[str, Any] | None:
    rows = models.get("data")
    if type(rows) is not list:
        return None
    return next((row for row in rows if type(row) is dict and row.get("id") == MODEL_ID), None)


def verify_readiness(health: dict[str, Any], models: dict[str, Any], expected: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    """Read-only check that the frozen exact model is already loaded and ready."""
    loaded = _loaded_record(health)
    model = _model_record(models)
    reasons = []
    if health.get("status") != "ok":
        reasons.append("health status is not ok")
    if health.get("version") != expected.get("version"):
        reasons.append("Lemonade version differs from frozen discovery")
    if health.get("model_loaded") != MODEL_ID:
        reasons.append("health does not report the requested model as loaded")
    if loaded is None:
        reasons.append("requested model is absent from all_models_loaded")
    else:
        if loaded.get("loaded") is not True or loaded.get("status") != "ready" or loaded.get("backend_alive") is not True:
            reasons.append("requested model is not loaded and ready")
        if loaded.get("is_busy") is True:
            reasons.append("requested model is busy during preflight")
        if loaded.get("checkpoint") != CHECKPOINT or loaded.get("recipe") != RECIPE or loaded.get("device") != DEVICE:
            reasons.append("loaded model checkpoint, recipe, or device differs from frozen discovery")
    if model is None:
        reasons.append("requested model is absent from model list")
    else:
        if model.get("checkpoint") != CHECKPOINT or model.get("recipe") != RECIPE:
            reasons.append("model-list checkpoint or recipe differs from frozen discovery")
    context = None
    if loaded is not None and type(loaded.get("recipe_options")) is dict:
        context = loaded["recipe_options"].get("ctx_size")
    if type(context) is not int and model is not None:
        context = model.get("context_length")
    if type(context) is not int or context != expected.get("context_length"):
        reasons.append("configured context length differs from frozen discovery")
    result = {
        "ready": not reasons,
        "model_id": MODEL_ID,
        "checkpoint": loaded.get("checkpoint") if loaded else None,
        "recipe": loaded.get("recipe") if loaded else None,
        "device": loaded.get("device") if loaded else None,
        "context_length": context,
        "version": health.get("version"),
        "reasons": reasons,
    }
    return not reasons, result


class LocalRunner:
    """Executes the two-seed schedule through a loopback HTTP transport."""

    def __init__(self, run_dir: str | Path, *, transport: Transport = stdlib_transport):
        self.run_dir = Path(run_dir).resolve()
        self.transport = transport
        self._write_lock = threading.Lock()
        self.max_tokens = MAX_TOKENS

    def _manifest(self) -> dict[str, Any]:
        path = self.run_dir / "local-run.json"
        if not path.is_file():
            raise RunnerError(f"not a prepared local run: {self.run_dir}")
        manifest = _json_read(path)
        _check_frozen(self.run_dir, manifest)
        return manifest

    def _save_http(self, path: Path, result: HTTPResponse) -> str:
        _write_once(path, result.body)
        meta_path = path.with_name(path.name.replace(".response.raw", ".http.json"))
        meta = {"status": result.status, "headers": result.headers, "body_sha256": _sha(result.body), "received_at": _utcnow()}
        _write_once(meta_path, _json_bytes(meta, pretty=True))
        return _sha(result.body)

    def _preflight(self, manifest: dict[str, Any]) -> dict[str, Any]:
        root = self.run_dir / "backend" / "preflight"
        root.mkdir(parents=True, exist_ok=True)
        attempts = len(list(root.glob("attempt-*"))) + 1
        attempt = root / f"attempt-{attempts:03d}"
        attempt.mkdir(parents=True, exist_ok=False)
        base = validate_base_url(manifest["model"]["base_url"])
        start = _utcnow()
        try:
            health_response = self.transport("GET", base + "/health", None, TIMEOUT_SECONDS)
            _write_once(attempt / "health.response.raw", health_response.body)
            _write_once(attempt / "health.http.json", _json_bytes({"status": health_response.status, "headers": health_response.headers}, pretty=True))
            models_response = self.transport("GET", base + "/models", None, TIMEOUT_SECONDS)
            _write_once(attempt / "models.response.raw", models_response.body)
            _write_once(attempt / "models.http.json", _json_bytes({"status": models_response.status, "headers": models_response.headers}, pretty=True))
        except Exception as exc:
            receipt = {"ready": False, "slots_consumed": 0, "reason": f"readiness_transport_failure: {type(exc).__name__}: {exc}", "started_at": start, "finished_at": _utcnow()}
            _write_once(attempt / "receipt.json", _json_bytes(receipt, pretty=True))
            raise RunnerError(receipt["reason"]) from exc
        if health_response.status < 200 or health_response.status >= 300 or models_response.status < 200 or models_response.status >= 300:
            receipt = {"ready": False, "slots_consumed": 0, "reason": "readiness_http_status_failure", "health_status": health_response.status, "models_status": models_response.status, "started_at": start, "finished_at": _utcnow()}
            _write_once(attempt / "receipt.json", _json_bytes(receipt, pretty=True))
            raise RunnerError(receipt["reason"])
        try:
            health = json.loads(health_response.body.decode("utf-8"))
            models = json.loads(models_response.body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            receipt = {"ready": False, "slots_consumed": 0, "reason": f"readiness_json_failure: {exc}", "started_at": start, "finished_at": _utcnow()}
            _write_once(attempt / "receipt.json", _json_bytes(receipt, pretty=True))
            raise RunnerError(receipt["reason"]) from exc
        ready, result = verify_readiness(health, models, manifest["model"])
        result.update({
            "started_at": start, "finished_at": _utcnow(),
            "health_sha256": _sha(health_response.body), "models_sha256": _sha(models_response.body),
            "slots_consumed": 0,
        })
        receipt_bytes = _json_bytes(result, pretty=True)
        _write_once(attempt / "receipt.json", receipt_bytes)
        if not ready:
            raise RunnerError("readiness mismatch: " + "; ".join(result["reasons"]))
        # Canonical readiness capture is frozen before any completion request.
        _write_once(self.run_dir / "backend" / "readiness.json", receipt_bytes)
        return result

    def _prompt_and_request(self, manifest: dict[str, Any], seed: int, role: str) -> tuple[Path, bytes, Path]:
        prompt_path = pilot.role_prompt(self.run_dir / "pilot", seed, role)
        prompt_bytes = prompt_path.read_bytes()
        prompt = prompt_bytes.decode("utf-8", errors="strict")
        message = {"role": "user", "content": prompt}
        body = _json_bytes({
            "model": MODEL_ID,
            "messages": [message],
            "max_tokens": manifest["request_policy"]["max_tokens"],
            "temperature": TEMPERATURE,
            "stream": False,
        })
        request_path = self.run_dir / "requests" / str(seed) / f"{role}.request.json"
        request_meta_path = self.run_dir / "requests" / str(seed) / f"{role}.request-meta.json"
        with self._write_lock:
            _write_once(request_path, body)
            prompt_hashes = _json_read(self.run_dir / "pilot" / "prompt_hashes.json")
            prompt_key = f"{seed}/{role}"
            if prompt_hashes.get(prompt_key) != _sha(prompt_bytes):
                raise RunnerError(f"prompt bytes do not match their recorded frozen hash: {prompt_key}")
            frozen_initial = manifest.get("initial_prompt_hashes", {})
            if prompt_key in frozen_initial and prompt_hashes[prompt_key] != frozen_initial[prompt_key]:
                raise RunnerError(f"initial prompt hash changed after preparation: {prompt_key}")
            request_meta = {
                "seed": seed, "role": role, "method": "POST", "url": manifest["request_policy"]["url"],
                "headers": {"Content-Type": "application/json"},
                "request_sha256": _sha(body), "prompt_sha256": prompt_hashes[prompt_key],
                "prompt_bytes_sha256": _sha(prompt_bytes), "model": MODEL_ID,
                "max_tokens": manifest["request_policy"]["max_tokens"], "temperature": TEMPERATURE, "stream": False,
                "timeout_seconds": TIMEOUT_SECONDS, "response_format": None,
            }
            _write_once(request_meta_path, _json_bytes(request_meta, pretty=True))
        return prompt_path, body, request_path

    def _failure(self, seed: int, role: str, reason: str, *, started_at: str, elapsed: float,
                 http_status: int | None = None, extra: dict[str, Any] | None = None) -> dict[str, Any]:
        record: dict[str, Any] = {
            "seed": seed, "role": role, "failed": True, "reason": reason,
            "started_at": started_at, "finished_at": _utcnow(), "duration_seconds": elapsed,
            "http_status": http_status,
        }
        if extra:
            record.update(extra)
        path = self.run_dir / "transport" / str(seed) / f"{role}.failure.json"
        _write_once(path, _json_bytes(record, pretty=True))
        pilot.record_failure(self.run_dir / "pilot", seed, role, reason, metadata={
            "provider": "Lemonade-local", "model": MODEL_ID, "checkpoint": CHECKPOINT,
            "recipe": RECIPE, "device": DEVICE, "max_tokens": self.max_tokens, "temperature": TEMPERATURE,
            "started_at": started_at, "finished_at": record["finished_at"], "duration_seconds": elapsed,
        })
        return record

    def _invoke(self, manifest: dict[str, Any], seed: int, role: str, request_body: bytes) -> dict[str, Any]:
        started_at = _utcnow()
        start = time.monotonic()
        response_path = self.run_dir / "transport" / str(seed) / f"{role}.response.raw"
        try:
            result = self.transport("POST", manifest["request_policy"]["url"], request_body, TIMEOUT_SECONDS)
        except Exception as exc:
            elapsed = time.monotonic() - start
            return self._failure(seed, role, f"transport_failure: {type(exc).__name__}: {exc}", started_at=started_at, elapsed=elapsed)
        elapsed = time.monotonic() - start
        response_hash = self._save_http(response_path, result)
        if result.transport_error:
            return self._failure(seed, role, f"transport_incomplete_response: {result.transport_error}", started_at=started_at,
                elapsed=elapsed, http_status=result.status, extra={"http_response_sha256": response_hash,
                    "partial_response_bytes": len(result.body)})
        if result.status < 200 or result.status >= 300:
            return self._failure(seed, role, "http_status_failure", started_at=started_at, elapsed=elapsed,
                http_status=result.status, extra={"http_response_sha256": response_hash})
        try:
            value = json.loads(result.body.decode("utf-8"))
            choices = value.get("choices")
            choice = choices[0] if type(choices) is list and choices else None
            message = choice.get("message") if type(choice) is dict else None
            if type(message) is not dict:
                raise ValueError("response lacks choices[0].message")
            content = message.get("content")
            reasoning = message.get("reasoning_content")
            if type(content) is not str:
                raise ValueError("response message.content is not a string")
        except (UnicodeDecodeError, json.JSONDecodeError, AttributeError, ValueError, TypeError) as exc:
            return self._failure(seed, role, f"response_parse_failure: {exc}", started_at=started_at, elapsed=elapsed,
                http_status=result.status, extra={"http_response_sha256": response_hash})
        content_bytes = content.encode("utf-8", errors="strict")
        content_path = self.run_dir / "transport" / str(seed) / f"{role}.content.raw"
        _write_once(content_path, content_bytes)
        reasoning_hash = None
        if reasoning is not None:
            if type(reasoning) is str:
                reasoning_bytes = reasoning.encode("utf-8", errors="strict")
                reasoning_path = self.run_dir / "transport" / str(seed) / f"{role}.reasoning.raw"
            else:
                reasoning_bytes = _json_bytes(reasoning)
                reasoning_path = self.run_dir / "transport" / str(seed) / f"{role}.reasoning.json"
            _write_once(reasoning_path, reasoning_bytes)
            reasoning_hash = _sha(reasoning_bytes)
        returned_model = value.get("model")
        finish_reason = choice.get("finish_reason")
        usage = value.get("usage")
        if returned_model not in {MODEL_ID, CHECKPOINT}:
            return self._failure(seed, role, "response_model_mismatch", started_at=started_at, elapsed=elapsed,
                http_status=result.status, extra={"http_response_sha256": response_hash, "content_sha256": _sha(content_bytes),
                    "response_model": returned_model, "finish_reason": finish_reason, "usage": usage})
        finished_at = _utcnow()
        call_record = {
            "seed": seed, "role": role, "provider": "Lemonade-local", "model": MODEL_ID,
            "returned_model": returned_model,
            "checkpoint": CHECKPOINT, "recipe": RECIPE, "device": DEVICE,
            "max_tokens": manifest["request_policy"]["max_tokens"],
            "http_status": result.status, "http_response_sha256": response_hash,
            "content_sha256": _sha(content_bytes), "reasoning_sha256": reasoning_hash,
            "usage": usage, "finish_reason": finish_reason,
            "possibly_truncated": finish_reason == "length",
            "started_at": started_at, "finished_at": finished_at, "duration_seconds": elapsed,
            "request_sha256": _sha(request_body),
        }
        try:
            receipt = pilot.submit_response(self.run_dir / "pilot", seed, role, content_bytes, metadata=call_record)
        except Exception as exc:
            return self._failure(seed, role, f"pilot_submit_failure: {type(exc).__name__}: {exc}", started_at=started_at,
                elapsed=elapsed, http_status=result.status, extra={"http_response_sha256": response_hash,
                    "content_sha256": _sha(content_bytes), "reasoning_sha256": reasoning_hash,
                    "finish_reason": finish_reason, "usage": usage})
        call_record["pilot_receipt"] = receipt
        call_path = self.run_dir / "transport" / str(seed) / f"{role}.call.json"
        _write_once(call_path, _json_bytes(call_record, pretty=True))
        return call_record

    def _dispatch_pair(self, manifest: dict[str, Any], seed: int, roles: tuple[str, str]) -> list[dict[str, Any]]:
        prepared = [self._prompt_and_request(manifest, seed, role) for role in roles]
        results: list[dict[str, Any]] = []
        with ThreadPoolExecutor(max_workers=MAX_PARALLEL, thread_name_prefix=f"lab4-{seed}") as pool:
            futures = {
                pool.submit(self._invoke, manifest, seed, role, prepared[index][1]): role
                for index, role in enumerate(roles)
            }
            for future in as_completed(futures):
                role = futures[future]
                try:
                    results.append(future.result())
                except Exception as exc:
                    # A dispatched call must consume its slot even if local persistence fails.
                    if pilot._outcome_saved(self.run_dir / "pilot", seed, role):
                        raise RunnerError(f"call {seed}/{role} was already recorded; stop without retry") from exc
                    started = _utcnow()
                    try:
                        results.append(self._failure(seed, role, f"runner_failure: {type(exc).__name__}: {exc}",
                            started_at=started, elapsed=0.0))
                    except Exception as record_exc:
                        raise RunnerError(f"could not persist failure for dispatched call {seed}/{role}") from record_exc
        return results

    def run(self) -> dict[str, Any]:
        manifest = self._manifest()
        self.max_tokens = manifest["request_policy"]["max_tokens"]
        if (self.run_dir / "run_started.json").exists():
            raise RunnerError("this run already dispatched requests; automatic rerun is disabled")
        self._preflight(manifest)
        start_record = {"started_at": _utcnow(), "manifest_hash": manifest["manifest_hash"],
            "readiness_sha256": _sha((self.run_dir / "backend" / "readiness.json").read_bytes()),
            "inference_calls_planned": 12}
        _write_once(self.run_dir / "run_started.json", _json_bytes(start_record, pretty=True))
        all_call_results: list[dict[str, Any]] = []
        for seed in SEEDS:
            all_call_results.extend(self._dispatch_pair(manifest, seed, ("u-proposer", "v-proposer")))
            # Materialize both cross-review prompts before either peer call begins.
            pilot.role_prompt(self.run_dir / "pilot", seed, "u-reviewer")
            pilot.role_prompt(self.run_dir / "pilot", seed, "v-reviewer")
            all_call_results.extend(self._dispatch_pair(manifest, seed, ("u-reviewer", "v-reviewer")))
            # Both final prompts are fixed before dispatch, so neither integrator sees the other's response.
            pilot.final_prompts(self.run_dir / "pilot", seed)
            all_call_results.extend(self._dispatch_pair(manifest, seed, ("shared-integrator", "raw-integrator")))
        # The existing pilot enforces all 12 slots before exposing evaluator results.
        evaluation = pilot.evaluate(self.run_dir / "pilot")
        eval_bytes = _json_bytes(evaluation, pretty=True)
        _write_once(self.run_dir / "evaluation.json", eval_bytes)
        final = {
            "status": "complete", "started_at": start_record["started_at"], "finished_at": _utcnow(),
            "manifest_hash": manifest["manifest_hash"], "readiness_sha256": start_record["readiness_sha256"],
            "recorded_call_count": len(all_call_results), "evaluation_sha256": _sha(eval_bytes),
            "failed_call_count": sum(1 for row in all_call_results if row.get("failed")),
            "calls": [{"seed": row.get("seed"), "role": row.get("role"), "failed": bool(row.get("failed")),
                       "pilot_receipt": row.get("pilot_receipt"), "finish_reason": row.get("finish_reason"),
                       "usage": row.get("usage"), "duration_seconds": row.get("duration_seconds")} for row in all_call_results],
        }
        _write_once(self.run_dir / "run_complete.json", _json_bytes(final, pretty=True))
        return {"run": final, "evaluation": evaluation}


def _cli() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare", help="freeze local plan, model discovery and pilot prompts; no network requests")
    prepare_parser.add_argument("--out-dir", required=True)
    prepare_parser.add_argument("--max-tokens", type=int, default=MAX_TOKENS,
                                help=f"freeze the completion cap (integer 1..{MAX_TOKENS}; default {MAX_TOKENS})")
    prepare_parser.add_argument("--preregistration", help="optional preregistration file to snapshot under its filename")
    run_parser = commands.add_parser("run", help="verify local readiness, then dispatch the twelve local model calls")
    run_parser.add_argument("--run-dir", required=True)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            result = prepare(args.out_dir, max_tokens=args.max_tokens, preregistration=args.preregistration)
        else:
            result = LocalRunner(args.run_dir).run()
        sys.stdout.write(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
    except (RunnerError, pilot.PilotError, protocol.ProtocolError) as exc:
        parser.exit(2, f"local_runner: {exc}\n")


if __name__ == "__main__":
    _cli()

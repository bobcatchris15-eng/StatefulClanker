"""Structural-only, replayable message and claim protocol for Lab 4."""
from __future__ import annotations

import hashlib
import json
import sqlite3
import base64
from pathlib import Path
from typing import Any, Iterable

SCHEMA_VERSION = 1
INTENTS = {"PROPOSE", "CHALLENGE", "REQUEST_EVIDENCE", "REPORT_EVIDENCE", "RETRACT", "CONCLUDE"}
CLAIM_STATUSES = {"active", "challenged", "retracted", "invalidated", "superseded"}
ENVELOPE_FIELDS = {"schema_version", "problem_id", "message_id", "sender", "recipients", "intent", "read_refs", "payload", "reply_to"}


class ProtocolError(ValueError):
    """A structurally invalid message or unsupported JSON value."""


class InvalidJSON(ProtocolError):
    """Input bytes do not encode valid UTF-8 JSON."""


class InvalidSchema(ProtocolError):
    """JSON parses, but violates the protocol's structural schema."""


def _json_value(value: Any) -> None:
    if value is None or type(value) in (bool, int):
        return
    if type(value) is str:
        try:
            value.encode("utf-8", errors="strict")
        except UnicodeEncodeError as exc:
            raise InvalidSchema("strings must contain Unicode scalar values") from exc
        return
    if type(value) is list:
        for item in value:
            _json_value(item)
        return
    if type(value) is dict:
        for key, item in value.items():
            if type(key) is not str:
                raise InvalidSchema("object keys must be strings")
            _json_value(key)
            _json_value(item)
        return
    raise InvalidSchema("only null, booleans, integers, strings, arrays, and objects are allowed")


def canonical_bytes(value: Any) -> bytes:
    """Return compact sorted UTF-8 JSON, rejecting floats and non-JSON values."""
    _json_value(value)
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8", errors="strict")
    except (UnicodeEncodeError, ValueError, TypeError) as exc:
        raise InvalidSchema("value cannot be encoded as canonical UTF-8 JSON") from exc


def _pairs_no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise InvalidSchema("duplicate object key")
        result[key] = value
    return result


def _reject_number(value: str) -> None:
    raise InvalidSchema("floating point and non-finite numbers are forbidden")


def parse_json(raw_bytes: bytes) -> Any:
    if not isinstance(raw_bytes, (bytes, bytearray)):
        raise InvalidJSON("message input must be bytes")
    try:
        text = bytes(raw_bytes).decode("utf-8", errors="strict")
        value = json.loads(text, object_pairs_hook=_pairs_no_duplicates, parse_float=_reject_number, parse_constant=_reject_number)
        _json_value(value)
        return value
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise InvalidJSON("invalid UTF-8 JSON") from exc


def _nonempty_string(value: Any) -> bool:
    return type(value) is str and bool(value)


def _ref(value: Any, *, dependency: bool = False) -> bool:
    if type(value) is not dict:
        return False
    fields = {"resource_id", "claim_revision"} if dependency else {"resource_id", "revision", "state_revision"}
    if set(value) != fields or not _nonempty_string(value["resource_id"]):
        return False
    key = "claim_revision" if dependency else "revision"
    if type(value[key]) is not int or value[key] < 0:
        return False
    if not dependency and (type(value["state_revision"]) is not int or value["state_revision"] < 0):
        return False
    return True


def _claim_shape(claim: Any, *, candidate: bool = False) -> bool:
    if type(claim) is not dict:
        return False
    if candidate:
        allowed = {"claim_id", "revision", "state_revision", "status", "value", "provenance", "dependencies"}
        if not allowed.issubset(claim) or set(claim) - allowed:
            return False
    elif set(claim) != {"claim_id", "revision", "state_revision", "status", "value", "provenance", "dependencies"}:
        return False
    if not _nonempty_string(claim.get("claim_id")) or type(claim.get("revision")) is not int or claim["revision"] < 1 or type(claim.get("state_revision")) is not int or claim["state_revision"] < 1:
        return False
    if candidate and claim.get("status") != "candidate":
        return False
    if not candidate and claim.get("status") != "active":
        return False
    provenance = claim.get("provenance")
    if type(provenance) is not dict or not _nonempty_string(provenance.get("message_id")):
        return False
    dependencies = claim.get("dependencies")
    if type(dependencies) is not list or not all(_ref(d, dependency=True) for d in dependencies):
        return False
    return True


def _payload_shape(intent: str, payload: Any) -> bool:
    if type(payload) is not dict:
        return False
    if intent == "PROPOSE":
        return set(payload) == {"claim"} and _claim_shape(payload["claim"])
    if intent == "CHALLENGE":
        return {"target", "assessment"}.issubset(payload) and set(payload) <= {"target", "assessment", "corrected_claim"} and _ref(payload["target"]) and type(payload["assessment"]) is dict and ("corrected_claim" not in payload or _claim_shape(payload["corrected_claim"], candidate=True))
    if intent == "REQUEST_EVIDENCE":
        return set(payload) == {"target", "request"} and _ref(payload["target"]) and type(payload["request"]) is dict
    if intent == "REPORT_EVIDENCE":
        return "report" in payload and set(payload) <= {"report", "corrected_claim"} and type(payload["report"]) is dict and ("corrected_claim" not in payload or _claim_shape(payload["corrected_claim"], candidate=True))
    if intent == "RETRACT":
        return set(payload) == {"target", "reason_code"} and _ref(payload["target"]) and _nonempty_string(payload["reason_code"])
    if intent == "CONCLUDE":
        return set(payload) == {"conclusion"} and type(payload["conclusion"]) is dict
    return False


def parse_envelope(raw_bytes: bytes) -> dict[str, Any]:
    value = parse_json(raw_bytes)
    if type(value) is not dict or set(value) != ENVELOPE_FIELDS:
        raise InvalidSchema("envelope fields do not match schema version 1")
    if type(value["schema_version"]) is not int or value["schema_version"] != SCHEMA_VERSION:
        raise InvalidSchema("unsupported schema version")
    for field in ("problem_id", "message_id", "sender"):
        if not _nonempty_string(value[field]):
            raise InvalidSchema(f"{field} must be a nonempty string")
    recipients = value["recipients"]
    if type(recipients) is not list or not recipients or any(not _nonempty_string(x) for x in recipients) or len(recipients) != len(set(recipients)):
        raise InvalidSchema("recipients must be a nonempty unique string array")
    if type(value["intent"]) is not str or value["intent"] not in INTENTS:
        raise InvalidSchema("unknown intent")
    if type(value["read_refs"]) is not list or not all(_ref(ref) for ref in value["read_refs"]):
        raise InvalidSchema("read_refs must contain exact value and lifecycle revisions")
    if len({ref["resource_id"] for ref in value["read_refs"]}) != len(value["read_refs"]):
        raise InvalidSchema("read_refs cannot contain duplicate resources")
    if value["reply_to"] is not None and not _nonempty_string(value["reply_to"]):
        raise InvalidSchema("reply_to must be null or a nonempty message id")
    if not _payload_shape(value["intent"], value["payload"]):
        raise InvalidSchema("payload does not match intent")
    return value


def _connect(path: str | Path) -> sqlite3.Connection:
    db = sqlite3.connect(str(path), timeout=30, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA busy_timeout=30000")
    db.execute("PRAGMA foreign_keys=ON")
    return db


def _schema(db: sqlite3.Connection) -> None:
    db.executescript("""
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS participants (name TEXT PRIMARY KEY);
    CREATE TABLE IF NOT EXISTS problem_resource (problem_id TEXT PRIMARY KEY, packet_json TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision=1), state_revision INTEGER NOT NULL CHECK(state_revision=1));
    CREATE TABLE IF NOT EXISTS submissions (
      receive_seq INTEGER PRIMARY KEY AUTOINCREMENT,
      problem_id TEXT,
      message_id TEXT,
      raw BLOB NOT NULL,
      parsed_json TEXT,
      accepted INTEGER NOT NULL,
      event_seq INTEGER,
      code TEXT,
      receipt_json TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS events (
      event_seq INTEGER PRIMARY KEY AUTOINCREMENT,
      message_id TEXT NOT NULL UNIQUE,
      problem_id TEXT NOT NULL,
      envelope_json TEXT NOT NULL,
      raw BLOB NOT NULL,
      event_hash TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS projection_claims (
      problem_id TEXT NOT NULL,
      claim_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      state_revision INTEGER NOT NULL,
      status TEXT NOT NULL,
      value_json TEXT NOT NULL,
      provenance_json TEXT NOT NULL,
      dependencies_json TEXT NOT NULL,
      owner TEXT NOT NULL,
      PRIMARY KEY(problem_id, claim_id)
    );
    CREATE TABLE IF NOT EXISTS projection_claim_history (
      problem_id TEXT NOT NULL,
      claim_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      state_revision INTEGER NOT NULL,
      status TEXT NOT NULL,
      value_json TEXT NOT NULL,
      provenance_json TEXT NOT NULL,
      dependencies_json TEXT NOT NULL,
      owner TEXT NOT NULL,
      PRIMARY KEY(problem_id, claim_id, revision)
    );
    CREATE TABLE IF NOT EXISTS projection_reviews (
      problem_id TEXT NOT NULL,
      message_id TEXT NOT NULL,
      event_seq INTEGER NOT NULL,
      envelope_json TEXT NOT NULL,
      PRIMARY KEY(problem_id, message_id)
    );
    CREATE TABLE IF NOT EXISTS projection_candidates (
      problem_id TEXT NOT NULL,
      message_id TEXT NOT NULL,
      candidate_index INTEGER NOT NULL,
      candidate_json TEXT NOT NULL,
      PRIMARY KEY(problem_id, message_id, candidate_index)
    );
    CREATE TABLE IF NOT EXISTS forks (
      fork_id TEXT PRIMARY KEY,
      message_id TEXT NOT NULL UNIQUE,
      problem_id TEXT NOT NULL,
      raw BLOB NOT NULL,
      envelope_json TEXT NOT NULL,
      read_refs_json TEXT NOT NULL,
      base_event_seq INTEGER NOT NULL,
      historical_projection_json TEXT NOT NULL,
      proposed_projection_json TEXT NOT NULL,
      status TEXT NOT NULL,
      resolution_json TEXT,
      receipt_json TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS fork_resolutions (
      resolution_seq INTEGER PRIMARY KEY AUTOINCREMENT,
      fork_id TEXT NOT NULL,
      administrator TEXT NOT NULL,
      decision TEXT NOT NULL,
      evidence_ref_json TEXT NOT NULL,
      prevailing_workable INTEGER NOT NULL CHECK(prevailing_workable=1),
      receipt_json TEXT NOT NULL
    );
    """)


def initialize_store(path: str | Path, problem_id: str, participants: Iterable[str], problem_packet: Any) -> None:
    if not _nonempty_string(problem_id):
        raise ProtocolError("problem_id must be nonempty")
    packet_json = canonical_bytes(problem_packet).decode("utf-8")
    participant_names = set(participants) | {"shared-integrator", "raw-integrator"}
    if any(not _nonempty_string(p) for p in participant_names):
        raise ProtocolError("participant names must be nonempty strings")
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    db = _connect(path)
    try:
        _schema(db)
        db.execute("BEGIN IMMEDIATE")
        old = db.execute("SELECT value FROM meta WHERE key='problem_id'").fetchone()
        if old:
            existing_packet = db.execute("SELECT packet_json FROM problem_resource WHERE problem_id=?", (problem_id,)).fetchone()
            if old["value"] != problem_id or existing_packet is None or existing_packet["packet_json"] != packet_json:
                raise ProtocolError("store already initialized with different frozen inputs")
            db.commit()
            return
        db.execute("INSERT INTO meta(key,value) VALUES('problem_id',?)", (problem_id,))
        db.execute("INSERT INTO problem_resource VALUES(?,?,1,1)", (problem_id, packet_json))
        participant_names.add("protocol-admin")
        db.executemany("INSERT INTO participants(name) VALUES(?)", ((p,) for p in sorted(participant_names)))
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


def _ref_current(db: sqlite3.Connection, problem_id: str, ref: dict[str, Any]) -> tuple[int, int] | None:
    rid = ref["resource_id"]
    if rid == f"problem:{problem_id}":
        return (1, 1)
    if rid.startswith("claim:"):
        row = db.execute("SELECT revision,state_revision FROM projection_claims WHERE problem_id=? AND claim_id=?", (problem_id, rid[6:])).fetchone()
        return (0, 0) if row is None and ref["revision"] == 0 and ref["state_revision"] == 0 else (None if row is None else (row["revision"], row["state_revision"]))
    if rid.startswith("event:"):
        row = db.execute("SELECT 1 FROM events WHERE problem_id=? AND message_id=?", (problem_id, rid[6:])).fetchone()
        return (1, 1) if row is not None else None
    return None


def _deps_valid(db: sqlite3.Connection, problem_id: str, deps: list[dict[str, Any]]) -> bool:
    for dep in deps:
        rid = dep["resource_id"]
        rev = dep["claim_revision"]
        if rid == f"problem:{problem_id}":
            if rev != 1:
                return False
        elif rid.startswith("claim:"):
            row = db.execute("SELECT revision,status FROM projection_claims WHERE problem_id=? AND claim_id=?", (problem_id, rid[6:])).fetchone()
            if row is None or row["revision"] != rev or row["status"] in ("retracted", "invalidated", "superseded"):
                return False
        else:
            return False
    return True


def _receipt(message_id: str | None, accepted: bool, event_seq: int | None = None, code: str | None = None) -> dict[str, Any]:
    result: dict[str, Any] = {"message_id": message_id, "accepted": accepted, "event_seq": event_seq}
    if code:
        result["code"] = code
    return result


def _record_rejection(db: sqlite3.Connection, raw: bytes, message_id: str | None, problem_id: str | None, code: str, parsed: dict[str, Any] | None = None) -> dict[str, Any]:
    receipt = _receipt(message_id, False, code=code)
    db.execute("INSERT INTO submissions(problem_id,message_id,raw,parsed_json,accepted,event_seq,code,receipt_json) VALUES(?,?,?,?,0,NULL,?,?)", (problem_id, message_id, bytes(raw), None if parsed is None else canonical_bytes(parsed).decode(), code, canonical_bytes(receipt).decode()))
    return receipt


def _validate_authorization(db: sqlite3.Connection, env: dict[str, Any]) -> str | None:
    sender = db.execute("SELECT 1 FROM participants WHERE name=?", (env["sender"],)).fetchone()
    if sender is None:
        return "UNKNOWN_SENDER"
    for recipient in env["recipients"]:
        if db.execute("SELECT 1 FROM participants WHERE name=?", (recipient,)).fetchone() is None:
            return "INVALID_RECIPIENT"
    return None


def _validate_reads(db: sqlite3.Connection, env: dict[str, Any]) -> str | None:
    for ref in env["read_refs"]:
        current = _ref_current(db, env["problem_id"], ref)
        if current is None:
            return "UNKNOWN_REFERENCE"
        if current != (ref["revision"], ref["state_revision"]):
            return "STALE_READ"
    if env["reply_to"] is not None:
        prior = db.execute("SELECT 1 FROM submissions WHERE problem_id=? AND message_id=?", (env["problem_id"], env["reply_to"])).fetchone()
        if prior is None:
            return "UNKNOWN_REFERENCE"
    return None


def _claim_ref(env: dict[str, Any], claim_id: str) -> dict[str, Any] | None:
    target = f"claim:{claim_id}"
    return next((ref for ref in env["read_refs"] if ref["resource_id"] == target), None)


def _validate_candidate(db: sqlite3.Connection, env: dict[str, Any], candidate: dict[str, Any]) -> str | None:
    if candidate["provenance"].get("message_id") != env["message_id"]:
        return "INVALID_SCHEMA"
    for dep in candidate["dependencies"]:
        if not any(ref["resource_id"] == dep["resource_id"] and ref["revision"] == dep["claim_revision"] for ref in env["read_refs"]):
            return "INVALID_TRANSITION"
    if not _deps_valid(db, env["problem_id"], candidate["dependencies"]):
        return "UNKNOWN_REFERENCE"
    return None


def _validate_transition(db: sqlite3.Connection, env: dict[str, Any]) -> str | None:
    problem_id = env["problem_id"]
    intent, payload = env["intent"], env["payload"]
    if intent == "PROPOSE":
        claim = payload["claim"]
        claim_id = claim["claim_id"]
        ref = _claim_ref(env, claim_id)
        if ref is None:
            return "INVALID_TRANSITION"
        existing = db.execute("SELECT revision,state_revision,status FROM projection_claims WHERE problem_id=? AND claim_id=?", (problem_id, claim_id)).fetchone()
        if existing is None:
            if ref["revision"] != 0 or ref["state_revision"] != 0 or claim["revision"] != 1 or claim["state_revision"] != 1:
                return "INVALID_TRANSITION"
        else:
            if existing["status"] in ("retracted", "invalidated", "superseded") or claim["revision"] != existing["revision"] + 1 or claim["state_revision"] != existing["state_revision"] + 1:
                return "INVALID_TRANSITION"
        if claim["provenance"].get("message_id") != env["message_id"]:
            return "INVALID_SCHEMA"
        for dep in claim["dependencies"]:
            if not any(ref["resource_id"] == dep["resource_id"] and ref["revision"] == dep["claim_revision"] for ref in env["read_refs"]):
                return "INVALID_TRANSITION"
        if not _deps_valid(db, problem_id, claim["dependencies"]):
            return "UNKNOWN_REFERENCE"
    elif intent in ("CHALLENGE", "REQUEST_EVIDENCE", "RETRACT"):
        target = payload["target"]
        ref = next((r for r in env["read_refs"] if r["resource_id"] == target["resource_id"]), None)
        if ref != target:
            return "INVALID_TRANSITION"
        if _ref_current(db, problem_id, target) != (target["revision"], target["state_revision"]):
            return "STALE_READ"
        if intent == "RETRACT":
            claim_id = target["resource_id"][6:] if target["resource_id"].startswith("claim:") else ""
            row = db.execute("SELECT owner FROM projection_claims WHERE problem_id=? AND claim_id=?", (problem_id, claim_id)).fetchone()
            if row is None:
                return "UNKNOWN_REFERENCE"
            if env["sender"] not in (row["owner"], "shared-integrator"):
                return "INVALID_TRANSITION"
        if intent == "CHALLENGE" and "corrected_claim" in payload:
            candidate_code = _validate_candidate(db, env, payload["corrected_claim"])
            if candidate_code:
                return candidate_code
    elif intent == "REPORT_EVIDENCE" and "corrected_claim" in payload:
        candidate_code = _validate_candidate(db, env, payload["corrected_claim"])
        if candidate_code:
            return candidate_code
    return None


def _current_projection(db: sqlite3.Connection, problem_id: str) -> dict[str, Any]:
    resource = db.execute("SELECT packet_json FROM problem_resource WHERE problem_id=?", (problem_id,)).fetchone()
    if resource is None:
        raise ProtocolError("unknown problem")
    claims: dict[str, Any] = {}
    for row in db.execute("SELECT * FROM projection_claims WHERE problem_id=? ORDER BY claim_id", (problem_id,)):
        claims[row["claim_id"]] = {
            "claim_id": row["claim_id"], "revision": row["revision"], "state_revision": row["state_revision"],
            "status": row["status"], "value": parse_json(row["value_json"].encode()),
            "provenance": parse_json(row["provenance_json"].encode()), "dependencies": parse_json(row["dependencies_json"].encode()),
            "owner": row["owner"],
        }
    reviews = [parse_json(r["envelope_json"].encode()) for r in db.execute("SELECT envelope_json FROM projection_reviews WHERE problem_id=? ORDER BY event_seq", (problem_id,))]
    candidates = []
    for row in db.execute("SELECT message_id,candidate_json FROM projection_candidates WHERE problem_id=? ORDER BY message_id,candidate_index", (problem_id,)):
        candidates.append({"message_id": row["message_id"], "claim": parse_json(row["candidate_json"].encode())})
    claim_history: dict[str, list[dict[str, Any]]] = {}
    for row in db.execute("SELECT * FROM projection_claim_history WHERE problem_id=? ORDER BY claim_id,revision", (problem_id,)):
        claim_history.setdefault(row["claim_id"], []).append({
            "claim_id": row["claim_id"], "revision": row["revision"], "state_revision": row["state_revision"],
            "status": row["status"], "value": parse_json(row["value_json"].encode()),
            "provenance": parse_json(row["provenance_json"].encode()), "dependencies": parse_json(row["dependencies_json"].encode()),
            "owner": row["owner"],
        })
    return {"problem_id": problem_id, "problem": parse_json(resource["packet_json"].encode()), "claims": claims, "claim_history": claim_history, "reviews": reviews, "candidates": candidates}


def _replace_projection(db: sqlite3.Connection, problem_id: str, projection: dict[str, Any]) -> None:
    db.execute("DELETE FROM projection_claims WHERE problem_id=?", (problem_id,))
    db.execute("DELETE FROM projection_claim_history WHERE problem_id=?", (problem_id,))
    db.execute("DELETE FROM projection_reviews WHERE problem_id=?", (problem_id,))
    db.execute("DELETE FROM projection_candidates WHERE problem_id=?", (problem_id,))
    for claim in projection["claims"].values():
        db.execute("INSERT INTO projection_claims VALUES(?,?,?,?,?,?,?,?,?)", (problem_id, claim["claim_id"], claim["revision"], claim["state_revision"], claim["status"], canonical_bytes(claim["value"]).decode(), canonical_bytes(claim["provenance"]).decode(), canonical_bytes(claim["dependencies"]).decode(), claim["owner"]))
    for claim_id, history in projection["claim_history"].items():
        for claim in history:
            db.execute("INSERT INTO projection_claim_history VALUES(?,?,?,?,?,?,?,?,?)", (problem_id, claim_id, claim["revision"], claim["state_revision"], claim["status"], canonical_bytes(claim["value"]).decode(), canonical_bytes(claim["provenance"]).decode(), canonical_bytes(claim["dependencies"]).decode(), claim["owner"]))
    for review in projection["reviews"]:
        seq = db.execute("SELECT event_seq FROM events WHERE message_id=?", (review["message_id"],)).fetchone()["event_seq"]
        db.execute("INSERT INTO projection_reviews VALUES(?,?,?,?)", (problem_id, review["message_id"], seq, canonical_bytes(review).decode()))
    for candidate in projection["candidates"]:
        index = db.execute("SELECT COUNT(*) FROM projection_candidates WHERE problem_id=? AND message_id=?", (problem_id, candidate["message_id"])).fetchone()[0]
        db.execute("INSERT INTO projection_candidates VALUES(?,?,?,?)", (problem_id, candidate["message_id"], index, canonical_bytes(candidate["claim"]).decode()))


def _apply_event(projection: dict[str, Any], env: dict[str, Any]) -> None:
    intent, payload = env["intent"], env["payload"]
    claims = projection["claims"]
    if intent == "PROPOSE":
        claim = payload["claim"]
        claim_id = claim["claim_id"]
        old = claims.get(claim_id)
        if old is not None:
            next_state_revision = old["state_revision"] + 1
            old["status"] = "superseded"
            old["state_revision"] = next_state_revision
            _sync_claim_history(projection, claim_id)
            _invalidate_dependents(projection, claim_id, old["revision"])
        else:
            next_state_revision = 1
        current = {
            "claim_id": claim_id, "revision": claim["revision"], "state_revision": next_state_revision,
            "status": "active", "value": claim["value"], "provenance": claim["provenance"],
            "dependencies": claim["dependencies"], "owner": env["sender"],
        }
        claims[claim_id] = current
        projection["claim_history"].setdefault(claim_id, []).append(dict(current))
    elif intent == "CHALLENGE":
        target = payload["target"]
        claim_id = target["resource_id"][6:]
        if claim_id in claims:
            claims[claim_id]["status"] = "challenged"
            claims[claim_id]["state_revision"] += 1
            _sync_claim_history(projection, claim_id)
        projection["reviews"].append(env)
        if "corrected_claim" in payload:
            projection["candidates"].append({"message_id": env["message_id"], "claim": payload["corrected_claim"]})
    elif intent == "REPORT_EVIDENCE":
        projection["reviews"].append(env)
        if "corrected_claim" in payload:
            projection["candidates"].append({"message_id": env["message_id"], "claim": payload["corrected_claim"]})
    elif intent == "REQUEST_EVIDENCE":
        projection["reviews"].append(env)
    elif intent == "RETRACT":
        claim_id = payload["target"]["resource_id"][6:]
        if claim_id in claims:
            target = claims[claim_id]
            target["status"] = "retracted"
            target["state_revision"] += 1
            _sync_claim_history(projection, claim_id)
            _invalidate_dependents(projection, claim_id, target["revision"])
    elif intent == "CONCLUDE":
        projection.setdefault("conclusions", []).append(env)


def _invalidate_dependents(projection: dict[str, Any], claim_id: str, revision: int) -> None:
    claims = projection["claims"]
    invalidated = {(claim_id, revision)}
    changed = True
    while changed:
        changed = False
        for candidate_id, claim in claims.items():
            if claim["status"] in ("retracted", "invalidated", "superseded"):
                continue
            if any((dep["resource_id"][6:], dep["claim_revision"]) in invalidated for dep in claim["dependencies"] if dep["resource_id"].startswith("claim:")):
                claim["status"] = "invalidated"
                claim["state_revision"] += 1
                _sync_claim_history(projection, candidate_id)
                invalidated.add((candidate_id, claim["revision"]))
                changed = True


def _sync_claim_history(projection: dict[str, Any], claim_id: str) -> None:
    current = projection["claims"][claim_id]
    history = projection["claim_history"].setdefault(claim_id, [])
    for index, old in enumerate(history):
        if old["revision"] == current["revision"]:
            history[index] = dict(current)
            return
    history.append(dict(current))


def _rebuild_projection(db: sqlite3.Connection, problem_id: str, through_event_seq: int | None = None) -> dict[str, Any]:
    resource = db.execute("SELECT packet_json FROM problem_resource WHERE problem_id=?", (problem_id,)).fetchone()
    if resource is None:
        raise ProtocolError("unknown problem")
    projection: dict[str, Any] = {"problem_id": problem_id, "problem": parse_json(resource["packet_json"].encode()), "claims": {}, "claim_history": {}, "reviews": [], "candidates": [], "_event_ids": []}
    if through_event_seq is None:
        rows = db.execute("SELECT envelope_json FROM events WHERE problem_id=? ORDER BY event_seq", (problem_id,))
    else:
        rows = db.execute("SELECT envelope_json FROM events WHERE problem_id=? AND event_seq<=? ORDER BY event_seq", (problem_id, through_event_seq))
    for row in rows:
        env = parse_json(row["envelope_json"].encode())
        projection["_event_ids"].append(env["message_id"])
        _apply_event(projection, env)
    return projection


def _snapshot_has_ref(projection: dict[str, Any], ref: dict[str, Any]) -> bool:
    rid = ref["resource_id"]
    if rid == f"problem:{projection['problem_id']}":
        return (ref["revision"], ref["state_revision"]) == (1, 1)
    if rid.startswith("claim:"):
        claim = projection["claims"].get(rid[6:])
        if claim is None:
            return (ref["revision"], ref["state_revision"]) == (0, 0)
        return (ref["revision"], ref["state_revision"]) == (claim["revision"], claim["state_revision"])
    if rid.startswith("event:"):
        return rid[6:] in projection.get("_event_ids", []) and (ref["revision"], ref["state_revision"]) == (1, 1)
    return False


def _historical_snapshot(db: sqlite3.Connection, problem_id: str, refs: list[dict[str, Any]]) -> tuple[int, dict[str, Any]] | None:
    seqs = [0] + [row[0] for row in db.execute("SELECT event_seq FROM events WHERE problem_id=? ORDER BY event_seq", (problem_id,))]
    for seq in reversed(seqs):
        snapshot = _rebuild_projection(db, problem_id, seq)
        if all(_snapshot_has_ref(snapshot, ref) for ref in refs):
            snapshot.pop("_event_ids", None)
            return seq, snapshot
    return None


def _deps_valid_in_snapshot(problem_id: str, snapshot: dict[str, Any], deps: list[dict[str, Any]]) -> bool:
    for dep in deps:
        rid, rev = dep["resource_id"], dep["claim_revision"]
        if rid == f"problem:{problem_id}":
            if rev != 1:
                return False
        elif rid.startswith("claim:"):
            claim = snapshot["claims"].get(rid[6:])
            if claim is None or claim["revision"] != rev or claim["status"] in ("retracted", "invalidated", "superseded"):
                return False
        else:
            return False
    return True


def _valid_proposal_in_snapshot(env: dict[str, Any], snapshot: dict[str, Any]) -> bool:
    claim = env["payload"]["claim"]
    current = snapshot["claims"].get(claim["claim_id"])
    expected_revision = 1 if current is None else current["revision"] + 1
    expected_state_revision = 1 if current is None else current["state_revision"] + 1
    ref = _claim_ref(env, claim["claim_id"])
    return (
        ref is not None
        and claim["revision"] == expected_revision
        and claim["state_revision"] == expected_state_revision
        and claim["provenance"].get("message_id") == env["message_id"]
        and all(any(ref["resource_id"] == dep["resource_id"] and ref["revision"] == dep["claim_revision"] for ref in env["read_refs"]) for dep in claim["dependencies"])
        and _deps_valid_in_snapshot(env["problem_id"], snapshot, claim["dependencies"])
    )


def _make_fork(db: sqlite3.Connection, raw: bytes, env: dict[str, Any]) -> dict[str, Any] | None:
    history = _historical_snapshot(db, env["problem_id"], env["read_refs"])
    if history is None:
        return None
    base_event_seq, historical = history
    if not _valid_proposal_in_snapshot(env, historical):
        return None
    fork_id = "fork-" + hashlib.sha256(env["problem_id"].encode() + b"\0" + env["message_id"].encode() + b"\0" + raw).hexdigest()[:24]
    proposed = json.loads(canonical_bytes(historical).decode("utf-8"))
    _apply_event(proposed, env)
    receipt = _receipt(env["message_id"], False, code="STALE_READ")
    receipt.update(disposition="forked", fork_id=fork_id)
    db.execute(
        "INSERT INTO forks(fork_id,message_id,problem_id,raw,envelope_json,read_refs_json,base_event_seq,historical_projection_json,proposed_projection_json,status,resolution_json,receipt_json) VALUES(?,?,?,?,?,?,?,?,?,'potential',NULL,?)",
        (fork_id, env["message_id"], env["problem_id"], raw, canonical_bytes(env).decode(), canonical_bytes(env["read_refs"]).decode(), base_event_seq, canonical_bytes(historical).decode(), canonical_bytes(proposed).decode(), canonical_bytes(receipt).decode()),
    )
    db.execute("INSERT INTO submissions(problem_id,message_id,raw,parsed_json,accepted,event_seq,code,receipt_json) VALUES(?,?,?,?,0,NULL,'STALE_READ',?)", (env["problem_id"], env["message_id"], raw, canonical_bytes(env).decode(), canonical_bytes(receipt).decode()))
    return receipt


def submit(path: str | Path, raw_bytes: bytes) -> dict[str, Any]:
    """Validate, audit, and atomically append a raw message, if structurally valid."""
    raw = bytes(raw_bytes)
    db = _connect(path)
    try:
        db.execute("BEGIN IMMEDIATE")
        try:
            parsed_value = parse_json(raw)
        except InvalidJSON:
            receipt = _record_rejection(db, raw, None, None, "INVALID_JSON")
            db.commit()
            return receipt
        except (ProtocolError, TypeError, ValueError):
            receipt = _record_rejection(db, raw, None, None, "INVALID_SCHEMA")
            db.commit()
            return receipt
        known_message_id = parsed_value.get("message_id") if type(parsed_value) is dict and _nonempty_string(parsed_value.get("message_id")) else None
        known_problem_id = parsed_value.get("problem_id") if type(parsed_value) is dict and _nonempty_string(parsed_value.get("problem_id")) else None
        if known_message_id is not None:
            previous = db.execute("SELECT raw,receipt_json FROM submissions WHERE message_id=? ORDER BY receive_seq LIMIT 1", (known_message_id,)).fetchone()
            if previous is not None:
                if bytes(previous["raw"]) == raw:
                    receipt = parse_json(previous["receipt_json"].encode())
                    db.rollback()
                    return receipt
                receipt = _record_rejection(db, raw, known_message_id, known_problem_id, "MESSAGE_ID_CONFLICT", parsed_value if type(parsed_value) is dict else None)
                db.commit()
                return receipt
        try:
            env = parse_envelope(raw)
        except (ProtocolError, TypeError, ValueError):
            receipt = _record_rejection(db, raw, known_message_id, known_problem_id, "INVALID_SCHEMA", parsed_value if type(parsed_value) is dict else None)
            db.commit()
            return receipt
        message_id, problem_id = env["message_id"], env["problem_id"]
        old = db.execute("SELECT raw,event_seq FROM events WHERE message_id=?", (message_id,)).fetchone()
        if old is not None:
            if bytes(old["raw"]) == raw:
                receipt = _receipt(message_id, True, old["event_seq"])
                db.execute("INSERT INTO submissions(problem_id,message_id,raw,parsed_json,accepted,event_seq,code,receipt_json) VALUES(?,?,?,?,1,?,NULL,?)", (problem_id, message_id, raw, canonical_bytes(env).decode(), old["event_seq"], canonical_bytes(receipt).decode()))
                db.commit()
                return receipt
            receipt = _record_rejection(db, raw, message_id, problem_id, "MESSAGE_ID_CONFLICT", env)
            db.commit()
            return receipt
        old_fork = db.execute("SELECT raw,receipt_json FROM forks WHERE message_id=?", (message_id,)).fetchone()
        if old_fork is not None:
            if bytes(old_fork["raw"]) == raw:
                receipt = parse_json(old_fork["receipt_json"].encode())
                db.execute("INSERT INTO submissions(problem_id,message_id,raw,parsed_json,accepted,event_seq,code,receipt_json) VALUES(?,?,?,?,0,NULL,'STALE_READ',?)", (problem_id, message_id, raw, canonical_bytes(env).decode(), canonical_bytes(receipt).decode()))
                db.commit()
                return receipt
            receipt = _record_rejection(db, raw, message_id, problem_id, "MESSAGE_ID_CONFLICT", env)
            db.commit()
            return receipt
        meta = db.execute("SELECT value FROM meta WHERE key='problem_id'").fetchone()
        if meta is None or meta["value"] != problem_id:
            receipt = _record_rejection(db, raw, message_id, problem_id, "UNKNOWN_REFERENCE", env)
            db.commit()
            return receipt
        code = _validate_authorization(db, env) or _validate_reads(db, env) or _validate_transition(db, env)
        if code:
            if code == "STALE_READ" and env["intent"] == "PROPOSE":
                fork_receipt = _make_fork(db, raw, env)
                if fork_receipt is not None:
                    db.commit()
                    return fork_receipt
                code = "UNKNOWN_REFERENCE"
            receipt = _record_rejection(db, raw, message_id, problem_id, code, env)
            db.commit()
            return receipt
        canonical = canonical_bytes(env)
        event_hash = hashlib.sha256(canonical).hexdigest()
        cursor = db.execute("INSERT INTO events(message_id,problem_id,envelope_json,raw,event_hash) VALUES(?,?,?,?,?)", (message_id, problem_id, canonical.decode("utf-8"), raw, event_hash))
        event_seq = cursor.lastrowid
        projection = _rebuild_projection(db, problem_id)
        _replace_projection(db, problem_id, projection)
        receipt = _receipt(message_id, True, event_seq)
        db.execute("INSERT INTO submissions(problem_id,message_id,raw,parsed_json,accepted,event_seq,code,receipt_json) VALUES(?,?,?,?,1,?,NULL,?)", (problem_id, message_id, raw, canonical.decode(), event_seq, canonical_bytes(receipt).decode()))
        db.commit()
        return receipt
    except sqlite3.Error:
        db.rollback()
        receipt = _receipt(None, False, code="DATABASE_ERROR")
        try:
            db.execute("BEGIN IMMEDIATE")
            _record_rejection(db, raw, None, None, "DATABASE_ERROR")
            db.commit()
        except sqlite3.Error:
            db.rollback()
        return receipt
    finally:
        db.close()


def record_rejection(path: str | Path, raw_bytes: bytes, code: str = "ROLE_MISMATCH", parsed: dict[str, Any] | None = None) -> dict[str, Any]:
    """Retain a raw submission rejected by the pilot's role gate without an event."""
    if not _nonempty_string(code):
        raise ProtocolError("rejection code must be a nonempty string")
    raw = bytes(raw_bytes)
    known = parsed
    if known is None:
        try:
            candidate = parse_json(raw)
            known = candidate if type(candidate) is dict else None
        except ProtocolError:
            known = None
    message_id = known.get("message_id") if type(known) is dict and _nonempty_string(known.get("message_id")) else None
    problem_id = known.get("problem_id") if type(known) is dict and _nonempty_string(known.get("problem_id")) else None
    db = _connect(path)
    try:
        db.execute("BEGIN IMMEDIATE")
        if message_id is not None:
            previous = db.execute("SELECT raw,receipt_json FROM submissions WHERE message_id=? ORDER BY receive_seq LIMIT 1", (message_id,)).fetchone()
            if previous is not None:
                if bytes(previous["raw"]) == raw:
                    receipt = parse_json(previous["receipt_json"].encode())
                    db.rollback()
                    return receipt
                receipt = _record_rejection(db, raw, message_id, problem_id, "MESSAGE_ID_CONFLICT", known)
                db.commit()
                return receipt
        receipt = _record_rejection(db, raw, message_id, problem_id, code, known)
        db.commit()
        return receipt
    except sqlite3.Error:
        db.rollback()
        return _receipt(message_id, False, code="DATABASE_ERROR")
    finally:
        db.close()


def get_projection(path: str | Path, problem_id: str) -> dict[str, Any]:
    db = _connect(path)
    try:
        projection = _current_projection(db, problem_id)
        conclusions = [parse_json(row[0].encode()) for row in db.execute("SELECT envelope_json FROM events WHERE problem_id=? ORDER BY event_seq", (problem_id,)) if parse_json(row[0].encode())["intent"] == "CONCLUDE"]
        if conclusions:
            projection["conclusions"] = conclusions
        projection["forks"] = _fork_registry(db, problem_id)
        return projection
    finally:
        db.close()


def inbox(path: str | Path, problem_id: str, recipient: str) -> list[dict[str, Any]]:
    db = _connect(path)
    try:
        rows = db.execute("SELECT event_seq,envelope_json,event_hash FROM events WHERE problem_id=? ORDER BY event_seq", (problem_id,)).fetchall()
        result = []
        for row in rows:
            env = parse_json(row["envelope_json"].encode())
            if recipient in env["recipients"]:
                result.append({"event_seq": row["event_seq"], "message_id": env["message_id"], "sender": env["sender"], "recipients": env["recipients"], "intent": env["intent"], "read_refs": env["read_refs"], "payload": env["payload"], "event_hash": row["event_hash"]})
        return result
    finally:
        db.close()


def replay(path: str | Path, problem_id: str) -> dict[str, Any]:
    db = _connect(path)
    try:
        projection = _rebuild_projection(db, problem_id)
        projection.pop("_event_ids", None)
        conclusions = [parse_json(row[0].encode()) for row in db.execute("SELECT envelope_json FROM events WHERE problem_id=? ORDER BY event_seq", (problem_id,)) if parse_json(row[0].encode())["intent"] == "CONCLUDE"]
        if conclusions:
            projection["conclusions"] = conclusions
        projection["forks"] = _fork_registry(db, problem_id)
        return projection
    finally:
        db.close()


def _fork_registry(db: sqlite3.Connection, problem_id: str) -> list[dict[str, Any]]:
    result = []
    for row in db.execute("SELECT fork_id,message_id,status,base_event_seq,read_refs_json,resolution_json FROM forks WHERE problem_id=? ORDER BY rowid", (problem_id,)):
        result.append({
            "fork_id": row["fork_id"], "source_message_id": row["message_id"], "status": row["status"],
            "base_event_seq": row["base_event_seq"], "read_refs": parse_json(row["read_refs_json"].encode()),
            "resolution": None if row["resolution_json"] is None else parse_json(row["resolution_json"].encode()),
        })
    return result


def get_fork(path: str | Path, fork_id: str) -> dict[str, Any]:
    db = _connect(path)
    try:
        row = db.execute("SELECT * FROM forks WHERE fork_id=?", (fork_id,)).fetchone()
        if row is None:
            raise ProtocolError("unknown fork")
        return {
            "fork_id": row["fork_id"], "source_message_id": row["message_id"], "problem_id": row["problem_id"],
            "raw_bytes_b64": base64.b64encode(bytes(row["raw"])).decode("ascii"),
            "envelope": parse_json(row["envelope_json"].encode()),
            "read_refs": parse_json(row["read_refs_json"].encode()), "base_event_seq": row["base_event_seq"],
            "historical_projection": parse_json(row["historical_projection_json"].encode()),
            "proposed_projection": parse_json(row["proposed_projection_json"].encode()), "status": row["status"],
            "resolution": None if row["resolution_json"] is None else parse_json(row["resolution_json"].encode()),
        }
    finally:
        db.close()


def export_fork_snapshot(path: str | Path, fork_id: str, out_path: str | Path | None = None) -> dict[str, Any]:
    snapshot = get_fork(path, fork_id)
    if out_path is not None:
        target = Path(out_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(target.suffix + ".tmp")
        temporary.write_bytes(canonical_bytes(snapshot) + b"\n")
        temporary.replace(target)
    return snapshot


def resolve_fork(path: str | Path, fork_id: str, *, administrator: str, evidence_ref: dict[str, Any], prevailing_workable: bool) -> dict[str, Any]:
    """Archive a potential branch only after explicit administrator attestation."""
    db = _connect(path)
    try:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT problem_id,status FROM forks WHERE fork_id=?", (fork_id,)).fetchone()
        if row is None:
            receipt = {"fork_id": fork_id, "accepted": False, "code": "UNKNOWN_REFERENCE"}
            db.rollback()
            return receipt
        if administrator != "protocol-admin":
            receipt = {"fork_id": fork_id, "accepted": False, "code": "UNKNOWN_SENDER"}
            db.rollback()
            return receipt
        if row["status"] != "potential":
            receipt = {"fork_id": fork_id, "accepted": False, "code": "INVALID_TRANSITION"}
            db.rollback()
            return receipt
        if type(evidence_ref) is not dict or not _ref(evidence_ref):
            receipt = {"fork_id": fork_id, "accepted": False, "code": "INVALID_SCHEMA"}
            db.rollback()
            return receipt
        if not evidence_ref["resource_id"].startswith("event:"):
            receipt = {"fork_id": fork_id, "accepted": False, "code": "INVALID_TRANSITION"}
            db.rollback()
            return receipt
        current = _ref_current(db, row["problem_id"], evidence_ref)
        if current is None:
            receipt = {"fork_id": fork_id, "accepted": False, "code": "UNKNOWN_REFERENCE"}
            db.rollback()
            return receipt
        if current != (evidence_ref["revision"], evidence_ref["state_revision"]):
            receipt = {"fork_id": fork_id, "accepted": False, "code": "STALE_READ"}
            db.rollback()
            return receipt
        evidence_row = db.execute("SELECT envelope_json FROM events WHERE problem_id=? AND message_id=?", (row["problem_id"], evidence_ref["resource_id"][6:])).fetchone()
        if evidence_row is None:
            receipt = {"fork_id": fork_id, "accepted": False, "code": "UNKNOWN_REFERENCE"}
            db.rollback()
            return receipt
        evidence_event = parse_json(evidence_row["envelope_json"].encode())
        if evidence_event["intent"] not in ("CONCLUDE", "REPORT_EVIDENCE") or not evidence_event["read_refs"]:
            receipt = {"fork_id": fork_id, "accepted": False, "code": "INVALID_TRANSITION"}
            db.rollback()
            return receipt
        for premise_ref in evidence_event["read_refs"]:
            premise = _ref_current(db, row["problem_id"], premise_ref)
            if premise is None:
                receipt = {"fork_id": fork_id, "accepted": False, "code": "UNKNOWN_REFERENCE"}
                db.rollback()
                return receipt
            if premise != (premise_ref["revision"], premise_ref["state_revision"]):
                receipt = {"fork_id": fork_id, "accepted": False, "code": "STALE_READ"}
                db.rollback()
                return receipt
        if type(prevailing_workable) is not bool or not prevailing_workable:
            receipt = {"fork_id": fork_id, "accepted": False, "code": "INVALID_TRANSITION"}
            db.rollback()
            return receipt
        resolution = {"decision": "discard", "administrator": administrator, "evidence_ref": evidence_ref, "prevailing_workable": True}
        receipt = {"fork_id": fork_id, "accepted": True, "status": "discarded"}
        db.execute("UPDATE forks SET status='discarded',resolution_json=? WHERE fork_id=?", (canonical_bytes(resolution).decode(), fork_id))
        db.execute("INSERT INTO fork_resolutions(fork_id,administrator,decision,evidence_ref_json,prevailing_workable,receipt_json) VALUES(?,?,?,?,1,?)", (fork_id, administrator, "discard", canonical_bytes(evidence_ref).decode(), canonical_bytes(receipt).decode()))
        db.commit()
        return receipt
    except sqlite3.Error:
        db.rollback()
        return {"fork_id": fork_id, "accepted": False, "code": "DATABASE_ERROR"}
    finally:
        db.close()


def event_hashes(path: str | Path, problem_id: str) -> list[dict[str, Any]]:
    db = _connect(path)
    try:
        return [dict(row) for row in db.execute("SELECT event_seq,message_id,event_hash FROM events WHERE problem_id=? ORDER BY event_seq", (problem_id,))]
    finally:
        db.close()


def submissions(path: str | Path, problem_id: str) -> list[dict[str, Any]]:
    db = _connect(path)
    try:
        return [{"receive_seq": row["receive_seq"], "message_id": row["message_id"], "raw": bytes(row["raw"]), "accepted": bool(row["accepted"]), "event_seq": row["event_seq"], "code": row["code"], "receipt": parse_json(row["receipt_json"].encode())} for row in db.execute("SELECT * FROM submissions WHERE problem_id=? OR problem_id IS NULL ORDER BY receive_seq", (problem_id,))]
    finally:
        db.close()

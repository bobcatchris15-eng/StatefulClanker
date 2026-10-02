import hashlib
import json
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import provider_experiment as experiment  # noqa: E402


def fixture_allowlist(folder: Path, key: str) -> Path:
    catalog = folder / f"{key}.catalog.json"
    catalog_row = {"id": f"family-{key}:free", "pricing": {"prompt": "0", "completion": "0"}}
    catalog.write_text(json.dumps({"data": [{**catalog_row, "isFree": True}]}), encoding="utf-8")
    allow = folder / f"{key}.allowlist.json"
    allow.write_text(json.dumps({
        "schema_version": 1, "provider": "kilo-free", "connection_id": f"conn-{key}",
        "endpoint_id": f"endpoint-{key}", "model": f"family-{key}:free",
        "base_url": "https://api.kilo.ai/api/gateway", "catalog_path": catalog.name,
        "catalog_sha256": hashlib.sha256(catalog.read_bytes()).hexdigest(),
    }), encoding="utf-8")
    return allow


def allowlist_map(folder: Path) -> Path:
    entries = {key: {"allowlist": fixture_allowlist(folder, key).name,
                     "allowed_returned_models": [f"family-{key}:free"]} for key in experiment.MODEL_KEYS}
    path = folder / "allowlists.json"
    path.write_text(json.dumps(entries), encoding="utf-8")
    return path


def valid_payload(role):
    if role.endswith("proposer"):
        return json.dumps({"coefficients": [1, 2, 3]})
    if role.endswith("reviewer"):
        return json.dumps({"assessment": "supported", "corrected_coefficients": [3, 4, 5]})
    return json.dumps({"status": "solved", "x": 2, "y": 4})


def valid_model_output(role):
    return valid_payload(role)


def valid_full_envelope(run_dir: Path, seed: int, role: str) -> bytes:
    problem = experiment._problem(run_dir / "pilot", seed)
    problem_id = problem["problem_id"]
    message_id = experiment.pilot._role_message_id(problem_id, role)
    ref = experiment._problem_ref(problem_id)
    if role.endswith("proposer"):
        coord = "u" if role.startswith("u-") else "v"
        claim_id = f"{coord}-relation"
        claim = {"claim_id": claim_id, "revision": 1, "state_revision": 1, "status": "active",
                 "value": {"coefficients": [1, 2, 3]}, "provenance": {"message_id": message_id},
                 "dependencies": [{"resource_id": f"problem:{problem_id}", "claim_revision": 1}]}
        reviewer = "v-reviewer" if coord == "u" else "u-reviewer"
        env = experiment.pilot._envelope_template(problem_id, message_id, role, [reviewer, "shared-integrator"],
            "PROPOSE", [ref, {"resource_id": f"claim:{claim_id}", "revision": 0, "state_revision": 0}], {"claim": claim})
    elif role.endswith("reviewer"):
        target = "v-relation" if role == "u-reviewer" else "u-relation"
        projection = experiment.pilot.protocol.get_projection(run_dir / "pilot" / "cases" / str(seed) / "store.sqlite", problem_id)
        claim = projection["claims"][target]
        target_ref = experiment._claim_ref(target, claim)
        basis_refs = [row["observation_id"] for row in problem["observations"]]
        env = experiment.pilot._envelope_template(problem_id, message_id, role, ["shared-integrator"], "CHALLENGE",
            [ref, target_ref], {"target": target_ref, "assessment": {"assessment": "supported", "basis_refs": basis_refs}},
            claim["provenance"]["message_id"])
    else:
        projection = experiment.pilot.protocol.get_projection(run_dir / "pilot" / "cases" / str(seed) / "store.sqlite", problem_id)
        refs = [ref, *(experiment._claim_ref(cid, claim) for cid, claim in sorted(projection["claims"].items()))]
        env = experiment.pilot._envelope_template(problem_id, message_id, role, ["shared-integrator"], "CONCLUDE", refs,
            {"conclusion": {"status": "solved", "x": 2, "y": 4}})
    return experiment.pilot.protocol.canonical_bytes(env)


class FixtureDispatcher:
    def __init__(self, *, invalid_role=None):
        self.invalid_role = invalid_role
        self.calls = []
        self.active = 0
        self.max_active = 0
        self.lock = threading.Lock()
        self.review_barrier = threading.Barrier(2)

    def __call__(self, request_path, allowlist_path, slot_dir, timeout_seconds):
        request = json.loads(Path(request_path).read_bytes())
        prompt = request["messages"][0]["content"]
        role = experiment.role_from_prompt(prompt)
        with self.lock:
            self.calls.append((role, request, Path(allowlist_path), Path(slot_dir), timeout_seconds))
            self.active += 1
            self.max_active = max(self.max_active, self.active)
        time.sleep(0.01)
        try:
            slot_dir = Path(slot_dir)
            condition_dir = slot_dir.parents[2]
            run_dir = condition_dir.parent
            if role == self.invalid_role:
                raw = b'{"coefficients":[true,2,3]}'
            elif condition_dir.name == "full":
                seed = int(slot_dir.parent.name)
                raw = valid_full_envelope(run_dir, seed, role)
            else:
                if role.endswith("reviewer"):
                    self.review_barrier.wait(timeout=3)
                raw = valid_payload(role).encode("utf-8")
            receipt = {
                "sent": True, "status": "completed", "httpStatus": 200,
                "returnedModel": f"family-{Path(allowlist_path).name.split('.')[0].split('-')[0]}:free",
                "usageReported": True, "promptTokens": 10, "completionTokens": 4, "totalTokens": 14,
                "finishReason": "stop", "contentSha256": hashlib.sha256(raw).hexdigest(),
            }
            slot_dir.mkdir(parents=True, exist_ok=True)
            (slot_dir / "content.raw").write_bytes(raw)
            (slot_dir / "receipt.json").write_text(json.dumps(receipt), encoding="utf-8")
            (slot_dir / "response.body.raw").write_bytes(b'{"fixture":true}')
            if role.endswith("reviewer") and condition_dir.name == "payload":
                time.sleep(0.03 if role == "u-reviewer" else 0.001)
            return {"exit_code": 0, "receipt": receipt, "content": raw, "stdout": b"{}\n", "stderr": b""}
        finally:
            with self.lock:
                self.active -= 1


class FailedDispatcher:
    def __call__(self, request_path, allowlist_path, slot_dir, timeout_seconds):
        return {"exit_code": 2, "receipt": {"sent": False, "status": "failed", "failureCode": "CONNECTION_NOT_FOUND"},
                "content": None, "stdout": b"", "stderr": b""}


class ProviderExperimentTests(unittest.TestCase):
    def test_prepare_creates_eight_separate_pilot_runs_and_exact_96_slot_schedule_without_transport(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            allowlists = allowlist_map(root)
            prereg = root / "LOCAL_PREREGISTRATION_v3.md"
            prereg.write_text("Frozen test preregistration\n", encoding="utf-8")
            campaign = root / "campaign"
            manifest = experiment.prepare(campaign, allowlist_map_path=allowlists, preregistration=prereg)
            self.assertEqual(manifest["planned_slots"], 96)
            self.assertEqual(len(manifest["conditions"]), 8)
            self.assertEqual(manifest["generation_policy"], {"max_output_tokens": 4096, "temperature": "0.6", "timeout_seconds": 180, "parallel_per_phase": 2, "retry_policy": "none", "one_fresh_user_message": True})
            for model in experiment.MODEL_KEYS:
                for condition in experiment.CONDITIONS:
                    run = campaign / "conditions" / model / condition
                    self.assertTrue((run / "pilot" / "run.json").is_file())
                    self.assertTrue((run / "prompts" / "4201" / "u-proposer.txt").is_file())
            self.assertTrue((campaign / "frozen_inputs" / prereg.name).is_file())
            self.assertIn("provider_experiment.py", manifest["source_hashes"])
            self.assertIn("FreeDispatch.dll", manifest["source_manifest"]["dispatcher_package_sha256"])
            self.assertIn("conditions/liquid/payload/compile_contexts/4201/u-proposer.json", manifest["input_hashes"])

    def test_payload_compiler_maps_known_structured_payloads_and_rejects_strict_schema_violations(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            campaign = root / "campaign"
            experiment.prepare(campaign, allowlist_map_path=allowlist_map(root))
            condition = campaign / "conditions" / experiment.MODEL_KEYS[0] / "payload" / "pilot"
            for seed in experiment.SEEDS:
                for role, value in (
                    ("u-proposer", {"coefficients": [1, 2, 3]}),
                    ("u-reviewer", {"assessment": "challenge", "corrected_coefficients": [3, 4, 5]}),
                    ("shared-integrator", {"status": "solved", "x": 7, "y": 9}),
                ):
                    env = experiment.compile_payload(condition, seed, role, json.dumps(value).encode())
                    self.assertEqual(env["sender"], role)
                    expected_intent = {"u-proposer": "PROPOSE", "u-reviewer": "CHALLENGE", "shared-integrator": "CONCLUDE"}[role]
                    if role == "u-reviewer":
                        # The proposal is not present in this isolated compiler test.
                        expected_intent = "REPORT_EVIDENCE"
                    self.assertEqual(env["intent"], expected_intent)
                    self.assertEqual(env["problem_id"], f"affine-{seed}")
            bad = (
                b'{"coefficients":[1,1,1],"coefficients":[2,2,2]}',
                b'{"coefficients":[1.0,2,3]}',
                b'{"coefficients":[true,2,3]}',
                b'{"coefficients":[1,2,11]}',
                b'{"coefficients":[1,2,3],"root_answer": [0,0]}',
            )
            for raw in bad:
                with self.subTest(raw=raw), self.assertRaises(experiment.PayloadSchemaError):
                    experiment.compile_payload(condition, 4201, "u-proposer", raw)
            for malformed_assessment in (b'{"assessment":[]}', b'{"assessment":{}}'):
                with self.subTest(raw=malformed_assessment), self.assertRaises(experiment.PayloadSchemaError):
                    experiment.parse_payload(malformed_assessment, "u-reviewer")

    def test_payload_compiler_uses_pre_dispatch_snapshot_after_other_review_changes_shared_status(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            campaign = root / "campaign"
            experiment.prepare(campaign, allowlist_map_path=allowlist_map(root))
            run = campaign / "conditions" / "liquid" / "payload"
            for role in experiment.ROLES[:2]:
                experiment.record_model_output(run, 4201, role, valid_full_envelope(run, 4201, role))
            frozen = experiment._compile_context(run / "pilot", 4201, "u-reviewer")
            experiment.get_prompt(run, 4201, "u-reviewer")
            path = run / "compile_contexts" / "4201" / "u-reviewer.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(frozen), encoding="utf-8")
            # The peer's state changes after the u-reviewer prompt was frozen.
            experiment.get_prompt(run, 4201, "v-reviewer")
            challenge = valid_full_envelope(run, 4201, "v-reviewer")
            experiment.pilot.submit_response(run / "pilot", 4201, "v-reviewer", challenge)
            self.assertEqual(experiment.pilot.protocol.get_projection(
                run / "pilot" / "cases" / "4201" / "store.sqlite", "affine-4201")["claims"]["u-relation"]["state_revision"], 2)
            raw = b'{"assessment":"challenge"}'
            receipt = experiment._record_payload(run, 4201, "u-reviewer", raw, {}, frozen)
            self.assertTrue(receipt["payload_valid"])
            saved = json.loads((run / "compiled_envelopes" / "4201" / "u-reviewer.json").read_text(encoding="utf-8"))
            self.assertEqual(saved["read_refs"][1], frozen["target_ref"])
            self.assertEqual(saved["read_refs"][1]["state_revision"], 1)

    def test_payload_run_retains_raw_then_compiles_valid_payloads_and_records_invalid_without_retry(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            campaign = root / "campaign"
            experiment.prepare(campaign, allowlist_map_path=allowlist_map(root))
            dispatcher = FixtureDispatcher(invalid_role="u-proposer")
            experiment.run_condition(campaign, experiment.MODEL_KEYS[0], "full", dispatcher=FixtureDispatcher())
            outcome = experiment.run_condition(campaign, experiment.MODEL_KEYS[0], "payload", dispatcher=dispatcher)
            self.assertEqual(outcome["status"], "complete")
            self.assertEqual(outcome["slot_count"], 12)
            self.assertEqual(outcome["failed_dispatches"], 0)
            self.assertEqual(len(dispatcher.calls), 12)
            self.assertEqual(dispatcher.max_active, 2)
            run = campaign / "conditions" / experiment.MODEL_KEYS[0] / "payload"
            raw_path = run / "model_outputs" / "4201" / "u-proposer.raw"
            compile_path = run / "compile_receipts" / "4201" / "u-proposer.json"
            self.assertEqual(raw_path.read_bytes(), b'{"coefficients":[true,2,3]}')
            compile_receipt = json.loads(compile_path.read_text(encoding="utf-8"))
            self.assertFalse(compile_receipt["payload_valid"])
            self.assertEqual(compile_receipt["raw_payload_sha256"], hashlib.sha256(raw_path.read_bytes()).hexdigest())
            for role in experiment.ROLES:
                self.assertTrue((run / "pilot" / "responses" / "4201" / f"{role}.raw").is_file())
            with self.assertRaises(experiment.ExperimentError):
                experiment.run_condition(campaign, experiment.MODEL_KEYS[0], "payload", dispatcher=dispatcher)
            self.assertEqual(len(dispatcher.calls), 12)

    def test_internal_dispatch_command_uses_campaign_frozen_dll_and_correct_allowlist_catalog_paths(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            campaign = root / "campaign"
            experiment.prepare(campaign, allowlist_map_path=allowlist_map(root))
            allow = campaign / "frozen_inputs" / "allowlists" / "liquid.allowlist.json"
            slot = campaign / "conditions" / "liquid" / "full" / "transport" / "4201" / "u-proposer"
            request = campaign / "conditions" / "liquid" / "full" / "requests" / "4201" / "u-proposer.request.json"
            request.parent.mkdir(parents=True, exist_ok=True)
            request.write_bytes(b'{"messages":[{"role":"user","content":"x"}],"maxOutputTokens":4096,"temperature":0.6,"timeoutSeconds":180}')
            captured = {}
            class Completed:
                returncode = 2
                stdout = b""
                stderr = b""
            def fake_run(command, **kwargs):
                captured["command"] = command
                captured["kwargs"] = kwargs
                return Completed()
            from unittest.mock import patch
            with patch.object(experiment.subprocess, "run", side_effect=fake_run):
                result = experiment._dispatch_command(request, allow, slot, 180)
            self.assertIsNone(result["content"])
            self.assertEqual(Path(captured["command"][1]), campaign / "frozen_inputs" / "dispatcher-package" / "FreeDispatch.dll")
            self.assertNotIn("run", captured["command"])
            self.assertTrue((campaign / "frozen_inputs" / "allowlists" / "../catalogs/liquid.catalog.json").resolve().is_file())

    def test_final_prompts_share_public_facts_and_payload_prompts_expose_same_role_state_without_envelope_header(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            campaign = root / "campaign"
            experiment.prepare(campaign, allowlist_map_path=allowlist_map(root))
            dispatcher = FixtureDispatcher()
            full = campaign / "conditions" / experiment.MODEL_KEYS[0] / "full"
            payload = campaign / "conditions" / experiment.MODEL_KEYS[0] / "payload"
            for run in (full, payload):
                for role in experiment.ROLES[:2]:
                    experiment.get_prompt(run, 4201, role)
                    raw = valid_full_envelope(run, 4201, role) if run.name == "full" else valid_payload(role).encode()
                    experiment.record_model_output(run, 4201, role, raw)
                for role in experiment.ROLES[2:4]:
                    experiment.get_prompt(run, 4201, role)
                    raw = valid_full_envelope(run, 4201, role) if run.name == "full" else valid_payload(role).encode()
                    experiment.record_model_output(run, 4201, role, raw)
                exp_prompt = experiment.get_prompt(run, 4201, "shared-integrator")
                raw_prompt = experiment.get_prompt(run, 4201, "raw-integrator")
                exp_txt, raw_txt = exp_prompt.read_text(encoding="utf-8"), raw_prompt.read_text(encoding="utf-8")
                self.assertEqual(experiment.extract_public_problem(exp_txt), experiment.extract_public_problem(raw_txt))
                if run.name == "full":
                    self.assertIn("CURRENT SHARED WORKSPACE", exp_txt)
                    self.assertNotIn("CURRENT SHARED WORKSPACE", raw_txt)
                else:
                    self.assertIn("SHARED WORKSPACE PROJECTION", exp_txt)
                    self.assertNotIn("SHARED WORKSPACE PROJECTION", raw_txt)
            compact_shared = experiment.get_prompt(payload, 4201, "shared-integrator").read_text(encoding="utf-8")
            # It carries the same peer projection, but not the protocol envelope template.
            self.assertIn('"intent"', compact_shared)  # JSON peer evidence may itself contain protocol records.
            self.assertIn("Output exactly {\"status\":\"solved\"", compact_shared)
            self.assertIn('"status":"solved"', compact_shared)

    def test_evaluation_gate_requires_all_96_slots_and_evaluation_is_offline(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            campaign = root / "campaign"
            experiment.prepare(campaign, allowlist_map_path=allowlist_map(root))
            with self.assertRaises(experiment.ExperimentError):
                experiment.evaluate(campaign)
            dispatcher = FixtureDispatcher()
            for model in experiment.MODEL_KEYS:
                for condition in experiment.CONDITIONS:
                    experiment.run_condition(campaign, model, condition, dispatcher=dispatcher)
            report = experiment.evaluate(campaign)
            self.assertTrue(report["offline_only"])
            self.assertEqual(report["completed_slot_count"], 96)

    def test_evaluation_rejects_slot_outcome_tampering_after_completion(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            campaign = root / "campaign"
            experiment.prepare(campaign, allowlist_map_path=allowlist_map(root))
            dispatcher = FixtureDispatcher()
            for model in experiment.MODEL_KEYS:
                for condition in experiment.CONDITIONS:
                    experiment.run_condition(campaign, model, condition, dispatcher=dispatcher)
            slot = campaign / "conditions" / "liquid" / "full" / "transport" / "4201" / "u-proposer" / "slot.json"
            raw = json.loads(slot.read_text(encoding="utf-8"))
            raw["tampered"] = True
            slot.write_text(json.dumps(raw), encoding="utf-8")
            with self.assertRaises(experiment.ExperimentError):
                experiment.evaluate(campaign)

    def test_campaign_freeze_rejects_changed_source_and_dispatcher_runtime(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            campaign = root / "campaign"
            manifest = experiment.prepare(campaign, allowlist_map_path=allowlist_map(root))
            frozen = campaign / "frozen_inputs" / "dispatcher-package" / "FreeDispatch.dll"
            original = frozen.read_bytes()
            frozen.write_bytes(original + b"tamper")
            with self.assertRaises(experiment.ExperimentError):
                experiment._load_campaign(campaign)
            frozen.write_bytes(original)
            source = Path(experiment.__file__)
            prior = source.read_bytes()
            try:
                source.write_bytes(prior + b"\n# tamper probe\n")
                with self.assertRaises(experiment.ExperimentError):
                    experiment._load_campaign(campaign)
            finally:
                source.write_bytes(prior)

    def test_initial_prompt_and_mutable_prompt_hash_cannot_be_changed_together(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            campaign = root / "campaign"
            experiment.prepare(campaign, allowlist_map_path=allowlist_map(root))
            prompt = campaign / "conditions" / "liquid" / "full" / "prompts" / "4201" / "u-proposer.txt"
            prompt.write_bytes(prompt.read_bytes() + b"changed")
            hashes_path = prompt.parents[2] / "prompt_hashes.json"
            hashes = json.loads(hashes_path.read_text(encoding="utf-8"))
            hashes["4201/u-proposer"] = hashlib.sha256(prompt.read_bytes()).hexdigest()
            hashes_path.write_text(json.dumps(hashes), encoding="utf-8")
            with self.assertRaises(experiment.ExperimentError):
                experiment._load_campaign(campaign)

    def test_failed_payload_transport_keeps_slot_without_content_and_evaluates_as_not_applicable(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            campaign = root / "campaign"
            experiment.prepare(campaign, allowlist_map_path=allowlist_map(root))
            for model in experiment.MODEL_KEYS:
                experiment.run_condition(campaign, model, "full", dispatcher=FailedDispatcher())
                experiment.run_condition(campaign, model, "payload", dispatcher=FailedDispatcher())
            first = campaign / "conditions" / "liquid" / "payload" / "compile_receipts" / "4201" / "u-proposer.json"
            receipt = json.loads(first.read_text(encoding="utf-8"))
            self.assertIsNone(receipt["payload_valid"])
            self.assertIsNone(receipt["raw_payload_sha256"])
            report = experiment.evaluate(campaign)
            self.assertEqual(report["completed_slot_count"], 96)
            self.assertEqual(report["conditions"]["liquid/payload"]["payload_valid_count"], 0)
            self.assertEqual(report["conditions"]["liquid/payload"]["payload_invalid_count"], 0)


if __name__ == "__main__":
    unittest.main()

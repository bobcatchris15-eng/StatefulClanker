import hashlib
import json
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

LAB4 = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LAB4))
import local_runner  # noqa: E402


def response(body, status=200, headers=None):
    return local_runner.HTTPResponse(status=status, body=body, headers=headers or {"Content-Type": "application/json"})


def ready_health(context_length=70728):
    return {
        "status": "ok", "version": "11.9.0", "model_loaded": local_runner.MODEL_ID,
        "all_models_loaded": [{
            "model_name": local_runner.MODEL_ID, "loaded": True, "status": "ready", "backend_alive": True,
            "checkpoint": local_runner.CHECKPOINT, "recipe": local_runner.RECIPE, "device": local_runner.DEVICE,
            "recipe_options": {"ctx_size": context_length},
        }],
    }


def model_list(context_length=70728):
    return {"object": "list", "data": [{
        "id": local_runner.MODEL_ID, "checkpoint": local_runner.CHECKPOINT,
        "recipe": local_runner.RECIPE, "context_length": context_length,
    }]}


class FakeTransport:
    def __init__(self, *, ready=True, fail_first_post=False, content="  ```json\n{}\n```  ", returned_model=None,
                 partial_first_post=False):
        self.ready = ready
        self.fail_first_post = fail_first_post
        self.content = content
        self.returned_model = returned_model
        self.partial_first_post = partial_first_post
        self.calls = []
        self.post_roles = []
        self.active = 0
        self.max_active = 0
        self.lock = threading.Lock()

    def __call__(self, method, url, body, timeout):
        with self.lock:
            self.calls.append((method, url, body, timeout))
        if method == "GET" and url.endswith("/health"):
            health = ready_health() if self.ready else {"status": "ok", "version": "11.9.0", "model_loaded": None, "all_models_loaded": []}
            return response(json.dumps(health).encode())
        if method == "GET" and url.endswith("/models"):
            return response(json.dumps(model_list()).encode())
        if method != "POST":
            raise AssertionError(f"unexpected method {method}")
        request = json.loads(body)
        role = request["messages"][0]["content"].split("You are ", 1)[-1].split(";", 1)[0] if "You are " in request["messages"][0]["content"] else "proposal"
        with self.lock:
            self.active += 1
            self.max_active = max(self.max_active, self.active)
            self.post_roles.append(role)
            post_number = len([item for item in self.calls if item[0] == "POST"])
        time.sleep(0.025)
        try:
            if self.fail_first_post and post_number == 1:
                return response(b'{"error":"fixture outage"}', status=503, headers={"Content-Type": "application/json", "X-Fixture": "error"})
            if self.partial_first_post and post_number == 1:
                return local_runner.HTTPResponse(200, b'{"choices":[', {"Content-Type": "application/json"}, "fixture incomplete body")
            data = {
                "id": f"fixture-{post_number}", "model": self.returned_model or local_runner.MODEL_ID,
                "choices": [{"message": {"role": "assistant", "content": self.content,
                    "reasoning_content": "private thought\nkeep exact  "}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 12, "completion_tokens": 4, "total_tokens": 16},
            }
            return response(json.dumps(data, ensure_ascii=False).encode(), headers={"Content-Type": "application/json", "X-Fixture": "success"})
        finally:
            with self.lock:
                self.active -= 1


class LocalRunnerTests(unittest.TestCase):
    def test_prepare_freezes_local_inputs_and_performs_no_http_requests(self):
        with tempfile.TemporaryDirectory() as td:
            transport = FakeTransport()
            run_dir = Path(td) / "local"
            manifest = local_runner.prepare(run_dir)
            self.assertEqual(manifest["planned_calls"], 12)
            self.assertEqual(manifest["model"]["model"], "qwen3.5-9b-FLM")
            self.assertEqual(manifest["request_policy"]["max_tokens"], 4096)
            self.assertEqual(manifest["request_policy"]["temperature"], 0)
            self.assertEqual(manifest["request_policy"]["timeout_seconds"], 300)
            self.assertEqual(transport.calls, [])
            self.assertTrue((run_dir / "pilot" / "run.json").is_file())
            self.assertEqual((run_dir / "frozen_inputs" / "LOCAL_RUNTIME_DISCOVERY.json").read_bytes(),
                (LAB4 / "LOCAL_RUNTIME_DISCOVERY.json").read_bytes())
            self.assertIn("local_runner.py", manifest["source_hashes"])
            self.assertIn("LOCAL_PREREGISTRATION.md", manifest["input_hashes"])
            self.assertIn("4201/u-proposer", manifest["initial_prompt_hashes"])

    def test_run_sends_twelve_fresh_requests_in_parallel_pairs_and_preserves_exact_artifacts(self):
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "local"
            local_runner.prepare(run_dir)
            transport = FakeTransport(content=" \n```json\n{\"schema_version\":1}\n``` ")
            runner = local_runner.LocalRunner(run_dir, transport=transport)
            report = runner.run()
            posts = [call for call in transport.calls if call[0] == "POST"]
            self.assertEqual(len(posts), 12)
            self.assertEqual(transport.max_active, 2)
            for _, url, body, timeout in posts:
                request = json.loads(body)
                self.assertEqual(url, local_runner.BASE_URL + "/chat/completions")
                self.assertEqual(request["model"], local_runner.MODEL_ID)
                self.assertEqual(request["max_tokens"], 4096)
                self.assertEqual(request["temperature"], 0)
                self.assertIs(request["stream"], False)
                self.assertEqual(len(request["messages"]), 1)
                self.assertEqual(request["messages"][0]["role"], "user")
                self.assertEqual(timeout, 300)
                self.assertNotIn("response_format", request)
            self.assertEqual(set(report["evaluation"]["cases"]), {"4201", "4202"})
            self.assertTrue((run_dir / "evaluation.json").is_file())

            raw_content = " \n```json\n{\"schema_version\":1}\n``` ".encode()
            content_files = list((run_dir / "transport").glob("*/*.content.raw"))
            self.assertEqual(len(content_files), 12)
            self.assertTrue(all(path.read_bytes() == raw_content for path in content_files))
            for response_path in (run_dir / "transport").glob("*/*.response.raw"):
                response_body = response_path.read_bytes()
                self.assertIn(b"private thought\\nkeep exact  ", response_body)
            reason_files = list((run_dir / "transport").glob("*/*.reasoning.raw"))
            self.assertEqual(len(reason_files), 12)
            self.assertTrue(all(path.read_bytes() == b"private thought\nkeep exact  " for path in reason_files))
            for request_path in (run_dir / "requests").glob("*/*.request.json"):
                call = json.loads((run_dir / "transport" / request_path.parent.name / (request_path.stem.replace(".request", "") + ".call.json")).read_text(encoding="utf-8"))
                request_body = request_path.read_bytes()
                self.assertEqual(hashlib.sha256(request_body).hexdigest(), call["request_sha256"])
                request = json.loads(request_body)
                self.assertNotIn("private thought", request["messages"][0]["content"])
            for role in local_runner.ROLES:
                for seed in local_runner.SEEDS:
                    self.assertTrue((run_dir / "pilot" / "responses" / str(seed) / f"{role}.raw").is_file())

    def test_http_error_consumes_one_slot_retains_body_and_partial_run_cannot_be_retried(self):
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "local"
            local_runner.prepare(run_dir)
            transport = FakeTransport(fail_first_post=True)
            runner = local_runner.LocalRunner(run_dir, transport=transport)
            runner.run()
            posts = [call for call in transport.calls if call[0] == "POST"]
            self.assertEqual(len(posts), 12)
            failure_records = list((run_dir / "transport").glob("*/*.failure.json"))
            self.assertEqual(len(failure_records), 1)
            failure = json.loads(failure_records[0].read_text(encoding="utf-8"))
            self.assertEqual(failure["http_status"], 503)
            error_response = failure_records[0].with_name(failure_records[0].name.replace(".failure.json", ".response.raw"))
            self.assertEqual(error_response.read_bytes(), b'{"error":"fixture outage"}')
            self.assertEqual(len(transport.post_roles), 12)
            with self.assertRaises(local_runner.RunnerError):
                runner.run()
            self.assertEqual(len([call for call in transport.calls if call[0] == "POST"]), 12)

    def test_readiness_failure_consumes_no_slots_and_explicit_retry_is_allowed(self):
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "local"
            local_runner.prepare(run_dir)
            transport = FakeTransport(ready=False)
            runner = local_runner.LocalRunner(run_dir, transport=transport)
            with self.assertRaises(local_runner.RunnerError):
                runner.run()
            self.assertEqual(len([call for call in transport.calls if call[0] == "POST"]), 0)
            receipt = list((run_dir / "backend" / "preflight").glob("*/receipt.json"))
            self.assertEqual(len(receipt), 1)
            self.assertEqual(json.loads(receipt[0].read_text(encoding="utf-8"))["slots_consumed"], 0)
            transport.ready = True
            runner.run()
            self.assertEqual(len([call for call in transport.calls if call[0] == "POST"]), 12)

    def test_remote_or_non_loopback_endpoint_is_rejected(self):
        for url in ("https://127.0.0.1:13305/api/v1", "http://example.com:13305/api/v1", "http://127.0.0.1:13305/other"):
            with self.subTest(url=url):
                with self.assertRaises(local_runner.RunnerError):
                    local_runner.validate_base_url(url)

    def test_checkpoint_alias_is_recorded_but_unrecognized_returned_model_consumes_failed_slot(self):
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "local"
            local_runner.prepare(run_dir)
            runner = local_runner.LocalRunner(run_dir, transport=FakeTransport(returned_model=local_runner.CHECKPOINT))
            runner.run()
            records = list((run_dir / "transport").glob("*/*.call.json"))
            self.assertEqual(len(records), 12)
            self.assertTrue(all(json.loads(path.read_text())["returned_model"] == local_runner.CHECKPOINT for path in records))

        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "local"
            local_runner.prepare(run_dir)
            runner = local_runner.LocalRunner(run_dir, transport=FakeTransport(returned_model="other-model"))
            runner.run()
            failures = [json.loads(path.read_text()) for path in (run_dir / "transport").glob("*/*.failure.json")]
            self.assertEqual(len(failures), 12)
            self.assertTrue(all(row["reason"] == "response_model_mismatch" for row in failures))

    def test_manifest_endpoint_tampering_stops_before_http(self):
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "local"
            local_runner.prepare(run_dir)
            path = run_dir / "local-run.json"
            manifest = json.loads(path.read_text())
            manifest["request_policy"]["url"] = "http://127.0.0.1:13305/api/v1/chat/completions-evil"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            transport = FakeTransport()
            with self.assertRaises(local_runner.RunnerError):
                local_runner.LocalRunner(run_dir, transport=transport).run()
            self.assertEqual(transport.calls, [])

    def test_incomplete_http_response_is_retained_and_consumes_slot_without_parsing(self):
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "local"
            local_runner.prepare(run_dir)
            runner = local_runner.LocalRunner(run_dir, transport=FakeTransport(partial_first_post=True))
            runner.run()
            partial = list((run_dir / "transport").glob("*/*.failure.json"))
            self.assertEqual(len(partial), 1)
            failure = json.loads(partial[0].read_text())
            self.assertTrue(failure["reason"].startswith("transport_incomplete_response"))
            response_path = partial[0].with_name(partial[0].name.replace(".failure.json", ".response.raw"))
            self.assertEqual(response_path.read_bytes(), b'{"choices":[')


if __name__ == "__main__":
    unittest.main()

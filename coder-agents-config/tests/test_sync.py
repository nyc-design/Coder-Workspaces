"""Offline CLI regression tests; requires jq, mikefarah/yq v4, and envsubst.

Run with: python3 -m unittest discover -s coder-agents-config/tests -v
"""

import copy
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


SYNC = Path(__file__).resolve().parents[1] / "sync.sh"
ORG_ID = "11111111-1111-4111-8111-111111111111"
PROVIDER_ID = "22222222-2222-4222-8222-222222222222"
MODEL_ID = "33333333-3333-4333-8333-333333333333"
OTHER_PROVIDER_ID = "44444444-4444-4444-8444-444444444444"
OTHER_MODEL_ID = "55555555-5555-4555-8555-555555555555"
MODEL_NAME = "cliproxy-claude/claude-haiku-5-5"
MODELS = f"/api/v2/organizations/{ORG_ID}/chats/models"
OVERRIDES = f"/api/v2/organizations/{ORG_ID}/chats/model-overrides"
PROVIDERS = "/api/v2/ai/providers"


def desired_override(context="title_generation", **extra):
    return {
        "context": context,
        "provider": "anthropic",
        "model": MODEL_NAME,
        **extra,
    }


class CoderAPI:
    """Stateful HTTP fixture: no external services or mocked executables."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.providers = [{"id": PROVIDER_ID, "name": "anthropic"}]
        self.models = [{
            "id": MODEL_ID,
            "ai_provider_id": PROVIDER_ID,
            "model": MODEL_NAME,
            "enabled": True,
        }]
        self.overrides = {
            "unlisted_context": {
                "context": "unlisted_context",
                "model_config_id": MODEL_ID,
                "reasoning_effort": "high",
            }
        }
        self.requests = []
        self.responses = {}
        self.unexpected = []

    def dispatch(self, method, path, body):
        self.requests.append((method, path, copy.deepcopy(body)))
        if (method, path) in self.responses:
            return self.responses[method, path]
        if method == "GET":
            if path in ("/api/v2/organizations/default", "/api/v2/organizations/team-slug"):
                return 200, {"id": ORG_ID}
            if path == PROVIDERS:
                return 200, self.providers
            if path == MODELS:
                return 200, {"models": self.models}
            if path == OVERRIDES:
                return 200, {"overrides": list(self.overrides.values())}
            if path in (f"/api/v2/organizations/{ORG_ID}/mcp-servers", "/api/v2/templates"):
                return 200, []
            if path == "/api/v2/chats/config/system-prompt":
                return 200, {"system_prompt": "test"}
            if path == "/api/v2/chats/config/plan-mode-instructions":
                return 200, {"plan_mode_instructions": "test"}
        if method == "PUT" and path.startswith(OVERRIDES + "/"):
            context = path.removeprefix(OVERRIDES + "/")
            self.overrides[context] = {"context": context, **body}
            return 200, self.overrides[context]
        if method == "POST" and path == MODELS:
            model = {**body, "id": MODEL_ID}
            self.models.append(model)
            return 201, model
        if path.startswith(MODELS + "/"):
            model_id = path.removeprefix(MODELS + "/")
            for model in self.models:
                if model["id"] == model_id:
                    if method == "PATCH":
                        model.update(body)
                        return 200, model
                    if method == "DELETE":
                        self.models.remove(model)
                        return 204, None
        self.unexpected.append((method, path, body))
        return 404, {"message": f"unexpected fixture request: {method} {path}"}


class SyncModelOverridesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        missing = [tool for tool in ("bash", "curl", "jq", "yq", "envsubst") if not shutil.which(tool)]
        if missing:
            raise unittest.SkipTest("Install required real tools: " + ", ".join(missing))
        version = subprocess.run(["yq", "--version"], text=True, capture_output=True, check=True)
        if not re.search(r"version v?4\.", version.stdout + version.stderr):
            raise unittest.SkipTest("These CLI tests require mikefarah/yq v4")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sync-model-overrides-")
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name)
        self.api = CoderAPI()
        api = self.api

        class Handler(BaseHTTPRequestHandler):
            def handle_request(self):
                length = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(length)) if length else None
                if self.headers.get("Coder-Session-Token") != "offline-test-token":
                    status, response = 401, {"message": "missing test authentication"}
                else:
                    status, response = api.dispatch(self.command, self.path, body)
                encoded = response if isinstance(response, bytes) else json.dumps(response).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                if status != 204:
                    self.wfile.write(encoded)

            do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = handle_request

            def log_message(self, *_args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def tearDown(self):
        self.assertEqual([], self.api.unexpected, "Fixture did not recognize an API call")

    def write_overrides(self, document):
        # JSON is valid YAML; production yq still parses every input file.
        (self.config / "model-overrides.yaml").write_text(json.dumps(document) + "\n")

    def run_sync(self, mode="push", success=True, **extra_env):
        env = os.environ.copy()
        env.pop("CODER_ORGANIZATION", None)
        env.update({
            "CODER_URL": f"http://127.0.0.1:{self.server.server_port}",
            "CODER_SESSION_TOKEN": "offline-test-token",
            "LLM_GATEWAY_API_KEY": "offline-test-key",
            "CONTEXT7_API_KEY": "offline-test-key",
            "GITHUB_PAT": "offline-test-key",
            **extra_env,
        })
        result = subprocess.run(
            ["bash", str(SYNC), mode, str(self.config)],
            cwd=SYNC.parents[1], env=env, text=True, capture_output=True, timeout=30,
        )
        output = f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        if success:
            self.assertEqual(0, result.returncode, output)
        else:
            self.assertNotEqual(0, result.returncode, output)
            self.assertTrue(result.stderr.strip(), "Failure must explain itself on stderr\n" + output)
        return result

    def override_writes(self):
        return [request for request in self.api.requests
                if request[0] != "GET" and request[1].startswith(OVERRIDES)]

    def read_export(self, name="model-overrides.yaml"):
        path = self.config / (name + ".new")
        self.assertTrue(path.is_file(), f"pull must export {path.name}")
        result = subprocess.run(
            ["yq", "-o=json", ".", str(path)], text=True, capture_output=True, check=True,
        )
        return json.loads(result.stdout)

    def test_push_writes_verified_reference_and_preserves_unlisted_context(self):
        untouched = copy.deepcopy(self.api.overrides["unlisted_context"])
        self.write_overrides({"overrides": [desired_override(reasoning_effort="low")]})
        self.run_sync()
        self.assertEqual([
            ("PUT", OVERRIDES + "/title_generation", {
                "model_config_id": MODEL_ID, "reasoning_effort": "low",
            })
        ], self.override_writes())
        self.assertEqual(untouched, self.api.overrides["unlisted_context"])
        put_index = next(i for i, request in enumerate(self.api.requests) if request[0] == "PUT")
        self.assertIn(("GET", OVERRIDES, None), self.api.requests[put_index + 1:])

    def test_missing_file_and_empty_overrides_make_no_writes(self):
        for document in (None, {"overrides": []}):
            with self.subTest(document=document):
                self.api.reset()
                if document is not None:
                    self.write_overrides(document)
                self.run_sync()
                self.assertEqual([], self.override_writes())

    def test_omitted_and_null_effort_inherit_default(self):
        for extra in ({}, {"reasoning_effort": None}):
            with self.subTest(extra=extra):
                self.api.reset()
                self.write_overrides({"overrides": [desired_override(**extra)]})
                self.run_sync()
                writes = self.override_writes()
                self.assertEqual(1, len(writes))
                self.assertEqual(MODEL_ID, writes[0][2]["model_config_id"])
                self.assertIsNone(writes[0][2].get("reasoning_effort"))

    def test_invalid_document_shapes_are_rejected_without_writes(self):
        for document in (None, [], "bad", {}, {"overrides": None},
                         {"overrides": {}}, {"overrides": "bad"}):
            with self.subTest(document=document):
                self.api.reset()
                self.write_overrides(document)
                self.run_sync(success=False)
                self.assertEqual([], self.override_writes())

    def test_invalid_fields_and_unsafe_contexts_are_rejected_without_writes(self):
        entries = [None, [], "bad"]
        for field in ("context", "provider", "model"):
            for value in (None, "", 42, [], {}):
                entries.append({**desired_override(), field: value})
            entry = desired_override()
            del entry[field]
            entries.append(entry)
        for context in ("Title_generation", "title-generation", "../admin", "title/a", "title?x", "title\n", "1title"):
            entries.append(desired_override(context))
        for effort in (True, 1, [], {}):
            entries.append(desired_override(reasoning_effort=effort))
        for entry in entries:
            with self.subTest(entry=entry):
                self.api.reset()
                self.write_overrides({"overrides": [desired_override("valid_context"), entry]})
                self.run_sync(success=False)
                self.assertEqual([], self.override_writes())

    def test_duplicate_contexts_are_rejected_before_writes(self):
        self.write_overrides({"overrides": [desired_override(), desired_override(reasoning_effort="low")]})
        self.run_sync(success=False)
        self.assertEqual([], self.override_writes())

    def test_missing_provider_is_resolved_before_any_override_put(self):
        self.write_overrides({"overrides": [
            desired_override("valid_context"),
            desired_override("other_context", provider="missing"),
        ]})
        self.run_sync(success=False)
        self.assertEqual([], self.override_writes())

    def test_missing_ambiguous_and_disabled_models_are_rejected_before_any_put(self):
        for case in ("missing", "ambiguous", "disabled"):
            with self.subTest(case=case):
                self.api.reset()
                target = {**self.api.models[0], "id": OTHER_MODEL_ID, "model": "second-model"}
                if case == "ambiguous":
                    self.api.models.extend([target, {**target, "id": "duplicate-model-id"}])
                elif case == "disabled":
                    self.api.models.append({**target, "enabled": False})
                self.write_overrides({"overrides": [
                    desired_override("valid_context"),
                    desired_override("other_context", model="second-model"),
                ]})
                self.run_sync(success=False)
                self.assertEqual([], self.override_writes())

    def test_model_matching_is_scoped_to_provider(self):
        self.api.providers.append({"id": OTHER_PROVIDER_ID, "name": "openai"})
        self.api.models.insert(0, {
            "id": OTHER_MODEL_ID, "ai_provider_id": OTHER_PROVIDER_ID,
            "model": MODEL_NAME, "enabled": True,
        })
        self.write_overrides({"overrides": [desired_override()]})
        self.run_sync()
        self.assertEqual(MODEL_ID, self.override_writes()[0][2]["model_config_id"])

    def test_push_models_finishes_before_overrides_resolve_new_model(self):
        self.api.models = []
        (self.config / "models.yaml").write_text(json.dumps({"models": [{
            "provider": "anthropic", "model": MODEL_NAME, "enabled": True,
        }]}))
        self.write_overrides({"overrides": [desired_override()]})
        self.run_sync()
        requests = self.api.requests
        created = next(i for i, r in enumerate(requests) if r[:2] == ("POST", MODELS))
        applied = next(i for i, r in enumerate(requests) if r[:2] == ("PUT", OVERRIDES + "/title_generation"))
        self.assertLess(created, applied)
        self.assertIn(("GET", MODELS, None), requests[created + 1:applied])
        self.assertEqual(MODEL_ID, requests[applied][2]["model_config_id"])

    def test_alternate_organization_is_resolved_to_uuid(self):
        self.write_overrides({"overrides": [desired_override()]})
        self.run_sync(CODER_ORGANIZATION="team-slug")
        self.assertIn(("GET", "/api/v2/organizations/team-slug", None), self.api.requests)
        self.assertNotIn(("GET", "/api/v2/organizations/default", None), self.api.requests)
        self.assertEqual(OVERRIDES + "/title_generation", self.override_writes()[0][1])

    def test_http_errors_are_fatal_in_resolution_put_and_verification(self):
        routes = [
            ("GET", "/api/v2/organizations/default"), ("GET", PROVIDERS),
            ("GET", MODELS), ("PUT", OVERRIDES + "/title_generation"), ("GET", OVERRIDES),
        ]
        for route in routes:
            with self.subTest(route=route):
                self.api.reset()
                self.api.responses[route] = (503, {"message": "offline fixture unavailable"})
                self.write_overrides({"overrides": [desired_override()]})
                result = self.run_sync(success=False)
                self.assertIn("503", result.stdout + result.stderr)
                if route[0] == "GET" and route[1] != OVERRIDES:
                    self.assertEqual([], self.override_writes())

    def test_verification_rejects_wrong_missing_and_duplicate_overrides(self):
        wanted = {"context": "title_generation", "model_config_id": MODEL_ID, "reasoning_effort": "low"}
        for overrides in ([], [{**wanted, "model_config_id": OTHER_MODEL_ID}],
                          [{**wanted, "reasoning_effort": "high"}], [wanted, wanted]):
            with self.subTest(overrides=overrides):
                self.api.reset()
                self.api.responses["GET", OVERRIDES] = (200, {"overrides": overrides})
                self.write_overrides({"overrides": [desired_override(reasoning_effort="low")]})
                self.run_sync(success=False)

    def test_malformed_resolution_and_verification_responses_are_fatal(self):
        cases = [
            (PROVIDERS, {}), (PROVIDERS, [{"name": "anthropic"}]),
            (MODELS, {}), (MODELS, {"models": None}), (MODELS, {"models": {}}),
            (MODELS, {"models": [{"ai_provider_id": PROVIDER_ID, "model": MODEL_NAME, "enabled": True}]}),
            (OVERRIDES, {}), (OVERRIDES, {"overrides": None}),
            (OVERRIDES, {"overrides": {}}), (OVERRIDES, b"not json"),
            (OVERRIDES, {"overrides": [{"context": "title_generation"}]}),
        ]
        for path, response in cases:
            with self.subTest(path=path, response=response):
                self.api.reset()
                self.api.responses["GET", path] = (200, response)
                self.write_overrides({"overrides": [desired_override()]})
                self.run_sync(success=False)
                if path != OVERRIDES:
                    self.assertEqual([], self.override_writes())

    def test_push_and_pull_reject_non_array_reference_collections(self):
        for mode in ("push", "pull"):
            for resource in ("providers", "models"):
                for shape in ("object", "null", "string"):
                    with self.subTest(mode=mode, resource=resource, shape=shape):
                        self.api.reset()
                        collection = {"key": getattr(self.api, resource)[0]}
                        if shape == "null":
                            collection = None
                        elif shape == "string":
                            collection = "invalid collection"
                        path = PROVIDERS if resource == "providers" else MODELS
                        response = collection if resource == "providers" else {"models": collection}
                        self.api.responses["GET", path] = (200, response)
                        self.write_overrides({"overrides": [desired_override()]})
                        self.run_sync(mode, success=False)
                        self.assertEqual([], self.override_writes())

    def test_push_and_pull_reject_missing_null_and_empty_reference_fields(self):
        fields = (
            ("providers", "id"), ("providers", "name"),
            ("models", "id"), ("models", "ai_provider_id"), ("models", "model"),
        )
        for mode in ("push", "pull"):
            for resource, field in fields:
                for state, value in (("missing", None), ("null", None), ("empty", "")):
                    with self.subTest(mode=mode, resource=resource, field=field, state=state):
                        self.api.reset()
                        record = getattr(self.api, resource)[0]
                        if state == "missing":
                            record.pop(field)
                        else:
                            record[field] = value
                        self.write_overrides({"overrides": [desired_override()]})
                        self.run_sync(mode, success=False)
                        self.assertEqual([], self.override_writes())

    def test_pull_rejects_missing_null_and_empty_model_config_ids(self):
        for state, value in (("missing", None), ("null", None), ("empty", "")):
            with self.subTest(state=state):
                self.api.reset()
                override = self.api.overrides["unlisted_context"]
                if state == "missing":
                    override.pop("model_config_id")
                else:
                    override["model_config_id"] = value
                self.run_sync("pull", success=False)

    def test_pull_rejects_null_and_empty_reference_joins(self):
        joins = (
            (("providers", "id"), ("models", "ai_provider_id")),
            (("models", "id"), ("overrides", "model_config_id")),
        )
        for join in joins:
            for state, value in (("missing", None), ("null", None), ("empty", "")):
                with self.subTest(join=join, state=state):
                    self.api.reset()
                    for resource, field in join:
                        records = getattr(self.api, resource)
                        record = records["unlisted_context"] if resource == "overrides" else records[0]
                        if state == "missing":
                            record.pop(field)
                        else:
                            record[field] = value
                    self.run_sync("pull", success=False)

    def test_pull_rejects_invalid_context_effort_and_duplicate_contexts(self):
        valid = {"context": "title_generation", "model_config_id": MODEL_ID}
        cases = [[{"model_config_id": MODEL_ID}]]
        for context in (None, "", "Title", "../admin", "title\n", 42, []):
            cases.append([{**valid, "context": context}])
        for effort in (True, 42, [], {}):
            cases.append([{**valid, "reasoning_effort": effort}])
        cases.append([valid, valid])
        for overrides in cases:
            with self.subTest(overrides=overrides):
                self.api.reset()
                self.api.responses["GET", OVERRIDES] = (200, {"overrides": overrides})
                self.run_sync("pull", success=False)

    def test_pull_exports_names_and_preserves_existing_yaml(self):
        original = "# keep this human-edited file\noverrides: []\n"
        path = self.config / "model-overrides.yaml"
        path.write_text(original)
        self.api.overrides = {
            "title_generation": {"context": "title_generation", "model_config_id": MODEL_ID, "reasoning_effort": "low"},
            "other_context": {"context": "other_context", "model_config_id": MODEL_ID},
        }
        self.run_sync("pull")
        exported = self.read_export()
        self.assertEqual({"overrides"}, set(exported))
        self.assertCountEqual([
            desired_override(reasoning_effort="low"), desired_override("other_context"),
        ], exported["overrides"])
        self.assertEqual(original, path.read_text())
        for identifier in (ORG_ID, PROVIDER_ID, MODEL_ID):
            self.assertNotIn(identifier, (self.config / "model-overrides.yaml.new").read_text())
        self.assertFalse(any(method != "GET" for method, _path, _body in self.api.requests))

    def test_pull_empty_overrides_exports_empty_array(self):
        self.api.overrides = {}
        self.run_sync("pull")
        self.assertEqual({"overrides": []}, self.read_export())

    def test_pull_unresolved_and_malformed_references_fail_loudly(self):
        cases = [
            {"context": "title_generation", "model_config_id": "missing-model"},
            {"context": "title_generation"},
            {"context": "title_generation", "model_config_id": MODEL_ID},
        ]
        for index, override in enumerate(cases):
            with self.subTest(override=override, missing_provider=index == 2):
                self.api.reset()
                self.api.overrides = {"title_generation": override}
                if index == 2:
                    self.api.providers = []
                self.run_sync("pull", success=False)

    def test_models_and_overrides_pull_push_roundtrip_and_second_push(self):
        self.api.overrides = {
            "title_generation": {"context": "title_generation", "model_config_id": MODEL_ID, "reasoning_effort": "low"},
        }
        self.assertNotIn("provider", self.api.models[0])
        expected = copy.deepcopy(self.api.overrides)
        self.run_sync("pull")
        self.assertEqual({"overrides": [desired_override(reasoning_effort="low")]}, self.read_export())
        exported_models = self.read_export("models.yaml")
        self.assertEqual(1, len(exported_models["models"]))
        self.assertEqual("anthropic", exported_models["models"][0]["provider"])
        self.assertEqual(MODEL_NAME, exported_models["models"][0]["model"])
        self.assertNotIn("ai_provider_id", exported_models["models"][0])
        for name in ("models.yaml", "model-overrides.yaml"):
            (self.config / name).write_bytes((self.config / (name + ".new")).read_bytes())
        self.api.overrides = {}
        for push_number in (1, 2):
            with self.subTest(push_number=push_number):
                self.api.requests = []
                self.run_sync()
                self.assertEqual(expected, self.api.overrides)
                patches = [body for method, path, body in self.api.requests
                           if method == "PATCH" and path == MODELS + "/" + MODEL_ID]
                self.assertEqual(1, len(patches))
                self.assertEqual(PROVIDER_ID, patches[0]["ai_provider_id"])
                self.assertNotIn("provider", patches[0])
                self.assertEqual(1, len(self.api.models))
                self.assertFalse(any(method in ("POST", "DELETE")
                                     for method, _path, _body in self.override_writes()))


if __name__ == "__main__":
    unittest.main()

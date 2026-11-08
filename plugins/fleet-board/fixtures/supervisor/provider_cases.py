"""Offline contract and isolation cases for production provider adapters."""
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from supervisor.inference_broker import (
    ContractError, InferenceBroker, InferenceChannel, InferenceClient, ProviderRequest, run_provider,
    validate_result,
)
from supervisor.isolation import (
    IsolationUnavailable, build_policy, probe_capabilities, run_isolated,
)
from supervisor.runner import Runner, prepare_worker_bootstrap
from supervisor.workers import request_scope_expansion


class ProviderCases(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="provider-case-")).resolve()
        self.workspace = self.root / "workspace"
        self.workspace.mkdir(mode=0o700)
        self.request = ProviderRequest.create(
            attempt_id="attempt-1", generation=2, role="reviewer", stage=None,
            provider="fake", model="fake-v1", input_text="review this",
        )

    def tearDown(self):
        import shutil
        shutil.rmtree(self.root)

    def script(self, name, content):
        path = self.root / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o700)
        return [str(path)]

    def test_versioned_contract_binds_exact_input_and_unknown_usage(self):
        self.assertEqual(self.request.schema_version, 1)
        self.assertEqual(self.request.input_sha,
                         hashlib.sha256(b"review this").hexdigest())
        command = self.script("reply.py", "#!/usr/bin/env python3\nimport json,sys\nr=json.load(sys.stdin)\nprint(json.dumps({'schema_version':1,'attempt_id':r['attempt_id'],'generation':r['generation'],'input_sha':r['input_sha'],'provider':r['provider'],'model':r['model'],'text':'clean','usage':None}))\n")
        result = run_provider(command, self.request, timeout=3)
        self.assertIsNone(result["usage"])
        self.assertEqual(result["input_sha"], self.request.input_sha)
        forged = dict(result, input_sha="0" * 64)
        with self.assertRaises(ContractError):
            validate_result(self.request, forged)

    def test_result_generation_rejects_json_boolean(self):
        request = ProviderRequest.create(
            attempt_id="attempt-1", generation=1, role="reviewer", stage=None,
            provider="fake", model="fake-v1", input_text="review this",
        )
        result = {'schema_version': 1, 'attempt_id': request.attempt_id,
                  'generation': True, 'input_sha': request.input_sha,
                  'provider': request.provider, 'model': request.model,
                  'text': 'clean', 'usage': None}
        with self.assertRaises(ContractError):
            validate_result(request, result)

    def test_provider_selection_is_explicit_and_attempt_bound(self):
        binding = {key: getattr(self.request, key) for key in
                   ("generation", "role", "stage", "provider", "model", "input_sha")}
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": ["fake"]}},
                                 attempts={"attempt-1": binding})
        with self.assertRaises(ContractError):
            broker.validate_request(dict(self.request.to_dict(), provider=None))
        with self.assertRaises(ContractError):
            broker.validate_request(dict(self.request.to_dict(), model="other"))
        with self.assertRaises(ContractError):
            broker.validate_request(dict(self.request.to_dict(), url="https://example.invalid"))
        with self.assertRaises(ContractError):
            broker.validate_request(dict(self.request.to_dict(), human_control={"action": "resume"}))
        with self.assertRaises(ContractError):
            broker.validate_request(dict(self.request.to_dict(), attempt_id="attempt-2"))

    def test_broker_delivers_only_the_registered_attempt_to_fake_provider(self):
        command = self.script("broker.py", "#!/usr/bin/env python3\nimport json,sys\nr=json.load(sys.stdin)\nprint(json.dumps({'schema_version':1,'attempt_id':r['attempt_id'],'generation':r['generation'],'input_sha':r['input_sha'],'provider':r['provider'],'model':r['model'],'text':'review complete','usage':None}))\n")
        binding = {key: getattr(self.request, key) for key in
                   ("generation", "role", "stage", "provider", "model", "input_sha")}
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": command}},
                                 attempts={"attempt-1": binding},
                                 trusted_environment={"FAKE_PROVIDER_KEY": "never-in-request"})
        result = broker.infer(self.request.to_dict(), timeout=3)
        self.assertEqual(result["attempt_id"], self.request.attempt_id)
        self.assertIsNone(result["usage"])

    def test_broker_deduplicates_request_ids_and_records_unknown_usage(self):
        calls = self.root / "provider-calls"
        command = self.script("counting-provider.py", "#!/usr/bin/env python3\nimport json,os,sys\nr=json.load(sys.stdin)\nwith open(os.environ['CALLS'], 'a') as f: f.write('call\\n')\nprint(json.dumps({'schema_version':1,'attempt_id':r['attempt_id'],'generation':r['generation'],'input_sha':r['input_sha'],'provider':r['provider'],'model':r['model'],'text':'clean','usage':None}))\n")
        binding = {key: getattr(self.request, key) for key in
                   ("generation", "role", "stage", "provider", "model", "input_sha")}
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": command}},
                                 attempts={"attempt-1": binding},
                                 trusted_environment={"CALLS": str(calls)})
        request = dict(self.request.to_dict(), request_id="call-1")
        result = broker.infer(request, timeout=3)
        self.assertIsNone(result["usage"])
        with self.assertRaises(ContractError):
            broker.infer(request, timeout=3)
        self.assertEqual(calls.read_text(encoding="utf-8").splitlines(), ["call"])
        record = broker.accounting_for("attempt-1")
        self.assertEqual(len(record), 1)
        self.assertEqual(record[0]["request_id"], "call-1")
        self.assertIsNone(record[0]["usage"])

    def test_local_channel_authenticates_attempt_and_exposes_inference_only(self):
        command = self.script("channel-provider.py", "#!/usr/bin/env python3\nimport json,sys\nr=json.load(sys.stdin)\nprint(json.dumps({'schema_version':1,'attempt_id':r['attempt_id'],'generation':r['generation'],'input_sha':r['input_sha'],'provider':r['provider'],'model':r['model'],'text':'channel result','usage':None}))\n")
        binding = {key: getattr(self.request, key) for key in
                   ("generation", "role", "stage", "provider", "model", "input_sha")}
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": command}},
                                 attempts={"attempt-1": binding})
        short_tmp = Path("/private/tmp" if Path("/private/tmp").is_dir() else "/tmp")
        channel_dir = Path(tempfile.mkdtemp(prefix="fb-channel-", dir=str(short_tmp)))
        try:
            with InferenceChannel(broker, channel_dir, ("attempt-1",)) as channel:
                token = channel.capability_for("attempt-1")
                result = InferenceClient(channel.socket_path, "attempt-1", token).infer(self.request.to_dict())
                self.assertEqual(result["text"], "channel result")
                with self.assertRaises(ContractError):
                    channel.request("attempt-1", "forged", self.request.to_dict())
                with self.assertRaises(ContractError):
                    channel.request("attempt-2", token, self.request.to_dict())
                with self.assertRaises(ContractError):
                    channel.request("attempt-1", token, self.request.to_dict(), operation="status")
                prepared = {key: getattr(self.request, key) for key in
                            ("attempt_id", "generation", "role", "provider", "model", "input_sha")}
                bootstrap = prepare_worker_bootstrap(prepared, channel, self.request.to_dict())
                self.assertEqual(set(bootstrap), {"schema_version", "attempt", "provider_request", "inference"})
                self.assertEqual(bootstrap["inference"]["capability"], token)
                self.assertNotIn("database", json.dumps(bootstrap).lower())
                with self.assertRaises(ContractError):
                    prepare_worker_bootstrap(dict(prepared, input_sha="0" * 64), channel,
                                             self.request.to_dict())
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as raw:
                    raw.settimeout(3)
                    raw.connect(str(channel.socket_path))
                    raw.sendall(struct.pack("!I", channel.MAX_REQUEST_BYTES + 1))
                    header = raw.recv(4)
                    self.assertEqual(len(header), 4)
                    size = struct.unpack("!I", header)[0]
                    self.assertLessEqual(size, 1024)
                    response = json.loads(raw.recv(size).decode("utf-8"))
                    self.assertIn("error", response)
        finally:
            import shutil
            shutil.rmtree(channel_dir)

    def test_subprocess_stdout_stderr_are_bounded_and_missing_executable_fails(self):
        noisy = self.script("noisy.py", "#!/usr/bin/env python3\nimport sys\nsys.stdout.write('x'*4096)\nsys.stderr.write('y'*4096)\n")
        with self.assertRaises(ContractError):
            run_provider(noisy, self.request, timeout=3, stdout_limit=128, stderr_limit=128)
        with self.assertRaises(ContractError):
            run_provider([str(self.root / "missing")], self.request, timeout=1)

    def test_deadline_and_cancellation_stop_the_provider_process_group(self):
        slow = self.script("slow.py", "#!/usr/bin/env python3\nimport time\ntime.sleep(10)\n")
        start = time.monotonic()
        with self.assertRaises(ContractError):
            run_provider(slow, self.request, timeout=0.1)
        self.assertLess(time.monotonic() - start, 3)
        with self.assertRaises(ContractError):
            run_provider(slow, self.request, timeout=5, cancel_after=0.1)

    def test_policy_limits_worker_paths_and_production_launch_fails_closed(self):
        policy = build_policy(self.workspace, self.root / "private-git",
                              self.root / "channels")
        self.assertIn("deny", policy["text"])
        self.assertTrue(policy["backend"] in ("macos", "linux"))
        escape = self.workspace / "escape"
        escape.symlink_to(self.root)
        with self.assertRaises(ValueError):
            build_policy(escape, self.root / "private-git", self.root / "channels")
        capability = probe_capabilities(policy)
        if not capability["available"]:
            with self.assertRaises(IsolationUnavailable):
                run_isolated(["/usr/bin/true"], policy, capability=capability)
            runner = Runner(self.root / "runner")
            with self.assertRaises(IsolationUnavailable):
                runner.launch_production({"attempt_id": "attempt-1"}, ["/usr/bin/true"], policy)

    def test_isolated_worker_output_capture_is_bounded(self):
        with patch("supervisor.isolation._wrapped_command",
                   return_value=["/bin/sh", "-c", "head -c 1048577 /dev/zero"]):
            with self.assertRaises(IsolationUnavailable):
                run_isolated(["ignored"], {"workspace": str(self.workspace)},
                             capability={"available": True}, timeout=3)

    def test_fixture_and_human_control_authority_are_not_worker_capabilities(self):
        policy = build_policy(self.workspace, self.root / "private-git",
                              self.root / "channels")
        for forbidden in ("controller.db", "board", "credentials", "ssh", "keychain", "publish", "human-control"):
            self.assertNotIn(forbidden, policy["channels"])
        defaults = json.loads((Path(__file__).resolve().parents[2] / "scripts" / "config-defaults.json").read_text())
        self.assertIs(defaults["supervisor"]["enabled"], False)
        self.assertIs(Runner(self.root / "runner").production_enabled, False)

    def test_scope_expansion_conflict_checkpoints_and_releases_slot_without_retry(self):
        class Store:
            def expand_scope(self, card, paths, revision):
                raise ValueError("scope conflict with #23")
        calls = []
        result = request_scope_expansion(
            Store(), 22, ["src"], 4, lambda: calls.append("checkpoint"),
            lambda: calls.append("release"),
        )
        self.assertEqual(calls, ["checkpoint", "release"])
        self.assertTrue(result["attempt_should_exit"])
        self.assertFalse(result["retry_penalty"])
        self.assertEqual(result["waiting_on"], "23")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        sys.argv.pop(1)  # shell harness supplies a private scratch directory
    unittest.main()

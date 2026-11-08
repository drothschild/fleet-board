"""Offline contract and isolation cases for production provider adapters."""
import hashlib
import concurrent.futures
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
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
import supervisor.isolation as isolation_module
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
        command = self.script("counting-provider.py", "#!/usr/bin/env python3\nimport json,sys\nr=json.load(sys.stdin)\nwith open(sys.argv[1], 'a') as f: f.write('call\\n')\nprint(json.dumps({'schema_version':1,'attempt_id':r['attempt_id'],'generation':r['generation'],'input_sha':r['input_sha'],'provider':r['provider'],'model':r['model'],'text':'clean','usage':None}))\n") + [str(calls)]
        binding = {key: getattr(self.request, key) for key in
                   ("generation", "role", "stage", "provider", "model", "input_sha")}
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": command}},
                                 attempts={"attempt-1": binding})
        request = dict(self.request.to_dict(), request_id="call-1")
        result = broker.infer(request, timeout=3)
        self.assertIsNone(result["usage"])
        replay = broker.infer(request, timeout=3)
        self.assertEqual(replay, result)
        self.assertEqual(calls.read_text(encoding="utf-8").splitlines(), ["call"])
        record = broker.accounting_for("attempt-1")
        self.assertEqual(len(record), 1)
        self.assertEqual(record[0]["request_id"], "call-1")
        self.assertIsNone(record[0]["usage"])

    def test_slow_attempt_does_not_serialize_other_inference_requests(self):
        slow_request = ProviderRequest.create(
            attempt_id="attempt-slow", generation=1, role="reviewer", stage=None,
            provider="fake", model="fake-v1", input_text="slow",
        )
        fast_request = ProviderRequest.create(
            attempt_id="attempt-fast", generation=1, role="reviewer", stage=None,
            provider="fake", model="fake-v1", input_text="fast",
        )
        command = self.script("concurrent-provider.py", "#!/usr/bin/env python3\nimport json,sys,time\nr=json.load(sys.stdin)\nif r['input_text']=='slow': time.sleep(.8)\nprint(json.dumps({'schema_version':1,'attempt_id':r['attempt_id'],'generation':r['generation'],'input_sha':r['input_sha'],'provider':r['provider'],'model':r['model'],'text':'done','usage':None}))\n")
        attempts = {}
        for request in (slow_request, fast_request):
            attempts[request.attempt_id] = {key: getattr(request, key) for key in
                                            ("generation", "role", "stage", "provider", "model", "input_sha")}
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": command}}, attempts=attempts)
        channel_dir = Path(tempfile.mkdtemp(prefix="fb-concurrent-", dir="/private/tmp"))
        try:
            with InferenceChannel(broker, channel_dir, tuple(attempts), request_timeout=3) as channel:
                slow = InferenceClient(channel.socket_path, "attempt-slow",
                                       channel.capability_for("attempt-slow"), timeout=3)
                fast = InferenceClient(channel.socket_path, "attempt-fast",
                                       channel.capability_for("attempt-fast"), timeout=3)
                with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                    pending = pool.submit(slow.infer, slow_request.to_dict())
                    time.sleep(.1)
                    started = time.monotonic()
                    result = fast.infer(fast_request.to_dict())
                    elapsed = time.monotonic() - started
                    self.assertEqual(result["text"], "done")
                    self.assertLess(elapsed, .6)
                    self.assertEqual(pending.result(timeout=3)["text"], "done")
        finally:
            import shutil
            shutil.rmtree(channel_dir)

    def test_inference_request_quota_is_per_attempt(self):
        binding = {key: getattr(self.request, key) for key in
                   ("generation", "role", "stage", "provider", "model", "input_sha")}
        other_binding = dict(binding)
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": ["unused"]}},
                                 attempts={"attempt-1": binding, "attempt-2": other_binding})
        channel_dir = Path(tempfile.mkdtemp(prefix="fb-quota-", dir="/private/tmp"))
        try:
            with InferenceChannel(broker, channel_dir, ("attempt-1", "attempt-2")) as channel:
                channel.MAX_REQUESTS_PER_ATTEMPT = 1
                self.assertTrue(channel._claim_attempt("attempt-1"))
                self.assertFalse(channel._claim_attempt("attempt-1"))
                self.assertTrue(channel._claim_attempt("attempt-2"))
                channel._release_attempt("attempt-1")
                self.assertFalse(channel._claim_attempt("attempt-1"))
        finally:
            import shutil
            shutil.rmtree(channel_dir)

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

    def test_isolated_worker_output_failure_kills_term_ignoring_child(self):
        marker = self.root / "surviving-child"
        ready = self.root / "child-ready"
        command = [sys.executable] + self.script(
            "noisy-parent.py",
            "#!/usr/bin/env python3\nimport pathlib,subprocess,sys,time\nchild=\"import pathlib,signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); pathlib.Path(sys.argv[2]).write_text('ready'); time.sleep(.7); pathlib.Path(sys.argv[1]).write_text('alive')\"\np=subprocess.Popen([sys.executable, '-c', child, sys.argv[1], sys.argv[2]])\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(.01)\nsys.stdout.write('x'*1048577)\nsys.stdout.flush()\n",
        ) + [str(marker), str(ready)]
        with patch("supervisor.isolation._wrapped_command", return_value=command):
            with self.assertRaises(IsolationUnavailable):
                run_isolated(["ignored"], {"workspace": str(self.workspace)},
                             capability={"available": True}, timeout=3)
        time.sleep(.9)
        self.assertFalse(marker.exists(), "worker descendant survived output cancellation")

    def test_private_git_setup_creates_contained_independent_repositories(self):
        helper = getattr(isolation_module, "prepare_private_git", None)
        self.assertTrue(callable(helper), "trusted private Git setup helper is required")
        source = self.root / "source"
        source.mkdir()
        subprocess_env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", HOME="/nonexistent",
                              GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                              GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
        subprocess.run(["git", "init", "-q", str(source)], check=True, env=subprocess_env)
        (source / "tracked.txt").write_text("private clone\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(source), "add", "tracked.txt"], check=True, env=subprocess_env)
        subprocess.run(["git", "-C", str(source), "commit", "-qm", "fixture"], check=True, env=subprocess_env)
        private_git = self.root / "private-git"
        private_git.mkdir(mode=0o700)
        result = helper(source, self.workspace, private_git)
        self.assertEqual(result["workspace"], str(self.workspace))
        self.assertTrue((self.workspace / "tracked.txt").is_file())
        for repository in (self.workspace, private_git):
            metadata = repository / ".git"
            self.assertTrue(metadata.is_dir())
            self.assertFalse((metadata / "objects" / "info" / "alternates").exists())
            common = subprocess.check_output(
                ["git", "-C", str(repository), "rev-parse", "--git-common-dir"],
                text=True, env=subprocess_env).strip()
            common_path = Path(common)
            if not common_path.is_absolute():
                common_path = repository / common_path
            self.assertEqual(common_path.resolve(), metadata.resolve())
            config = (metadata / "config").read_text(encoding="utf-8")
            self.assertNotIn(str(source), config)
            self.assertNotIn("credential", config.lower())

    def test_host_probe_reports_each_required_boundary_check(self):
        channel_dir = Path(tempfile.mkdtemp(prefix="fb-probe-channel-", dir="/private/tmp"))
        try:
            policy = build_policy(self.workspace, self.root / "private-git", channel_dir)
            capability = probe_capabilities(policy)
        finally:
            import shutil
            shutil.rmtree(channel_dir)
        expected = {"workspace_read", "workspace_write", "controller_db", "controller_socket",
                    "board_storage", "shared_git_metadata", "host_credentials",
                    "ssh_agent", "keychain", "symlink_escape", "loopback_network",
                    "publication", "forged_human_control", "inference_channel"}
        self.assertEqual(set(capability.get("checks", {})), expected)

    def test_host_probe_handles_an_existing_inference_socket(self):
        channel_dir = Path(tempfile.mkdtemp(prefix="fb-existing-channel-", dir="/private/tmp"))
        protected_sockets = []
        try:
            policy = build_policy(self.workspace, self.root / "private-git", channel_dir)
            controller_db = self.root / "controller.db"
            controller_db.write_bytes(b"test fixture")
            board = self.root / "board"
            board.mkdir()
            shared_git = self.root / "shared-git"
            shared_git.mkdir()
            credentials = self.root / "credentials"
            credentials.write_bytes(b"test fixture")
            keychain = self.root / "keychain"
            keychain.write_bytes(b"test fixture")
            for name in ("controller", "ssh-agent"):
                listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                path = self.root / (name + ".sock")
                listener.bind(str(path))
                listener.listen(1)
                protected_sockets.append(listener)
            protected = {
                "controller_db": str(controller_db),
                "controller_socket": str(self.root / "controller.sock"),
                "board_storage": str(board),
                "shared_git_metadata": str(shared_git),
                "host_credentials": [str(credentials)],
                "ssh_agent": str(self.root / "ssh-agent.sock"),
                "keychain": [str(keychain)],
            }
            with InferenceChannel(
                    InferenceBroker({"fake": {"model": "fake-v1", "command": ["unused"]}},
                                    attempts={"attempt-1": {
                                        key: getattr(self.request, key) for key in
                                        ("generation", "role", "stage", "provider", "model", "input_sha")
                                    }}), channel_dir, ("attempt-1",)) as channel:
                result = probe_capabilities(policy, inference_socket=channel.socket_path,
                                            protected_resources=protected)
                self.assertFalse(result["available"])
                self.assertNotIn("NameError", result["reason"] or "")
        finally:
            import shutil
            for listener in protected_sockets:
                listener.close()
            shutil.rmtree(channel_dir)

    def test_host_probe_requires_complete_real_protected_resource_map(self):
        policy = build_policy(self.workspace, self.root / "private-git",
                              self.root / "channels")
        result = probe_capabilities(policy, protected_resources={"controller_db": str(self.root / "db")})
        self.assertFalse(result["available"])
        self.assertIn("protected", result["reason"].lower())

    def test_unauthenticated_connections_do_not_consume_channel_quota(self):
        command = self.script("quota-provider.py", "#!/usr/bin/env python3\nimport json,sys\nr=json.load(sys.stdin)\nprint(json.dumps({'schema_version':1,'attempt_id':r['attempt_id'],'generation':r['generation'],'input_sha':r['input_sha'],'provider':r['provider'],'model':r['model'],'text':'accepted','usage':None}))\n")
        binding = {key: getattr(self.request, key) for key in
                   ("generation", "role", "stage", "provider", "model", "input_sha")}
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": command}},
                                 attempts={"attempt-1": binding})
        channel_dir = Path(tempfile.mkdtemp(prefix="fb-auth-quota-", dir="/private/tmp"))
        try:
            with InferenceChannel(broker, channel_dir, ("attempt-1",)) as channel:
                for _ in range(channel.MAX_REQUESTS + 1):
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as raw:
                        raw.settimeout(2)
                        raw.connect(str(channel.socket_path))
                client = InferenceClient(channel.socket_path, "attempt-1",
                                         channel.capability_for("attempt-1"), timeout=3)
                self.assertEqual(client.infer(self.request.to_dict())["text"], "accepted")
        finally:
            import shutil
            shutil.rmtree(channel_dir)

    def test_production_launch_requires_durable_deadline_and_cancellation(self):
        prepared = {
            "attempt_id": "attempt-1", "generation": 1, "input_sha": self.request.input_sha,
            "role": "reviewer", "provider": "fake", "model": "fake-v1",
            "started_at": time.time(), "deadline": time.time() + 60,
        }
        runner = Runner(self.root / "runner", production_enabled=True)
        policy = build_policy(self.workspace, self.root / "private-git", self.root / "channels")
        fake_channel = object()
        with patch("supervisor.runner.probe_capabilities", return_value={"available": True}), \
             patch("supervisor.runner.prepare_private_git"), \
             patch("supervisor.runner.prepare_worker_bootstrap", return_value={"schema_version": 1}), \
             patch("supervisor.runner.run_isolated") as isolated:
            with self.assertRaises((TypeError, ValueError)):
                runner.launch_production(prepared, ["/usr/bin/true"], policy,
                                         channel=fake_channel, request={},
                                         source_repository=self.root)
            cancel = threading.Event()
            result = runner.launch_production(prepared, ["/usr/bin/true"], policy,
                                              channel=fake_channel, request={},
                                              source_repository=self.root, cancel_event=cancel)
        self.assertIs(result, isolated.return_value)
        self.assertAlmostEqual(isolated.call_args.kwargs["timeout"],
                               prepared["deadline"] - time.time(), delta=1)
        self.assertIs(isolated.call_args.kwargs["cancel_event"], cancel)

    def test_isolated_worker_deadline_and_cancellation_kill_process_group(self):
        child_marker = self.root / "cancelled-descendant"
        ready = self.root / "cancel-descendant-ready"
        command = [sys.executable] + self.script(
            "cancel-parent.py",
            "#!/usr/bin/env python3\nimport pathlib,signal,subprocess,sys,time\nchild=\"import pathlib,signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); pathlib.Path(sys.argv[2]).write_text('ready'); time.sleep(.8); pathlib.Path(sys.argv[1]).write_text('alive')\"\np=subprocess.Popen([sys.executable, '-c', child, sys.argv[1], sys.argv[2]])\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(.01)\nwhile True: time.sleep(.05)\n",
        ) + [str(child_marker), str(ready)]
        with patch("supervisor.isolation._wrapped_command", return_value=command):
            with self.assertRaises(IsolationUnavailable):
                run_isolated(["ignored"], {"workspace": str(self.workspace)},
                             capability={"available": True}, timeout=.1,
                             cancel_event=threading.Event())
            cancellation = threading.Event()
            timer = threading.Timer(.1, cancellation.set)
            timer.start()
            try:
                with self.assertRaises(IsolationUnavailable):
                    run_isolated(["ignored"], {"workspace": str(self.workspace)},
                                 capability={"available": True}, timeout=3,
                                 cancel_event=cancellation)
            finally:
                timer.cancel()
        time.sleep(.9)
        self.assertFalse(child_marker.exists(), "cancelled worker descendant survived")

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

"""Offline contract and isolation cases for production provider adapters."""
import hashlib
import concurrent.futures
import errno
import json
import os
from pathlib import Path
import socket
import signal
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

    def test_dispatcher_timeout_cancels_callback_before_later_pump(self):
        from supervisor.workers import OwnerThreadDispatcher

        dispatcher = OwnerThreadDispatcher(call_timeout=0.05)
        invoked = []
        errors = []

        def submit():
            try:
                dispatcher.call(lambda: invoked.append("mutated"))
            except Exception as exc:
                errors.append(exc)

        caller = threading.Thread(target=submit)
        caller.start()
        deadline = time.monotonic() + 1
        while dispatcher._queue.qsize() == 0 and time.monotonic() < deadline:
            time.sleep(0.001)
        self.assertEqual(dispatcher._queue.qsize(), 1)
        caller.join(timeout=1)
        self.assertFalse(caller.is_alive())
        self.assertEqual(len(errors), 1)
        self.assertIsInstance(errors[0], TimeoutError)

        dispatcher.run_pending()
        self.assertEqual(invoked, [])

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

    def test_attempt_cancellation_stops_its_inflight_provider(self):
        started = self.root / "provider-started"
        command = self.script(
            "cancel-aware-provider.py",
            "#!/usr/bin/env python3\nimport json,pathlib,sys,time\njson.load(sys.stdin)\npathlib.Path(sys.argv[1]).write_text('started')\ntime.sleep(10)\n",
        ) + [str(started)]
        binding = {key: getattr(self.request, key) for key in
                   ("generation", "role", "stage", "provider", "model", "input_sha")}
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": command}},
                                 attempts={"attempt-1": binding})
        cancel = threading.Event()
        channel_dir = Path(tempfile.mkdtemp(prefix="fb-attempt-cancel-", dir="/private/tmp"))
        try:
            with InferenceChannel(
                    broker, channel_dir, ("attempt-1",), request_timeout=20,
                    attempt_controls={"attempt-1": {
                        "deadline": time.time() + 20, "cancel_event": cancel}}) as channel:
                client = InferenceClient(channel.socket_path, "attempt-1",
                                         channel.capability_for("attempt-1"), timeout=3)
                with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                    pending = pool.submit(client.infer, self.request.to_dict())
                    deadline = time.monotonic() + 3
                    while not started.exists() and time.monotonic() < deadline:
                        time.sleep(.01)
                    self.assertTrue(started.exists(), "fake provider did not start")
                    cancel.set()
                    with self.assertRaises(ContractError):
                        pending.result(timeout=2)
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

    def test_over_quota_attempt_cannot_consume_shared_channel_quota(self):
        other = ProviderRequest.create(
            attempt_id="attempt-2", generation=2, role="reviewer", stage=None,
            provider="fake", model="fake-v1", input_text="review another input",
        )
        command = self.script(
            "multi-attempt-provider.py",
            "#!/usr/bin/env python3\nimport json,sys\nr=json.load(sys.stdin)\nprint(json.dumps({'schema_version':1,'attempt_id':r['attempt_id'],'generation':r['generation'],'input_sha':r['input_sha'],'provider':r['provider'],'model':r['model'],'text':'accepted','usage':None}))\n",
        )
        bindings = {}
        for request in (self.request, other):
            bindings[request.attempt_id] = {key: getattr(request, key) for key in
                                            ("generation", "role", "stage", "provider", "model", "input_sha")}
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": command}},
                                 attempts=bindings)
        channel_dir = Path(tempfile.mkdtemp(prefix="fb-over-quota-", dir="/private/tmp"))
        try:
            with InferenceChannel(broker, channel_dir, tuple(bindings)) as channel:
                channel.MAX_REQUESTS = 2
                channel.MAX_REQUESTS_PER_ATTEMPT = 1
                first = channel.request("attempt-1", channel.capability_for("attempt-1"),
                                        self.request.to_dict())
                self.assertEqual(first["text"], "accepted")
                for index in range(3):
                    rejected = dict(self.request.to_dict(), request_id="over-quota-{}".format(index))
                    with self.assertRaises(ContractError):
                        channel.request("attempt-1", channel.capability_for("attempt-1"), rejected)
                second = channel.request("attempt-2", channel.capability_for("attempt-2"),
                                         other.to_dict())
                self.assertEqual(second["text"], "accepted")
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
                self.assertEqual(set(bootstrap), {"schema_version", "attempt", "provider_request", "inference", "operations"})
                self.assertEqual(bootstrap["operations"], [])
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

    def test_attempt_scoped_result_heartbeat_and_scope_operations(self):
        from supervisor.workers import (OwnerThreadDispatcher, build_attempt_operation_handlers,
                                        build_attempt_terminal_checker)

        request = ProviderRequest.create(
            attempt_id="attempt-1", generation=2, role="stage-reviewer", stage="code",
            provider="fake", model="fake-v1", input_text="review this",
        )
        binding = {
            "domain_id": "domain-1", "job_id": "job-1", "attempt_id": request.attempt_id,
            "generation": request.generation, "input_sha": request.input_sha,
            "role": request.role, "stage": request.stage,
            "provider": request.provider, "model": request.model,
        }
        operation_binding = {key: binding[key] for key in
                             ("domain_id", "job_id", "attempt_id", "generation", "input_sha", "role", "stage")}
        provider_binding = {key: getattr(request, key) for key in
                            ("generation", "role", "stage", "provider", "model", "input_sha")}
        command = self.script(
            "operations-provider.py",
            "#!/usr/bin/env python3\nimport json,sys\nr=json.load(sys.stdin)\nprint(json.dumps({'schema_version':1,'attempt_id':r['attempt_id'],'generation':r['generation'],'input_sha':r['input_sha'],'provider':r['provider'],'model':r['model'],'text':'ok','usage':None}))\n",
        )
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": command}},
                                 attempts={request.attempt_id: provider_binding})
        received = {"heartbeat": [], "result": [], "scope_request": []}
        result_store_root = self.root / "operation-result-store"
        result_store_root.mkdir(mode=0o700)

        class ResultStore:
            directory = result_store_root
            domain_id = "domain-1"

            def record_result(self, envelope, **_trusted):
                received["result"].append(envelope)
                return {"disposition": "current"}

            def expand_scope(self, card, paths, revision):
                received["scope_request"].append((card, paths, revision))
                raise ValueError("scope conflict with #23")

            def operation_attempt_authority(self, _attempt_id, _generation, _input_sha):
                return "active"

        (self.workspace / "report.md").write_text(
            "## Status\nclean\n\n## Findings\n- none\n\n## For the card\nReviewed.\n\n"
            "VERIFIED: `true` -> 1 check\n", encoding="utf-8")
        report_hash = hashlib.sha256((self.workspace / "report.md").read_bytes()).hexdigest()
        dispatcher = OwnerThreadDispatcher()
        result_store = ResultStore()
        handlers = build_attempt_operation_handlers(
            result_store, "22", binding=operation_binding, scratch=self.workspace,
            heartbeat=lambda payload: received["heartbeat"].append(payload) or {"accepted": True},
            checkpoint=lambda: received.setdefault("scope_callbacks", []).append("checkpoint"),
            release_slot=lambda: received.setdefault("scope_callbacks", []).append("release"),
            dispatcher=dispatcher)
        terminal_checker = build_attempt_terminal_checker(result_store, dispatcher)
        channel_dir = Path(tempfile.mkdtemp(prefix="fb-worker-operations-", dir="/private/tmp"))
        operation_state_dir = Path(tempfile.mkdtemp(prefix="fb-controller-operations-", dir="/private/tmp"))
        try:
            with InferenceChannel(broker, channel_dir, (request.attempt_id,),
                                  operation_journal=operation_state_dir / "operations.json",
                                  terminal_attempt_checker=terminal_checker,
                                  controller_dispatcher=dispatcher) as channel:
                channel.bind_attempt_operations(
                    request.attempt_id,
                    operation_binding, handlers)
                self.assertEqual(channel.operations_for(request.attempt_id),
                                 ("heartbeat", "result", "scope_request"))
                bootstrap = prepare_worker_bootstrap(binding, channel, request.to_dict())
                self.assertEqual(bootstrap["operations"],
                                 ["heartbeat", "result", "scope_request"])
                client = InferenceClient(channel.socket_path, request.attempt_id,
                                         channel.capability_for(request.attempt_id), timeout=3)
                def owner_request(payload, operation):
                    result, error = [], []

                    def submit():
                        try:
                            result.append(client.request(payload, operation=operation))
                        except Exception as exc:
                            error.append(exc)

                    request_thread = threading.Thread(target=submit)
                    request_thread.start()
                    while request_thread.is_alive():
                        dispatcher.run_pending(timeout=0.05)
                        request_thread.join(timeout=0.01)
                    if error:
                        raise error[0]
                    return result[0]

                heartbeat = dict(operation_binding, schema_version=1,
                                 request_id="heartbeat-1", at=time.time())
                self.assertEqual(owner_request(heartbeat, "heartbeat"), {"accepted": True})
                self.assertEqual(owner_request(heartbeat, "heartbeat"), {"accepted": True})
                result = dict(operation_binding, schema_version=1, outcome="success",
                              request_id="result-1",
                              report_path="report.md", artifact_hashes={"report.md": report_hash},
                              usage=None, exit_code=0)
                self.assertEqual(owner_request(result, "result"), {"disposition": "current"})
                forged_result = dict(result, request_id="result-forged",
                                     report_path="../outside/report",
                                     artifact_hashes={"../outside/report": "b" * 64})
                with self.assertRaises(ContractError):
                    owner_request(forged_result, "result")
                scope = dict(operation_binding, schema_version=1, paths=["src/worker.py"],
                             request_id="scope-1", expected_revision=7)
                denied = owner_request(scope, "scope_request")
                self.assertFalse(denied["granted"])
                self.assertFalse(denied["retry_penalty"])
                self.assertTrue(denied["attempt_should_exit"])
                self.assertEqual(owner_request(scope, "scope_request"), denied)
                with self.assertRaises(ContractError):
                    owner_request(dict(heartbeat, input_sha="0" * 64), "heartbeat")
                with self.assertRaises(ContractError):
                    owner_request(dict(scope, generation=request.generation + 1), "scope_request")
                with self.assertRaises(ContractError):
                    owner_request({}, "board_merge")
                self.assertEqual(len(received["heartbeat"]), 1)
                self.assertEqual(len(received["result"]), 1)
                self.assertEqual(len(received["scope_request"]), 1)
                self.assertEqual(received["scope_callbacks"], ["checkpoint", "release"])
        finally:
            import shutil
            shutil.rmtree(channel_dir)

    def test_controller_scope_handler_uses_reservations_and_releases_without_retry(self):
        from supervisor.workers import build_attempt_operation_handlers

        class Store:
            def __init__(self):
                self.calls = []
                self.conflict = True
                self.domain_id = "d" * 64

            def record_result(self, _envelope):
                return {"disposition": "current"}

            def expand_scope(self, card, paths, revision):
                self.calls.append((card, paths, revision))
                if self.conflict:
                    raise ValueError("scope conflict with #23")
                return {"card": card, "paths": paths, "reservation_revision": 2}

        store = Store()
        store.directory = self.root / "scope-controller-store"
        store.directory.mkdir(mode=0o700)
        callbacks = []
        binding = {"domain_id": "d" * 64, "job_id": "job-1", "attempt_id": "attempt-1",
                   "generation": 1, "input_sha": "a" * 64, "role": "stage-reviewer", "stage": "code"}
        handlers = build_attempt_operation_handlers(
            store, "22", binding=binding, scratch=self.workspace,
            heartbeat=lambda payload: {"accepted": True},
            checkpoint=lambda: callbacks.append("checkpoint"),
            release_slot=lambda: callbacks.append("release"),
        )
        result = handlers["scope_request"]({"paths": ["src/new.py"], "expected_revision": 8})
        self.assertEqual(store.calls, [("22", ["src/new.py"], 8)])
        self.assertEqual(callbacks, ["checkpoint", "release"])
        self.assertEqual(result["waiting_on"], "23")
        self.assertFalse(result["retry_penalty"])
        self.assertTrue(result["attempt_should_exit"])
        store.conflict = False
        granted = handlers["scope_request"]({"paths": ["src/next.py"], "expected_revision": 9})
        self.assertTrue(granted["granted"])
        self.assertEqual(granted["reservation"]["reservation_revision"], 2)

    def test_scope_operation_replay_survives_channel_restart_for_grant_and_conflict(self):
        from supervisor.workers import (OwnerThreadDispatcher, build_attempt_operation_handlers,
                                        build_attempt_terminal_checker)

        requests = {
            "attempt-granted": ProviderRequest.create(
                attempt_id="attempt-granted", generation=1, role="stage-reviewer", stage="code",
                provider="fake", model="fake-v1", input_text="grant scope"),
            "attempt-denied": ProviderRequest.create(
                attempt_id="attempt-denied", generation=1, role="stage-reviewer", stage="code",
                provider="fake", model="fake-v1", input_text="deny scope"),
        }
        broker_bindings = {
            attempt_id: {key: getattr(request, key) for key in
                         ("generation", "role", "stage", "provider", "model", "input_sha")}
            for attempt_id, request in requests.items()
        }
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": ["unused"]}},
                                 attempts=broker_bindings)
        test_root = Path(tempfile.mkdtemp(prefix="fb-op-", dir="/private/tmp"))
        journal_dir = test_root / "controller-state"
        journal_dir.mkdir(mode=0o700)
        journal_path = journal_dir / "operations.json"
        expansion_calls, conflict_callbacks = [], []
        bindings, handlers = {}, {}
        dispatcher = OwnerThreadDispatcher()

        class Store:
            def __init__(self, attempt_id):
                self.directory = journal_dir / (attempt_id + "-store")
                self.directory.mkdir(mode=0o700)
                self.domain_id = "domain-1"

            def record_result(self, _envelope):
                return {"disposition": "current"}

            def expand_scope(self, card, paths, revision):
                expansion_calls.append((card, list(paths), revision))
                if card == "24":
                    raise ValueError("scope conflict with #23")
                return {"card": card, "paths": paths, "reservation_revision": 4}

            def operation_attempt_authority(self, _attempt_id, _generation, _input_sha):
                return "active"

        controller_store = Store("controller")
        terminal_checker = build_attempt_terminal_checker(controller_store, dispatcher)
        for index, (attempt_id, request) in enumerate(requests.items()):
            binding = {"domain_id": "domain-1", "job_id": "job-" + str(index),
                       "attempt_id": attempt_id, "generation": 1,
                       "input_sha": request.input_sha, "role": request.role, "stage": request.stage}
            bindings[attempt_id] = binding
            handlers[attempt_id] = build_attempt_operation_handlers(
                controller_store, "22" if attempt_id == "attempt-granted" else "24",
                binding=binding, scratch=self.workspace,
                heartbeat=lambda payload: {"accepted": True},
                checkpoint=lambda: conflict_callbacks.append("checkpoint"),
                release_slot=lambda: conflict_callbacks.append("release"),
                dispatcher=dispatcher,
            )

        payloads = {
            "attempt-granted": dict(bindings["attempt-granted"], schema_version=1,
                                     request_id="scope-grant", paths=["src/new.py"],
                                     expected_revision=9),
            "attempt-denied": dict(bindings["attempt-denied"], schema_version=1,
                                    request_id="scope-deny", paths=["src/new.py"],
                                    expected_revision=9),
        }
        first_results = {}
        for suffix, result_store in (("one", {}), ("two", first_results)):
            directory = test_root / ("channel-" + suffix)
            directory.mkdir(mode=0o700)
            with InferenceChannel(
                    broker, directory, tuple(requests), operation_journal=journal_path,
                    terminal_attempt_checker=terminal_checker,
                    controller_dispatcher=dispatcher) as channel:
                for attempt_id in requests:
                    channel.bind_attempt_operations(attempt_id, bindings[attempt_id], handlers[attempt_id])
                for attempt_id in requests:
                    result, error = [], []

                    def submit_request(active_attempt=attempt_id):
                        try:
                            result.append(channel.request(
                                active_attempt, channel.capability_for(active_attempt),
                                payloads[active_attempt], operation="scope_request"))
                        except Exception as exc:
                            error.append(exc)

                    request_thread = threading.Thread(target=submit_request)
                    request_thread.start()
                    while request_thread.is_alive():
                        dispatcher.run_pending(timeout=0.05)
                        request_thread.join(timeout=0.01)
                    if error:
                        raise error[0]
                    result_store[attempt_id] = result[0]
        self.assertTrue(first_results["attempt-granted"]["granted"])
        self.assertFalse(first_results["attempt-denied"]["granted"])
        self.assertEqual(expansion_calls, [("22", ["src/new.py"], 9),
                                           ("24", ["src/new.py"], 9)])
        self.assertEqual(conflict_callbacks, ["checkpoint", "release"])
        import shutil
        shutil.rmtree(test_root)

    def test_inflight_scope_operation_recovery_fails_closed(self):
        from supervisor.workers import (OwnerThreadDispatcher, build_attempt_operation_handlers,
                                        build_attempt_terminal_checker)

        request = ProviderRequest.create(
            attempt_id="attempt-recover", generation=3, role="stage-reviewer", stage="code",
            provider="fake", model="fake-v1", input_text="recover scope")
        broker_binding = {key: getattr(request, key) for key in
                          ("generation", "role", "stage", "provider", "model", "input_sha")}
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": ["unused"]}},
                                 attempts={request.attempt_id: broker_binding})
        test_root = Path(tempfile.mkdtemp(prefix="fb-recover-", dir="/private/tmp"))
        state_dir = test_root / "state"
        state_dir.mkdir(mode=0o700)
        channel_dir = test_root / "channel"
        channel_dir.mkdir(mode=0o700)
        binding = {"domain_id": "domain-1", "job_id": "job-1",
                   "attempt_id": request.attempt_id, "generation": request.generation,
                   "input_sha": request.input_sha, "role": request.role, "stage": request.stage}
        payload = dict(binding, schema_version=1, request_id="pending-scope",
                       paths=["src/new.py"], expected_revision=5)
        body_sha = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":"),
                                               allow_nan=False).encode("utf-8")).hexdigest()
        journal = state_dir / "operations.json"
        journal.write_text(json.dumps({"schema_version": 1, "operations": [{
            "attempt_id": request.attempt_id, "operation": "scope_request",
            "request_id": "pending-scope", "body_sha": body_sha, "state": "in_flight"}]}),
            encoding="utf-8")
        journal.chmod(0o600)
        effects = []

        class Store:
            directory = state_dir / "store"
            domain_id = "domain-1"

            def expand_scope(self, card, paths, revision):
                effects.append("expand")
                return {"card": card, "paths": paths, "reservation_revision": revision + 1}

            def record_result(self, _envelope):
                return {"disposition": "current"}

            def operation_attempt_authority(self, _attempt_id, _generation, _input_sha):
                return "active"

        (state_dir / "store").mkdir(mode=0o700)
        dispatcher = OwnerThreadDispatcher()
        result_store = Store()
        handlers = build_attempt_operation_handlers(
            result_store, "22", binding=binding, scratch=self.workspace,
            heartbeat=lambda value: {"accepted": True}, checkpoint=lambda: effects.append("checkpoint"),
            release_slot=lambda: effects.append("release"), dispatcher=dispatcher)
        terminal_checker = build_attempt_terminal_checker(result_store, dispatcher)
        channel = InferenceChannel(broker, channel_dir, (request.attempt_id,),
                                   operation_journal=journal,
                                   terminal_attempt_checker=terminal_checker,
                                   controller_dispatcher=dispatcher)
        channel.bind_attempt_operations(request.attempt_id, binding, handlers)
        with self.assertRaisesRegex(ContractError, "already consumed"):
            channel._dispatch_worker_operation(request.attempt_id, "scope_request", payload)
        self.assertEqual(effects, [])
        import shutil
        shutil.rmtree(test_root)

    def test_operation_journal_retirement_requires_terminal_release_and_blocks_replay(self):
        from supervisor.workers import (OwnerThreadDispatcher, build_attempt_operation_handlers,
                                        build_attempt_terminal_checker)

        request = ProviderRequest.create(
            attempt_id="attempt-retire", generation=4, role="stage-reviewer", stage="code",
            provider="fake", model="fake-v1", input_text="retire journal")
        broker_binding = {key: getattr(request, key) for key in
                          ("generation", "role", "stage", "provider", "model", "input_sha")}
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": ["unused"]}},
                                 attempts={request.attempt_id: broker_binding})
        test_root = Path(tempfile.mkdtemp(prefix="fb-retire-", dir="/private/tmp"))
        state_dir = test_root / "state"
        state_dir.mkdir(mode=0o700)
        channel_dir = test_root / "channel"
        channel_dir.mkdir(mode=0o700)
        store_dir = state_dir / "store"
        store_dir.mkdir(mode=0o700)
        binding = {"domain_id": "domain-1", "job_id": "job-1",
                   "attempt_id": request.attempt_id, "generation": request.generation,
                   "input_sha": request.input_sha, "role": request.role, "stage": request.stage}

        class Store:
            directory = store_dir
            domain_id = "domain-1"

            def record_result(self, _envelope, **_trusted):
                return {"disposition": "current"}

            def expand_scope(self, card, paths, revision):
                return {"card": card, "paths": paths, "reservation_revision": revision + 1}

            def operation_attempt_authority(self, _attempt_id, _generation, _input_sha):
                return "terminal_released" if authority["retirable"] else "active"

        dispatcher = OwnerThreadDispatcher()
        store = Store()
        handlers = build_attempt_operation_handlers(
            store, "22", binding=binding, scratch=self.workspace,
            dispatcher=dispatcher,
            heartbeat=lambda _payload: {"accepted": True},
            checkpoint=lambda: None, release_slot=lambda: None)
        authority = {"retirable": False}
        terminal_checker = build_attempt_terminal_checker(store, dispatcher)

        journal = state_dir / "operations.json"
        arbitrary_dir = test_root / "arbitrary-channel"
        arbitrary_dir.mkdir(mode=0o700)
        with self.assertRaisesRegex(ValueError, "trusted terminal checker"):
            InferenceChannel(broker, arbitrary_dir, (request.attempt_id,),
                             operation_journal=journal,
                             terminal_attempt_checker=lambda *_identity: False,
                             controller_dispatcher=dispatcher)
        channel = InferenceChannel(broker, channel_dir, (request.attempt_id,),
                                   operation_journal=journal,
                                   terminal_attempt_checker=terminal_checker,
                                   controller_dispatcher=dispatcher)
        channel.bind_attempt_operations(request.attempt_id, binding, handlers)
        in_flight = (request.attempt_id, "scope_request", "uncertain")
        channel._operation_calls[in_flight] = {"body_sha": "a" * 64, "state": "in_flight"}
        channel._persist_operation_journal()
        with self.assertRaisesRegex(ContractError, "in-flight"):
            channel.retire_attempt_operations(request.attempt_id)
        self.assertIn(in_flight, channel._operation_calls)

        authority["retirable"] = True
        with self.assertRaisesRegex(ContractError, "in-flight"):
            channel.retire_attempt_operations(request.attempt_id)
        self.assertIn(in_flight, channel._operation_calls)

        channel._operation_calls[in_flight] = {"body_sha": "a" * 64, "state": "complete",
                                               "result": {"accepted": True}}
        channel._persist_operation_journal()
        self.assertTrue(channel.retire_attempt_operations(request.attempt_id))
        self.assertEqual(channel._operation_calls, {})
        channel.stop()

        restarted_dir = test_root / "restarted-channel"
        restarted_dir.mkdir(mode=0o700)
        restarted = InferenceChannel(broker, restarted_dir, (request.attempt_id,),
                                     operation_journal=journal,
                                     terminal_attempt_checker=terminal_checker,
                                     controller_dispatcher=dispatcher)
        with self.assertRaisesRegex(ContractError, "terminal"):
            restarted.bind_attempt_operations(request.attempt_id, binding, handlers)
        import shutil
        shutil.rmtree(test_root)

    def test_operation_admission_racing_retirement_cannot_resurrect_journal(self):
        from supervisor.workers import (OwnerThreadDispatcher, build_attempt_operation_handlers,
                                        build_attempt_terminal_checker)

        request = ProviderRequest.create(
            attempt_id="attempt-retire-race", generation=5, role="stage-reviewer", stage="code",
            provider="fake", model="fake-v1", input_text="retire admission race")
        broker_binding = {key: getattr(request, key) for key in
                          ("generation", "role", "stage", "provider", "model", "input_sha")}
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": ["unused"]}},
                                 attempts={request.attempt_id: broker_binding})
        test_root = Path(tempfile.mkdtemp(prefix="fb-retire-race-", dir="/private/tmp"))
        state_dir = test_root / "state"
        state_dir.mkdir(mode=0o700)
        store_dir = state_dir / "store"
        store_dir.mkdir(mode=0o700)
        channel_dir = test_root / "channel"
        channel_dir.mkdir(mode=0o700)
        binding = {"domain_id": "domain-1", "job_id": "job-1",
                   "attempt_id": request.attempt_id, "generation": request.generation,
                   "input_sha": request.input_sha, "role": request.role, "stage": request.stage}
        authority = {"value": "active"}
        calls = []

        class Store:
            directory = store_dir
            domain_id = "domain-1"

            def record_result(self, _envelope, **_trusted):
                return {"disposition": "current"}

            def expand_scope(self, card, paths, revision):
                return {"card": card, "paths": paths, "reservation_revision": revision + 1}

            def operation_attempt_authority(self, _attempt_id, _generation, _input_sha):
                return authority["value"]

        dispatcher = OwnerThreadDispatcher()
        store = Store()
        handlers = build_attempt_operation_handlers(
            store, "22", binding=binding, scratch=self.workspace, dispatcher=dispatcher,
            heartbeat=lambda _payload: calls.append("heartbeat") or {"accepted": True},
            checkpoint=lambda: None, release_slot=lambda: None)
        terminal_checker = build_attempt_terminal_checker(store, dispatcher)
        journal = state_dir / "operations.json"
        channel = InferenceChannel(broker, channel_dir, (request.attempt_id,),
                                   operation_journal=journal,
                                   terminal_attempt_checker=terminal_checker,
                                   controller_dispatcher=dispatcher)
        channel.bind_attempt_operations(request.attempt_id, binding, handlers)

        payload = {"schema_version": 1, **binding, "request_id": "race-1", "at": time.time()}
        snapshot_taken = threading.Event()
        continue_dispatch = threading.Event()
        original_validate = channel._validate_operation_payload

        def paused_validate(operation, value, attempt_binding):
            snapshot_taken.set()
            if not continue_dispatch.wait(2):
                raise AssertionError("test did not release operation admission")
            return original_validate(operation, value, attempt_binding)

        channel._validate_operation_payload = paused_validate
        results = []
        errors = []

        def dispatch():
            try:
                results.append(channel._dispatch_worker_operation(
                    request.attempt_id, "heartbeat", payload))
            except Exception as exc:
                errors.append(exc)

        worker = threading.Thread(target=dispatch)
        worker.start()
        try:
            self.assertTrue(snapshot_taken.wait(1), "operation did not reach the admission barrier")
            authority["value"] = "terminal_released"
            retirement_errors = []
            try:
                channel.retire_attempt_operations(request.attempt_id)
            except ContractError as exc:
                retirement_errors.append(exc)
        finally:
            continue_dispatch.set()
            deadline = time.monotonic() + 2
            while worker.is_alive() and time.monotonic() < deadline:
                dispatcher.run_pending(timeout=0.02)
                worker.join(timeout=0.005)
            worker.join(timeout=0.1)

        self.assertFalse(worker.is_alive(), "operation dispatch did not finish")
        self.assertEqual(len(retirement_errors), 1,
                         "retirement must refuse while a dispatch has snapshotted its handler")
        self.assertEqual(errors, [])
        self.assertEqual(results, [{"accepted": True}])
        self.assertEqual(calls, ["heartbeat"])
        self.assertIn((request.attempt_id, "heartbeat", "race-1"), channel._operation_calls)
        self.assertTrue(channel.retire_attempt_operations(request.attempt_id))
        self.assertEqual(channel._operation_calls, {})
        channel.stop()

    def make_result_case(self, report_text, role="stage-reviewer"):
        from supervisor.store import Store

        domain = {
            "common_dir": str(self.workspace), "board_backend": "local",
            "board_identity": "provider-result-factory",
            "runtime_root": str(self.root / "result-runtime"),
        }
        store = Store.open(domain, filesystem_inspector=lambda _path: "local",
                           stop_evidence_verifier=lambda _evidence: True)
        self.addCleanup(store.close)
        store.start_session({"id": "session-1", "started_at": 1, "deadline": 100,
                             "known_spend": 0, "unknown_spend": False, "budget_stop": None})
        stage = "code"
        job = {"id": "job-1", "card": "22", "action": "review", "role": role,
               "stage": stage, "round": 1, "input_sha": self.request.input_sha,
               "input_version": "v1", "generation": self.request.generation,
               "provider": "fake", "model": "fake-v1", "nonce": self.request.attempt_id,
               "session_id": "session-1"}
        store.prepare_attempt(job, store.snapshot()["domain"]["revision"],
                              {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        binding = {"domain_id": store.domain_id, "job_id": job["id"],
                   "attempt_id": self.request.attempt_id, "generation": self.request.generation,
                   "input_sha": self.request.input_sha, "role": role, "stage": stage}
        report = self.workspace / "report.md"
        report.write_text(report_text, encoding="utf-8")
        digest = hashlib.sha256(report.read_bytes()).hexdigest()
        payload = dict(binding, schema_version=1, request_id="result-1", outcome="success",
                       report_path="report.md", artifact_hashes={"report.md": digest},
                       usage={"cost_usd": 0.1}, exit_code=0)
        return store, binding, payload, report

    def test_trusted_result_handler_ingests_report_and_records_durable_result(self):
        from supervisor.workers import (OwnerThreadDispatcher, build_attempt_operation_handlers,
                                        build_attempt_result_handler)

        report = ("## Status\nclean\n\n## Findings\n- none\n\n## For the card\n"
                  "Reviewed the change.\n\nVERIFIED: `true` -> 1 check\n")
        store, binding, payload, _source = self.make_result_case(report)
        handler = build_attempt_result_handler(store, binding, self.workspace)
        outcome = handler(payload)
        self.assertEqual(outcome["disposition"], "current")
        durable_report = store.directory / "artifacts" / binding["attempt_id"] / "report.md"
        self.assertEqual(durable_report.read_text(encoding="utf-8"), report)
        stored = store.snapshot()["results"]
        self.assertEqual(len(stored), 1)
        self.assertEqual(stored[0]["disposition"], "current")

    def test_trusted_result_handler_derives_failure_from_blocked_implementor_report(self):
        from supervisor.workers import build_attempt_result_handler

        report = ("## Status\nblocked\n\n## Findings\n- none\n\n## For the card\n"
                  "Blocked by: #23\n\n## PR\n#88\n\nVERIFIED: `true` -> 1 check\n")
        store, binding, payload, _source = self.make_result_case(report, role="implementor")
        handler = build_attempt_result_handler(store, binding, self.workspace)
        result = handler(payload)
        self.assertEqual(result["disposition"], "stale")
        stored = store.snapshot()["results"][0]
        self.assertEqual(json.loads(stored["envelope"])["outcome"], "failure")
        self.assertEqual(store.snapshot()["jobs"][0]["state"], "needs_attention")

    def test_trusted_result_handler_derives_failure_from_nonzero_exit(self):
        from supervisor.workers import build_attempt_result_handler

        report = ("## Status\nclean\n\n## Findings\n- none\n\n## For the card\n"
                  "Reviewed the change.\n\nVERIFIED: `true` -> 1 check\n")
        store, binding, payload, _source = self.make_result_case(report)
        handler = build_attempt_result_handler(store, binding, self.workspace)
        result = handler(dict(payload, exit_code=7))
        self.assertEqual(result["disposition"], "stale")
        stored = store.snapshot()["results"][0]
        self.assertEqual(json.loads(stored["envelope"])["outcome"], "failure")

    def test_trusted_result_handler_honors_durable_cancellation_state(self):
        from supervisor.workers import (OwnerThreadDispatcher, build_attempt_result_handler,
                                        build_attempt_terminal_checker)

        report = ("## Status\nclean\n\n## Findings\n- none\n\n## For the card\n"
                  "Reviewed the change.\n\nVERIFIED: `true` -> 1 check\n")
        store, binding, payload, _source = self.make_result_case(report)
        dispatcher = OwnerThreadDispatcher()
        checker = build_attempt_terminal_checker(store, dispatcher)
        identity = (binding["attempt_id"], binding["generation"], binding["input_sha"])
        self.assertEqual(checker(*identity), "active")
        store.request_cancellation(binding["attempt_id"], "cancel-result", "stop",
                                   store.snapshot()["domain"]["revision"])
        self.assertEqual(checker(*identity), "revoked")
        handler = build_attempt_result_handler(store, binding, self.workspace)
        result = handler(payload)
        self.assertEqual(result["disposition"], "stale")
        stored = store.snapshot()["results"][0]
        self.assertEqual(json.loads(stored["envelope"])["outcome"], "cancelled")

    def test_real_store_result_over_channel_uses_owner_thread_dispatcher(self):
        from supervisor.workers import (OwnerThreadDispatcher, build_attempt_operation_handlers,
                                        build_attempt_terminal_checker)

        report = ("## Status\nclean\n\n## Findings\n- none\n\n## For the card\n"
                  "Reviewed the change.\n\nVERIFIED: `true` -> 1 check\n")
        store, binding, payload, _source = self.make_result_case(report)
        request = ProviderRequest.create(
            attempt_id=binding["attempt_id"], generation=binding["generation"],
            role=binding["role"], stage=binding["stage"], provider="fake", model="fake-v1",
            input_text=self.request.input_text)
        provider_binding = {key: getattr(request, key) for key in
                            ("generation", "role", "stage", "provider", "model", "input_sha")}
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": ["unused"]}},
                                 attempts={request.attempt_id: provider_binding})
        dispatcher = OwnerThreadDispatcher()
        handlers = build_attempt_operation_handlers(
            store, "22", binding=binding, scratch=self.workspace, dispatcher=dispatcher,
            heartbeat=lambda _value: {"accepted": True}, checkpoint=lambda: None,
            release_slot=lambda: None)
        state_root = Path(tempfile.mkdtemp(prefix="fb-store-dispatch-", dir="/private/tmp"))
        channel_dir = state_root / "channel"
        channel_dir.mkdir(mode=0o700)
        channel = InferenceChannel(
            broker, channel_dir, (request.attempt_id,), operation_journal=state_root / "operations.json",
            terminal_attempt_checker=build_attempt_terminal_checker(store, dispatcher),
            controller_dispatcher=dispatcher)
        client_result, client_error = [], []
        with channel:
            channel.bind_attempt_operations(request.attempt_id, binding, handlers)
            client = InferenceClient(channel.socket_path, request.attempt_id,
                                     channel.capability_for(request.attempt_id), timeout=3)

            def submit():
                try:
                    client_result.append(client.request(payload, operation="result"))
                except Exception as exc:
                    client_error.append(exc)

            request_thread = threading.Thread(target=submit)
            request_thread.start()
            while request_thread.is_alive():
                dispatcher.run_pending(timeout=0.05)
                request_thread.join(timeout=0.01)
        self.assertEqual(client_error, [])
        self.assertEqual(client_result, [{"disposition": "current"}])
        self.assertEqual(len(store.snapshot()["results"]), 1)
        checker = build_attempt_terminal_checker(store, dispatcher)
        self.assertEqual(checker(binding["attempt_id"], binding["generation"], binding["input_sha"]),
                         "revoked")
        identity = {"boot_id": "fixture-boot", "pid": 43210,
                    "started_at": "fixture-start", "nonce": binding["attempt_id"]}
        store.update_attempt(binding["attempt_id"], {
            "state": "result_ready", "boot_id": identity["boot_id"],
            "process_identity": identity, "started_at": 10, "deadline": 100,
        }, store.snapshot()["domain"]["revision"])
        from supervisor.models import StopEvidence
        evidence = StopEvidence(
            domain_id=store.domain_id, job_id=binding["job_id"],
            attempt_id=binding["attempt_id"], generation=binding["generation"],
            boot_id=identity["boot_id"], pid=identity["pid"],
            started_at=identity["started_at"], nonce=identity["nonce"],
            kind="fixture_complete_tree", free_fixture=True)
        store.record_execution_stopped(binding["attempt_id"], evidence,
                                       store.snapshot()["domain"]["revision"])
        self.assertEqual(checker(binding["attempt_id"], binding["generation"], binding["input_sha"]),
                         "terminal_released")
        import shutil
        shutil.rmtree(state_root)

    def test_trusted_result_handler_rejects_paths_outside_attempt_artifacts(self):
        from supervisor.workers import build_attempt_result_handler

        report = ("## Status\nclean\n\n## Findings\n- none\n\n## For the card\n"
                  "Reviewed the change.\n\nVERIFIED: `true` -> 1 check\n")
        store, binding, payload, _source = self.make_result_case(report)
        handler = build_attempt_result_handler(store, binding, self.workspace)
        with self.assertRaises(ValueError):
            build_attempt_result_handler(store, binding, store.directory)
        forged = dict(payload, report_path="/private/tmp/outside-report",
                      artifact_hashes={"/private/tmp/outside-report": "a" * 64})
        with self.assertRaises(ValueError):
            handler(forged)
        self.assertEqual(store.snapshot()["results"], [])

    def test_trusted_result_handler_rejects_bad_hash_and_role_report(self):
        from supervisor.workers import build_attempt_result_handler

        report = "malformed role report\n"
        store, binding, payload, _source = self.make_result_case(report)
        handler = build_attempt_result_handler(store, binding, self.workspace)
        with self.assertRaises(ValueError):
            handler(dict(payload, artifact_hashes={"report.md": "0" * 64}))
        with self.assertRaises(ValueError):
            handler(payload)
        self.assertEqual(store.snapshot()["results"], [])

    def test_subprocess_stdout_stderr_are_bounded_and_missing_executable_fails(self):
        noisy = self.script("noisy.py", "#!/usr/bin/env python3\nimport sys\nsys.stdout.write('x'*4096)\nsys.stderr.write('y'*4096)\n")
        with self.assertRaises(ContractError):
            run_provider(noisy, self.request, timeout=3, stdout_limit=128, stderr_limit=128)
        with self.assertRaises(ContractError):
            run_provider([str(self.root / "missing")], self.request, timeout=1)

    def test_provider_cancellation_kills_term_resistant_descendant_after_leader_exits(self):
        child_marker = self.root / "provider-descendant-alive"
        ready = self.root / "provider-descendant-ready"
        command = self.script(
            "provider-parent.py",
            "#!/usr/bin/env python3\nimport json,pathlib,subprocess,sys,time\njson.load(sys.stdin)\nchild=\"import pathlib,signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); pathlib.Path(sys.argv[2]).write_text('ready'); time.sleep(.8); pathlib.Path(sys.argv[1]).write_text('alive')\"\nsubprocess.Popen([sys.executable, '-c', child, sys.argv[1], sys.argv[2]])\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(.01)\n",
        ) + [str(child_marker), str(ready)]
        with self.assertRaises(ContractError):
            run_provider(command, self.request, timeout=.3)
        time.sleep(.9)
        self.assertFalse(child_marker.exists(), "provider descendant survived cancellation")

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
                run_isolated(["/usr/bin/true"], policy, capability=capability,
                             cancel_event=threading.Event())
            runner = Runner(self.root / "runner")
            with self.assertRaises(IsolationUnavailable):
                runner.launch_production({"attempt_id": "attempt-1"}, ["/usr/bin/true"], policy)

    def test_isolated_worker_output_capture_is_bounded(self):
        with patch("supervisor.isolation._wrapped_command",
                   return_value=["/bin/sh", "-c", "head -c 1048577 /dev/zero"]):
            with self.assertRaises(IsolationUnavailable):
                run_isolated(["ignored"], {"workspace": str(self.workspace)},
                             capability={"available": True}, timeout=3,
                             cancel_event=threading.Event())

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
                             capability={"available": True}, timeout=3,
                             cancel_event=threading.Event())
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
                    "publication", "forged_human_control", "inference_channel", "channel_write"}
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
                        envelope = json.dumps({
                            "schema_version": 1, "operation": "infer",
                            "attempt_id": "attempt-1", "capability": "invalid",
                            "request": self.request.to_dict(),
                        }, separators=(",", ":")).encode("utf-8")
                        raw.sendall(struct.pack("!I", len(envelope)) + envelope)
                        header = raw.recv(4)
                        self.assertEqual(len(header), 4)
                        size = struct.unpack("!I", header)[0]
                        self.assertIn("error", json.loads(raw.recv(size).decode("utf-8")))
                client = InferenceClient(channel.socket_path, "attempt-1",
                                         channel.capability_for("attempt-1"), timeout=3)
                self.assertEqual(client.infer(self.request.to_dict())["text"], "accepted")
        finally:
            import shutil
            shutil.rmtree(channel_dir)

    def test_production_launch_requires_durable_deadline_and_cancellation(self):
        from supervisor.workers import (OwnerThreadDispatcher, build_attempt_operation_handlers,
                                        build_attempt_result_handler, build_attempt_terminal_checker)
        prepared = {
            "domain_id": "domain-1", "job_id": "job-1",
            "attempt_id": "attempt-1", "generation": 1, "input_sha": self.request.input_sha,
            "role": "reviewer", "stage": None, "provider": "fake", "model": "fake-v1",
            "started_at": time.time(), "deadline": time.time() + 60,
        }
        runner = Runner(self.root / "runner", production_enabled=True)
        policy = build_policy(self.workspace, self.root / "private-git", self.root / "channels")
        controls = []
        operation_bindings = []
        handler_store_root = self.root / "runner-result-store"
        handler_store_root.mkdir(mode=0o700)
        class HandlerStore:
            directory = handler_store_root
            domain_id = "domain-1"
            def record_result(self, envelope):
                return {"disposition": "current"}
            def expand_scope(self, card, paths, revision):
                return {"card": card, "paths": paths, "reservation_revision": revision + 1}
            def operation_attempt_authority(self, _attempt_id, _generation, _input_sha):
                return "active"
        production_store = HandlerStore()
        operation_binding = {key: prepared[key] for key in
                             ("domain_id", "job_id", "attempt_id", "generation", "input_sha", "role", "stage")}
        trusted_result = build_attempt_result_handler(HandlerStore(), operation_binding,
                                                       self.workspace)
        from supervisor.workers import TrustedAttemptResultHandler
        class ForgedResultHandler(TrustedAttemptResultHandler):
            def __call__(self, payload):
                return {"disposition": "current"}
        forged_result_handler = ForgedResultHandler(HandlerStore(), operation_binding,
                                                     self.workspace)
        other_scratch = self.root / "other-result-scratch"
        other_scratch.mkdir(mode=0o700)
        wrong_scratch_handler = build_attempt_result_handler(
            HandlerStore(), operation_binding, other_scratch)
        worker_writable_store = HandlerStore()
        worker_writable_store.directory = Path(policy["channels"])
        writable_store_handler = build_attempt_result_handler(
            worker_writable_store, operation_binding, self.workspace)
        class FakeChannel:
            socket_path = self.root / "inference.sock"
            def capability_for(self, attempt_id):
                return "capability-for-" + attempt_id
            def bind_attempt_control(self, attempt_id, deadline, cancel_event):
                controls.append((attempt_id, deadline, cancel_event))
            def bind_attempt_operations(self, attempt_id, binding, handlers):
                operation_bindings.append((attempt_id, binding, handlers))
            def operations_for(self, attempt_id):
                return ("heartbeat", "result", "scope_request")
        fake_channel = FakeChannel()
        controller_dispatcher = OwnerThreadDispatcher()
        fake_channel.controller_dispatcher = controller_dispatcher
        fake_channel.terminal_attempt_checker = build_attempt_terminal_checker(
            production_store, controller_dispatcher)
        controller_state = self.root / "controller-state"
        controller_state.mkdir(mode=0o700)
        fake_channel.operation_journal = controller_state / "operations.json"
        with patch("supervisor.runner.probe_capabilities", return_value={"available": True}), \
             patch("supervisor.runner.prepare_private_git"), \
             patch("supervisor.runner.prepare_worker_bootstrap", return_value={"schema_version": 1}), \
             patch("supervisor.runner.run_isolated") as isolated:
            with self.assertRaises(ValueError):
                runner.launch_production({key: value for key, value in prepared.items()
                                          if key != "deadline"},
                                         ["/usr/bin/true"], policy, channel=fake_channel,
                                         request={}, source_repository=self.root,
                                         cancel_event=threading.Event())
            with self.assertRaises((TypeError, ValueError)):
                runner.launch_production(prepared, ["/usr/bin/true"], policy,
                                         channel=fake_channel, request={},
                                         source_repository=self.root)
            with self.assertRaises(ValueError):
                runner.launch_production(prepared, ["/usr/bin/true"], policy,
                                         channel=fake_channel, request={},
                                         source_repository=self.root, cancel_event=object())
            with self.assertRaises(IsolationUnavailable):
                runner.launch_production(
                    prepared, ["/usr/bin/true"], policy, channel=fake_channel, request={},
                    source_repository=self.root, cancel_event=threading.Event(),
                    operation_handlers={"heartbeat": lambda value: value,
                                        "result": lambda value: value,
                                        "scope_request": lambda value: value})
            with self.assertRaises(IsolationUnavailable):
                runner.launch_production(
                    prepared, ["/usr/bin/true"], policy, channel=fake_channel, request={},
                    source_repository=self.root, cancel_event=threading.Event(),
                    operation_handlers={"heartbeat": lambda value: value,
                                        "result": wrong_scratch_handler,
                                        "scope_request": lambda value: value})
            with self.assertRaises(IsolationUnavailable):
                runner.launch_production(
                    prepared, ["/usr/bin/true"], policy, channel=fake_channel, request={},
                    source_repository=self.root, cancel_event=threading.Event(),
                    operation_handlers={"heartbeat": lambda value: value,
                                        "result": writable_store_handler,
                                        "scope_request": lambda value: value})
            with self.assertRaises(IsolationUnavailable):
                runner.launch_production(
                    prepared, ["/usr/bin/true"], policy, channel=fake_channel, request={},
                    source_repository=self.root, cancel_event=threading.Event(),
                    operation_handlers={"heartbeat": lambda value: value,
                                        "result": forged_result_handler,
                                        "scope_request": lambda value: value})
            controls[:] = []
            operation_bindings[:] = []
            cancel = threading.Event()
            fake_channel.operation_journal = None
            with self.assertRaises(IsolationUnavailable):
                runner.launch_production(prepared, ["/usr/bin/true"], policy,
                                         channel=fake_channel, request={},
                                         source_repository=self.root, cancel_event=cancel,
                                         operation_handlers={"heartbeat": lambda value: value,
                                                             "result": trusted_result,
                                                             "scope_request": lambda value: value})
            fake_channel.operation_journal = controller_state / "operations.json"
            safe_handlers = build_attempt_operation_handlers(
                production_store, "22", binding=operation_binding, scratch=self.workspace,
                dispatcher=controller_dispatcher, heartbeat=lambda _value: {"accepted": True},
                checkpoint=lambda: None, release_slot=lambda: None)
            dispatch_calls = []

            def isolated_side_effect(*_args, **_kwargs):
                controller_dispatcher.call(lambda: dispatch_calls.append("owner"))
                return isolated.return_value

            isolated.side_effect = isolated_side_effect
            with self.assertRaisesRegex(IsolationUnavailable, "off the Store-owning thread"):
                runner.launch_production(
                    prepared, ["/usr/bin/true"], policy, channel=fake_channel, request={},
                    source_repository=self.root, cancel_event=cancel,
                    operation_handlers=safe_handlers)
            launch_result, launch_error = [], []

            def submit_launch():
                try:
                    launch_result.append(runner.launch_production(
                        prepared, ["/usr/bin/true"], policy, channel=fake_channel, request={},
                        source_repository=self.root, cancel_event=cancel,
                        operation_handlers=safe_handlers))
                except Exception as exc:
                    launch_error.append(exc)

            launch_thread = threading.Thread(target=submit_launch)
            launch_thread.start()
            while launch_thread.is_alive():
                controller_dispatcher.run_pending(timeout=0.05)
                launch_thread.join(timeout=0.01)
            if launch_error:
                raise launch_error[0]
            result = launch_result[0]
        self.assertIs(result, isolated.return_value)
        self.assertAlmostEqual(isolated.call_args.kwargs["timeout"],
                               prepared["deadline"] - time.time(), delta=1)
        self.assertIs(isolated.call_args.kwargs["cancel_event"], cancel)
        self.assertEqual(dispatch_calls, ["owner"])
        self.assertEqual(controls, [("attempt-1", prepared["deadline"], cancel)])
        self.assertEqual(operation_bindings[0][0], "attempt-1")
        self.assertEqual(operation_bindings[0][1]["input_sha"], prepared["input_sha"])
        self.assertEqual(set(operation_bindings[0][2]), {"heartbeat", "result", "scope_request"})

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

    def test_worker_group_cleanup_kills_after_non_esrch_probe_error(self):
        from supervisor.isolation import _terminate_process_group

        class Process:
            pid = 4321

            def wait(self, timeout):
                return 0

        with patch.object(isolation_module.os, "killpg",
                          side_effect=[None, PermissionError("probe denied"), None]) as killpg:
            _terminate_process_group(Process())
        self.assertIn(((4321, signal.SIGKILL),), killpg.call_args_list)

    def test_worker_group_cleanup_does_not_kill_after_esrch_probe(self):
        from supervisor.isolation import _terminate_process_group

        class Process:
            pid = 4322

            def wait(self, timeout):
                return 0

        with patch.object(isolation_module.os, "killpg",
                          side_effect=[None, ProcessLookupError(errno.ESRCH, "no such process group")]) as killpg:
            _terminate_process_group(Process())
        self.assertNotIn(((4322, signal.SIGKILL),), killpg.call_args_list)

    def test_isolated_worker_broken_pipe_kills_surviving_process_group(self):
        child_marker = self.root / "io-error-descendant"
        ready = self.root / "io-error-descendant-ready"
        command = [sys.executable] + self.script(
            "io-error-parent.py",
            "#!/usr/bin/env python3\nimport pathlib,subprocess,sys,time\nchild=\"import pathlib,signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); pathlib.Path(sys.argv[2]).write_text('ready'); time.sleep(.8); pathlib.Path(sys.argv[1]).write_text('alive')\"\nsubprocess.Popen([sys.executable, '-c', child, sys.argv[1], sys.argv[2]])\n",
        ) + [str(child_marker), str(ready)]

        def broken_pipe(_fd, _data):
            deadline = time.monotonic() + 2
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            raise BrokenPipeError("worker closed bootstrap pipe")

        with patch("supervisor.isolation._wrapped_command", return_value=command), \
             patch("supervisor.isolation.os.write", side_effect=broken_pipe):
            with self.assertRaises(IsolationUnavailable):
                run_isolated(["ignored"], {"workspace": str(self.workspace)},
                             capability={"available": True}, timeout=3,
                             input_data=b"bootstrap", cancel_event=threading.Event())
        time.sleep(.9)
        self.assertFalse(child_marker.exists(), "worker descendant survived bootstrap I/O failure")

    def test_fixture_and_human_control_authority_are_not_worker_capabilities(self):
        policy = build_policy(self.workspace, self.root / "private-git",
                              self.root / "channels")
        for forbidden in ("controller.db", "board", "credentials", "ssh", "keychain", "publish", "human-control"):
            self.assertNotIn(forbidden, policy["channels"])
        defaults = json.loads((Path(__file__).resolve().parents[2] / "scripts" / "config-defaults.json").read_text())
        self.assertIs(defaults["supervisor"]["enabled"], False)
        self.assertIs(Runner(self.root / "runner").production_enabled, False)

    def test_linux_policy_mounts_attempt_channels_read_only(self):
        policy = build_policy(self.workspace, self.root / "private-git",
                              self.root / "channels")
        policy.update(backend="linux", command="/usr/bin/bwrap")
        with patch("supervisor.isolation.os.path.exists", return_value=False):
            command = isolation_module._wrapped_command(["/usr/bin/true"], policy)
        channel_index = command.index(policy["channels"])
        self.assertEqual(command[channel_index - 1], "--ro-bind",
                         "worker must connect to attempt IPC without mutating channel paths")

    def test_macos_policy_denies_channel_path_mutation(self):
        policy = build_policy(self.workspace, self.root / "private-git",
                              self.root / "channels")
        self.assertIn('(subpath "' + policy["channels"] + '")', policy["text"])
        write_rule = next(line for line in policy["text"].splitlines()
                          if line.startswith("(allow file-write*"))
        self.assertNotIn(policy["channels"], write_rule)

    def test_forged_human_control_probe_uses_authenticated_unknown_operation(self):
        from supervisor.isolation import _forged_control_frame, _forged_control_rejection_frame
        frame = _forged_control_frame("attempt-1", "attempt-capability")
        size = struct.unpack("!I", frame[:4])[0]
        request = json.loads(frame[4:])
        self.assertEqual(size, len(frame[4:]))
        self.assertEqual(request, {
            "schema_version": 1, "operation": "human_control",
            "attempt_id": "attempt-1", "capability": "attempt-capability",
            "request": {"attempt_id": "attempt-1"},
        })
        rejection = _forged_control_rejection_frame()
        rejection_size = struct.unpack("!I", rejection[:4])[0]
        self.assertEqual(rejection_size, len(rejection[4:]))
        self.assertEqual(json.loads(rejection[4:]), {
            "schema_version": 1, "error": "request rejected",
        })

    def test_probe_symlink_is_registered_for_cleanup_before_creation(self):
        from supervisor.isolation import _create_probe_symlink
        cleanup_paths = []
        path = self.root / "failed-probe-escape"
        with patch.object(Path, "symlink_to", side_effect=OSError("injected symlink failure")):
            with self.assertRaises(OSError):
                _create_probe_symlink(path, self.root / "protected", cleanup_paths)
        self.assertEqual(cleanup_paths, [path])

    def test_probe_listener_ownership_is_recorded_before_listen(self):
        from supervisor.isolation import _bind_probe_listener
        class Listener:
            def bind(self, _path):
                pass
            def listen(self, _backlog):
                raise OSError("injected listen failure")
        owned = []
        with self.assertRaises(OSError):
            _bind_probe_listener(Listener(), self.root / "probe.sock", owned)
        self.assertEqual(owned, [True])

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

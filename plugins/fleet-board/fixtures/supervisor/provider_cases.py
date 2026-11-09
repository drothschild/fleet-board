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

    def test_docker_policy_requires_explicit_local_image_and_never_pulls(self):
        private_git = self.root / "docker-private-git"
        channels = self.root / "docker-channels"
        image = "sha256:" + "a" * 64
        with self.assertRaises((TypeError, ValueError)):
            build_policy(self.workspace, private_git, channels, backend="docker")
        with self.assertRaises(ValueError):
            build_policy(self.workspace, private_git, channels,
                         backend="docker", docker_image="latest")
        policy = self.build_docker_policy(self.workspace, private_git, channels,
                                          docker_image=image)
        self.assertEqual(policy["backend"], "docker")
        self.assertEqual(policy["docker_image"], image)
        self.assertTrue(policy["command"])

    def test_docker_policy_rejects_remote_daemon_overrides(self):
        image = "sha256:" + "a" * 64
        for variable, value in (("DOCKER_HOST", "tcp://remote.example:2376"),
                                ("DOCKER_CONTEXT", "remote-production")):
            with self.subTest(variable=variable):
                with patch.dict(os.environ, {variable: value}):
                    with self.assertRaises((ValueError, IsolationUnavailable)):
                        build_policy(self.workspace, self.root / "docker-private-git",
                                     self.root / "docker-channels", backend="docker",
                                     docker_image=image)

    def test_docker_policy_records_verified_desktop_linux_vm_identity(self):
        from subprocess import CompletedProcess

        image = "sha256:" + "a" * 64
        responses = self.docker_identity_responses(CompletedProcess)
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("DOCKER_HOST", None)
            os.environ.pop("DOCKER_CONTEXT", None)
            with patch("supervisor.isolation.shutil.which", return_value="/usr/local/bin/docker"), \
                    patch("supervisor.isolation.subprocess.run", side_effect=responses):
                policy = build_policy(self.workspace, self.root / "docker-private-git",
                                      self.root / "docker-channels", backend="docker",
                                      docker_image=image)
        self.assertEqual(policy.get("daemon_identity"), {
            "context": "desktop-linux",
            "endpoint": "unix://" + str(Path.home() / ".docker/run/docker.sock"),
            "name": "docker-desktop",
            "os_type": "linux",
            "operating_system": "Docker Desktop",
        })

    def test_docker_run_argv_enforces_offline_readonly_boundary(self):
        from supervisor.isolation import docker_run_argv

        private_git = self.root / "docker-private-git"
        channels = self.root / "docker-channels"
        image = "sha256:" + "b" * 64
        policy = self.build_docker_policy(self.workspace, private_git, channels,
                                          docker_image=image)
        argv = docker_run_argv(["python3", "-m", "supervisor.docker_agent"],
                               policy, str(self.root / "worker.cid"))
        self.assertEqual(argv[:3], [policy["command"], "run", "--rm"])
        self.assertIn("--pull=never", argv)
        self.assertIn("--network=none", argv)
        self.assertIn("--read-only", argv)
        self.assertIn("--cap-drop=ALL", argv)
        self.assertIn("--security-opt=no-new-privileges", argv)
        self.assertIn("--pids-limit=64", argv)
        self.assertIn("--memory=2g", argv)
        self.assertIn("--cpus=2", argv)
        self.assertIn("--user={}:{}".format(os.getuid(), os.getgid()), argv)
        self.assertIn(image, argv)
        self.assertEqual(argv[-2:], ["-m", "supervisor.docker_agent"])
        joined = "\0".join(argv)
        for forbidden in ("host.docker.internal", "docker.sock", "ssh-agent",
                          str(channels)):
            self.assertNotIn(forbidden, joined)
        self.assertNotIn("src={},dst=".format(Path.home()), joined)
        self.assertIn("src={},dst=/workspace".format(self.workspace), joined)
        self.assertIn("src={},dst=/private-git".format(private_git), joined)
        self.assertIn("dst=/guest/supervisor,readonly", joined)

    def test_docker_policy_rejects_mount_delimiters_and_symlink_roots(self):
        delimiter_root = self.root / "path,with-comma"
        delimiter_root.mkdir(mode=0o700)
        with self.assertRaises(ValueError):
            build_policy(delimiter_root, self.root / "private-git",
                         self.root / "channels", backend="docker",
                         docker_image="sha256:" + "c" * 64)
        alias = self.root / "docker-workspace-alias"
        alias.symlink_to(self.workspace)
        with self.assertRaises(ValueError):
            build_policy(alias, self.root / "private-git",
                         self.root / "channels", backend="docker",
                         docker_image="sha256:" + "d" * 64)

    def test_docker_guest_framing_roundtrip_and_rejects_truncation(self):
        from supervisor.docker_agent import MAX_FRAME_BYTES, read_frame, write_frame

        stream = __import__("io").BytesIO()
        write_frame(stream, {"type": "response", "id": "r1", "result": {"ok": True}})
        stream.seek(0)
        self.assertEqual(read_frame(stream),
                         {"type": "response", "id": "r1", "result": {"ok": True}})
        with self.assertRaises(ValueError):
            read_frame(__import__("io").BytesIO(b"\0\0\0\x05{}"))
        with self.assertRaises(ValueError):
            read_frame(__import__("io").BytesIO(struct.pack("!I", MAX_FRAME_BYTES + 1)))

    def test_docker_guest_worker_socket_roundtrip(self):
        from supervisor.docker_agent import serve_worker_connection

        left, right = socket.socketpair()
        calls = []

        class Relay:
            def request(self, envelope, attempt_id, capability, *, timeout=None):
                calls.append((envelope, attempt_id, capability))
                return {"schema_version": 1, "result": {"accepted": True}}

        thread = threading.Thread(target=serve_worker_connection,
                                  args=(right, Relay(), "attempt-1", "secret"))
        thread.start()
        envelope = {"schema_version": 1, "operation": "heartbeat",
                    "attempt_id": "attempt-1", "capability": "secret",
                    "request": {"request_id": "roundtrip"}}
        payload = json.dumps(envelope, separators=(",", ":")).encode()
        left.sendall(struct.pack("!I", len(payload)) + payload)
        def receive_exact(size):
            chunks = bytearray()
            while len(chunks) < size:
                chunks.extend(left.recv(size - len(chunks)))
            return bytes(chunks)

        size = struct.unpack("!I", receive_exact(4))[0]
        response = json.loads(receive_exact(size))
        self.assertEqual(response, {"schema_version": 1, "result": {"accepted": True}})
        self.assertEqual(calls, [(envelope, "attempt-1", "secret")])
        thread.join(timeout=2)
        left.close()
        self.assertFalse(thread.is_alive())

    def test_docker_guest_rpc_allowlist_and_attempt_binding(self):
        from supervisor.docker_agent import validate_worker_envelope

        for operation in ("infer", "heartbeat", "result", "scope_request"):
            envelope = {"schema_version": 1, "operation": operation,
                        "attempt_id": "attempt-1", "capability": "secret",
                        "request": {"request_id": "req-" + operation}}
            self.assertEqual(validate_worker_envelope(envelope, "attempt-1", "secret"),
                             (operation, envelope["request"]))
        forged = {"schema_version": 1, "operation": "human_control",
                  "attempt_id": "attempt-1", "capability": "secret", "request": {}}
        with self.assertRaises(ValueError):
            validate_worker_envelope(forged, "attempt-1", "secret")
        with self.assertRaises(ValueError):
            validate_worker_envelope(dict(envelope, capability="wrong"),
                                     "attempt-1", "secret")

    def test_docker_guest_multiplexer_correlates_concurrent_out_of_order_responses(self):
        from supervisor.docker_agent import RelayMultiplexer

        sent = []
        sent_lock = threading.Lock()

        def send(frame):
            with sent_lock:
                sent.append(frame)

        relay = RelayMultiplexer(send)
        results = {}

        def request(name):
            envelope = {"schema_version": 1, "operation": "heartbeat",
                        "attempt_id": "attempt-1", "capability": "secret",
                        "request": {"request_id": name}}
            results[name] = relay.request(envelope, "attempt-1", "secret", timeout=2)

        calls = [threading.Thread(target=request, args=(name,)) for name in ("slow", "fast")]
        for call in calls:
            call.start()
        deadline = time.monotonic() + 1
        while len(sent) < 2 and time.monotonic() < deadline:
            time.sleep(.001)
        self.assertEqual(len(sent), 2)
        by_request = {frame["request"]["request_id"]: frame["id"] for frame in sent}
        relay.deliver({"type": "response", "id": by_request["fast"],
                       "response": {"schema_version": 1, "result": {"done": "fast"}}})
        relay.deliver({"type": "response", "id": by_request["slow"],
                       "response": {"schema_version": 1, "result": {"done": "slow"}}})
        for call in calls:
            call.join(timeout=2)
            self.assertFalse(call.is_alive())
        self.assertEqual(results, {"fast": {"schema_version": 1, "result": {"done": "fast"}},
                                   "slow": {"schema_version": 1, "result": {"done": "slow"}}})

    def test_docker_guest_output_frames_are_separate_and_bounded(self):
        from supervisor.docker_agent import output_frame

        self.assertEqual(output_frame("stderr", b"worker output"),
                         {"type": "stderr", "data": "d29ya2VyIG91dHB1dA=="})
        with self.assertRaises(ValueError):
            output_frame("stdout", b"x" * 65537)

    def docker_policy(self, fake_docker):
        return self.build_docker_policy(
            self.workspace, self.root / "docker-private-git",
            self.root / "docker-channels", docker_image="sha256:" + "e" * 64) | {
                "command": fake_docker}

    @staticmethod
    def docker_identity_responses(completed_process=None):
        import json
        from subprocess import CompletedProcess

        completed_process = completed_process or CompletedProcess
        endpoint = "unix://" + str(Path.home() / ".docker/run/docker.sock")
        return [
            completed_process([], 0, b"desktop-linux\n", b""),
            completed_process([], 0, json.dumps([{"Endpoints": {"docker": {"Host": endpoint}}}]).encode(), b""),
            completed_process([], 0, json.dumps({"Name": "docker-desktop", "OSType": "linux",
                                                 "OperatingSystem": "Docker Desktop",
                                                 "ServerVersion": "29.9.2"}).encode(), b""),
        ]

    def build_docker_policy(self, workspace, private_git, channels, *, docker_image):
        from supervisor.isolation import build_policy

        responses = self.docker_identity_responses()
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("DOCKER_HOST", None)
            os.environ.pop("DOCKER_CONTEXT", None)
            with patch("supervisor.isolation.shutil.which", return_value="/usr/local/bin/docker"), \
                    patch("supervisor.isolation.subprocess.run", side_effect=responses):
                return build_policy(workspace, private_git, channels, backend="docker",
                                    docker_image=docker_image)

    def fake_docker(self, mode):
        body = """#!/usr/bin/env python3
import base64, json, os, struct, sys, time
mode = @MODE@
def read_frame():
    header = sys.stdin.buffer.read(4)
    if len(header) != 4: raise SystemExit(2)
    size = struct.unpack('!I', header)[0]
    return json.loads(sys.stdin.buffer.read(size))
def write_frame(value):
    data = json.dumps(value, separators=(',', ':')).encode()
    sys.stdout.buffer.write(struct.pack('!I', len(data)) + data)
    sys.stdout.buffer.flush()
if len(sys.argv) > 1 and sys.argv[1] == 'rm':
    open(@LOG@, 'a').write(' '.join(sys.argv[2:]) + '\\n')
    raise SystemExit(0)
if sys.argv[1:] == ['context', 'show']:
    print('desktop-linux'); raise SystemExit(0)
if sys.argv[1:3] == ['context', 'inspect']:
    print(json.dumps([{'Endpoints': {'docker': {'Host': 'unix://' + os.path.expanduser('~/.docker/run/docker.sock')}}}]))
    raise SystemExit(0)
if sys.argv[1:2] == ['info']:
    print(json.dumps({'Name':'docker-desktop','OSType':'linux','OperatingSystem':'Docker Desktop','ServerVersion':'29.9.2'}))
    raise SystemExit(0)
open(@RUNLOG@, 'a').write(' '.join(sys.argv[1:]) + '\\n')
if mode == 'daemon': raise SystemExit(125)
cidfile = next(arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('--cidfile='))
with open(cidfile, 'w') as stream: stream.write(@CID@)
if mode == 'cancel': time.sleep(20); raise SystemExit(0)
start = read_frame()
if mode == 'malformed':
    write_frame({'type': 'exit', 'code': 0}); raise SystemExit(0)
operation = 'human_control' if mode == 'unknown' else 'heartbeat'
write_frame({'type':'rpc','id':'rpc-1','operation':operation,
             'attempt_id':start['attempt_id'],'capability':start['capability'],
             'request':{'attempt_id':start['attempt_id'],'request_id':'req-1'}})
if mode == 'unknown': time.sleep(20); raise SystemExit(0)
response = read_frame()
if response.get('type') != 'response' or response.get('id') != 'rpc-1': raise SystemExit(3)
write_frame({'type':'stdout','data':base64.b64encode(b'worker stdout').decode()})
write_frame({'type':'stderr','data':base64.b64encode(b'worker stderr').decode()})
if mode == 'oversize':
    write_frame({'type':'stdout','data':base64.b64encode(b'x'*(1024*1024+1)).decode()})
    time.sleep(10); raise SystemExit(0)
write_frame({'type':'exit','code':0})
""".replace("@MODE@", repr(mode)).replace("@LOG@", repr(str(self.root / "docker-rm.log"))).replace(
            "@RUNLOG@", repr(str(self.root / "docker-run.log"))).replace(
            "@CID@", repr("not-a-container-id" if mode == "malformed" else "a" * 64))
        return self.script("fake-docker-" + mode, body)[0]

    def docker_transport_args(self):
        bootstrap = {"attempt": {"attempt_id": "attempt-1"},
                     "inference": {"schema_version": 1, "socket_path": "/host/channels/inference.sock",
                                   "attempt_id": "attempt-1", "capability": "secret"}}

        class Channel:
            def __init__(self):
                self.calls = []

            def request(inner, attempt_id, capability, request, *, operation="infer", timeout=None):
                inner.calls.append((attempt_id, capability, request, operation))
                return {"accepted": True}

        channel = Channel()
        return bootstrap, channel

    def fake_docker_missing_cidfile(self, mode, ids=None):
        ids = ids or []
        script = """#!/usr/bin/env python3
import json, os, sys, time
mode = @MODE@
ids = @IDS@
if sys.argv[1:] == ['context', 'show']:
    print('desktop-linux'); raise SystemExit(0)
if sys.argv[1:3] == ['context', 'inspect']:
    print(json.dumps([{'Endpoints': {'docker': {'Host': 'unix://' + os.path.expanduser('~/.docker/run/docker.sock')}}}]))
    raise SystemExit(0)
if sys.argv[1:2] == ['info']:
    print(json.dumps({'Name':'docker-desktop','OSType':'linux','OperatingSystem':'Docker Desktop'}))
    raise SystemExit(0)
if sys.argv[1:2] == ['ps']:
    open(@LISTLOG@, 'a').write(' '.join(sys.argv[1:]) + '\\n')
    if mode == 'list-failure': raise SystemExit(1)
    if mode == 'late-match':
        count = sum(1 for _line in open(@LISTLOG@, 'r'))
        print('e' * 64 if count == 5 else '')
        raise SystemExit(0)
    print('\\n'.join(ids)); raise SystemExit(0)
if sys.argv[1:2] == ['rm']:
    open(@RMLOG@, 'a').write(' '.join(sys.argv[1:]) + '\\n')
    if mode == 'remove-failure': raise SystemExit(1)
    raise SystemExit(0)
if sys.argv[1:2] == ['run']:
    open(@RUNLOG@, 'a').write(' '.join(sys.argv[1:]) + '\\n')
    time.sleep(.05)
    raise SystemExit(125)
raise SystemExit(2)
""".replace('@MODE@', repr(mode)).replace('@IDS@', repr(ids)).replace(
            '@LISTLOG@', repr(str(self.root / 'docker-ps.log'))).replace(
            '@RMLOG@', repr(str(self.root / 'docker-label-rm.log'))).replace(
            '@RUNLOG@', repr(str(self.root / 'docker-label-run.log')))
        return self.script('fake-docker-label-' + mode, script)[0]

    def test_docker_host_transport_reconciles_missing_cidfile_by_attempt_label(self):
        from supervisor.docker_transport import DockerWorkerTransport

        bootstrap, channel = self.docker_transport_args()
        ids = ['a' * 64, 'b' * 64]
        fake = self.fake_docker_missing_cidfile('matches', ids)
        with self.assertRaises((ContractError, IsolationUnavailable)):
            DockerWorkerTransport().run(
                ['python3', '-m', 'worker'], self.docker_policy(fake),
                bootstrap=bootstrap, channel=channel, attempt_id='attempt-1',
                capability='secret', timeout=2, cancel_event=threading.Event())
        run_log = (self.root / 'docker-label-run.log').read_text(encoding='utf-8')
        self.assertIn('--label=org.fleet-board.supervisor.attempt-id=attempt-1', run_log)
        self.assertTrue((self.root / 'docker-label-rm.log').exists(),
                        'missing cidfile left the labeled container without cleanup')
        removals = (self.root / 'docker-label-rm.log').read_text(encoding='utf-8')
        self.assertIn('-f ' + ids[0], removals)
        self.assertIn('-f ' + ids[1], removals)

    def test_docker_host_transport_rechecks_labels_after_initial_empty_listing(self):
        from supervisor.docker_transport import DockerWorkerTransport

        bootstrap, channel = self.docker_transport_args()
        fake = self.fake_docker_missing_cidfile('late-match')
        started = time.monotonic()
        with self.assertRaises((ContractError, IsolationUnavailable)) as raised:
            DockerWorkerTransport().run(
                ['python3', '-m', 'worker'], self.docker_policy(fake),
                bootstrap=bootstrap, channel=channel, attempt_id='attempt-1',
                capability='secret', timeout=2, cancel_event=threading.Event())
        self.assertTrue((self.root / 'docker-ps.log').exists(),
                        'label reconciliation did not run: ' + repr(raised.exception))
        removals = (self.root / 'docker-label-rm.log').read_text(encoding='utf-8') \
            if (self.root / 'docker-label-rm.log').exists() else ''
        self.assertIn('-f ' + 'e' * 64, removals,
                      'later matching container was missed after an empty first listing')
        listings = (self.root / 'docker-ps.log').read_text(encoding='utf-8').splitlines()
        self.assertGreaterEqual(len(listings), 6,
                                'cleanup stopped before the full label visibility grace period')
        self.assertGreaterEqual(time.monotonic() - started, .45,
                                'cleanup trusted transient empty label listings')

    def test_docker_transport_rejects_nonfinite_and_boolean_timeouts_before_launch(self):
        import math
        from supervisor.docker_transport import DockerWorkerTransport

        bootstrap, channel = self.docker_transport_args()
        fake = self.fake_docker('ok')
        policy = self.docker_policy(fake)
        for timeout in (math.nan, math.inf, True, 86400.001):
            with self.subTest(timeout=timeout):
                with self.assertRaises(ValueError):
                    DockerWorkerTransport().run(
                        ['python3', '-m', 'worker'], policy, bootstrap=bootstrap,
                        channel=channel, attempt_id='attempt-1', capability='secret',
                        timeout=timeout, cancel_event=threading.Event())
        self.assertFalse((self.root / 'docker-run.log').exists(),
                         'invalid timeout reached Docker launch')
        self.assertEqual(DockerWorkerTransport().run(
            ['python3', '-m', 'worker'], policy, bootstrap=bootstrap,
            channel=channel, attempt_id='attempt-1', capability='secret',
            timeout=86400, cancel_event=threading.Event()).returncode, 0)

    def test_docker_identity_check_rejects_nonfinite_and_boolean_timeouts(self):
        import math
        from supervisor.isolation import verify_docker_desktop_identity

        fake = self.fake_docker('ok')
        for timeout in (math.nan, math.inf, True, 86400.001):
            with self.subTest(timeout=timeout):
                with self.assertRaises(IsolationUnavailable):
                    verify_docker_desktop_identity(fake, timeout=timeout,
                                                   cancel_event=threading.Event())
        self.assertEqual(verify_docker_desktop_identity(
            fake, timeout=86400, cancel_event=threading.Event())['os_type'], 'linux')

    def test_docker_host_transport_refuses_malformed_labeled_container_id(self):
        from supervisor.docker_transport import DockerWorkerTransport

        bootstrap, channel = self.docker_transport_args()
        fake = self.fake_docker_missing_cidfile('matches', ['not-a-container-id'])
        with self.assertRaisesRegex(IsolationUnavailable, 'cleanup failed'):
            DockerWorkerTransport().run(
                ['python3', '-m', 'worker'], self.docker_policy(fake),
                bootstrap=bootstrap, channel=channel, attempt_id='attempt-1',
                capability='secret', timeout=2, cancel_event=threading.Event())
        self.assertFalse((self.root / 'docker-label-rm.log').exists(),
                         'malformed IDs must never be passed to docker rm')

    def test_docker_host_transport_surfaces_label_listing_or_removal_failure(self):
        from supervisor.docker_transport import DockerWorkerTransport

        bootstrap, channel = self.docker_transport_args()
        for mode, ids in (('list-failure', []),
                          ('remove-failure', ['c' * 64, 'd' * 64])):
            with self.subTest(mode=mode):
                fake = self.fake_docker_missing_cidfile(mode, ids)
                with self.assertRaisesRegex(IsolationUnavailable, 'cleanup failed'):
                    DockerWorkerTransport().run(
                        ['python3', '-m', 'worker'], self.docker_policy(fake),
                        bootstrap=bootstrap, channel=channel, attempt_id='attempt-1',
                        capability='secret', timeout=2, cancel_event=threading.Event())
                if mode == 'remove-failure':
                    removals = (self.root / 'docker-label-rm.log').read_text(encoding='utf-8')
                    for container_id in ids:
                        self.assertIn('-f ' + container_id, removals)

    def test_docker_host_transport_deadline_bounds_stalled_identity_check(self):
        from supervisor.docker_transport import DockerWorkerTransport

        run_log = self.root / 'docker-identity-stall-run.log'
        fake = self.script('fake-docker-identity-stall', """#!/usr/bin/env python3
import os, sys, time
if sys.argv[1:] == ['context', 'show']:
    time.sleep(10)
    print('desktop-linux'); raise SystemExit(0)
if sys.argv[1:2] == ['run']:
    open(@RUNLOG@, 'a').write('launched\\n')
    raise SystemExit(0)
raise SystemExit(2)
""".replace('@RUNLOG@', repr(str(run_log))))[0]
        bootstrap, channel = self.docker_transport_args()
        started = time.monotonic()
        with self.assertRaises(IsolationUnavailable):
            DockerWorkerTransport().run(
                ['python3', '-m', 'worker'], self.docker_policy(fake),
                bootstrap=bootstrap, channel=channel, attempt_id='attempt-1',
                capability='secret', timeout=.2, cancel_event=threading.Event())
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 1.0, 'identity verification exceeded the transport deadline')
        self.assertFalse(run_log.exists(), 'Docker worker launched after identity deadline expired')

    def test_docker_host_transport_bounds_the_frame_queue(self):
        import queue
        from supervisor.docker_transport import DockerWorkerTransport

        constructed = []
        real_queue = queue.Queue

        def recording_queue(*args, **kwargs):
            instance = real_queue(*args, **kwargs)
            constructed.append(instance)
            return instance

        bootstrap, channel = self.docker_transport_args()
        with patch("supervisor.docker_transport.queue.Queue", side_effect=recording_queue):
            DockerWorkerTransport().run(
                ["python3", "-m", "worker"], self.docker_policy(self.fake_docker("relay")),
                bootstrap=bootstrap, channel=channel, attempt_id="attempt-1",
                capability="secret", timeout=4, cancel_event=threading.Event())
        self.assertEqual(len(constructed), 1)
        self.assertGreater(constructed[0].maxsize, 0,
                           "Docker frame reader must apply bounded-queue backpressure")

    def test_docker_host_transport_stops_and_settles_relay_tasks_on_failure(self):
        from supervisor.docker_transport import DockerWorkerTransport

        release = threading.Event()
        started = threading.Event()
        finished = threading.Event()
        transport_cancel = threading.Event()

        class BlockingChannel:
            def request(inner, attempt_id, capability, request, *, operation="infer",
                        timeout=None):
                started.set()
                while not release.wait(.01):
                    if transport_cancel.is_set():
                        finished.set()
                        raise ContractError("relay request cancelled")
                finished.set()
                return {"accepted": True}

        source = """#!/usr/bin/env python3
import json,struct,sys,time
if sys.argv[1] == 'rm': raise SystemExit(0)
if sys.argv[1:] == ['context', 'show']:
 print('desktop-linux'); raise SystemExit(0)
if sys.argv[1:3] == ['context', 'inspect']:
 print(json.dumps([{'Endpoints': {'docker': {'Host': 'unix://' + __import__('os').path.expanduser('~/.docker/run/docker.sock')}}}]))
 raise SystemExit(0)
if sys.argv[1:2] == ['info']:
 print(json.dumps({'Name':'docker-desktop','OSType':'linux','OperatingSystem':'Docker Desktop','ServerVersion':'29.9.2'}))
 raise SystemExit(0)
cid=next(a.split('=',1)[1] for a in sys.argv if a.startswith('--cidfile='))
open(cid,'w').write('""" + "a" * 64 + """')
def read():
 h=sys.stdin.buffer.read(4); n=struct.unpack('!I',h)[0]
 return json.loads(sys.stdin.buffer.read(n))
def write(v):
 b=json.dumps(v,separators=(',',':')).encode()
 sys.stdout.buffer.write(struct.pack('!I',len(b))+b); sys.stdout.buffer.flush()
s=read()
write({'type':'rpc','id':'rpc-1','operation':'heartbeat','attempt_id':s['attempt_id'],
       'capability':s['capability'],'request':{'attempt_id':s['attempt_id'],'request_id':'req-1'}})
time.sleep(.1)
write({'type':'unknown'})
time.sleep(10)
"""
        fake = self.script("fake-docker-relay-failure", source)[0]
        bootstrap, _ = self.docker_transport_args()
        bootstrap["inference"]["capability"] = "secret"
        try:
            with self.assertRaises((ContractError, IsolationUnavailable)):
                DockerWorkerTransport().run(
                    ["python3", "-m", "worker"], self.docker_policy(fake),
                    bootstrap=bootstrap, channel=BlockingChannel(),
                    attempt_id="attempt-1", capability="secret", timeout=3,
                    cancel_event=transport_cancel)
            self.assertTrue(started.is_set(), "fake broker callback never became active")
            self.assertTrue(transport_cancel.is_set(),
                            "failed transport did not cancel its authorized broker callback")
            self.assertTrue(finished.wait(.5),
                            "transport returned while an authorized broker callback was still active")
        finally:
            release.set()

    def test_docker_host_transport_bounds_large_start_write_by_deadline_and_cancellation(self):
        import signal
        from supervisor.docker_transport import DockerWorkerTransport

        pidfile = self.root / "docker-no-reader.pid"
        rm_log = self.root / "docker-no-reader-rm.log"
        source = """#!/usr/bin/env python3
import os,sys,time
if len(sys.argv)>1 and sys.argv[1]=='rm':
 open(""" + repr(str(rm_log)) + """,'a').write(' '.join(sys.argv[2:])+'\\n')
 raise SystemExit(0)
if sys.argv[1:] == ['context', 'show']:
 print('desktop-linux'); raise SystemExit(0)
if sys.argv[1:3] == ['context', 'inspect']:
 print('[{"Endpoints":{"docker":{"Host":"unix://' + os.path.expanduser('~/.docker/run/docker.sock') + '"}}}]')
 raise SystemExit(0)
if sys.argv[1:2] == ['info']:
 print('{"Name":"docker-desktop","OSType":"linux","OperatingSystem":"Docker Desktop","ServerVersion":"29.9.2"}')
 raise SystemExit(0)
cid=next(a.split('=',1)[1] for a in sys.argv if a.startswith('--cidfile='))
open(cid,'w').write('""" + "a" * 64 + """')
open(""" + repr(str(pidfile)) + """,'w').write(str(os.getpid()))
time.sleep(10)
"""
        fake = self.script("fake-docker-no-reader", source)[0]
        bootstrap, channel = self.docker_transport_args()
        bootstrap["padding"] = "x" * (3 * 1024 * 1024)

        def call(cancel_event, timeout, outcome):
            try:
                DockerWorkerTransport().run(
                    ["python3", "-m", "worker"], self.docker_policy(fake),
                    bootstrap=bootstrap, channel=channel, attempt_id="attempt-1",
                    capability="secret", timeout=timeout, cancel_event=cancel_event)
            except (ContractError, IsolationUnavailable):
                outcome.append("stopped")

        for cancel_after in (0.5, None):
            with self.subTest(cancel_after=cancel_after):
                cancel_event = threading.Event()
                outcome = []
                timer = None
                if cancel_after is not None:
                    timer = threading.Timer(cancel_after, cancel_event.set)
                    timer.start()
                thread = threading.Thread(target=call,
                                          args=(cancel_event, 3 if cancel_after else .15, outcome))
                thread.start()
                thread.join(timeout=1)
                completed_without_intervention = not thread.is_alive()
                if thread.is_alive() and pidfile.exists():
                    os.kill(int(pidfile.read_text(encoding="ascii")), signal.SIGKILL)
                thread.join(timeout=3)
                if timer is not None:
                    timer.join(timeout=1)
                self.assertTrue(completed_without_intervention,
                                "bootstrap write ignored cancellation/deadline while Docker did not read stdin")
                self.assertEqual(outcome, ["stopped"])
                self.assertIn("-f " + "a" * 64,
                              rm_log.read_text(encoding="utf-8"))

    def test_docker_host_transport_relays_authorized_request_and_output(self):
        from supervisor.docker_transport import DockerWorkerTransport

        fake = self.fake_docker("relay")
        policy = self.docker_policy(fake)
        bootstrap, channel = self.docker_transport_args()
        result = DockerWorkerTransport().run(
            ["python3", "-m", "worker"], policy, bootstrap=bootstrap,
            channel=channel, attempt_id="attempt-1", capability="secret", timeout=4,
            cancel_event=threading.Event())
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"worker stdout")
        self.assertEqual(result.stderr, b"worker stderr")
        self.assertEqual(len(channel.calls), 1)
        self.assertEqual(channel.calls[0][0:2], ("attempt-1", "secret"))
        self.assertEqual(channel.calls[0][3], "heartbeat")

    def test_docker_host_transport_rejects_unknown_operation_and_cleans_container(self):
        from supervisor.docker_transport import DockerWorkerTransport

        fake = self.fake_docker("unknown")
        policy = self.docker_policy(fake)
        bootstrap, channel = self.docker_transport_args()
        with self.assertRaises((ContractError, IsolationUnavailable)):
            DockerWorkerTransport().run(
                ["python3", "-m", "worker"], policy, bootstrap=bootstrap,
                channel=channel, attempt_id="attempt-1", capability="secret", timeout=2,
                cancel_event=threading.Event())
        self.assertEqual(channel.calls, [])
        self.assertIn("-f " + "a" * 64,
                      (self.root / "docker-rm.log").read_text(encoding="utf-8"))

    def test_docker_host_transport_fails_closed_on_daemon_or_malformed_cid(self):
        from supervisor.docker_transport import DockerWorkerTransport

        bootstrap, channel = self.docker_transport_args()
        for mode in ("daemon", "malformed"):
            with self.subTest(mode=mode):
                with self.assertRaises((ContractError, IsolationUnavailable)):
                    DockerWorkerTransport().run(
                        ["python3", "-m", "worker"], self.docker_policy(self.fake_docker(mode)),
                        bootstrap=bootstrap, channel=channel, attempt_id="attempt-1",
                        capability="secret", timeout=2, cancel_event=threading.Event())

    def test_docker_host_transport_cancellation_and_output_overflow_remove_container(self):
        from supervisor.docker_transport import DockerWorkerTransport

        bootstrap, channel = self.docker_transport_args()
        for mode in ("cancel", "oversize"):
            with self.subTest(mode=mode):
                fake = self.fake_docker(mode)
                policy = self.docker_policy(fake)
                cancel = threading.Event()
                if mode == "cancel":
                    timer = threading.Timer(.2, cancel.set)
                    timer.start()
                with self.assertRaises((ContractError, IsolationUnavailable)):
                    DockerWorkerTransport().run(
                        ["python3", "-m", "worker"], policy, bootstrap=bootstrap,
                        channel=channel, attempt_id="attempt-1", capability="secret", timeout=3,
                        cancel_event=cancel)
                if mode == "cancel":
                    timer.join(timeout=1)
                if mode == "cancel":
                    self.assertIn("--label=org.fleet-board.supervisor.attempt-id=attempt-1",
                                  (self.root / "docker-run.log").read_text(encoding="utf-8"))
                self.assertIn("-f " + "a" * 64,
                              (self.root / "docker-rm.log").read_text(encoding="utf-8"))

    def test_runner_dispatches_only_explicit_docker_policy_to_docker_transport(self):
        from supervisor.runner import run_worker_isolated

        policy = {"backend": "docker"}
        channel = object()
        cancel = threading.Event()
        expected = object()
        with patch("supervisor.runner.DockerWorkerTransport") as transport:
            transport.return_value.run.return_value = expected
            result = run_worker_isolated(
                ["python3", "-m", "worker"], policy, capability_result={"available": True},
                input_data=b"ignored", bootstrap={"inference": {}}, channel=channel,
                attempt_id="attempt-1", inference_capability="secret", timeout=5,
                cancel_event=cancel)
        self.assertIs(result, expected)
        transport.return_value.run.assert_called_once_with(
            ["python3", "-m", "worker"], policy, bootstrap={"inference": {}},
            channel=channel, attempt_id="attempt-1", capability="secret", timeout=5,
            cancel_event=cancel)

    def protected_resources_for_probe(self):
        paths = {}
        db = self.root / "probe-controller.db"
        db.write_text("sentinel", encoding="utf-8")
        board = self.root / "probe-board"
        shared = self.root / "probe-shared-git"
        board.mkdir(mode=0o700)
        shared.mkdir(mode=0o700)
        credential = self.root / "probe-credential"
        credential.write_text("sentinel", encoding="utf-8")
        keychain = self.root / "probe-keychain"
        keychain.write_text("sentinel", encoding="utf-8")
        sockets = []
        socket_paths = []
        for name in ("controller.sock", "agent.sock"):
            path = self.root / name
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.bind(str(path))
            sockets.append(sock)
            socket_paths.append(str(path))
        return ({"controller_db": str(db), "controller_socket": socket_paths[0],
                 "board_storage": str(board), "shared_git_metadata": str(shared),
                 "host_credentials": [str(credential)], "ssh_agent": socket_paths[1],
                 "keychain": [str(keychain)]}, sockets)

    def test_docker_probe_fails_closed_when_daemon_or_cached_image_is_unavailable(self):
        from supervisor.isolation import probe_docker_capabilities
        from subprocess import CompletedProcess

        resources, sockets = self.protected_resources_for_probe()
        try:
            policy = self.docker_policy(self.fake_docker("daemon"))
            with patch("supervisor.isolation.subprocess.run",
                       return_value=CompletedProcess([], 1, b"", b"daemon unavailable")):
                result = probe_docker_capabilities(policy, protected_resources=resources)
            self.assertFalse(result["available"])
            self.assertFalse(result["checks"]["docker_daemon"])
            self.assertFalse(result["checks"]["image_present"])

            with patch("supervisor.isolation.subprocess.run", side_effect=[
                    *self.docker_identity_responses(CompletedProcess),
                    CompletedProcess([], 1, b"", b"image not found")]) as docker:
                result = probe_docker_capabilities(policy, protected_resources=resources)
            self.assertFalse(result["available"])
            self.assertTrue(result["checks"]["docker_daemon"])
            self.assertFalse(result["checks"]["image_present"])
            self.assertEqual(docker.call_count, 4)
            self.assertTrue(all(not value for key, value in result["checks"].items()
                                if key not in ("docker_daemon", "image_present")))
        finally:
            for sock in sockets:
                sock.close()

    def test_docker_probe_requires_complete_host_protected_resource_map(self):
        from supervisor.isolation import probe_docker_capabilities

        result = probe_docker_capabilities(self.docker_policy(self.fake_docker("daemon")),
                                           protected_resources={"controller_db": "/missing"})
        self.assertFalse(result["available"])
        self.assertIn("protected-resource", result["reason"])

    def test_docker_probe_requires_guest_transport_mount_to_be_read_only(self):
        from supervisor.isolation import _DOCKER_PROBE_CHECKS

        self.assertIn("guest_package_write_denied", _DOCKER_PROBE_CHECKS)

    def test_docker_probe_qualifies_cancellation_separately_from_deadline_cleanup(self):
        from supervisor.isolation import _DOCKER_PROBE_CHECKS

        self.assertIn("timeout_cleanup", _DOCKER_PROBE_CHECKS)
        self.assertIn("cancellation_cleanup", _DOCKER_PROBE_CHECKS)

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

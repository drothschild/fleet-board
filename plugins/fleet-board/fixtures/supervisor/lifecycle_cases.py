"""Offline contract cases for the persistent supervisor lifecycle boundary."""
import json
import os
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(sys.argv.pop()).resolve()

try:
    from supervisor.service import Service
except ModuleNotFoundError as exc:
    if exc.name not in ("supervisor", "supervisor.service"):
        raise
    Service = None

try:
    from supervisor.cli import main
except ModuleNotFoundError as exc:
    if exc.name not in ("supervisor", "supervisor.cli"):
        raise
    main = None


class FakeClock:
    def __init__(self, now=100):
        self.now = now

    def __call__(self):
        return self.now


def domain(root, identity="fixture"):
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    return {"common_dir": str(root), "board_backend": "local",
            "board_identity": identity, "runtime_root": str(root / "runtime")}


class LifecycleContract(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(Service, "persistent supervisor service is not implemented")
        self.assertIsNotNone(main, "persistent supervisor CLI is not implemented")
        self.root = ROOT / self.id().rsplit(".", 1)[-1]
        self.root.mkdir(mode=0o700)
        self.socket_tmp = Path("/private/tmp/fb-supervisor-tests")
        self.socket_tmp.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.clock = FakeClock()
        with mock.patch.dict(os.environ, {"TMPDIR": str(self.socket_tmp)}):
            self.service = Service.open(domain(self.root), clock=self.clock,
                                        host_boot_id="boot-1",
                                        peer_resolver=lambda connection: "fixture-user")
        self.addCleanup(self.service.close)

    def command(self, argv, transport=None):
        from io import StringIO
        out, err = StringIO(), StringIO()
        code = main(argv, env={"FLEET_BOARD_DOMAIN": str(self.root)},
                    stdout=out, stderr=err, transport=transport)
        return code, out.getvalue(), err.getvalue()

    def test_start_acknowledges_only_after_recovery_finishes(self):
        order = []
        self.service.recovery = mock.Mock()
        self.service.recovery.reconcile.side_effect = lambda now: order.append("recovered")
        ack = self.service.start_serving()
        self.assertEqual(order, ["recovered"])
        self.assertTrue(ack["ready"])
        self.assertTrue(ack["recovery_complete"])

    def test_socket_directory_and_socket_have_private_modes(self):
        ack = self.service.start_serving()
        if ack.get("socket_unavailable"):
            self.skipTest("sandbox denies binding the supervisor Unix socket")
        directory = Path(self.service.directory)
        endpoint = Path(self.service.socket_path)
        self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(endpoint.stat().st_mode), 0o600)

    def test_concurrent_and_repeated_start_share_one_owner(self):
        outcomes = []
        services = []
        barrier = threading.Barrier(3)
        def start(_index):
            # Each contender owns its connection: open and start on one thread.
            service = Service.open(domain(self.root), clock=self.clock, host_boot_id="boot-1")
            services.append(service)
            barrier.wait()
            outcomes.append(service.start_serving())
        threads = [threading.Thread(target=start, args=(index,)) for index in range(2)]
        for thread in threads:
            thread.start()
        barrier.wait()
        for thread in threads:
            thread.join(timeout=5)
        self.addCleanup(lambda: [service.stop_serving() for service in services])
        self.assertTrue(all(not thread.is_alive() for thread in threads))
        self.assertEqual(sum(bool(item.get("owner")) for item in outcomes), 1)
        self.assertTrue(all(item.get("ready") for item in outcomes))

    def test_legacy_wrapper_lock_refuses_service_start(self):
        # claim-run-lock.py uses pid + ps lstart as its legacy format. Exercise
        # that on a real live child so the test covers the cross-process lock.
        import subprocess
        from pathlib import Path
        lock = self.root / "legacy.lock"
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        def stop_child():
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
        self.addCleanup(stop_child)
        script = Path(__file__).resolve().parents[2] / "scripts" / "claim-run-lock.py"
        try:
            subprocess.run([sys.executable, str(script), str(lock), str(process.pid)],
                           check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as exc:
            if "Operation not permitted: 'ps'" in (exc.stderr or ""):
                self.skipTest("sandbox denies the real ps call required by legacy-lock fixture")
            raise
        self.service.run_lock_path = str(lock)
        with self.assertRaisesRegex(RuntimeError, "legacy"):
            self.service.start_serving()

    def test_service_claims_stale_shared_lock_and_excludes_other_worktree(self):
        lock = self.root / "shared-run.lock"
        lock.write_text("99999999\nnot-a-real-start-time\n", encoding="utf-8")
        with mock.patch.dict(os.environ, {"TMPDIR": str(self.socket_tmp)}):
            first = Service.open(domain(self.root), clock=self.clock, host_boot_id="boot-1",
                                 run_lock_path=str(lock))
        second_root = self.root / "linked-worktree"
        second_root.mkdir()
        with mock.patch.dict(os.environ, {"TMPDIR": str(self.socket_tmp)}):
            second = Service.open(domain(second_root), clock=self.clock, host_boot_id="boot-1",
                                  run_lock_path=str(lock))
        self.addCleanup(first.close)
        self.addCleanup(second.close)
        self.assertTrue(first.start_serving().get("owner"))
        with self.assertRaisesRegex(RuntimeError, "legacy"):
            second.start_serving()

    def test_desired_state_survives_service_reopen(self):
        self.service.start_serving()
        self.service.command("pause", request_id="pause-1", expected_revision=0,
                             actor="fixture-user")
        self.service.stop_serving()
        reopened = Service.open(domain(self.root), clock=self.clock, host_boot_id="boot-1")
        self.addCleanup(reopened.close)
        self.assertEqual(reopened.snapshot()["domain"]["desired_mode"], "paused")

    def test_pause_and_resume_change_admission_state(self):
        self.service.start_serving()
        self.service.command("pause", request_id="pause-1", expected_revision=0,
                             actor="fixture-user")
        self.assertFalse(self.service.admissions_open)
        self.service.command("resume", request_id="resume-1", expected_revision=1,
                             actor="fixture-user")
        self.assertTrue(self.service.admissions_open)

    def test_stop_drain_closes_admissions_without_cancelling_workers(self):
        self.service.start_serving()
        self.service.stop(mode="drain", request_id="stop-1", expected_revision=0,
                          actor="fixture-user")
        self.assertFalse(self.service.admissions_open)
        self.assertEqual(self.service.cancellation_requests, [])

    def test_stop_cancel_requests_cancellation_through_store(self):
        self.service.start_serving()
        real = self.service.snapshot
        live = [{"id": "a1", "state": "running"}, {"id": "a2", "state": "launching"},
                {"id": "a3", "state": "done"}]
        self.service.snapshot = lambda: dict(real(), attempts=live)
        with mock.patch.object(self.service.store, "request_cancellation") as cancel:
            self.service.stop(mode="cancel", request_id="stop-1", expected_revision=0,
                              actor="fixture-user")
        self.assertEqual([call.args[0] for call in cancel.call_args_list], ["a1", "a2"])
        self.assertEqual(self.service.cancellation_requests, ["a1", "a2"])
        self.assertEqual(real()["domain"]["desired_mode"], "stopped")

    def test_stop_cancel_targets_each_live_attempt(self):
        self.service.start_serving()
        self.service.cancel_live_attempts = mock.Mock()
        self.service.stop(mode="cancel", request_id="stop-1", expected_revision=0,
                          actor="fixture-user")
        self.service.cancel_live_attempts.assert_called_once()

    def test_crash_during_shutdown_reports_uncertain_writer(self):
        self.service.start_serving()
        self.service.shutdown_observer = lambda: "unknown"
        result = self.service.stop_serving()
        self.assertEqual(result["status"], "unresolved_shutdown")
        self.assertFalse(result.get("terminated", False))
        self.assertFalse(Path(self.service.socket_path).exists())
        self.assertFalse(Path(self.service.worker_socket_path).exists())
        self.service.shutdown_observer = lambda: "stopped"
        self.assertEqual(self.service.start_serving().get("owner"), True)

    def test_supported_resolve_is_audited_and_uncertain_writer_rejects_it(self):
        self.service.start_serving()
        self.service.writer_uncertain = True
        with self.assertRaisesRegex((ValueError, RuntimeError), "uncertain|writer"):
            self.service.handle_request({"command": "resolve", "request_id": "resolve-uncertain",
                                         "card": 17, "action": "retry", "reason": "reviewed"},
                                        peer=object())
        self.service.writer_uncertain = False
        self.service.handle_request({"command": "resolve", "request_id": "resolve-ok",
                                     "card": 17, "action": "retry", "reason": "reviewed"},
                                    peer=object())
        audited = [json.loads(item["request"]) for item in self.service.snapshot()["commands"]]
        self.assertTrue(any(item.get("command") == "resolve" and item.get("actor")
                            for item in audited))

    def test_recovery_runs_while_stopped_without_opening_admissions(self):
        self.service.recovery = mock.Mock()
        ack = self.service.start_serving()
        self.assertTrue(ack["recovery_complete"])
        self.assertFalse(self.service.admissions_open)
        self.assertEqual(self.service.snapshot()["domain"]["desired_mode"], "stopped")

    def test_blocked_controller_rpc_times_out_without_blocking_other_requests(self):
        self.service.start_serving()
        self.service.request_timeout = 0.02
        self.service.rpc_handler = lambda request: time.sleep(0.2)
        with self.assertRaises(TimeoutError):
            self.service.request({"command": "slow"})
        self.service.rpc_handler = lambda request: {"ok": True}
        self.assertEqual(self.service.request({"command": "status"}), {"ok": True})

    def test_stale_command_revision_is_rejected(self):
        self.service.start_serving()
        self.service.command("pause", request_id="pause-1", expected_revision=0,
                             actor="fixture-user")
        with self.assertRaisesRegex(ValueError, "revision"):
            self.service.command("resume", request_id="resume-1", expected_revision=0,
                                 actor="fixture-user")

    def test_duplicate_command_id_has_one_effect_and_same_outcome(self):
        self.service.start_serving()
        first = self.service.command("pause", request_id="pause-1", expected_revision=0,
                                     actor="fixture-user")
        second = self.service.command("pause", request_id="pause-1", expected_revision=0,
                                      actor="fixture-user")
        self.assertEqual(first, second)
        events = self.service.events()
        self.assertEqual(sum(item["type"] == "command" for item in events), 1)

    def test_actor_is_derived_from_peer_and_spoofed_body_is_rejected(self):
        self.service.start_serving()
        result = self.service.handle_request({"command": "status"}, peer="admin")
        self.assertIn("revision", result)
        self.assertEqual(self.service.authenticated_actor("admin"), "fixture-user")
        with self.assertRaisesRegex(ValueError, "actor"):
            self.service.handle_request({"command": "pause", "actor": "admin"},
                                        peer="fixture-user")
        self.assertEqual(self.service.authenticated_actor(object()), "fixture-user")

    def test_worker_ipc_cannot_issue_lifecycle_or_resolution_commands(self):
        self.service.start_serving()
        for command in ("pause", "resume", "stop", "resolve", "release"):
            with self.subTest(command=command), self.assertRaises(PermissionError):
                self.service.worker_request({"command": command})

    def test_oversized_controller_request_is_rejected(self):
        self.service.start_serving()
        with self.assertRaisesRegex(ValueError, "size"):
            self.service.handle_request({"payload": "x" * (1024 * 1024 + 1)},
                                        peer="fixture-user")

    def test_fragmented_and_maximum_request_and_large_cli_response(self):
        ack = self.service.start_serving()
        if ack.get("socket_unavailable"):
            self.skipTest("sandbox denies binding the supervisor Unix socket")
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(self.service.socket_path)
        raw = json.dumps({"command": "status"}).encode()
        for part in (raw[:3], raw[3:8], raw[8:]):
            client.sendall(part)
        response = b""
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            response += chunk
        client.close()
        self.assertTrue(json.loads(response)["ok"])

        empty_max_request = {"command": "status", "padding": ""}
        max_request = {"command": "status", "padding": "x" *
                       (1024 * 1024 - len(json.dumps(empty_max_request).encode("utf-8")))}
        self.assertIn("revision", self.service.handle_request(max_request, peer=object()))

        from supervisor.cli import _socket_transport
        # A real socket-backed response exercises the CLI's recv loop.
        self.service.large_response = "y" * (1024 * 1024 + 100)
        self.service.handle_request = lambda request, *, peer: {"large": self.service.large_response}
        transport = _socket_transport(self.service.socket_path)
        self.assertGreater(len(json.dumps(transport({"command": "status"}))), 1024 * 1024)

    def test_socket_directory_refuses_symlink_and_insecure_existing_directory(self):
        target = self.root / "target-dir"
        target.mkdir(mode=0o755)
        socket_root = self.socket_tmp / ("fb-supervisor-" + self.service.store.domain_id[:12])
        # Repoint the service's deterministic socket location through its path.
        try:
            self.service.directory = str(target)
            if socket_root.is_symlink():
                socket_root.unlink()
            elif socket_root.exists():
                import shutil
                shutil.rmtree(socket_root)
            socket_root.symlink_to(target, target_is_directory=True)
            try:
                self.service.start_serving()
            except (ValueError, OSError):
                pass
            else:
                self.fail("startup accepted a symlink socket directory")
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)
        finally:
            socket_root.unlink(missing_ok=True)

    def test_session_accounting_survives_start_resume_restart_and_reboot(self):
        self.service.start_serving()
        session = {"id": "session-1", "started_at": 10, "deadline": 500,
                   "known_spend": 7.25, "unknown_spend": True,
                   "budget_stop": "unknown"}
        self.service.store.start_session(session)
        revision = self.service.status()["revision"]
        self.service.command("pause", request_id="pause-1", expected_revision=revision,
                             actor="fixture-user")
        revision = self.service.status()["revision"]
        self.service.command("resume", request_id="resume-1", expected_revision=revision,
                             actor="fixture-user")
        self.service.stop_serving()
        reopened = Service.open(domain(self.root), clock=self.clock, host_boot_id="boot-2")
        self.addCleanup(reopened.close)
        restored = next(item for item in reopened.snapshot()["sessions"]
                        if item["id"] == "session-1")
        self.assertEqual((restored["deadline"], restored["known_spend"],
                          restored["unknown_spend"], restored["budget_stop"]),
                         (500, 7.25, True, "unknown"))

    def test_read_only_status_available_when_execution_cannot_start(self):
        self.service.start_serving()
        self.service.execution_available = False
        status = self.service.status()
        self.assertTrue(status["read_only"])
        self.assertEqual(status["desired_mode"], "stopped")

    def test_runner_version_compatibility_survives_process_restart(self):
        self.service.start_serving()
        self.service.register_runner_version("runner-1", "protocol-1")
        self.service.stop_serving()
        reopened = Service.open(domain(self.root), clock=self.clock, host_boot_id="boot-1")
        self.addCleanup(reopened.close)
        self.assertTrue(reopened.runner_compatible("runner-1", "protocol-1"))
        self.assertFalse(reopened.runner_compatible("runner-2", "protocol-1"))


class CLIContract(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(main, "persistent supervisor CLI is not implemented")

    def invoke(self, *argv):
        from io import StringIO
        out, err = StringIO(), StringIO()
        code = main(list(argv), env={}, stdout=out, stderr=err,
                    transport=lambda request: {"ok": True, "request": request})
        return code, out.getvalue(), err.getvalue()

    def test_cli_exposes_all_lifecycle_and_inspection_commands(self):
        for command in (("start",), ("pause",), ("resume",),
                        ("stop", "--mode", "drain"), ("stop", "--mode", "cancel"),
                        ("status",), ("reconcile",), ("events",),
                        ("resolve", "--card", "17", "--action", "retry")):
            with self.subTest(command=command):
                code, _, err = self.invoke(*command)
                self.assertEqual(code, 0, err)

    def test_cli_reconcile_returns_snapshot_and_cursor_without_waiting(self):
        code, output, err = self.invoke("reconcile")
        self.assertEqual(code, 0, err)
        result = json.loads(output)
        self.assertIn("snapshot", result)
        self.assertIn("cursor", result)

    def test_pause_resume_stop_send_current_revisions_over_real_service(self):
        root = ROOT / "cli-real-service"
        root.mkdir(mode=0o700)
        socket_tmp = Path("/private/tmp/fb-supervisor-tests")
        socket_tmp.mkdir(mode=0o700, parents=True, exist_ok=True)
        with mock.patch.dict(os.environ, {"TMPDIR": str(socket_tmp)}):
            service = Service.open(domain(root), host_boot_id="boot-1",
                                   peer_resolver=lambda connection: "fixture-user")
        self.addCleanup(service.close)
        seen = []
        def transport(request):
            if request.get("command") in ("pause", "resume", "stop"):
                seen.append(request["expected_revision"])
            return service.handle_request(request, peer=object())
        for args in (("pause",), ("resume",), ("stop", "--mode", "drain")):
            err = __import__("io").StringIO()
            code = main(list(args), env={}, stdout=__import__("io").StringIO(),
                        stderr=err, transport=transport)
            self.assertEqual(code, 0, err.getvalue())
        self.assertEqual(seen, [0, 1, 2])

    def test_events_uses_bounded_store_query(self):
        root = ROOT / "events-bounded"
        root.mkdir(mode=0o700)
        service = Service.open(domain(root), host_boot_id="boot-1")
        self.addCleanup(service.close)
        service.store.events_after = mock.Mock(return_value=[])
        service.store.snapshot = mock.Mock(side_effect=AssertionError("full snapshot loaded"))
        self.assertEqual(service.events(after=10, limit=7), [])
        service.store.events_after.assert_called_once_with(10, 7)

    def test_cli_rejects_contradictory_or_unsupported_arguments(self):
        cases = (("stop",), ("stop", "--mode", "invalid"),
                 ("pause", "--mode", "drain"), ("resolve", "--action", "retry"),
                 ("unknown",))
        for args in cases:
            with self.subTest(args=args):
                code, _, err = self.invoke(*args)
                self.assertEqual(code, 2)
                self.assertIn("usage", err.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)

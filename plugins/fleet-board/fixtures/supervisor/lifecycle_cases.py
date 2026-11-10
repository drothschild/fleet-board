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
        self.clock = FakeClock()
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
        self.service.start_serving()
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
        self.service.legacy_lock_live = True
        with self.assertRaisesRegex(RuntimeError, "legacy"):
            self.service.start_serving()

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
        self.service.stop(mode="cancel", request_id="stop-1", expected_revision=0,
                          actor="fixture-user")
        self.assertTrue(self.service.store.snapshot()["domain"]["desired_mode"] == "stopped")
        self.assertTrue(self.service.cancellation_requests)

    def test_crash_during_shutdown_reports_uncertain_writer(self):
        self.service.start_serving()
        self.service.shutdown_observer = lambda: "unknown"
        result = self.service.stop_serving()
        self.assertEqual(result["status"], "unresolved_shutdown")
        self.assertFalse(result.get("terminated", False))

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
        with self.assertRaisesRegex(ValueError, "actor"):
            self.service.handle_request({"command": "pause", "actor": "admin"},
                                        peer="fixture-user")
        self.assertEqual(self.service.authenticated_actor("fixture-user"), "fixture-user")

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

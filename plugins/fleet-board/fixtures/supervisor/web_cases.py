"""HTTP-to-supervisor proxy contract cases (Task 5.2 S2)."""
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from unittest import mock

ROOT = Path(sys.argv.pop()).resolve()
PLUGIN = Path(__file__).resolve().parents[2]
SCRIPTS = PLUGIN / "scripts"
try:
    from supervisor.service import Service
except ModuleNotFoundError as exc:
    if exc.name not in ("supervisor", "supervisor.service"):
        raise
    Service = None


def short_tmp():
    path = Path(tempfile.mkdtemp(prefix="fbw-", dir=os.path.realpath("/tmp")))
    os.chmod(path, 0o700)
    return path


class SupervisorWebContract(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(Service, "HTTP-to-supervisor proxy is not implemented")
        self.case = ROOT / self.id().rsplit(".", 1)[-1]
        self.case.mkdir(mode=0o700)
        self.tmp_socket = short_tmp()
        self.addCleanup(shutil.rmtree, str(self.tmp_socket), True)
        self.repo = self.case / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        (self.repo / ".fleet-board.yml").write_text(
            "board:\n  repo: acme/toy\n"
            "supervisor:\n  enabled: true\n", encoding="utf-8")
        (self.repo / ".fleet-board").mkdir()
        (self.repo / ".fleet-board" / "cards").mkdir()
        (self.repo / ".fleet-board" / "next").write_text("1\n", encoding="utf-8")
        self.config = self.repo / ".fleet-board.yml"
        self.socket_path = self.tmp_socket / "control.sock"
        self.env = dict(os.environ, FLEET_BOARD_CONFIG=str(self.config),
                        FLEET_BOARD_LOG_DIR=str(self.case / "logs"),
                        FLEET_BOARD_SUPERVISOR_SOCKET=str(self.socket_path),
                        TMPDIR=str(self.tmp_socket), PYTHONDONTWRITEBYTECODE="1",
                        PYTHONPATH=str(SCRIPTS), FLEET_BOARD_USER="web-test")
        self.service = None
        self.server = None
        self.port = None
        self.addCleanup(self.stop_all)

    def start_service(self):
        domain = {"common_dir": str(self.repo / ".git"),
                  "board_backend": "local", "board_identity": str(self.repo),
                  "runtime_root": str(self.case / "runtime")}
        with mock.patch.dict(os.environ, {"TMPDIR": str(self.tmp_socket),
                                          "FLEET_BOARD_LOG_DIR": str(self.case / "logs")}):
            self.service = Service.open(domain, run_lock_path=str(self.case / "run.lock"),
                                        board_repo=str(self.repo), execution_enabled=True,
                                        host_boot_id="web-test-boot")
        self.service.socket_path = str(self.socket_path)
        try:
            ack = self.service.start_serving()
        except OSError as exc:
            self.skipTest("sandbox denies local Unix socket service: %s" % exc)
        except RuntimeError as exc:
            if "Operation not permitted: 'ps'" in str(exc):
                self.skipTest("sandbox denies process metadata required by service lock")
            raise
        if ack.get("socket_unavailable"):
            self.skipTest("sandbox denies local Unix socket service")
        return ack

    def start_web(self):
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            probe.bind(("127.0.0.1", 0))
        except OSError as exc:
            probe.close()
            self.skipTest("sandbox denies loopback HTTP: %s" % exc)
        probe.close()
        self.server = subprocess.Popen(
            [sys.executable, str(SCRIPTS / "board-web.py"), "--root", str(self.repo),
             "--port", "0", "--scripts", str(SCRIPTS)],
            env=self.env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True)
        import select
        ready, _, _ = select.select([self.server.stdout], [], [], 15)
        line = self.server.stdout.readline().strip() if ready else ""
        if not re.match(r"^listening on http://127\.0\.0\.1:\d+$", line):
            # Never block on stderr of a server that is still alive.
            self.server.kill()
            self.fail("board-web did not start: %r %s" % (line, self.server.stderr.read()))
        self.port = int(line.rsplit(":", 1)[1])

    def stop_all(self):
        if self.server is not None:
            self.server.terminate()
            try:
                self.server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.server.kill()
                self.server.wait()
        if self.service is not None:
            self.service.close()

    def http(self, method, path, body=None, *, token=True, host=None):
        headers = {"Host": host or "127.0.0.1:%d" % self.port}
        if token:
            headers["X-Fleet-Board"] = "1"
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        request = Request("http://127.0.0.1:%d%s" % (self.port, path),
                          data=data, headers=headers, method=method)
        try:
            with urlopen(request, timeout=3) as response:
                return response.status, json.loads(response.read() or b"{}")
        except HTTPError as exc:
            return exc.code, json.loads(exc.read() or b"{}")

    def test_disabled_mode_keeps_legacy_run_api(self):
        self.config.write_text("board:\n  repo: acme/toy\n", encoding="utf-8")
        self.start_web()
        code, payload = self.http("GET", "/api/run")
        self.assertEqual(code, 200)
        self.assertIn("state", payload)

    def test_enabled_mode_proxies_supervisor_and_never_mutates_legacy_markers(self):
        self.start_service()
        active = self.repo / ".fleet-board" / "active"
        active.mkdir()
        marker = active / "7"
        marker.write_text("active\n")
        self.start_web()
        code, payload = self.http("GET", "/api/supervisor")
        self.assertEqual(code, 200, "GET /api/supervisor is not routed to the service")
        self.assertIn("revision", payload)
        self.assertTrue(marker.exists(), "supervisor mode cleared legacy active marker")
        self.assertFalse((self.case / "logs" / "toy" / "run.pid").exists(),
                         "supervisor mode wrote legacy run.pid")

    def test_design_routes_are_proxied_and_mutations_are_revision_bound(self):
        self.start_service()
        self.start_web()
        status, state = self.http("GET", "/api/supervisor")
        self.assertEqual(status, 200, "supervisor status route is missing")
        revision = state.get("revision", 0)
        routes = [
            ("POST", "/api/supervisor/start", {"request_id": "start-1", "expected_revision": revision}),
            ("POST", "/api/supervisor/pause", {"request_id": "pause-1", "expected_revision": revision}),
            ("POST", "/api/supervisor/resume", {"request_id": "resume-1", "expected_revision": revision}),
            ("POST", "/api/supervisor/stop", {"request_id": "stop-1", "expected_revision": revision, "mode": "drain"}),
            ("GET", "/api/supervisor/events?after=0&limit=2", None),
            ("GET", "/api/cards/1/execution", None),
            ("POST", "/api/cards/1/execution/pause", {"request_id": "cp-1", "expected_revision": revision, "mode": "drain"}),
            ("POST", "/api/cards/1/execution/release-reservations", {"request_id": "release-1", "expected_revision": revision, "expected_reservation_revision": 0, "reason": "reviewed"}),
            ("POST", "/api/cards/1/execution/resolve", {"request_id": "resolve-1", "expected_revision": revision, "action": "retry", "reason": "reviewed"}),
            ("POST", "/api/cards/1/execution/resume", {"request_id": "cr-1", "expected_revision": revision}),
        ]
        for method, path, body in routes:
            code, response = self.http(method, path, body)
            self.assertNotEqual(code, 404, "%s %s is not routed: %r" % (method, path, response))
            self.assertNotEqual(code, 501, "%s %s is not implemented" % (method, path))

    def test_security_validation_and_http_limits_apply_to_new_routes(self):
        self.start_service()
        self.start_web()
        self.assertEqual(self.http("GET", "/api/supervisor", token=True,
                                   host="foreign.example")[0], 403)
        self.assertEqual(self.http("POST", "/api/supervisor/start", {}, token=False)[0], 403)
        code, _ = self.http("POST", "/api/supervisor/pause", {"request_id": "actor", "actor": "forged"})
        self.assertEqual(code, 400, "caller supplied actor must be rejected")
        request = Request("http://127.0.0.1:%d/api/supervisor/start" % self.port,
                          data=b"{" , headers={"Host": "127.0.0.1:%d" % self.port,
                          "X-Fleet-Board": "1", "Content-Type": "application/json"}, method="POST")
        with self.assertRaises(HTTPError) as caught:
            urlopen(request, timeout=3)
        self.assertEqual(caught.exception.code, 400)

    def test_unreachable_returns_last_known_state_and_mutations_503(self):
        self.start_web()
        code, payload = self.http("GET", "/api/supervisor")
        self.assertEqual(code, 200, "unreachable status must be readable")
        self.assertTrue(payload.get("unreachable"), "missing unreachable flag")
        self.assertIn("last_known", payload)
        self.assertIsNone(payload.get("occupancy", "missing"), "occupancy must be unknown, not zero")
        code, _ = self.http("POST", "/api/supervisor/stop", {"request_id": "offline-1", "expected_revision": 0})
        self.assertEqual(code, 503)

    def test_run_compatibility_distinguishes_acknowledgement_from_ready(self):
        self.start_service()
        self.start_web()
        code, payload = self.http("GET", "/api/run")
        self.assertEqual(code, 200)
        self.assertNotEqual(payload.get("state"), "running", "spawn/acknowledgement must not imply ready")
        code, response = self.http("POST", "/api/run/start", {"request_id": "compat-start", "expected_revision": 0})
        self.assertIn(code, (200, 202), "compatibility Start did not delegate")
        self.assertNotIn("pid", response, "supervisor projection leaked legacy PID semantics")

    def test_event_paging_and_log_references_are_bounded_and_safe(self):
        self.start_service()
        self.start_web()
        code, page = self.http("GET", "/api/supervisor/events?" + urlencode({"after": 0, "limit": 2}))
        self.assertEqual(code, 200)
        self.assertLessEqual(len(page.get("events", [])), 2)
        self.assertIn("next_cursor", page)
        code, result = self.http("GET", "/api/cards/1/execution")
        self.assertEqual(code, 200)
        for ref in result.get("logs", []):
            self.assertRegex(ref.get("id", ""), r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
            self.assertNotIn("/", ref.get("id", ""))

    def test_unknown_card_state_is_not_normalized_or_dispatched(self):
        self.start_service()
        self.start_web()
        code, result = self.http("GET", "/api/cards/999/execution")
        self.assertEqual(code, 200)
        self.assertFalse(result.get("dispatchable", False), "unknown card must remain non-dispatchable")

    def test_methods_and_unknown_routes_keep_http_semantics(self):
        self.start_service()
        self.start_web()
        self.assertEqual(self.http("GET", "/api/supervisor/no-such-route")[0], 404)
        request = Request("http://127.0.0.1:%d/api/supervisor" % self.port,
                          headers={"Host": "127.0.0.1:%d" % self.port}, method="DELETE")
        try:
            urlopen(request, timeout=3)
        except HTTPError as exc:
            self.assertEqual(exc.code, 404)
        else:
            self.fail("unsupported method unexpectedly succeeded")


if __name__ == "__main__":
    unittest.main(verbosity=2)

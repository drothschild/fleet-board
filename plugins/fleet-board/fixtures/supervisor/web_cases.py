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

    def test_every_http_mutation_requires_request_id_and_integer_revision_without_side_effects(self):
        self.start_service()
        self.start_web()
        mutations = [
            ("/api/supervisor/start", {"request_id": "start-bound", "expected_revision": 0}),
            ("/api/supervisor/pause", {"request_id": "pause-bound", "expected_revision": 0}),
            ("/api/supervisor/resume", {"request_id": "resume-bound", "expected_revision": 0}),
            ("/api/supervisor/stop", {"request_id": "stop-bound", "expected_revision": 0, "mode": "drain"}),
            ("/api/cards/1/execution/pause", {"request_id": "cp-bound", "expected_revision": 0}),
            ("/api/cards/1/execution/release-reservations", {"request_id": "cr-bound", "expected_revision": 0,
                                                                "expected_reservation_revision": 0, "reason": "x"}),
            ("/api/cards/1/execution/resolve", {"request_id": "cx-bound", "expected_revision": 0,
                                                  "action": "retry", "reason": "x"}),
            ("/api/cards/1/execution/resume", {"request_id": "cu-bound", "expected_revision": 0}),
        ]
        for path, complete in mutations:
            for field in ("request_id", "expected_revision"):
                with self.subTest(path=path, missing=field):
                    before = self.service.snapshot()
                    incomplete = dict(complete)
                    incomplete.pop(field)
                    code, _ = self.http("POST", path, incomplete)
                    self.assertEqual(code, 400, "missing %s accepted by %s" % (field, path))
                    self.assertEqual(self.service.snapshot(), before)

    def test_mutation_retry_deduplicates_and_stale_revision_returns_current_without_reapply(self):
        self.start_service()
        self.start_web()
        initial = self.service.get_status()
        request = {"request_id": "retry-pause", "expected_revision": initial["revision"]}
        first_code, first = self.http("POST", "/api/supervisor/pause", request)
        after_first = self.service.snapshot()
        second_code, second = self.http("POST", "/api/supervisor/pause", request)
        self.assertIn(first_code, (200, 202))
        self.assertEqual(second_code, first_code)
        self.assertEqual(second, first, "same request_id must return its original outcome")
        self.assertEqual(self.service.snapshot()["events"], after_first["events"])
        stale = dict(request, request_id="stale-pause", expected_revision=initial["revision"] - 1)
        stale_code, stale_body = self.http("POST", "/api/supervisor/pause", stale)
        self.assertEqual(stale_code, 409)
        self.assertIn("current", stale_body)
        self.assertEqual(self.service.snapshot(), after_first)

    def test_legacy_no_body_run_start_and_stop_derive_binding_and_are_idempotent(self):
        """Only these no-body compatibility routes may synthesize request IDs/revisions."""
        self.start_service()
        self.start_web()
        for action in ("start", "stop"):
            with self.subTest(action=action):
                code, payload = self.http("POST", "/api/run/" + action)
                self.assertIn(code, (200, 202))
                self.assertNotIn("request_id", payload)
                self.assertNotIn("expected_revision", payload)

    def test_unreachable_supervisor_keeps_reachable_top_level_shape(self):
        self.start_service()
        self.start_web()
        code, reachable = self.http("GET", "/api/supervisor")
        self.assertEqual(code, 200)
        self.service.stop_serving()  # the web server stays up; only the service goes away
        code, unreachable = self.http("GET", "/api/supervisor")
        self.assertEqual(code, 200)
        self.assertTrue(unreachable.get("unreachable"))
        for key in reachable:
            self.assertIn(key, unreachable, "missing stable status key %s" % key)
        self.assertIn("phase", unreachable)
        self.assertIn("desired_mode", unreachable)
        self.assertIn("revision", unreachable)
        self.assertIn("last_known_at", unreachable)
        self.assertIsNone(unreachable.get("occupancy"))

    def test_run_projection_requires_ready_acknowledgement_and_observed_running_phase(self):
        self.start_service()
        self.start_web()
        status = self.service.get_status()
        status.update({"desired_mode": "running", "phase": "starting", "ready": False})
        with mock.patch.object(self.service, "status", return_value=status):
            code, run = self.http("GET", "/api/run")
        self.assertEqual(code, 200)
        self.assertNotEqual(run.get("state"), "running")
        status.update({"phase": "stopped", "ready": False})
        with mock.patch.object(self.service, "status", return_value=status):
            _, run = self.http("GET", "/api/run")
        self.assertNotEqual(run.get("state"), "stopped", "running intent while recovering is not stopped")
        status.update({"phase": "running", "ready": True})
        with mock.patch.object(self.service, "status", return_value=status):
            _, run = self.http("GET", "/api/run")
        self.assertEqual(run.get("state"), "running")

    def test_client_rejects_untrusted_socket_paths_and_peer_before_sending(self):
        from supervisor import webproxy
        target = self.tmp_socket / "target.sock"
        target.write_text("not a socket")
        link = self.tmp_socket / "link.sock"
        link.symlink_to(target)
        for path in (str(link), str(target)):
            with self.subTest(path=path), mock.patch.dict(os.environ, {"FLEET_BOARD_SUPERVISOR_SOCKET": path}):
                with self.assertRaises((OSError, ValueError, RuntimeError)):
                    webproxy.request(path, {"command": "status"})
        self.assertNotEqual(webproxy.socket_path("123456789012-left"),
                            webproxy.socket_path("123456789012-right"),
                            "socket path must distinguish full domain IDs sharing a 12-char prefix")
        self.assertTrue(hasattr(webproxy, "_peer_uid_matches") or hasattr(webproxy, "peer_uid_matches"),
                        "client needs a testable peer-uid check")

    def test_response_can_be_chunked_or_connection_remain_open_and_bad_frame_is_503(self):
        from supervisor import webproxy
        class ChunkSocket:
            def __init__(self, *_args): self.parts = [b'{"ok":', b'true,"result":{"phase":"idle"}}']
            def settimeout(self, _timeout): pass
            def connect(self, _path): pass
            def sendall(self, _data): pass
            def recv(self, _size): return self.parts.pop(0) if self.parts else b""
            def close(self): pass
        with mock.patch.object(webproxy.socket, "socket", ChunkSocket):
            self.assertEqual(webproxy.request("unused", {"command": "status"}), {"phase": "idle"})
        with mock.patch.object(webproxy.socket, "socket", ChunkSocket):
            self.assertEqual(webproxy.request("unused", {"command": "status"}), {"phase": "idle"})
        class BadSocket(ChunkSocket):
            def __init__(self, *_args): self.parts = [b'{"ok": tr']  # truncated, then EOF
        with mock.patch.object(webproxy.socket, "socket", BadSocket):
            with self.assertRaises((ValueError, OSError)):
                webproxy.request("unused", {"command": "status"})

    def test_card_control_validation_and_structured_error_codes(self):
        self.start_service()
        self.start_web()
        for action, body in (("pause", {}), ("release-reservations", {"request_id": "x", "expected_revision": 0}),
                             ("resolve", {"request_id": "x", "expected_revision": 0}),
                             ("resume", {})):
            code, _ = self.http("POST", "/api/cards/1/execution/" + action, body)
            self.assertEqual(code, 400, "%s accepted invalid or incomplete fields" % action)
        with mock.patch.object(self.service, "_handle_request",
                               side_effect=RuntimeError("revision database is corrupt")):
            code, _ = self.http("POST", "/api/cards/1/execution/pause",
                                {"request_id": "internal", "expected_revision": 0})
        self.assertIn(code, (500, 503), "internal error classified from message text as conflict")

    def test_card_log_references_are_real_validated_and_redacted(self):
        self.start_service()
        self.start_web()
        store = self.service.store
        store.start_session({"id": "s1", "started_at": 1, "deadline": 1000, "known_spend": 0,
                             "unknown_spend": False, "budget_stop": None})
        job = {"id": "job-1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "a" * 64, "input_version": "v1", "generation": 1,
               "provider": "fixture", "model": "fixture", "nonce": "attempt-web", "session_id": "s1"}
        store.prepare_attempt(job, store.snapshot()["domain"]["revision"],
                              {"global_cap": 4, "provider_cap": 4, "paths": ["src/card-1"]})
        attempt_id = store.snapshot()["attempts"][0]["id"]
        logs = store.directory / "artifacts" / attempt_id / "worker.log"
        logs.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        logs.write_text("token=ghp_abcdefghijklmnopqrstuvwxyz012345\n" + str(self.repo) + "\n", encoding="utf-8")
        code, result = self.http("GET", "/api/cards/1/execution")
        self.assertEqual(code, 200)
        refs = result.get("logs", [])
        self.assertTrue(refs, "attempt log reference not returned")
        for bad in ("../worker.log", str(logs), "..%2fworker.log", "%2fetc%2fpasswd", "bad%00id"):
            # The future validated log endpoint must reject these IDs. Until it is routed,
            # this request must remain an ordinary 404, never a filesystem read.
            status, body = self.http("GET", "/api/cards/1/execution/log/" + bad)
            self.assertIn(status, (400, 404), "%r was accepted: %r" % (bad, body))
        log_id = refs[0]["id"]
        status, body = self.http("GET", "/api/cards/1/execution/log/" + log_id)
        self.assertEqual(status, 200)
        rendered = json.dumps(body)
        self.assertNotIn("ghp_", rendered)
        self.assertNotIn(str(self.repo), rendered)

    def test_status_last_known_cache_is_thread_safe_and_bounded(self):
        from supervisor import webproxy
        webproxy._LAST.clear()
        for i in range(512):
            webproxy.remember("domain-%d" % i, {"phase": "running"})
        self.assertLessEqual(len(webproxy._LAST), 128, "per-domain status cache is unbounded")
        errors = []
        def reader():
            for i in range(2000):
                value = webproxy.last("flapping-domain")
                if value is not None and (not isinstance(value[0], float) or not isinstance(value[1], dict)):
                    errors.append(value)
        import threading
        threads = [threading.Thread(target=reader) for _ in range(8)]
        for thread in threads: thread.start()
        for i in range(2000): webproxy.remember("flapping-domain", {"revision": i})
        for thread in threads: thread.join()
        self.assertFalse(errors)


if __name__ == "__main__":
    unittest.main(verbosity=2)

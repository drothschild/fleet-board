"""HTTP-to-supervisor proxy contract cases: the board server in front of the supervisor socket."""
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
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

from supervisor import paths
from supervisor.service import Service
from stub_handler import StubHandler
from supervisor.state import State


def short_tmp():
    path = Path(tempfile.mkdtemp(prefix="fbw-", dir=os.path.realpath("/tmp")))
    os.chmod(path, 0o700)
    return path


class SupervisorWebContract(unittest.TestCase):

    def setUp(self):
        self.case = ROOT / self.id().rsplit(".", 1)[-1]
        self.case.mkdir(mode=0o700)
        self.tmp_socket = short_tmp()
        self.addCleanup(shutil.rmtree, str(self.tmp_socket), True)
        self.repo = self.case / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        (self.repo / ".fleet-board.yml").write_text(
            "board:\n  repo: acme/toy\n", encoding="utf-8")
        (self.repo / ".fleet-board").mkdir()
        (self.repo / ".fleet-board" / "cards").mkdir()
        (self.repo / ".fleet-board" / "next").write_text("1\n", encoding="utf-8")
        self.config = self.repo / ".fleet-board.yml"
        # The default socket location: a private base, the service, the CLI and the web server all derive it.
        self.socket_base = self.tmp_socket / "base"
        self.socket_base.mkdir()
        os.chmod(str(self.socket_base), 0o700)
        patcher = mock.patch.dict(os.environ, {"FLEET_BOARD_SOCKET_DIR": str(self.socket_base),
                                               "FLEET_BOARD_LOG_DIR": str(self.case / "logs")})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.env = dict(os.environ, FLEET_BOARD_CONFIG=str(self.config),
                        TMPDIR=str(self.tmp_socket), PYTHONDONTWRITEBYTECODE="1",
                        PYTHONPATH=str(SCRIPTS), FLEET_BOARD_USER="web-test")
        self.env.pop("FLEET_BOARD_SUPERVISOR_SOCKET", None)
        self.service = None
        self.state = None
        self.handler = None
        self.server = None
        self.port = None
        self.addCleanup(self.stop_all)

    def start_service(self, root=None):
        root = root or self.repo
        self.state = State("web-run", time.time)
        self.handler = StubHandler(self.state)
        self.service = Service(root, self.state, self.handler, run_lock_path=str(self.case / "run.lock"),
                               peer_resolver=lambda _peer: "fixture-human")
        try:
            ack = self.service.serve()
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

    def http(self, method, path, body=None, *, token=True, host=None, timeout=3):
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
            with urlopen(request, timeout=timeout) as response:
                return response.status, json.loads(response.read() or b"{}")
        except HTTPError as exc:
            return exc.code, json.loads(exc.read() or b"{}")

    def test_supervisor_routes_with_no_supervisor(self):
        self.start_web()
        code, payload = self.http("GET", "/api/run")
        self.assertEqual(code, 200)
        self.assertIn("state", payload)
        code, payload = self.http("GET", "/api/supervisor")
        self.assertEqual(code, 200, payload)
        self.assertIs(payload["running"], False)
        self.assertIsNone(payload["run"])
        self.assertIn("all_time", payload)
        self.assertIn("planner", payload)
        for action in ("pause", "resume", "stop"):
            code, body = self.http("POST", "/api/supervisor/" + action, {"request_id": "r", "expected_revision": 0})
            self.assertEqual((code, body.get("code")), (409, "not_running"), action)
        self.assertFalse(self.socket_exists(), "a request launched or created a supervisor")
        self.assertEqual([x for x in self.logs_tree() if "supervisor" in x], [], "a request created supervisor state")

    def test_routes_of_removed_service_commands_are_gone(self):
        self.start_service()
        self.start_web()
        for method, path in (("GET", "/api/supervisor/events"), ("GET", "/api/cards/1/execution"),
                             ("GET", "/api/cards/1/execution/log/abc")):
            self.assertEqual(self.http(method, path)[0], 404, "%s %s" % (method, path))
        for action in ("pause", "resume", "resolve", "release-reservations"):
            code, _ = self.http("POST", "/api/cards/1/execution/" + action, {"request_id": "r", "expected_revision": 0})
            self.assertEqual(code, 404, action)

    def test_supervisor_routes_answer_when_a_supervisor_socket_answers(self):
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

    def test_compat_run_routes_enforce_a_supplied_binding_exactly_like_the_new_routes(self):
        self.start_service()
        self.start_web()
        revision = self.service.status_view()["revision"]
        body = {"request_id": "compat-bound-start", "expected_revision": revision}
        code, first = self.http("POST", "/api/run/start", body)
        self.assertIn(code, (200, 202))
        self.assertNotIn("unbound", first, "a bound request must not be labelled unbound")
        # A stale binding conflicts and carries the current state; nothing is applied.
        code, paused = self.http("POST", "/api/supervisor/pause", {"request_id": "bump", "expected_revision": revision})
        self.assertEqual(code, 202, paused)
        after = self.service.status_view()
        code, stale = self.http("POST", "/api/run/stop", {"request_id": "compat-stale-stop", "expected_revision": revision})
        self.assertEqual(code, 409, stale)
        self.assertIn("current", stale)
        self.assertEqual(stale["current"]["revision"], after["revision"])
        self.assertEqual(self.service.status_view(), after)
        self.assertFalse(self.handler.stop_requested.is_set(), "a stale compat stop stopped the supervisor")
        # Half a binding, or a forged actor, is refused like on the new routes.
        for bad in ({"request_id": "only-id"}, {"expected_revision": revision}, {"request_id": "x", "expected_revision": "7"},
                    {"request_id": "a", "expected_revision": revision, "actor": "forged"}):
            with self.subTest(bad=bad):
                code, _ = self.http("POST", "/api/run/stop", bad)
                self.assertEqual(code, 400)
        self.assertEqual(self.service.status_view(), after)

    def test_compat_run_routes_without_a_body_derive_their_own_binding_and_say_unbound(self):
        self.start_service()
        self.start_web()
        code, payload = self.http("POST", "/api/run/start")
        self.assertIn(code, (200, 202))
        self.assertIs(payload.get("unbound"), True)
        code, payload = self.http("POST", "/api/run/start")  # idempotent by design
        self.assertIn(code, (200, 202))
        self.assertIs(payload.get("unbound"), True)
        code, payload = self.http("POST", "/api/run/stop")
        self.assertIn(code, (200, 202))
        self.assertIs(payload.get("unbound"), True)
        self.assertEqual(self.handler.stop_mode, "drain")

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
        ]
        for path, complete in mutations:
            for field in ("request_id", "expected_revision"):
                with self.subTest(path=path, missing=field):
                    before = self.service.status_view()
                    incomplete = dict(complete)
                    incomplete.pop(field)
                    code, _ = self.http("POST", path, incomplete)
                    self.assertEqual(code, 400, "missing %s accepted by %s" % (field, path))
                    self.assertEqual(self.service.status_view(), before)
        self.assertFalse(self.handler.stop_requested.is_set())

    def test_mutation_retry_deduplicates_and_stale_revision_returns_current_without_reapply(self):
        self.start_service()
        self.start_web()
        initial = self.service.status_view()
        request = {"request_id": "retry-pause", "expected_revision": initial["revision"]}
        first_code, first = self.http("POST", "/api/supervisor/pause", request)
        after_first = self.service.status_view()
        second_code, second = self.http("POST", "/api/supervisor/pause", request)
        self.assertIn(first_code, (200, 202))
        self.assertEqual(second_code, first_code)
        self.assertEqual(second, first, "same request_id must return its original outcome")
        self.assertEqual(self.service.status_view(), after_first)
        stale = dict(request, request_id="stale-pause", expected_revision=initial["revision"] - 1)
        stale_code, stale_body = self.http("POST", "/api/supervisor/pause", stale)
        self.assertEqual(stale_code, 409)
        self.assertIn("current", stale_body)
        self.assertEqual(self.service.status_view(), after_first)

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

    def test_default_socket_location_is_shared_by_service_cli_and_web(self):
        # No FLEET_BOARD_SUPERVISOR_SOCKET override: the three components derive the same location.
        self.start_service()
        self.assertLess(len(self.service.socket_path), 100, "AF_UNIX path must stay short")
        self.start_web()
        code, payload = self.http("GET", "/api/supervisor")
        self.assertEqual(code, 200)
        self.assertFalse(payload.get("unreachable"),
                         "board-web could not find the service at its default socket: %r" % (payload,))
        from io import StringIO
        from supervisor.cli import main
        out, err = StringIO(), StringIO()
        status = main(["status", "--json"], env={"FLEET_BOARD_DOMAIN": str(self.repo),
                                                 "FLEET_BOARD_SOCKET_DIR": str(self.socket_base)}, stdout=out, stderr=err)
        self.assertEqual(status, 0, err.getvalue())
        self.assertEqual(json.loads(out.getvalue())["pid"], os.getpid())

    # --- Start launches a missing supervisor; Stop never strands the board ---------------

    def launching_world(self):
        """Board server with the default socket location: the launched supervisor lives where
        every component derives it on its own."""
        self.addCleanup(self.reap_launched)

    def reap_launched(self):
        env = dict(self.env, FLEET_BOARD_DOMAIN=str(self.repo))
        try:
            subprocess.run([str(SCRIPTS / "supervisor.sh"), "stop", "--cancel"], env=env,
                           capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            pass

    def skip_if_sandboxed(self, code, payload):
        text = json.dumps(payload).lower()
        if code == 503 and ("operation not permitted" in text or "socket" in text):
            self.skipTest("sandbox denies the real service: %s" % text[:200])

    def wait_until(self, probe, seconds=8.0):
        deadline = time.time() + seconds
        while time.time() < deadline:
            value = probe()
            if value:
                return value
            time.sleep(0.1)
        return probe()

    def test_a_supervisor_that_exits_turns_the_board_back_to_the_run_api(self):
        self.start_service()
        self.start_web()
        self.assertEqual(self.http("GET", "/api/supervisor")[0], 200)
        self.service.close()
        code, payload = self.http("GET", "/api/supervisor")
        self.assertEqual((code, payload.get("running")), (200, False))
        code, run = self.http("GET", "/api/run")
        self.assertEqual(code, 200)
        self.assertNotIn("supervisor", run)

    def test_start_waits_for_a_stopping_supervisor_to_go_then_launches_a_new_one(self):
        self.launching_world()
        self.start_service()
        self.start_web()
        old = os.getpid()
        self.state.mode = "stopping"
        threading.Timer(0.6, self.service.close).start()
        code, started = self.http("POST", "/api/supervisor/start", {"request_id": "again-1", "expected_revision": 0}, timeout=20)
        self.skip_if_sandboxed(code, started)
        self.assertEqual(code, 202, started)
        self.assertIs(started.get("launched"), True, "Start reported a stopping supervisor as running")
        code, status = self.http("GET", "/api/supervisor")
        self.assertEqual(code, 200, status)
        self.assertNotEqual(status["pid"], old, "Start must launch a new supervisor, not reuse the exiting one")
        self.assertEqual(status["mode"], "running")

    def test_start_launches_the_supervisor_with_no_tick_wrapper_present(self):
        self.assertFalse((SCRIPTS / "fleet-board-run.sh").exists(), "the tick wrapper is still shipped")
        self.launching_world()
        self.env.pop("FLEET_BOARD_RUN", None)
        self.start_web()
        for method, path in (("GET", "/api/run"), ("POST", "/api/run/start"), ("POST", "/api/run/stop")):
            self.assertEqual(self.http(method, path)[0], 404, "%s %s is still routed" % (method, path))
        code, started = self.http("POST", "/api/supervisor/start", {"request_id": "nowrap-1", "expected_revision": 0},
                                  timeout=20)
        self.skip_if_sandboxed(code, started)
        self.assertEqual(code, 202, started)
        self.assertIs(started.get("launched"), True, "Start did not launch a supervisor")
        code, status = self.http("GET", "/api/supervisor")
        self.assertEqual((code, status.get("running")), (200, True), status)
        self.assertFalse((self.repo / ".fleet-board.stop").exists(), "Start wrote the tick-stop file")

    def test_start_never_launches_beside_a_supervisor_that_stays_stopping(self):
        self.launching_world()
        self.start_service()
        self.start_web()
        self.state.mode = "stopping"
        code, refused = self.http("POST", "/api/supervisor/start", {"request_id": "again-2", "expected_revision": 0}, timeout=20)
        self.assertEqual(code, 503, refused)
        self.assertRegex(refused["error"], r"(?i)stopping")
        self.assertNotIn("launched", refused)

    def test_start_on_a_running_supervisor_launches_nothing(self):
        self.start_service()
        self.start_web()
        code, started = self.http("POST", "/api/supervisor/start", {"request_id": "run-1", "expected_revision": 0})
        self.assertEqual(code, 202, started)
        self.assertNotIn("launched", started)

    def logs_tree(self):
        logs = self.case / "logs"
        return sorted(str(p.relative_to(logs)) for p in logs.rglob("*")) if logs.exists() else []

    def test_reads_create_no_supervisor_state_when_no_service_ran(self):
        self.start_web()
        for path, want in (("/api/board", 200), ("/api/supervisor", 200), ("/api/run", 200),
                           ("/api/board", 200), ("/api/supervisor", 200), ("/api/usage", 200)):
            code, _ = self.http("GET", path)
            self.assertEqual(code, want, path)
        tree = self.logs_tree()
        self.assertFalse([x for x in tree if "supervisor" in x or x.endswith(".sqlite3")],
                         "a GET created supervisor state on disk: %r" % (tree,))

    def test_a_broken_runtime_location_can_never_turn_api_board_into_a_500(self):
        # A symlink in the log directory path made the old per-request store open raise.
        real = self.case / "real-logs"
        real.mkdir(mode=0o700)
        link = self.case / "link-logs"
        link.symlink_to(real)
        self.env["FLEET_BOARD_LOG_DIR"] = str(link)
        self.start_web()
        for path in ("/api/board", "/api/supervisor", "/api/run"):
            code, _ = self.http("GET", path)
            self.assertEqual(code, 200,
                             "%s answered %s with a broken runtime location" % (path, code))

    def test_linked_worktree_board_finds_its_service_at_the_default_socket(self):
        git = ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-C", str(self.repo)]
        subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "init"], check=True)
        worktree = self.case / "linked"
        subprocess.run(git + ["worktree", "add", "-q", "-b", "wt", str(worktree)], check=True)
        worktree = worktree.resolve()
        self.assertTrue((worktree / ".git").is_file(), "fixture must be a linked worktree")
        self.start_service(root=worktree)
        (worktree / ".fleet-board").mkdir()
        (worktree / ".fleet-board" / "cards").mkdir()
        (worktree / ".fleet-board" / "next").write_text("1\n", encoding="utf-8")
        self.repo = worktree
        self.start_web()
        code, _ = self.http("GET", "/api/board")
        self.assertEqual(code, 200)
        code, payload = self.http("GET", "/api/supervisor")
        self.assertEqual(code, 200, payload)
        self.assertFalse(payload.get("unreachable"), "linked worktree board cannot find its service: %r" % (payload,))

    def test_every_error_code_survives_the_socket_and_maps_to_its_own_http_status(self):
        self.start_service()
        self.start_web()
        revision = self.service.status_view()["revision"]
        # stale revision: 409 with the current state
        code, body = self.http("POST", "/api/supervisor/pause", {"request_id": "e-stale", "expected_revision": revision - 1})
        self.assertEqual((code, body.get("code")), (409, "stale_revision")); self.assertIn("current", body)
        self.assertEqual(body["current"]["phase"], "running", "the conflict body must be a page-readable status")
        # invalid: 400
        code, body = self.http("POST", "/api/supervisor/stop", {"request_id": "e-invalid", "expected_revision": revision, "mode": "bogus"})
        self.assertEqual((code, body.get("code")), (400, "invalid"))
        # unauthenticated: a refused peer is not an outage
        self.service.peer_resolver = lambda _peer: (_ for _ in ()).throw(PermissionError("peer credentials unavailable"))
        code, body = self.http("GET", "/api/supervisor")
        self.assertEqual((code, body.get("code")), (403, "unauthenticated"), body)
        self.service.peer_resolver = lambda _peer: "fixture-human"
        # unavailable: 503
        with mock.patch.object(self.service, "_handle_request", side_effect=TimeoutError("controller request timed out")):
            code, body = self.http("POST", "/api/supervisor/pause", {"request_id": "e-unavail", "expected_revision": revision})
        self.assertEqual((code, body.get("code")), (503, "unavailable"))
        # internal: 500 with a redacted message
        with mock.patch.object(self.service, "_handle_request", side_effect=RuntimeError("boom at /secret/runtime/state failed")):
            code, body = self.http("POST", "/api/supervisor/pause", {"request_id": "e-internal", "expected_revision": revision})
        self.assertEqual(code, 500)
        self.assertNotIn("/secret", json.dumps(body))
        self.assertEqual(body.get("code"), "internal")

    def test_a_value_error_mentioning_unavailable_or_revision_is_not_misclassified(self):
        self.start_service()
        self.start_web()
        revision = self.service.status_view()["revision"]
        for text in ("evidence unavailable", "revision mismatch in the evidence", "uncertain writer notes"):
            with self.subTest(text=text), mock.patch.object(self.service, "_handle_request", side_effect=ValueError(text)):
                code, body = self.http("POST", "/api/supervisor/pause", {"request_id": "m-" + text[:4], "expected_revision": revision})
                self.assertEqual((code, body.get("code")), (400, "invalid"))
        code, snapshot = self.http("GET", "/api/supervisor")
        self.assertNotEqual(code, 503)
        self.assertFalse(snapshot.get("unreachable"), "a ValueError flipped the board to stale")

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

    def test_the_webproxy_keeps_no_last_known_state(self):
        from supervisor import webproxy
        for name in ("remember", "last", "_LAST"):
            self.assertFalse(hasattr(webproxy, name), "webproxy.%s is dead state" % name)
        source = (SCRIPTS / "board-web.py").read_text(encoding="utf-8")
        self.assertNotIn("last_known", source)
        self.assertNotIn("remember_stopped", source)

    def test_run_compatibility_projects_the_supervisor_mode(self):
        self.start_service()
        self.start_web()
        code, payload = self.http("GET", "/api/run")
        self.assertEqual(code, 200)
        self.assertEqual(payload.get("state"), "running", "a serving supervisor in running mode is running")
        self.state.pause("provider down")
        code, payload = self.http("GET", "/api/run")
        self.assertEqual(payload.get("state"), "paused")
        code, response = self.http("POST", "/api/run/start")
        self.assertIn(code, (200, 202), "compatibility Start did not delegate")
        self.assertNotIn("pid", response, "supervisor projection leaked legacy PID semantics")

    def launched_pid(self):
        code, payload = self.http("GET", "/api/supervisor")
        return payload.get("pid") if payload.get("running") is not False else None

    def pid_alive(self, pid):
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        return True

    def socket_exists(self):
        return os.path.exists(paths.controller_socket(paths.domain_id_for_root(self.repo)))

    def test_domain_id_is_a_pure_function_the_service_uses_too(self):
        source = (SCRIPTS / "board-web.py").read_text(encoding="utf-8")
        self.assertNotIn("supervisor.store", source, "board-web must never open supervisor state")
        runtime = self.case / "pure-runtime"
        domain = {"common_dir": str(self.repo / ".git"), "board_backend": "local",
                  "board_identity": str(self.repo.resolve()), "runtime_root": str(runtime)}
        digest = paths.domain_id(domain)
        self.assertEqual(len(digest), 64)
        self.assertFalse(runtime.exists(), "computing a domain id created files")
        self.assertEqual(paths.domain_id_for_root(self.repo), digest)
        service = Service(self.repo, State("r", time.time), StubHandler(State("r", time.time)),
                          run_lock_path=str(self.case / "pure.lock"))
        self.assertEqual(service.domain_id, digest, "the service and the pure function disagree on the domain id")
        self.assertFalse(Path(service.socket_dir).exists(), "building a Service created its socket directory")

    def test_the_default_runtime_root_is_shared(self):
        home = self.case / "home"
        home.mkdir(mode=0o700)
        with mock.patch.dict(os.environ, {"HOME": str(home)}):
            os.environ.pop("FLEET_BOARD_LOG_DIR", None)
            expected = Path(os.path.expanduser("~")) / ".fleet-board" / "runs" / "supervisor"
            self.assertEqual(paths.runtime_root(), expected)
            self.assertEqual(paths.runtime_root({}), expected)
            self.assertEqual(paths.runtime_root({"FLEET_BOARD_LOG_DIR": "/x/logs"}), Path("/x/logs/supervisor"))

    def test_api_supervisor_returns_the_v2_status_with_the_page_projection(self):
        self.start_service()
        from supervisor.state import Action
        self.state.begin(Action(card=3, action="review", column="in_review", role="reviewer", provider="claude",
                                paths=["src/a"], started_at=1.0, started_mono=2.0))
        self.start_web()
        code, payload = self.http("GET", "/api/supervisor")
        self.assertEqual(code, 200)
        self.assertFalse(payload.get("unreachable"))
        self.assertEqual(payload["schema_version"], 2)
        self.assertEqual(payload["pid"], os.getpid())
        self.assertEqual(payload["root"], os.path.realpath(str(self.repo)))
        self.assertEqual((payload["mode"], payload["desired_mode"], payload["phase"]), ("running",) * 3)
        self.assertIs(payload["ready"], True)
        self.assertEqual([a["card"] for a in payload["active"]], [3])
        self.assertEqual(payload["capacity"], {"slots": 1, "global_cap": None, "per_provider": {"claude": 1}})
        self.assertEqual(payload["queue"], {"ready": None, "running": 1, "waiting": None, "attention": None})
        for gone in ("session", "boot_registration", "known_spend", "host_boot_id", "heartbeat", "claims", "config"):
            self.assertNotIn(gone, payload)

    # --- Task 6.1: usage, stuck, activity, Start semantics --------------------------------------

    def ledger_line(self, **kw):
        base = {"run_id": "web-run", "card": 3, "kind": "card", "column": "ready", "action": "start",
                "role": "implementor", "provider": "claude", "model": "sonnet", "input": 10, "output": 5,
                "cache_write": 2, "cache_read": 1, "started_at": "2026-11-11T10:00:00Z",
                "ended_at": "2026-11-11T10:01:00Z", "log": "/x.jsonl"}
        base.update(kw)
        return base

    def write_ledger(self, *lines):
        from supervisor import usage
        for line in lines:
            usage.append(self.repo, line)

    def write_card(self, n, state="in_review"):
        (self.repo / ".fleet-board" / "cards" / ("%d.json" % n)).write_text(json.dumps(
            {"number": n, "title": "card %d" % n, "state": state, "labels": [], "body": "",
             "updated_at": "2026-11-11T10:00:00Z"}), encoding="utf-8")

    def active_marker(self, n):
        active = self.repo / ".fleet-board" / "active"
        active.mkdir(exist_ok=True)
        (active / str(n)).write_text("")

    def load_board_module(self, name):
        import importlib.util
        spec = importlib.util.spec_from_file_location(name, str(SCRIPTS / "board-web.py"))
        board = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(board)
        board.APP["root"] = str(self.repo)
        return board

    def test_usage_route_works_with_no_supervisor(self):
        self.write_ledger(self.ledger_line(), self.ledger_line(card=None, kind="planner", input=7, output=1,
                                                               cache_write=0, cache_read=0),
                          self.ledger_line(card=4, input=None))
        self.start_web()
        code, body = self.http("GET", "/api/usage")
        self.assertEqual(code, 200, body)
        self.assertIsNone(body["run"], "no supervisor, no run total")
        self.assertEqual(body["all_time"]["input"], 10)
        self.assertEqual(body["all_time"]["unknown"], 1)
        self.assertIs(body["all_time"]["partial"], True)
        self.assertEqual(body["planner"]["total"], 8)
        code, body = self.http("GET", "/api/cards/3/usage")
        self.assertEqual(code, 200, body)
        self.assertEqual(body["card"], 3)
        self.assertEqual(body["totals"]["total"], 18)
        code, body = self.http("GET", "/api/cards/4/usage")
        self.assertEqual(body["totals"]["unknown"], 1, "an unreadable count must stay unknown, not 0")
        self.assertEqual(self.http("GET", "/api/supervisor")[1]["all_time"]["input"], 10)

    def test_usage_route_carries_per_column_totals(self):
        self.write_ledger(self.ledger_line(column="in_progress"),
                          self.ledger_line(card=4, column="in_progress", input=100),
                          self.ledger_line(column="review_security", input=None),
                          self.ledger_line(card=None, kind="planner", column="in_progress", input=7000))
        self.start_web()
        code, body = self.http("GET", "/api/usage")
        self.assertEqual(code, 200, body)
        cols = body["columns"]
        self.assertEqual(sorted(cols), ["in_progress", "review_security"])
        self.assertEqual(cols["in_progress"]["input"], 110, "the planner line leaked into a column")
        self.assertIs(cols["in_progress"]["partial"], False)
        self.assertEqual(cols["review_security"]["unknown"], 1)
        self.assertIs(cols["review_security"]["partial"], True)
        self.assertEqual(self.http("GET", "/api/supervisor")[1]["columns"]["in_progress"]["input"], 110)

    def test_the_columns_come_from_the_one_cached_ledger_read(self):
        board = self.load_board_module("board_web_usage_columns")
        board.APP["scripts"] = str(SCRIPTS)
        self.write_ledger(self.ledger_line(column="in_progress"))
        real = board.supervisor_usage.read
        calls = []

        def counting(*a, **k):
            calls.append(1)
            return real(*a, **k)
        with mock.patch.object(board.supervisor_usage, "read", counting):
            first = board.usage_view()
            again = board.usage_view()
        self.assertEqual(len(calls), 1, "the ledger was read more than once for the totals and the columns")
        self.assertEqual(first["columns"]["in_progress"]["input"], 10)
        self.assertEqual(first, again)

    def test_usage_route_reports_this_run_while_a_supervisor_runs(self):
        self.write_ledger(self.ledger_line(), self.ledger_line(run_id="older", input=100))
        self.start_service()
        self.start_web()
        code, body = self.http("GET", "/api/usage")
        self.assertEqual(code, 200, body)
        self.assertEqual(body["run"]["input"], 10)
        self.assertEqual(body["all_time"]["input"], 110)

    def test_a_damaged_ledger_marks_totals_partial(self):
        self.write_ledger(self.ledger_line())
        with open(str(self.repo / ".fleet-board" / "usage.jsonl"), "a") as handle:
            handle.write("{not json\n")
        self.start_web()
        code, body = self.http("GET", "/api/usage")
        self.assertEqual(code, 200)
        self.assertIs(body["all_time"]["partial"], True)

    def stuck_settled(self, seconds=20.0):
        """GET /api/stuck until the background check has produced a result; returns the body."""
        deadline = time.time() + seconds
        while True:
            code, body = self.http("GET", "/api/stuck")
            self.assertEqual(code, 200, body)
            if not body["checking"] or time.time() > deadline:
                return body
            time.sleep(0.1)

    def test_stuck_route_works_with_no_supervisor(self):
        self.write_card(3)
        self.active_marker(3)
        self.start_web()
        body = self.stuck_settled()
        self.assertEqual([(x["card"], x["kind"]) for x in body["findings"]], [(3, "marker")])
        self.assertIn("detail", body["findings"][0])
        self.assertIsNone(body["error"])
        self.assertIsInstance(body["checked_at"], float)
        code, board = self.http("GET", "/api/board")
        by_number = {c["number"]: c for c in board["cards"]}
        self.assertEqual(by_number[3]["stuck"]["kind"], "marker")
        self.assertIn("detail", by_number[3]["stuck"])
        self.assertIsNone(by_number[3]["activity"])
        self.assertIsNone(board["run"]["stuck_error"])
        self.assertIsInstance(board["run"]["stuck_checked_at"], float)
        self.assertIs(board["run"]["stuck_known"], True)

    def test_while_a_supervisor_runs_the_board_shows_no_stuck_card_and_never_runs_find(self):
        # The loop's `stuck` handler runs find() on demand (it keeps no cached list), so while a supervisor
        # answers the board shows no stuck card at all: cards waiting for a slot, a reconcile or a resume
        # are healthy, and the board never runs find() itself nor asks the loop.
        from supervisor.state import Action
        self.write_card(3)
        self.write_card(5)
        self.write_card(7, state="in_progress")   # waiting for a slot: no action, no marker
        self.active_marker(3)
        self.active_marker(5)
        self.start_service()
        commands = []
        inner = self.service.handler

        def recording(command):
            commands.append(command.get("command"))
            return inner(command)
        self.service.handler = recording
        self.state.begin(Action(card=3, action="review", column="in_review", role="reviewer", provider="claude",
                                paths=[], started_at=time.time() - 12, started_mono=0.0))
        self.start_web()
        code, body = self.http("GET", "/api/stuck")
        self.assertEqual(code, 200, body)
        self.assertEqual(body["findings"], [])
        self.assertIs(body["checking"], False)
        time.sleep(1.0)   # a background find() would have reported card 5 or 7 by now
        code, board = self.http("GET", "/api/board")
        self.assertEqual(code, 200)
        by_number = {c["number"]: c for c in board["cards"]}
        for n in (3, 5, 7):
            self.assertIsNone(by_number[n]["stuck"], "card %d marked stuck while a supervisor runs" % n)
        self.assertIs(board["run"]["stuck_checking"], False)
        self.assertEqual(by_number[3]["activity"]["action"], "review")
        self.assertGreaterEqual(by_number[3]["activity"]["elapsed_seconds"], 12)
        self.assertLess(by_number[3]["activity"]["elapsed_seconds"], 60)
        self.assertIsNone(by_number[5]["activity"])
        self.assertNotIn("stuck", commands, "the board asked the supervisor loop to run find()")

    def test_the_board_never_runs_find_while_a_supervisor_answers(self):
        board = self.load_board_module("board_web_running")
        calls = []
        with mock.patch.object(board.supervisor_stuck, "find", lambda *a, **k: calls.append(1) or []):
            view = board.stuck_view({"schema_version": 2, "mode": "running", "active": []})
            time.sleep(0.3)
        self.assertEqual(calls, [], "find() ran while a supervisor answers")
        self.assertEqual(view["findings"], [])
        self.assertIs(view["checking"], False)
        self.assertIs(view["known"], True)

    def test_a_changed_board_is_rechecked_at_once_and_an_unchanged_one_waits_for_the_interval(self):
        self.write_card(3)
        self.active_marker(3)
        self.start_web()
        first = self.stuck_settled()
        self.assertEqual(len(first["findings"]), 1)
        again = self.http("GET", "/api/stuck")[1]
        self.assertEqual(again["checked_at"], first["checked_at"], "an unchanged board was rescanned inside the interval")
        (self.repo / ".fleet-board" / "active" / "3").unlink()   # what `stuck --release 3` does to the markers
        deadline = time.time() + 10   # far below the 30 s interval: only the mtime change can refresh it
        while time.time() < deadline:
            body = self.http("GET", "/api/stuck")[1]
            if body["findings"] == [] and not body["checking"]:
                break
            time.sleep(0.2)
        self.assertEqual(body["findings"], [], "a released card stayed stuck until the interval")
        self.assertEqual(self.http("GET", "/api/board")[1]["cards"][0]["stuck"], None)

    def test_the_refresh_interval_is_the_longer_of_30_seconds_and_twice_the_last_scan(self):
        board = self.load_board_module("board_web_interval")
        board._STUCK["duration"] = 0.5
        self.assertEqual(board.stuck_interval(), 30.0)
        board._STUCK["duration"] = 20.0
        self.assertEqual(board.stuck_interval(), 40.0)

    def test_stuck_refresh_runs_on_demand_and_only_when_due(self):
        board = self.load_board_module("board_web_due")
        calls = []
        board_dir = self.repo / ".fleet-board"

        def counting(*_a, **_k):
            calls.append(1)
            return []

        def settle():
            deadline = time.time() + 5
            while board._STUCK["running"] and time.time() < deadline:
                time.sleep(0.02)
        with mock.patch.object(board.supervisor_stuck, "find", counting):
            # a hidden tab's poll never starts one, even with no result yet
            view = board.stuck_state(board_dir, refresh=False)
            time.sleep(0.2)
            self.assertEqual(calls, [], "a poll that asked for no refresh started one")
            self.assertIsNone(view["findings"])
            self.assertIs(view["known"], False)
            # a page-initiated launch in flight: no refresh starts
            with board._LAUNCH_LOCK:
                board.stuck_state(board_dir)
                time.sleep(0.2)
            self.assertEqual(calls, [], "a refresh started while a page launch was in flight")
            board.stuck_state(board_dir)
            settle()
            self.assertEqual(len(calls), 1)
            board.stuck_state(board_dir)
            settle()
            self.assertEqual(len(calls), 1, "an unchanged board was rescanned inside the interval")
            self.active_marker(9)   # the active markers directory appears: its mtime changed
            board.stuck_state(board_dir)
            settle()
            self.assertEqual(len(calls), 2, "a changed markers directory was not rechecked")
            self.write_card(11)
            os.utime(str(board_dir / "cards"), ns=(1, 1))   # a cards directory mtime that is surely different
            board.stuck_state(board_dir)
            settle()
            self.assertEqual(len(calls), 3, "a changed cards directory was not rechecked")
            board._STUCK["mono"] -= 31   # the interval passes
            board.stuck_state(board_dir)
            settle()
            self.assertEqual(len(calls), 4, "an expired result was not refreshed")
            self.assertIs(board.stuck_state(board_dir, refresh=False)["known"], True)

    def test_an_error_before_any_result_is_not_a_result(self):
        board = self.load_board_module("board_web_error_first")

        def broken(*_a, **_k):
            raise ValueError("boom")
        with mock.patch.object(board.supervisor_stuck, "find", broken):
            board.stuck_state(None)
            deadline = time.time() + 5
            while board.stuck_state(None, refresh=False)["checking"] and time.time() < deadline:
                time.sleep(0.05)
            state = board.stuck_state(None, refresh=False)
        self.assertIn("boom", state["error"])
        self.assertIsNone(state["findings"])
        self.assertIs(state["known"], False)

    def test_the_board_poll_can_ask_for_no_stuck_refresh(self):
        self.write_card(3)
        self.active_marker(3)
        self.start_web()
        code, board = self.http("GET", "/api/board?refresh_stuck=0")
        self.assertEqual(code, 200, board)
        time.sleep(1.0)
        code, body = self.http("GET", "/api/stuck?refresh_stuck=0")
        self.assertIsNone(body["checked_at"], "a no-refresh poll started a stuck check")
        self.assertIs(body["known"], False)
        self.assertIs(board["run"]["stuck_known"], False)
        body = self.stuck_settled()   # a visible poll does start it
        self.assertEqual(len(body["findings"]), 1)
        self.assertIs(self.http("GET", "/api/board")[1]["run"]["stuck_known"], True)

    def test_ui_status_is_ready_only_once_the_startup_check_is_done(self):
        from supervisor import webproxy
        base = {"schema_version": 2, "mode": "running", "active": []}
        self.assertIs(webproxy.ui_status(dict(base, startup="done"))["ready"], True)
        self.assertIs(webproxy.ui_status(dict(base, startup="checking"))["ready"], False)
        self.assertIs(webproxy.ui_status(dict(base))["ready"], False)

    def test_the_not_running_usage_view_is_cached_on_the_ledger_size_and_mtime(self):
        board = self.load_board_module("board_web_usage_cache")
        board.APP["scripts"] = str(SCRIPTS)
        self.write_ledger(self.ledger_line())
        real = board.supervisor_usage.view
        calls = []

        def counting(*a, **k):
            calls.append(1)
            return real(*a, **k)
        with mock.patch.object(board.supervisor_usage, "view", counting):
            first = board.usage_view()
            again = board.usage_view()
            self.assertEqual(len(calls), 1, "an unchanged ledger was parsed again")
            self.assertEqual(first, again)
            self.write_ledger(self.ledger_line(input=90))
            third = board.usage_view()
            self.assertEqual(len(calls), 2, "a grown ledger was not parsed again")
            self.assertEqual(third["all_time"]["input"], 100)
            board.usage_view(card=3)
            self.assertEqual(len(calls), 3, "a card drill-down reused the summary")

    def test_find_never_runs_on_a_request_thread(self):
        board = self.load_board_module("board_web_slow")
        release = threading.Event()
        calls = []

        def slow_find(root, live_cards=frozenset(), **_k):
            calls.append(threading.current_thread())
            release.wait(10)
            return []
        with mock.patch.object(board.supervisor_stuck, "find", slow_find):
            began = time.time()
            first = board.stuck_state(None)
            second = board.stuck_state(None)
            self.assertLess(time.time() - began, 1.0, "a request waited for find()")
            self.assertIsNone(first["findings"])
            self.assertIs(first["checking"], True)
            self.assertIs(second["checking"], True)
            deadline = time.time() + 5
            while not calls and time.time() < deadline:
                time.sleep(0.05)
            self.assertEqual(len(calls), 1, "more than one refresher ran at once")
            self.assertIsNot(calls[0], threading.current_thread())
            release.set()
            deadline = time.time() + 5
            while board.stuck_state(None)["checking"] and time.time() < deadline:
                time.sleep(0.05)
            done = board.stuck_state(None)
            self.assertEqual((done["findings"], done["error"]), ([], None))

    def test_a_failed_stuck_check_is_visible(self):
        board = self.load_board_module("board_web_failing")

        def broken(*_a, **_k):
            raise ValueError("config.sh failed: boom")
        with mock.patch.object(board.supervisor_stuck, "find", broken):
            board.stuck_state(None)
            deadline = time.time() + 5
            while board.stuck_state(None)["checking"] and time.time() < deadline:
                time.sleep(0.05)
            state = board.stuck_state(None)
        self.assertIn("boom", state["error"])
        self.assertIsInstance(state["checked_at"], float)

    def test_the_stuck_refresher_never_stays_running_after_a_failure(self):
        board = self.load_board_module("board_web_refresher_dies")

        class Boom(BaseException):
            pass

        def dies(*_a, **_k):
            raise Boom()
        # a refresher that dies with a BaseException must still release the "running" guard
        with mock.patch.object(board.supervisor_stuck, "find", dies):
            board._STUCK["running"] = True  # as stuck_state sets it before starting the thread
            try:
                board._refresh_stuck(None)
            except Boom:
                pass
        self.assertIs(board._STUCK["running"], False, "running stayed True after the refresher died")
        # Thread.start raising must not leave the guard set either
        with mock.patch.object(board.threading, "Thread") as thread:
            thread.return_value.start.side_effect = RuntimeError("can't start new thread")
            with self.assertRaises(RuntimeError):
                board.stuck_state(None)
        self.assertIs(board._STUCK["running"], False, "running stayed True after Thread.start raised")

    def test_stuck_is_suppressed_while_a_run_holds_the_lock_without_answering_as_the_supervisor(self):
        start = " ".join(subprocess.run(["ps", "-o", "lstart=", "-p", str(os.getpid())], capture_output=True,
                                        text=True, env=dict(os.environ, LC_ALL="C", TZ="UTC")).stdout.split())
        lock = self.case / "logs" / "acme-toy.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text("%d\n%s\n" % (os.getpid(), start))
        self.write_card(3, state="in_progress")
        self.active_marker(3)
        self.start_web()
        code, body = self.http("GET", "/api/stuck")
        self.assertEqual(code, 200, body)
        self.assertEqual(body["findings"], [])
        self.assertEqual(body["suppressed"], "a run is active (pid %d)" % os.getpid())
        code, board = self.http("GET", "/api/board")
        self.assertIsNone(board["cards"][0]["stuck"])
        self.assertEqual(board["run"]["stuck_suppressed"], "a run is active (pid %d)" % os.getpid())

    def test_board_reads_the_supervisor_status_once_per_request(self):
        self.write_card(3)
        self.start_service()
        calls = []
        real = self.service.status_view
        self.service.status_view = lambda: (calls.append(1), real())[1]
        self.start_web()
        self.http("GET", "/api/board")
        calls[:] = []
        self.assertEqual(self.http("GET", "/api/board")[0], 200)
        self.assertLessEqual(len(calls), 2, "/api/board asked the supervisor for status %d times" % len(calls))

    def test_card_usage_of_a_non_positive_card_is_a_client_error(self):
        self.start_web()
        code, _ = self.http("GET", "/api/cards/0/usage")
        self.assertIn(code, (400, 404))

    def test_an_unreadable_ledger_reads_null_never_zero(self):
        if os.getuid() == 0:
            self.skipTest("root reads any file")
        self.write_ledger(self.ledger_line())
        ledger = self.repo / ".fleet-board" / "usage.jsonl"
        os.chmod(str(ledger), 0)
        self.addCleanup(os.chmod, str(ledger), 0o600)
        self.start_web()
        code, body = self.http("GET", "/api/supervisor")
        self.assertEqual(code, 200, body)
        self.assertIs(body["running"], False)
        self.assertIsNone(body["run"])
        self.assertIsNone(body["all_time"])
        self.assertIsNone(body["planner"])
        self.assertTrue(body["error"])

    def test_a_launch_that_exits_1_waits_briefly_for_the_winning_supervisor(self):
        board = self.load_board_module("board_web_slowwin")
        answers = iter([None, None, None, None])

        def fake_call(command, body=None, **extra):
            value = next(answers, {"mode": "running", "revision": 1})
            if value is None:
                raise board.ApiError(503, "supervisor unavailable: down", {"code": "unavailable"})
            return value

        def lose(*_a, **_k):
            raise board.supervisor_launcher.LaunchError("exit 1", exit_code=1)
        with mock.patch.object(board, "proxy_call", fake_call), \
                mock.patch.object(board.supervisor_launcher, "launch_detached", lose):
            self.assertIs(board.ensure_service(), False)

    def test_legacy_stop_rechecks_the_service_lock_inside_the_run_lock(self):
        board = self.load_board_module("board_web_recheck")
        board.APP["scripts"] = str(SCRIPTS)
        answers = iter([False, True])
        with mock.patch.object(board, "ctx", return_value=({}, self.repo / ".fleet-board")), \
                mock.patch.object(board, "supervisor_running", return_value=False), \
                mock.patch.object(board, "service_holds_run_lock", lambda cfg: next(answers, True)), \
                mock.patch.object(board, "run_alive", return_value=True):
            with self.assertRaises(board.ApiError) as caught:
                board.stop_run({}, {})
        self.assertEqual(caught.exception.code, 409)
        self.assertFalse((self.repo / ".fleet-board.stop").exists())

    def test_start_on_a_paused_supervisor_resumes_it(self):
        self.start_service()
        self.state.pause("operator")
        self.start_web()
        revision = self.service.status_view()["revision"]
        code, body = self.http("POST", "/api/supervisor/start", {"request_id": "resume-by-start", "expected_revision": revision})
        self.assertEqual(code, 202, body)
        self.assertNotIn("launched", body)
        self.assertEqual(self.state.mode, "running", "Start left a paused supervisor paused")
        self.assertEqual(body["desired_mode"], "running")

    def test_start_on_a_paused_supervisor_with_a_stale_revision_conflicts(self):
        self.start_service()
        self.state.pause("operator")
        self.start_web()
        code, body = self.http("POST", "/api/supervisor/start", {"request_id": "stale-start", "expected_revision": -1})
        self.assertEqual((code, body.get("code")), (409, "stale_revision"))
        self.assertEqual(self.state.mode, "paused")

    def test_start_that_loses_the_run_lock_race_reports_the_running_supervisor(self):
        # The probe finds nothing, the launch then fails because a CLI start won the lock: re-probe and report it.
        board = self.load_board_module("board_web_race")
        answers = iter([None, None])

        def fake_call(command, body=None, **extra):
            value = next(answers, {"mode": "running", "revision": 1})
            if value is None:
                raise board.ApiError(503, "supervisor unavailable: down", {"code": "unavailable"})
            return value

        def lose(*_a, **_k):
            raise board.supervisor_launcher.LaunchError("supervisor exited before it was ready (exit 1)", exit_code=1)
        with mock.patch.object(board, "proxy_call", fake_call), \
                mock.patch.object(board.supervisor_launcher, "launch_detached", lose):
            self.assertIs(board.ensure_service(), False)

    def test_start_still_fails_when_the_launch_fails_and_nothing_runs(self):
        board = self.load_board_module("board_web_nolaunch")

        def down(command, body=None, **extra):
            raise board.ApiError(503, "supervisor unavailable: down", {"code": "unavailable"})

        def lose(*_a, **_k):
            raise board.supervisor_launcher.LaunchError("boom", exit_code=1)
        with mock.patch.object(board, "proxy_call", down), \
                mock.patch.object(board.supervisor_launcher, "launch_detached", lose):
            with self.assertRaises(board.ApiError) as caught:
                board.ensure_service()
        self.assertEqual(caught.exception.code, 503)

    def test_legacy_stop_never_touches_the_stop_file_while_a_supervisor_holds_the_run_lock(self):
        # A supervisor that holds the lock but does not answer: the lock's third line says "service".
        start = " ".join(subprocess.run(["ps", "-o", "lstart=", "-p", str(os.getpid())], capture_output=True,
                                        text=True, env=dict(os.environ, LC_ALL="C", TZ="UTC")).stdout.split())
        lock = self.case / "logs" / "acme-toy.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text("%d\n%s\nservice\n" % (os.getpid(), start))
        self.start_web()
        code, body = self.http("POST", "/api/run/stop")
        self.assertEqual(code, 409, body)
        self.assertFalse((self.repo / ".fleet-board.stop").exists(), "Stop touched the tick-stop file")
        code, body = self.http("POST", "/api/run/start")
        self.assertEqual(code, 409, body)
        self.assertFalse((self.repo / ".fleet-board.stop").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""Offline lifecycle contracts: ownership, the socket, the foreground CLI and the detached launcher."""
import io
import json
import os
import signal
import socket
import stat
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(sys.argv.pop()).resolve()
PLUGIN = Path(__file__).resolve().parents[2]
SCRIPTS = PLUGIN / "scripts"

from supervisor import errors, launcher, paths
from supervisor.cli import main
from supervisor.service import Service, StubHandler
from supervisor.state import State

SANDBOX_PS = "Operation not permitted: 'ps'"


class FakeClock:
    def __init__(self, now=100):
        self.now = now

    def __call__(self):
        return self.now


def make_root(base, name="board"):
    root = Path(base) / name
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    return root


def new_service(root, run_lock, **kwargs):
    state = State("run-" + root.name, FakeClock())
    handler = StubHandler(state)
    kwargs.setdefault("peer_resolver", lambda _peer: "fixture-user")
    return Service(root, state, handler, run_lock_path=str(run_lock), **kwargs), state, handler


def short_base(test):
    """A short private socket base: AF_UNIX paths are length-limited and ROOT is long."""
    path = Path(tempfile.mkdtemp(prefix="fbt.", dir="/tmp"))
    os.chmod(str(path), 0o700)
    test.addCleanup(shutil.rmtree, str(path), True)
    return path


def short_logs(test):
    path = ROOT / (test.id().rsplit(".", 1)[-1] + "-logs")
    path.mkdir(mode=0o700, exist_ok=True)
    return path


class ServiceCase(unittest.TestCase):
    def setUp(self):
        self.root = make_root(ROOT, self.id().rsplit(".", 1)[-1])
        self.logs = short_logs(self)
        patcher = mock.patch.dict(os.environ, {"FLEET_BOARD_LOG_DIR": str(self.logs)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def open(self, name="svc", **kwargs):
        service, state, handler = new_service(self.root, self.logs / (name + ".lock"), **kwargs)
        self.addCleanup(service.close)
        return service, state, handler

    def serve(self, service):
        try:
            ack = service.serve()
        except RuntimeError as exc:
            if SANDBOX_PS in str(exc):
                self.skipTest("sandbox denies the real ps call required by the run lock")
            raise
        if ack.get("socket_unavailable"):
            self.skipTest("sandbox denies binding the supervisor Unix socket")
        return ack


class LifecycleContract(ServiceCase):
    def test_serve_acknowledges_with_owner_and_socket(self):
        service, _, _ = self.open()
        ack = self.serve(service)
        self.assertIs(ack["ready"], True)
        self.assertIs(ack["owner"], True)
        self.assertEqual(ack["socket"], service.socket_path)
        self.assertEqual(set(ack), {"ready", "owner", "socket"})

    def test_socket_is_0600_in_0700_dir(self):
        service, _, _ = self.open()
        self.serve(service)
        endpoint = Path(service.socket_path)
        self.assertEqual(stat.S_IMODE(endpoint.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(endpoint.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((endpoint.parent / "owner.lock").stat().st_mode), 0o600)
        self.assertEqual(str(endpoint.parent.parent), str(paths.socket_base()))

    def test_the_socket_never_follows_tmpdir(self):
        with mock.patch.dict(os.environ, {"TMPDIR": "/definitely/not/here"}):
            service, _, _ = self.open()
        self.assertTrue(service.socket_path.startswith(os.environ["FLEET_BOARD_SOCKET_DIR"]))

    def test_concurrent_and_repeated_serve_share_one_owner(self):
        outcomes, services = [], []
        barrier = threading.Barrier(3)

        def contend():
            service, _, _ = self.open("c%d" % len(services))
            services.append(service)
            barrier.wait()
            try:
                outcomes.append(service.serve())
            except Exception as exc:  # noqa: BLE001
                outcomes.append(exc)
        threads = [threading.Thread(target=contend) for _ in range(2)]
        for thread in threads:
            thread.start()
        barrier.wait()
        for thread in threads:
            thread.join(timeout=10)
        for outcome in outcomes:
            if isinstance(outcome, RuntimeError) and SANDBOX_PS in str(outcome):
                self.skipTest("sandbox denies the real ps call")
        self.assertTrue(all(isinstance(o, dict) for o in outcomes), outcomes)
        if any(o.get("socket_unavailable") for o in outcomes):
            self.skipTest("sandbox denies binding the supervisor Unix socket")
        self.assertEqual(sum(bool(o.get("owner")) for o in outcomes), 1, outcomes)
        self.assertTrue(all(o.get("ready") for o in outcomes))

    def test_a_second_owner_reports_the_running_pid(self):
        first, _, _ = self.open("one")
        self.serve(first)
        second, _, _ = self.open("two")
        ack = second.serve()
        self.assertIs(ack["owner"], False)
        self.assertEqual(second.owner_pid(), os.getpid())

    def test_close_releases_ownership_and_removes_the_socket(self):
        first, _, _ = self.open("one")
        self.serve(first)
        path = first.socket_path
        first.close()
        self.assertFalse(Path(path).exists())
        second, _, _ = self.open("two")
        self.assertIs(self.serve(second)["owner"], True)

    def test_legacy_wrapper_lock_refuses_service_start(self):
        lock = self.logs / "legacy.lock"
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])

        def stop_child():
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
        self.addCleanup(stop_child)
        script = SCRIPTS / "claim-run-lock.py"
        try:
            subprocess.run([sys.executable, str(script), str(lock), str(process.pid)],
                           check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as exc:
            if SANDBOX_PS in (exc.stderr or ""):
                self.skipTest("sandbox denies the real ps call required by legacy-lock fixture")
            raise
        service, _, _ = new_service(self.root, lock)
        self.addCleanup(service.close)
        with self.assertRaisesRegex(RuntimeError, "legacy"):
            service.serve()
        self.assertFalse(Path(service.socket_path).exists(), "a refused start left a socket behind")

    def test_default_run_lock_uses_the_configured_repo_slug(self):
        (self.root / ".fleet-board.yml").write_text("board:\n  repo: owner/project-name\n", encoding="utf-8")
        state = State("r", FakeClock())
        service = Service(self.root, state, StubHandler(state), peer_resolver=lambda _p: "u")
        self.addCleanup(service.close)
        self.assertEqual(service.run_lock_path, str(self.logs / "owner-project-name.lock"))

    def test_service_claims_stale_shared_lock_and_excludes_another_service(self):
        lock = self.logs / "shared.lock"
        lock.write_text("99999999\nnot-a-real-start-time\n", encoding="utf-8")
        first, _, _ = new_service(self.root, lock)
        other_root = make_root(ROOT, self.id().rsplit(".", 1)[-1] + "-linked")
        second, _, _ = new_service(other_root, lock)
        self.addCleanup(first.close)
        self.addCleanup(second.close)
        self.assertTrue(self.serve(first).get("owner"))
        with self.assertRaisesRegex(RuntimeError, "legacy"):
            second.serve()

    def test_a_service_releases_its_run_lock_on_close(self):
        lock = self.logs / "release.lock"
        service, _, _ = new_service(self.root, lock)
        self.serve(service)
        self.assertTrue(lock.exists())
        service.close()
        self.assertFalse(lock.exists())

    # --- the socket ------------------------------------------------------------------

    def test_status_over_the_real_socket_matches_the_in_process_view(self):
        service, state, _ = self.open()
        self.serve(service)
        from supervisor.cli import _socket_transport
        status = _socket_transport(service.socket_path)({"command": "status"})
        self.assertEqual(status["schema_version"], 2)
        self.assertEqual(status["pid"], os.getpid())
        self.assertEqual(status["revision"], state.revision)

    def test_peer_uid_must_match_over_the_real_socket(self):
        service, _, _ = self.open(peer_resolver=Service._peer_actor)
        self.serve(service)
        from supervisor.cli import _socket_transport
        self.assertEqual(_socket_transport(service.socket_path)({"command": "status"})["schema_version"], 2)
        with mock.patch("supervisor.service.os.getuid", return_value=os.getuid() + 1):
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.connect(service.socket_path)
            client.sendall(b'{"command":"status"}')
            raw = b""
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                raw += chunk
            client.close()
        reply = json.loads(raw)
        self.assertFalse(reply["ok"])
        self.assertEqual(reply["error"]["code"], "unauthenticated")

    def test_fragmented_request_and_large_response(self):
        service, _, _ = self.open()
        self.serve(service)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(service.socket_path)
        raw = json.dumps({"command": "status"}).encode()
        for part in (raw[:3], raw[3:8], raw[8:]):
            client.sendall(part)
            time.sleep(0.01)
        response = b""
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            response += chunk
        client.close()
        self.assertTrue(json.loads(response)["ok"])
        from supervisor.cli import _socket_transport
        service._handle_request = lambda request, *, peer: {"large": "y" * (1024 * 1024 + 100)}
        self.assertGreater(len(json.dumps(_socket_transport(service.socket_path)({"command": "status"}))), 1024 * 1024)

    def test_an_oversized_request_over_the_socket_is_an_error_reply(self):
        service, _, _ = self.open()
        self.serve(service)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(5)
        client.connect(service.socket_path)
        try:
            client.sendall(b'{"command":"status","padding":"' + b"x" * (1024 * 1024 + 10))
        except OSError:
            pass
        raw = b""
        try:
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                raw += chunk
        except OSError:
            pass
        client.close()
        if raw:
            self.assertFalse(json.loads(raw)["ok"])

    def test_finished_connection_threads_are_pruned(self):
        service, _, _ = self.open()
        self.serve(service)
        from supervisor.cli import _socket_transport
        transport = _socket_transport(service.socket_path)
        for _ in range(40):
            transport({"command": "status"})
        deadline = time.time() + 5
        while time.time() < deadline and sum(t.is_alive() for t in service._threads) > 2:
            time.sleep(0.05)
        self.assertLess(len(service._threads), 12, "one Thread object per connection is kept for the life of the service")

    def test_socket_directory_refuses_symlink_and_insecure_existing_directory(self):
        service, _, _ = self.open()
        directory = service.socket_dir
        paths.ensure_socket_base()
        target = ROOT / "symlink-target"
        target.mkdir(mode=0o755)
        directory.symlink_to(target, target_is_directory=True)
        self.addCleanup(lambda: directory.unlink() if directory.is_symlink() else None)
        with self.assertRaises((errors.UnsafeSocketDir, ValueError, OSError)):
            service.serve()
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)
        directory.unlink()
        directory.mkdir(mode=0o755)
        os.chmod(str(directory), 0o755)
        self.addCleanup(lambda: directory.rmdir() if directory.is_dir() and not directory.is_symlink() else None)
        with self.assertRaises((errors.UnsafeSocketDir, ValueError, OSError)):
            service.serve()

    def test_a_symlinked_socket_base_is_refused(self):
        real = short_base(self)
        link = Path(str(real) + "-link")
        link.symlink_to(real, target_is_directory=True)
        self.addCleanup(link.unlink)
        with mock.patch.dict(os.environ, {"FLEET_BOARD_SOCKET_DIR": str(link)}):
            service, _, _ = self.open("linked")
            with self.assertRaises(errors.UnsafeSocketDir):
                service.serve()

    def test_a_socket_that_is_not_ours_is_not_replaced(self):
        service, _, _ = self.open()
        directory = service.socket_dir
        paths.ensure_socket_base()
        directory.mkdir(mode=0o700, exist_ok=True)
        Path(service.socket_path).write_text("not a socket", encoding="utf-8")
        with self.assertRaises((ValueError, OSError)):
            self.serve(service)
        self.assertEqual(Path(service.socket_path).read_text(encoding="utf-8"), "not a socket")

    def test_a_blocked_stop_reply_is_flushed_before_close_returns(self):
        service, state, handler = self.open()
        self.serve(service)
        from supervisor.cli import _socket_transport
        transport = _socket_transport(service.socket_path)
        result = transport({"command": "stop", "mode": "drain", "request_id": "s", "expected_revision": state.revision})
        self.assertEqual(result, {"stopping": True, "mode": "drain"})
        self.assertTrue(handler.stop_requested.wait(2))


class CLIContract(unittest.TestCase):
    def invoke(self, *argv, env=None, transport=None):
        out, err = io.StringIO(), io.StringIO()
        seen = []

        def fake(request):
            seen.append(request)
            if request.get("command") == "status":
                return {"schema_version": 2, "revision": 4, "mode": "running", "pause_reason": None,
                        "active": [], "pid": 99, "root": "/r"}
            return {"ok": True, "request": request}
        code = main(list(argv), env={} if env is None else env, stdout=out, stderr=err,
                    transport=fake if transport is None else transport)
        return code, out.getvalue(), err.getvalue(), seen

    def test_cli_exposes_the_foreground_commands(self):
        for command in (("pause",), ("resume",), ("status",), ("status", "--json"), ("stop",),
                        ("stop", "--drain"), ("stop", "--cancel")):
            with self.subTest(command=command):
                code, _, err, _ = self.invoke(*command)
                self.assertEqual(code, 0, err)

    def test_stop_drain_and_cancel_flags(self):
        for args, mode in (((), "drain"), (("--drain",), "drain"), (("--cancel",), "cancel")):
            with self.subTest(args=args):
                code, _, err, seen = self.invoke("stop", *args)
                self.assertEqual(code, 0, err)
                stop = [r for r in seen if r["command"] == "stop"][0]
                self.assertEqual(stop["mode"], mode)
                self.assertEqual(stop["expected_revision"], 4)
                self.assertTrue(stop["request_id"])

    def test_pause_and_resume_send_the_current_revision(self):
        for command in ("pause", "resume"):
            code, _, err, seen = self.invoke(command)
            self.assertEqual(code, 0, err)
            sent = [r for r in seen if r["command"] == command][0]
            self.assertEqual(sent["expected_revision"], 4)

    def test_status_json_prints_the_status_and_plain_status_is_human_readable(self):
        code, out, _, _ = self.invoke("status", "--json")
        self.assertEqual(json.loads(out)["schema_version"], 2)
        code, out, _, _ = self.invoke("status")
        self.assertIn("running", out)
        self.assertIn("99", out)
        with self.assertRaises(ValueError):
            json.loads(out)

    def test_cli_rejects_contradictory_or_removed_arguments(self):
        cases = (("stop", "--drain", "--cancel"), ("stop", "--mode", "drain"), ("pause", "--mode", "drain"),
                 ("resolve", "--card", "1", "--action", "retry"), ("reconcile",), ("events",),
                 ("serve", "--domain", "x", "--log-dir", "y"), ("serve",), ("unknown",), ())
        for args in cases:
            with self.subTest(args=args):
                code, _, err, _ = self.invoke(*args)
                self.assertEqual(code, 2)
                self.assertIn("usage", err.lower())

    def test_no_socket_tmp_shim_remains(self):
        text = (SCRIPTS / "supervisor" / "cli.py").read_text(encoding="utf-8")
        for gone in ("socket-tmp", "socket_tmp", "socket_tmpdir", "boot_registration", "host_boot_id"):
            self.assertNotIn(gone, text)

    def test_detach_arrives_in_a_later_phase(self):
        code, _, err, _ = self.invoke("start", "--detach")
        self.assertEqual(code, 2)
        self.assertIn("--detach arrives in a later phase", err)

    def test_help_documents_the_socket_override_requirements(self):
        out = io.StringIO()
        code = main(["--help"], env={}, stdout=out, stderr=io.StringIO(), transport=lambda r: {})
        self.assertEqual(code, 0)
        text = out.getvalue()
        self.assertIn("FLEET_BOARD_SUPERVISOR_SOCKET", text)
        self.assertIn("0700", text)
        self.assertIn("grandparent", text)
        self.assertIn("FLEET_BOARD_SOCKET_DIR", text)

    def test_an_unreachable_service_is_exit_1_naming_the_root(self):
        base = short_base(self)
        root = make_root(ROOT, "unreachable-root")
        out, err = io.StringIO(), io.StringIO()
        code = main(["status"], env={"FLEET_BOARD_DOMAIN": str(root), "FLEET_BOARD_SOCKET_DIR": str(base)},
                    stdout=out, stderr=err)
        self.assertEqual(code, 1)
        self.assertIn("not running", err.getvalue())

    def test_the_default_root_is_the_git_toplevel_of_the_cwd(self):
        repo = make_root(ROOT, "default-root")
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        deep = repo / "a" / "b"
        deep.mkdir(parents=True)
        base = short_base(self)
        env = dict(os.environ, FLEET_BOARD_SOCKET_DIR=str(base), PYTHONPATH=str(SCRIPTS), PYTHONDONTWRITEBYTECODE="1")
        env.pop("FLEET_BOARD_DOMAIN", None)
        run = subprocess.run([str(SCRIPTS / "supervisor.sh"), "status"], cwd=str(deep), env=env,
                             capture_output=True, text=True, timeout=20)
        self.assertEqual(run.returncode, 1, run.stderr)
        self.assertIn(os.path.realpath(str(repo)), run.stderr)

    def test_the_supervisor_socket_override_is_honoured(self):
        seen = []
        base = short_base(self)
        directory = base / "d"
        directory.mkdir(mode=0o700)
        out, err = io.StringIO(), io.StringIO()
        root = make_root(ROOT, "override-root")
        env = {"FLEET_BOARD_DOMAIN": str(root), "FLEET_BOARD_SUPERVISOR_SOCKET": str(directory / "control.sock")}
        with mock.patch("supervisor.cli._socket_transport", side_effect=lambda path: seen.append(path) or (lambda r: {
                "schema_version": 2, "revision": 0, "mode": "running", "pause_reason": None, "active": [],
                "pid": 1, "root": str(root)})):
            code = main(["status", "--json"], env=env, stdout=out, stderr=err)
        self.assertEqual(code, 0, err.getvalue())
        self.assertEqual(seen, [str(directory / "control.sock")])

    def test_pause_resume_stop_send_current_revisions_over_a_real_service(self):
        root = make_root(ROOT, "cli-real-service")
        service, state, handler = new_service(root, ROOT / "cli-real.lock")
        self.addCleanup(service.close)
        seen = []

        def transport(request):
            if request.get("command") in ("pause", "resume", "stop"):
                seen.append(request["expected_revision"])
            return service.handle_request(request, peer=object())
        for args in (("pause",), ("resume",), ("stop", "--drain")):
            err = io.StringIO()
            code = main(list(args), env={}, stdout=io.StringIO(), stderr=err, transport=transport)
            self.assertEqual(code, 0, err.getvalue())
        self.assertEqual(seen, [0, 1, 2])
        self.assertTrue(handler.stop_requested.is_set())


class ForegroundStart(unittest.TestCase):
    """`start` is the process: no daemon, no serve subcommand."""

    def setUp(self):
        self.case = make_root(ROOT, self.id().rsplit(".", 1)[-1])
        self.base = short_base(self)
        self.logs = ROOT / (self.id().rsplit(".", 1)[-1] + "-logs")
        self.logs.mkdir(mode=0o700)
        self.env = dict(os.environ, FLEET_BOARD_DOMAIN=str(self.case), FLEET_BOARD_SOCKET_DIR=str(self.base),
                        FLEET_BOARD_LOG_DIR=str(self.logs), PYTHONPATH=str(SCRIPTS), PYTHONDONTWRITEBYTECODE="1")
        self.procs = []
        self.addCleanup(self.reap)

    def reap(self):
        for proc in self.procs:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)
            for pipe in (proc.stdout, proc.stderr):
                if pipe:
                    pipe.close()

    def start(self, *extra):
        proc = subprocess.Popen([str(SCRIPTS / "supervisor.sh"), "start", *extra], env=self.env,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.procs.append(proc)
        return proc

    def ack(self, proc, timeout=15):
        import select
        ready, _, _ = select.select([proc.stdout], [], [], timeout)
        if not ready:
            proc.kill()
            self.fail("start printed no acknowledgement within %ss: %s" % (timeout, proc.stderr.read()))
        line = proc.stdout.readline()
        if not line:
            err = proc.stderr.read()
            if SANDBOX_PS in err:
                self.skipTest("sandbox denies the real ps call")
            if "unavailable" in err.lower() and "socket" in err.lower():
                self.skipTest("sandbox denies binding the supervisor Unix socket")
            self.fail("start exited before acknowledging: " + err)
        return json.loads(line)

    def cli(self, *args):
        return subprocess.run([str(SCRIPTS / "supervisor.sh"), *args], env=self.env, capture_output=True,
                              text=True, timeout=20)

    def finish(self, proc, timeout=15):
        try:
            return proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            self.fail("the foreground process did not exit")

    def test_start_runs_in_the_foreground_and_status_answers(self):
        proc = self.start()
        ack = self.ack(proc)
        self.assertIs(ack["ready"], True)
        self.assertIs(ack["owner"], True)
        self.assertIsNone(proc.poll(), "start must keep running in the foreground")
        status = self.cli("status", "--json")
        self.assertEqual(status.returncode, 0, status.stderr)
        result = json.loads(status.stdout)
        self.assertEqual(result["schema_version"], 2)
        self.assertEqual(result["root"], os.path.realpath(str(self.case)))
        self.assertEqual(result["mode"], "running")
        self.assertIsInstance(result["pid"], int)
        self.assertEqual(self.cli("pause").returncode, 0)
        self.assertEqual(json.loads(self.cli("status", "--json").stdout)["mode"], "paused")
        self.assertEqual(self.cli("resume").returncode, 0)
        stop = self.cli("stop")
        self.assertEqual(stop.returncode, 0, stop.stderr)
        self.assertEqual(json.loads(stop.stdout), {"stopping": True, "mode": "drain"})
        self.assertEqual(self.finish(proc), 0)
        self.assertEqual(self.cli("status").returncode, 1)

    def test_status_pid_is_the_foreground_process(self):
        proc = self.start()
        self.ack(proc)
        self.assertEqual(json.loads(self.cli("status", "--json").stdout)["pid"], proc.pid)
        self.cli("stop", "--cancel")
        self.assertEqual(self.finish(proc), 0)

    def test_second_start_names_the_running_pid(self):
        first = self.start()
        self.ack(first)
        second = self.start()
        self.assertEqual(self.finish(second), 1)
        err = second.stderr.read()
        self.assertIn("supervisor already running for %s (pid %d)" % (os.path.realpath(str(self.case)), first.pid), err)
        self.assertIsNone(first.poll(), "the first supervisor must be undisturbed")
        self.cli("stop")
        self.assertEqual(self.finish(first), 0)

    def test_sigint_stops_cleanly_exit_0(self):
        proc = self.start()
        self.ack(proc)
        proc.send_signal(signal.SIGINT)
        self.assertEqual(self.finish(proc), 0, proc.stderr.read())
        self.assertEqual(self.cli("status").returncode, 1, "the socket must be gone after a clean stop")
        self.assertEqual([e for e in os.listdir(str(self.base))
                          if os.path.exists(os.path.join(str(self.base), e, "c.sock"))], [])

    def test_sigterm_stops_cleanly_exit_0(self):
        proc = self.start()
        self.ack(proc)
        proc.send_signal(signal.SIGTERM)
        self.assertEqual(self.finish(proc), 0, proc.stderr.read())

    def test_detach_and_ignore_stuck_parse_and_detach_exits_2(self):
        proc = self.start("--detach")
        self.assertEqual(self.finish(proc), 2)
        self.assertIn("--detach arrives in a later phase", proc.stderr.read())
        proc = self.start("--ignore-stuck")
        self.ack(proc)
        self.cli("stop")
        self.assertEqual(self.finish(proc), 0)

    def test_the_serve_subcommand_is_gone(self):
        run = self.cli("serve", "--domain", str(self.case), "--log-dir", str(self.logs))
        self.assertEqual(run.returncode, 2)


class DetachedLauncher(unittest.TestCase):
    def setUp(self):
        name = self.id().rsplit(".", 1)[-1]
        self.case = make_root(ROOT, name)
        self.base = short_base(self)
        self.logs = ROOT / (name + "-logs")
        self.logs.mkdir(mode=0o700)

    def test_launch_detached_starts_a_service_that_answers_and_logs_to_a_file(self):
        env = dict(os.environ, FLEET_BOARD_SOCKET_DIR=str(self.base), FLEET_BOARD_LOG_DIR=str(self.logs))
        log = self.logs / "supervisor.log"
        try:
            ack = launcher.launch_detached(self.case, log, env=env)
        except launcher.LaunchError as exc:
            if SANDBOX_PS in str(exc) or "socket" in str(exc).lower():
                self.skipTest("sandbox: " + str(exc)[:120])
            raise
        domain_id = paths.domain_id_for_root(self.case)
        socket_path = paths.controller_socket(domain_id, env=env)
        self.addCleanup(subprocess.run, [str(SCRIPTS / "supervisor.sh"), "stop", "--cancel"],
                        env=dict(env, FLEET_BOARD_DOMAIN=str(self.case), PYTHONPATH=str(SCRIPTS)),
                        capture_output=True, timeout=20)
        self.assertIs(ack["ready"], True)
        self.assertIsInstance(ack["pid"], int)
        from supervisor.cli import _socket_transport
        self.assertEqual(_socket_transport(socket_path)({"command": "status"})["pid"], ack["pid"])
        self.assertTrue(log.exists())
        self.assertEqual(stat.S_IMODE(log.stat().st_mode) & 0o077, 0, "the log must be private")

    def test_the_child_env_never_inherits_the_socket_dir_the_caller_did_not_give(self):
        board = make_root(ROOT, "env-board")
        child = mock.Mock()
        child.poll.return_value = 1
        child.wait.return_value = 1
        with mock.patch.dict(os.environ, {"FLEET_BOARD_SOCKET_DIR": str(self.base)}):
            with mock.patch.object(launcher.subprocess, "Popen", return_value=child) as popen:
                with self.assertRaises(launcher.LaunchError):
                    launcher.launch_detached(board, self.logs / "x.log", env={"FLEET_BOARD_LOG_DIR": str(self.logs)},
                                             timeout=1)
            self.assertNotIn("FLEET_BOARD_SOCKET_DIR", popen.call_args.kwargs["env"])
            with mock.patch.object(launcher.subprocess, "Popen", return_value=child) as popen:
                with self.assertRaises(launcher.LaunchError):
                    launcher.launch_detached(board, self.logs / "y.log", timeout=1,
                                             env={"FLEET_BOARD_SOCKET_DIR": "/tmp/given"})
            self.assertEqual(popen.call_args.kwargs["env"]["FLEET_BOARD_SOCKET_DIR"], "/tmp/given")

    def test_the_launcher_spawns_a_detached_argv_without_a_shell_and_bounds_readiness(self):
        board = make_root(ROOT, "argv-board")
        child = mock.Mock()
        child.poll.return_value = None
        child.wait.return_value = 0
        with mock.patch.object(launcher.subprocess, "Popen", return_value=child) as popen:
            with self.assertRaisesRegex(launcher.LaunchError, "timed out"):
                launcher.launch_detached(board, self.logs / "z.log",
                                         env={"FLEET_BOARD_SOCKET_DIR": str(self.base)}, timeout=0.3)
        argv = popen.call_args.args[0]
        self.assertIsInstance(argv, list)
        self.assertEqual(argv[1:4], ["-m", "supervisor.cli", "start"])
        self.assertNotIn("serve", argv)
        self.assertNotIn("--socket-tmp", argv)
        self.assertFalse(popen.call_args.kwargs.get("shell", False))
        self.assertIs(popen.call_args.kwargs.get("start_new_session"), True)
        self.assertEqual(popen.call_args.kwargs["stdin"], subprocess.DEVNULL)
        child.terminate.assert_called()

    def test_a_child_that_exits_first_is_a_launch_error_with_the_log_tail(self):
        board = make_root(ROOT, "exit-board")
        log = self.logs / "exit.log"
        child = mock.Mock()
        child.poll.return_value = 1
        child.wait.return_value = 1

        def fake_popen(argv, **kwargs):
            kwargs["stderr"].write("boom: no good\n")
            kwargs["stderr"].flush()
            return child
        with mock.patch.object(launcher.subprocess, "Popen", side_effect=fake_popen):
            with self.assertRaisesRegex(launcher.LaunchError, "boom: no good"):
                launcher.launch_detached(board, log, env={"FLEET_BOARD_SOCKET_DIR": str(self.base)}, timeout=2)

    def test_the_old_serve_launcher_is_gone(self):
        self.assertFalse(hasattr(launcher, "launch_service"))
        text = (SCRIPTS / "supervisor" / "launcher.py").read_text(encoding="utf-8")
        self.assertNotIn('"serve"', text)
        self.assertNotIn("socket-tmp", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)

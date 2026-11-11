"""Cases for where the supervisor socket lives: it must not depend on the caller's TMPDIR."""
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(sys.argv.pop()).resolve()
SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from supervisor import errors, paths  # noqa: E402

PROXY = ("import json, sys\n"
         "from supervisor import paths, webproxy\n"
         "did = paths.domain_id_for_root(sys.argv[1])\n"
         "print(json.dumps(webproxy.request(webproxy.socket_path(did), {'command': 'status'})))\n")


def _digest(did):
    return hashlib.sha256(str(did).encode("utf-8")).hexdigest()[:20]


def short_dir(prefix):
    """A short real directory: AF_UNIX paths are length-limited."""
    path = Path(tempfile.mkdtemp(prefix=prefix, dir=os.path.realpath("/tmp")))
    os.chmod(path, 0o700)
    return path


class SocketLocation(unittest.TestCase):
    def setUp(self):
        self.work = short_dir("fbp-")
        self.addCleanup(shutil.rmtree, str(self.work), True)
        self.home = self.work / "home"
        self.home.mkdir(mode=0o700)
        self.board = self.work / "board"
        self.board.mkdir()
        subprocess.run(["git", "init", "-q", str(self.board)], check=True)
        (self.board / ".fleet-board.yml").write_text("board:\n  repo: acme/toy\n", encoding="utf-8")
        self.addCleanup(self._kill_service)

    def _kill_service(self):
        subprocess.run(["pkill", "-f", "supervisor.cli serve --domain " + str(self.board.resolve())],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def base_env(self, **extra):
        env = {"PATH": os.environ["PATH"], "HOME": str(self.home), "PYTHONDONTWRITEBYTECODE": "1",
               "PYTHONPATH": str(SCRIPTS), "FLEET_BOARD_DOMAIN": str(self.board)}
        env.update(extra)
        return env

    def cli(self, *args, env):
        return subprocess.run([sys.executable, "-m", "supervisor.cli"] + list(args), env=env, cwd=str(self.board),
                              capture_output=True, text=True, timeout=60)

    def start_service(self, env):
        done = self.cli("start", env=env)
        if "Operation not permitted" in done.stderr or "socket_unavailable" in done.stdout:
            self.skipTest("sandbox denies local Unix socket service")
        self.assertIn(done.returncode, (0, 3), "start failed: %s %s" % (done.stdout, done.stderr))

    def test_service_and_clients_agree_when_their_tmpdirs_differ(self):
        tmp_a, tmp_b = short_dir("fbA-"), short_dir("fbB-")
        for path in (tmp_a, tmp_b):
            self.addCleanup(shutil.rmtree, str(path), True)
        logs = self.work / "logs"
        service_env = self.base_env(TMPDIR=str(tmp_a), FLEET_BOARD_LOG_DIR=str(logs),
                                    FLEET_BOARD_SOCKET_DIR=str(self.work / "sock"))
        self.start_service(service_env)
        # Clients run with a different TMPDIR and no other override than the shared socket dir.
        client_env = self.base_env(TMPDIR=str(tmp_b), FLEET_BOARD_LOG_DIR=str(logs),
                                   FLEET_BOARD_SOCKET_DIR=str(self.work / "sock"))
        status = self.cli("status", env=client_env)
        self.assertEqual(status.returncode, 0, "CLI under a different TMPDIR cannot reach the service: " + status.stderr)
        proxy = subprocess.run([sys.executable, "-c", PROXY, str(self.board)], env=client_env,
                               capture_output=True, text=True, timeout=30)
        self.assertEqual(proxy.returncode, 0, "webproxy under a different TMPDIR cannot reach the service: " + proxy.stderr)
        self.assertIn("revision", json.loads(proxy.stdout))

    def test_service_not_reached_through_tmpdir_even_without_a_socket_dir_override(self):
        tmp_a, tmp_b = short_dir("fbA-"), short_dir("fbB-")
        for path in (tmp_a, tmp_b):
            self.addCleanup(shutil.rmtree, str(path), True)
        logs = self.work / "logs"
        self.start_service(self.base_env(TMPDIR=str(tmp_a), FLEET_BOARD_LOG_DIR=str(logs)))
        self.addCleanup(self._rm_default_socket_dir)
        status = self.cli("status", env=self.base_env(TMPDIR=str(tmp_b), FLEET_BOARD_LOG_DIR=str(logs)))
        self.assertEqual(status.returncode, 0, "CLI under another TMPDIR cannot reach the service: " + status.stderr)

    def _rm_default_socket_dir(self):
        did = paths.domain_id_for_root(self.board)
        shutil.rmtree(str(Path("/tmp") / ("fleet-board-%d" % os.getuid()) / ("fbs-" + _digest(did))), True)

    def test_no_overrides_at_all_service_and_client_agree_on_the_stable_location(self):
        self.addCleanup(self._rm_default_socket_dir)
        env = self.base_env()
        self.assertFalse([k for k in env if k.startswith("FLEET_BOARD_") and k != "FLEET_BOARD_DOMAIN"] or "TMPDIR" in env)
        self.start_service(env)
        status = self.cli("status", env=env)
        self.assertEqual(status.returncode, 0, "status failed: " + status.stderr)
        did = paths.domain_id_for_root(self.board)
        expected = Path("/tmp") / ("fleet-board-%d" % os.getuid()) / ("fbs-" + _digest(did)) / "c.sock"
        self.assertTrue(stat.S_ISSOCK(os.lstat(str(expected)).st_mode),
                        "service socket is not at the stable default location %s" % expected)

    def test_unsafe_socket_base_is_refused_with_a_typed_error(self):
        self.assertTrue(hasattr(errors, "UnsafeSocketDir"), "errors.UnsafeSocketDir does not exist")
        loose = self.work / "loose"
        loose.mkdir()
        os.chmod(str(loose), 0o777)
        target = self.work / "target"
        target.mkdir(mode=0o700)
        link = self.work / "link"
        link.symlink_to(target, target_is_directory=True)
        for base, why in ((loose, "group/other accessible"), (link, "symlink")):
            with self.assertRaises(errors.UnsafeSocketDir, msg=why):
                paths.ensure_socket_base({"FLEET_BOARD_SOCKET_DIR": str(base)})
        self.assertEqual(errors.classify(errors.UnsafeSocketDir("x"))["code"], "unsafe_socket_dir")
        env = self.base_env(FLEET_BOARD_LOG_DIR=str(self.work / "logs"), FLEET_BOARD_SOCKET_DIR=str(loose))
        done = self.cli("start", env=env)
        self.assertNotEqual(done.returncode, 0, "start must not use an unsafe socket directory")
        self.assertEqual(os.listdir(str(loose)), [], "an unsafe base directory must stay untouched")

    def test_safe_base_is_created_private(self):
        base = self.work / "fresh"
        got = paths.ensure_socket_base({"FLEET_BOARD_SOCKET_DIR": str(base)})
        self.assertEqual(Path(got), base)
        self.assertEqual(stat.S_IMODE(os.lstat(str(base)).st_mode), 0o700)

    def test_default_base_ignores_tmpdir(self):
        expected = "/tmp/fleet-board-%d" % os.getuid()
        self.assertEqual(str(paths.socket_base({"TMPDIR": "/somewhere/else"})), expected)
        self.assertEqual(str(paths.socket_base({})), expected)

    def test_domain_id_and_socket_dir_digests_are_pinned(self):
        identity = {"common_dir": "/srv/fleet/repo/.git", "board_backend": "local", "board_identity": "/srv/fleet/repo"}
        did = paths.identity_digest(identity)
        self.assertEqual(did, "0926247a14284fb39566448e95343e9a1a5a321d49d798060a889be94ac6e17e")
        self.assertEqual(paths.socket_dir(did, "/b"), Path("/b/fbs-7b09ace66741890a1491"))
        self.assertEqual(paths.controller_socket(did, "/b"), "/b/fbs-7b09ace66741890a1491/c.sock")
        self.assertEqual(paths.worker_socket(did, "/b"), "/b/fbs-7b09ace66741890a1491/w.sock")


if __name__ == "__main__":
    unittest.main(verbosity=2)

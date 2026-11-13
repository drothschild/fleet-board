"""Cases for where the supervisor socket lives: it must not depend on the caller's TMPDIR."""
import os
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(sys.argv.pop()).resolve()
SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from supervisor import errors, paths, webproxy  # noqa: E402


def short_dir(prefix):
    """A short real directory: AF_UNIX paths are length-limited."""
    path = Path(tempfile.mkdtemp(prefix=prefix, dir=os.path.realpath("/tmp")))
    os.chmod(path, 0o700)
    return path


class SocketLocation(unittest.TestCase):
    def setUp(self):
        self.work = short_dir("fbp-")
        self.addCleanup(shutil.rmtree, str(self.work), True)

    def test_default_base_ignores_tmpdir(self):
        expected = Path("/tmp/fleet-board-%d" % os.getuid())
        self.assertEqual(paths.socket_base({"TMPDIR": "/x"}), expected)
        self.assertEqual(paths.socket_base({}), expected)

    def test_override_base(self):
        self.assertEqual(paths.socket_base({"FLEET_BOARD_SOCKET_DIR": str(self.work)}), self.work)

    def test_safe_base_is_created_private(self):
        base = self.work / "fresh"
        got = paths.ensure_socket_base({"FLEET_BOARD_SOCKET_DIR": str(base)})
        self.assertEqual(Path(got), base)
        self.assertEqual(stat.S_IMODE(os.lstat(str(base)).st_mode), 0o700)

    def test_unsafe_socket_base_is_refused_with_a_typed_error(self):
        loose = self.work / "loose"
        loose.mkdir()
        os.chmod(str(loose), 0o777)
        target = self.work / "target"
        target.mkdir(mode=0o700)
        link = self.work / "link"
        link.symlink_to(target, target_is_directory=True)
        for base, why in ((loose, "group/other accessible"), (link, "symlink")):
            with self.assertRaises(errors.UnsafeSocketDir, msg=why) as caught:
                paths.ensure_socket_base({"FLEET_BOARD_SOCKET_DIR": str(base)})
            self.assertEqual(errors.classify(caught.exception)["code"], "unsafe_socket_dir")

    def test_too_long_socket_path_raises(self):
        base = self.work / ("d" * 120)
        with self.assertRaises(errors.UnsafeSocketDir):
            paths.socket_dir("some-domain-id", base)
        with self.assertRaises(errors.UnsafeSocketDir):
            paths.controller_socket("some-domain-id", env={"FLEET_BOARD_SOCKET_DIR": str(base)})

    def test_domain_id_and_socket_dir_digests_are_pinned(self):
        identity = {"common_dir": "/srv/fleet/repo/.git", "board_backend": "local", "board_identity": "/srv/fleet/repo"}
        did = paths.identity_digest(identity)
        self.assertEqual(did, "0926247a14284fb39566448e95343e9a1a5a321d49d798060a889be94ac6e17e")
        self.assertEqual(paths.socket_dir(did, "/b"), Path("/b/fbs-7b09ace66741890a1491"))
        self.assertEqual(paths.controller_socket(did, "/b"), "/b/fbs-7b09ace66741890a1491/c.sock")

    def test_webproxy_refuses_group_readable_socket_dir(self):
        import socket
        base = self.work / "base"
        base.mkdir(mode=0o700)
        sdir = base / "fbs-x"
        sdir.mkdir(mode=0o750)
        os.chmod(str(sdir), 0o750)
        path = str(sdir / "c.sock")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(server.close)
        server.bind(path)
        server.listen(1)
        with self.assertRaises(errors.UnsafeSocketDir):
            webproxy.request(path, {"command": "status"})


if __name__ == "__main__":
    unittest.main(verbosity=2)

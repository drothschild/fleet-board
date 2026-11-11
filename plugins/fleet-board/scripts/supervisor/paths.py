"""One definition of where a domain's private control sockets live.

The service, the CLI and the board server must all derive the same location from the
domain id alone; a mismatch makes a healthy service look unreachable.
"""
import hashlib
import os
from pathlib import Path

# AF_UNIX paths are length-limited (104 bytes on macOS, 108 on Linux).
_MAX_SOCKET_PATH = 100


def socket_dir(domain_id, tmpdir=None):
    """Per-domain private directory for the controller and worker sockets.

    Named from a hash of the full domain id (not a short prefix), under TMPDIR,
    falling back to /tmp when TMPDIR would make the socket path too long.
    """
    digest = hashlib.sha256(str(domain_id).encode("utf-8")).hexdigest()[:20]
    name = "fbs-" + digest
    base = Path(tmpdir if tmpdir is not None else os.environ.get("TMPDIR") or "/tmp")
    candidate = base / name
    if len(str(candidate / "c.sock")) >= _MAX_SOCKET_PATH:
        candidate = Path("/tmp") / name
    return candidate


def controller_socket(domain_id, tmpdir=None):
    return str(socket_dir(domain_id, tmpdir) / "c.sock")


def worker_socket(domain_id, tmpdir=None):
    return str(socket_dir(domain_id, tmpdir) / "w.sock")

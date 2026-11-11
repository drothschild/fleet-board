"""One definition of a supervisor domain's identity and where its files live.

The service, the CLI and the board server must all derive the same domain id, runtime
root and socket location from the same inputs; a mismatch makes a healthy service look
unreachable. Nothing here opens a database or creates a file: a board server answering a
GET can compute an id without touching supervisor state.
"""
import hashlib
import os
import subprocess
from pathlib import Path

from .models import canonical_json

# AF_UNIX paths are length-limited (104 bytes on macOS, 108 on Linux).
_MAX_SOCKET_PATH = 100


def log_dir(env=None):
    """The runtime log directory, the same default the headless wrapper uses."""
    env = os.environ if env is None else env
    return Path(env.get("FLEET_BOARD_LOG_DIR") or (Path.home() / ".fleet-board" / "runs"))


def runtime_root(env=None):
    """Where the supervisor store lives: one default for start, the other commands, the web
    server and Store itself."""
    return log_dir(env) / "supervisor"


def socket_tmpdir(env=None):
    env = os.environ if env is None else env
    return env.get("TMPDIR") or "/tmp"


def git_common_dir(root):
    """The git common directory of the checkout at root (the main repository's .git for a
    linked worktree), or root itself outside a repository. Read-only."""
    root = Path(root).resolve(strict=True)
    marker = root / ".git"
    if marker.is_dir():
        return marker.resolve(strict=True)
    if not marker.exists():
        return root
    # A linked worktree (or submodule) has a .git file: ask git for the common dir.
    for flags in (["--path-format=absolute", "--git-common-dir"], ["--git-common-dir"]):
        try:
            out = subprocess.run(["git", "-C", str(root), "rev-parse"] + flags, stdin=subprocess.DEVNULL,
                                 capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            break
        line = out.stdout.strip()
        if out.returncode == 0 and line and "\n" not in line:
            path = Path(line)
            path = path if path.is_absolute() else root / path
            if path.is_dir():
                return path.resolve(strict=True)
    raise ValueError("invalid git common directory")


def board_domain(root, runtime=None):
    """The domain description for the board checkout at root."""
    root = Path(root).resolve(strict=True)
    return {"common_dir": str(git_common_dir(root)), "board_backend": "local",
            "board_identity": str(root),
            "runtime_root": str(runtime if runtime is not None else runtime_root())}


def normalize_identity(domain):
    """The validated identity (the only fields that make an id) with a resolved common dir."""
    identity = {key: domain[key] for key in ("common_dir", "board_backend", "board_identity")}
    if not all(isinstance(v, str) and v for v in identity.values()):
        raise ValueError("invalid domain identity")
    common = Path(identity["common_dir"])
    if not common.is_absolute() or not common.is_dir():
        raise ValueError("invalid git common directory")
    identity["common_dir"] = str(common.resolve(strict=True))
    return identity


def identity_digest(identity):
    return hashlib.sha256(canonical_json(identity).encode()).hexdigest()


def domain_id(domain):
    """The domain id: a pure function of the identity inputs (no database, no side effects)."""
    return identity_digest(normalize_identity(domain))


def domain_id_for_root(root):
    return domain_id(board_domain(root))


def socket_dir(domain_id, tmpdir=None):
    """Per-domain private directory for the controller and worker sockets.

    Named from a hash of the full domain id (not a short prefix), under TMPDIR,
    falling back to /tmp when TMPDIR would make the socket path too long.
    """
    digest = hashlib.sha256(str(domain_id).encode("utf-8")).hexdigest()[:20]
    name = "fbs-" + digest
    base = Path(tmpdir if tmpdir is not None else socket_tmpdir())
    candidate = base / name
    if len(str(candidate / "c.sock")) >= _MAX_SOCKET_PATH:
        candidate = Path("/tmp") / name
    return candidate


def controller_socket(domain_id, tmpdir=None):
    return str(socket_dir(domain_id, tmpdir) / "c.sock")


def worker_socket(domain_id, tmpdir=None):
    return str(socket_dir(domain_id, tmpdir) / "w.sock")

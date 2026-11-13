"""One definition of a supervisor domain's identity and where its files live.

The service, the CLI and the board server must all derive the same domain id, runtime
root and socket location from the same inputs; a mismatch makes a healthy service look
unreachable. Nothing here opens a database or creates a file: a board server answering a
GET can compute an id without touching supervisor state.
"""
import hashlib
import json
import os
import stat
import subprocess
from pathlib import Path

from . import errors

# AF_UNIX paths are length-limited (104 bytes on macOS, 108 on Linux).
_MAX_SOCKET_PATH = 100


def log_dir(env=None):
    """The runtime log directory (FLEET_BOARD_LOG_DIR, default ~/.fleet-board/runs)."""
    env = os.environ if env is None else env
    return Path(env.get("FLEET_BOARD_LOG_DIR") or (Path.home() / ".fleet-board" / "runs"))


def runtime_root(env=None):
    """Where the supervisor store lives: one default for start, the other commands, the web
    server and Store itself."""
    return log_dir(env) / "supervisor"


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


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


def socket_base(env=None):
    """The directory that holds every domain's socket directory.

    Never derived from TMPDIR (a client and a service with different TMPDIRs must agree):
    /tmp/fleet-board-<uid> by default, FLEET_BOARD_SOCKET_DIR as the one explicit override.
    Pure: it creates nothing and touches no file."""
    env = os.environ if env is None else env
    override = env.get("FLEET_BOARD_SOCKET_DIR")
    if override:
        return Path(override)
    return Path("/tmp") / ("fleet-board-%d" % os.getuid())


def check_socket_base(base):
    """Refuse a base that is a symlink, not a directory, foreign-owned or group/other accessible."""
    info = os.lstat(str(base))
    if stat.S_ISLNK(info.st_mode):
        raise errors.UnsafeSocketDir("supervisor socket base is a symlink: %s" % base)
    if not stat.S_ISDIR(info.st_mode):
        raise errors.UnsafeSocketDir("supervisor socket base is not a directory: %s" % base)
    if info.st_uid != os.getuid():
        raise errors.UnsafeSocketDir("supervisor socket base is not owned by this user: %s" % base)
    if stat.S_IMODE(info.st_mode) & 0o077:
        raise errors.UnsafeSocketDir("supervisor socket base is group/other accessible: %s" % base)


def check_socket_path(path):
    """Refuse a socket whose directory, or that directory's parent (the base), is unsafe."""
    directory = Path(path).parent
    info = os.lstat(str(directory))
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise errors.UnsafeSocketDir("supervisor socket directory is not a real directory: %s" % directory)
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise errors.UnsafeSocketDir("supervisor socket directory is not private to this user: %s" % directory)
    check_socket_base(directory.parent)


def ensure_socket_base(env=None):
    """Create the base 0700 if missing and verify it; returns it."""
    base = socket_base(env)
    try:
        base.mkdir(mode=0o700, parents=True)
    except FileExistsError:
        pass
    check_socket_base(base)
    return base


def socket_dir(domain_id, base=None, env=None):
    """Per-domain private directory for the controller socket, named from a hash of the
    full domain id under the socket base. A path too long for AF_UNIX is refused, never
    moved somewhere else."""
    digest = hashlib.sha256(str(domain_id).encode("utf-8")).hexdigest()[:20]
    candidate = Path(base if base is not None else socket_base(env)) / ("fbs-" + digest)
    if len(str(candidate / "c.sock")) >= _MAX_SOCKET_PATH:
        raise errors.UnsafeSocketDir("supervisor socket path is too long for a unix socket: %s" % candidate)
    return candidate


def controller_socket(domain_id, base=None, env=None):
    return str(socket_dir(domain_id, base, env) / "c.sock")

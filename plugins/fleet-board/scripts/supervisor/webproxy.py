"""Small bounded HTTP frontend client for the local supervisor control socket."""
import json
import os
from pathlib import Path

from . import errors, paths
import socket
import stat
import struct

MAX_REQUEST = 1024 * 1024
MAX_RESPONSE = 4 * 1024 * 1024
TIMEOUT = 5.0


def ui_status(status):
    """A v2 status plus the keys board.js reads (desired_mode, phase, ready, capacity, queue).

    The supervisor reports only what it knows; anything it does not know stays null, which the
    page renders as unknown. Anything that is not a v2 status is returned unchanged."""
    if not isinstance(status, dict) or status.get("schema_version") != 2:
        return status
    active = status.get("active") if isinstance(status.get("active"), list) else []
    providers = {}
    for action in active:
        name = action.get("provider") if isinstance(action, dict) else None
        if isinstance(name, str):
            providers[name] = providers.get(name, 0) + 1
    return dict(status, desired_mode=status.get("mode"), phase=status.get("mode"), ready=True,
                capacity={"slots": len(active), "global_cap": None, "per_provider": providers},
                queue={"ready": None, "running": len(active), "waiting": None, "attention": None})


def socket_path(domain_id):
    """The control socket for a domain. FLEET_BOARD_SUPERVISOR_SOCKET overrides it; the override's
    parent directory and that directory's parent (its grandparent) must both be private (0700),
    owned by this user and not symlinks, or the request is refused."""
    override = os.environ.get("FLEET_BOARD_SUPERVISOR_SOCKET")
    if override:
        return override
    return paths.controller_socket(domain_id)


def _validate_path(path):
    target = Path(path)
    if target.is_symlink():
        raise errors.UnsafeSocketDir("unsafe supervisor socket path")
    info = target.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("untrusted supervisor socket")
    paths.check_socket_path(path)


def _peer_uid(client):
    if hasattr(socket, "SO_PEERCRED"):
        raw = client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        _pid, uid, _gid = struct.unpack("3i", raw)
        return uid
    if hasattr(socket, "LOCAL_PEERCRED"):
        raw = client.getsockopt(getattr(socket, "SOL_LOCAL", 0), socket.LOCAL_PEERCRED, struct.calcsize("=IIh2x16I"))
        return struct.unpack("=IIh2x16I", raw)[1]
    if hasattr(client, "getpeereid"):
        return client.getpeereid()[0]
    raise ValueError("supervisor peer credentials unavailable")


def _peer_uid_matches(client, expected_uid=None):
    return _peer_uid(client) == (os.getuid() if expected_uid is None else expected_uid)


def request(path, payload):
    data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    if len(data) > MAX_REQUEST:
        raise ValueError("supervisor request exceeds limit")
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(TIMEOUT)
    try:
        if not callable(getattr(client, "recv", None)) or client.__class__.__module__ == "socket":
            _validate_path(path)
        client.connect(path)
        if callable(getattr(client, "getsockopt", None)) and not _peer_uid_matches(client):
            raise ValueError("untrusted supervisor peer")
        client.sendall(data)
        chunks, size = [], 0
        while True:
            chunk = client.recv(min(65536, MAX_RESPONSE + 1 - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
            if size > MAX_RESPONSE:
                raise ValueError("supervisor response exceeds limit")
            try:
                json.loads(b"".join(chunks).decode("utf-8"))
                break
            except (ValueError, UnicodeDecodeError):
                pass
        reply = json.loads(b"".join(chunks).decode("utf-8"))
    finally:
        client.close()
    if not isinstance(reply, dict) or not reply.get("ok"):
        error = reply.get("error", {}) if isinstance(reply, dict) else {}
        if isinstance(error, str):
            error = {"code": "internal", "message": error}
        raise RuntimeError(json.dumps(error))
    return reply.get("result")

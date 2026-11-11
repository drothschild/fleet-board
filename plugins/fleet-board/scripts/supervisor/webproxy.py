"""Small bounded HTTP frontend client for the local supervisor control socket."""
import json
import os
from pathlib import Path
import socket
import time

MAX_REQUEST = 1024 * 1024
MAX_RESPONSE = 4 * 1024 * 1024
TIMEOUT = 5.0
_LAST = {}


def socket_path(domain_id):
    override = os.environ.get("FLEET_BOARD_SUPERVISOR_SOCKET")
    if override:
        return override
    return str(Path(os.environ.get("TMPDIR", "/tmp")) /
               ("fb-supervisor-" + domain_id[:12]) / "c.sock")


def request(path, payload):
    data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    if len(data) > MAX_REQUEST:
        raise ValueError("supervisor request exceeds limit")
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(TIMEOUT)
    try:
        client.connect(path)
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
        reply = json.loads(b"".join(chunks).decode("utf-8"))
    finally:
        client.close()
    if not isinstance(reply, dict) or not reply.get("ok"):
        raise RuntimeError(reply.get("error", "supervisor request failed") if isinstance(reply, dict) else "invalid supervisor response")
    return reply.get("result")


def remember(domain_id, state):
    _LAST[domain_id] = (time.time(), state)


def last(domain_id):
    return _LAST.get(domain_id)

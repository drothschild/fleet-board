"""The one place that starts the supervisor detached and waits until its socket answers.

Both `supervisor start --detach` (a later phase) and the board server's Start on an unreachable
supervisor call launch_detached(). It never creates a second owner: the child takes the
repository's owner lock or exits, and either way the caller talks to whoever owns it.
"""
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

from . import paths, webproxy

READY_TIMEOUT = 8.0
_LOG_TAIL = 300


class LaunchError(RuntimeError):
    """The supervisor did not become ready; the message says why."""


def launch_detached(root, log_path, env=None, timeout=READY_TIMEOUT):
    """Start `supervisor.cli start` in its own session for root; return once its socket answers.

    Output goes to log_path (private, appended). Returns {"ready": True, "pid": <supervisor pid>,
    "log": log_path}. Raises LaunchError when the child exits first or does not answer in time
    (a child that never became ready is terminated)."""
    env = os.environ if env is None else env
    root = Path(root).resolve(strict=True)
    log_path = Path(log_path).absolute()
    scripts = str(Path(__file__).resolve().parents[1])
    child_env = dict(os.environ)
    # The caller's environment decides the socket location, never ours: pop what it did not give.
    child_env.pop("FLEET_BOARD_SOCKET_DIR", None)
    if env.get("FLEET_BOARD_SOCKET_DIR"):
        child_env["FLEET_BOARD_SOCKET_DIR"] = env["FLEET_BOARD_SOCKET_DIR"]
    for key in ("FLEET_BOARD_LOG_DIR", "FLEET_BOARD_CONFIG"):
        if env.get(key):
            child_env[key] = env[key]
    child_env.update({"FLEET_BOARD_DOMAIN": str(root),
                      "PYTHONPATH": scripts + (os.pathsep + child_env["PYTHONPATH"]
                                               if child_env.get("PYTHONPATH") else "")})
    log_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(str(log_path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a") as log:
        child = subprocess.Popen([sys.executable, "-m", "supervisor.cli", "start"], cwd=str(root),
                                 env=child_env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                 start_new_session=True)
    socket_path = paths.controller_socket(paths.domain_id_for_root(root), env=child_env)

    def probe():
        try:
            return webproxy.request(socket_path, {"command": "status"})
        except (OSError, ValueError, RuntimeError):
            return None
    deadline = time.time() + timeout
    while True:
        status = probe()
        if status is not None:
            threading.Thread(target=_reap, args=(child,), daemon=True).start()
            return {"ready": True, "pid": status.get("pid"), "log": str(log_path)}
        if child.poll() is not None:
            raise LaunchError("supervisor exited before it answered" + _tail(log_path))
        if time.time() >= deadline:
            _discard(child)
            raise LaunchError("supervisor readiness timed out after %.0f seconds" % timeout + _tail(log_path))
        time.sleep(0.05)


def _tail(log_path):
    try:
        text = Path(log_path).read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""
    return ": " + text[-_LOG_TAIL:] if text else ""


def _discard(child):
    """Terminate a child that never became ready and reap it."""
    child.terminate()
    try:
        child.wait(timeout=3)
    except Exception:  # noqa: BLE001 - best effort; the child was asked to exit
        pass


def _reap(child):
    """Reap the child when it exits so a long-lived caller (the board server) leaves no zombie."""
    try:
        child.wait()
    except Exception:  # noqa: BLE001 - nothing to do if the child is already gone
        pass


def wait_until(probe, timeout=5.0, interval=0.05):
    """Poll probe() until it returns a truthy value or timeout; return the last value."""
    deadline = time.time() + timeout
    value = probe()
    while not value and time.time() < deadline:
        time.sleep(interval)
        value = probe()
    return value

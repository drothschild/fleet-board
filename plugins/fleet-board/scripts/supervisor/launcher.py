"""The one place that starts the supervisor detached and waits until its socket answers.

Both `supervisor start --detach` and the board server's Start on an unreachable
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

READY_TIMEOUT = 30.0
_LOG_TAIL = 300
_OUTPUT_MAX = 64 * 1024


class LaunchError(RuntimeError):
    """The supervisor did not become ready; the message says why. `exit_code` is the child's exit status when
    it exited (4: it refused to start over stuck cards) and `output` is what it wrote during this launch."""

    def __init__(self, message, exit_code=None, output=""):
        super().__init__(message)
        self.exit_code = exit_code
        self.output = output


def launch_detached(root, log_path, env=None, timeout=READY_TIMEOUT, ignore_stuck=False):
    """Start `supervisor.cli start` in its own session for root; return once it is ready: its socket answers
    and reports startup "done" (the startup check passed and the loop is running).

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
        child_env.pop(key, None)
        if env.get(key):
            child_env[key] = env[key]
    child_env.update({"FLEET_BOARD_DOMAIN": str(root),
                      "PYTHONPATH": scripts + (os.pathsep + child_env["PYTHONPATH"]
                                               if child_env.get("PYTHONPATH") else "")})
    # FLEET_BOARD_SUPERVISOR_SOCKET is a client-side override: the child binds at the default location.
    bind_path = paths.controller_socket(paths.domain_id_for_root(root), env=child_env)
    override = env.get("FLEET_BOARD_SUPERVISOR_SOCKET")
    if override and override != bind_path:
        raise LaunchError("FLEET_BOARD_SUPERVISOR_SOCKET points away from where start binds: %s" % bind_path)
    log_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(str(log_path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.fchmod(fd, 0o600)
    offset = os.fstat(fd).st_size
    argv = [sys.executable, "-m", "supervisor.cli", "start"] + (["--ignore-stuck"] if ignore_stuck else [])
    with os.fdopen(fd, "a") as log:
        child = subprocess.Popen(argv, cwd=str(root),
                                 env=child_env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                 start_new_session=True)
    socket_path = bind_path

    def probe():
        try:
            return webproxy.request(socket_path, {"command": "status"})
        except (OSError, ValueError, RuntimeError):
            return None
    deadline = time.time() + timeout
    while True:
        status = probe()
        # Only the child counts: a supervisor that already runs answers too, but the child then exits.
        if isinstance(status, dict) and status.get("startup") == "done" and status.get("pid") == child.pid:
            threading.Thread(target=_reap, args=(child,), daemon=True).start()
            return {"ready": True, "pid": status.get("pid"), "log": str(log_path)}
        code = child.poll()
        if code is not None:
            output = _output(log_path, offset)
            raise LaunchError("supervisor exited before it was ready (exit %s)" % code + _tail(output),
                              exit_code=code, output=output)
        if time.time() >= deadline:
            _discard(child)
            raise LaunchError("supervisor readiness timed out after %.0f seconds" % timeout
                              + _tail(_output(log_path, offset)))
        time.sleep(0.05)


def _output(log_path, offset):
    """What the child wrote since this launch began (the log is appended across runs)."""
    try:
        with open(str(log_path), "rb") as handle:
            handle.seek(offset)
            return handle.read(_OUTPUT_MAX).decode("utf-8", errors="replace")
    except OSError:
        return ""


def _tail(output):
    text = output.strip()
    return ": " + text[-_LOG_TAIL:] if text else ""


def _discard(child):
    """Terminate a child that never became ready and reap it."""
    child.terminate()
    try:
        child.wait(timeout=10)
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

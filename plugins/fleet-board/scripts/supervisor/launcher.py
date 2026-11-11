"""The one place that launches a detached supervisor service and waits for its readiness ack.

Both the CLI (`supervisor start`) and the board server (Start on an unreachable service) call
launch_service(). It never creates a second owner: the child takes the service lock or reports
`owner: false`, and the caller then reconnects to whoever owns it.
"""
import json
import os
import select
import subprocess
import sys
import threading
import time
from pathlib import Path

from . import paths

READY_TIMEOUT = 8.0


class LaunchError(RuntimeError):
    """The service did not become ready; the message says why."""


def _argv(board_root, log_dir, socket_tmp):
    return [sys.executable, "-m", "supervisor.cli", "serve", "--domain", str(board_root),
            "--log-dir", str(Path(log_dir).absolute()), "--socket-tmp", str(Path(socket_tmp).absolute())]


def launch_service(board_root, env=None, timeout=READY_TIMEOUT):
    """Start `supervisor.cli serve` detached for board_root and return its readiness ack.

    The ack is returned as the service printed it. `owner: false` is a valid answer: another
    healthy owner won the lock, and the caller reconnects to it. Raises LaunchError when the
    child times out, exits first, or reports it cannot serve (the child is terminated)."""
    env = os.environ if env is None else env
    board_root = Path(board_root).resolve(strict=True)
    log_dir = str(paths.log_dir(env))
    socket_tmp = paths.socket_tmpdir(env)
    scripts = str(Path(__file__).resolve().parents[1])
    child_env = dict(os.environ)
    child_env.update({"FLEET_BOARD_LOG_DIR": log_dir, "TMPDIR": socket_tmp,
                      "PYTHONPATH": scripts + (os.pathsep + child_env["PYTHONPATH"]
                                               if child_env.get("PYTHONPATH") else "")})
    child = subprocess.Popen(_argv(board_root, log_dir, socket_tmp), cwd=str(board_root), env=child_env,
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, start_new_session=True)
    ready, _, _ = select.select([child.stdout], [], [], timeout)
    if not ready:
        _discard(child)
        raise LaunchError("supervisor service readiness timed out after %.0f seconds" % timeout)
    line = child.stdout.readline()
    if not line:
        detail = child.stderr.read().strip()
        _discard(child)
        raise LaunchError("supervisor service exited before readiness" + (": " + detail[-300:] if detail else ""))
    try:
        ack = json.loads(line)
    except ValueError as exc:
        _discard(child)
        raise LaunchError("supervisor service returned an invalid readiness acknowledgement") from exc
    if not isinstance(ack, dict) or not ack.get("ready") or ack.get("socket_unavailable"):
        _discard(child)
        raise LaunchError("supervisor service failed to become ready: " + json.dumps(ack))
    # The child owns its own life from here; reap it when it exits so a long-lived caller
    # (the board server) leaves no zombie after a Stop.
    for pipe in (child.stdout, child.stderr):
        try:
            pipe.close()
        except (OSError, ValueError):
            pass
    threading.Thread(target=_reap, args=(child,), daemon=True).start()
    return ack


def _discard(child):
    """Terminate a child that never became ready and reap it."""
    child.terminate()
    try:
        child.wait(timeout=3)
    except Exception:  # noqa: BLE001 - best effort; the child was asked to exit
        pass


def _reap(child):
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

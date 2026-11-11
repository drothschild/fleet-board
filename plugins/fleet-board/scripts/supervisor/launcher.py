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


def _argv(board_root, log_dir):
    return [sys.executable, "-m", "supervisor.cli", "serve", "--domain", str(board_root),
            "--log-dir", str(Path(log_dir).absolute())]


def service_log_path(env=None):
    """Where the detached service's stderr goes: a real file, never a pipe nobody drains."""
    return paths.log_dir(env) / "supervisor-service.log"


def _open_log(path):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.fchmod(fd, 0o600)
    return fd


def _log_tail(path, offset):
    try:
        with open(str(path), "rb") as stream:
            stream.seek(offset)
            return stream.read().decode("utf-8", "replace").strip()
    except OSError:
        return ""


def _registered_credentials(board_root, env):
    """The registered domain's credentials.env values (every parsed name) for any start. A
    missing or unsafe file never blocks an explicit Start: it prints the same hint the boot watcher
    shows, naming variables only. Values never reach argv or a log."""
    from . import boot  # deferred: boot imports this module
    try:
        reg = boot.registry_dir(env)
        entry, _error = boot._load_entry(reg, boot._key_for(board_root, reg))
    except Exception:  # noqa: BLE001 - no usable registration means nothing to add
        return {}
    if not entry:
        return {}
    values, problem = boot.registered_credentials(reg, entry)
    absent = [name for name in entry.get("credentials", []) if not (values.get(name) or env.get(name) or os.environ.get(name))]
    if absent:
        print("supervisor: credentials not available to the service: %s (%s)"
              % (", ".join(absent), problem or "create %s with mode 0600" % (reg / "credentials.env")),
              file=sys.stderr, flush=True)
    return values


def launch_child(board_root, env=None, timeout=READY_TIMEOUT, extra_env=None, merge_registered=True):
    """Start `supervisor.cli serve` detached for board_root; return (child, ack).

    The ack is returned as the service printed it. `owner: false` is a valid answer: another
    healthy owner won the lock, and the caller reconnects to it. Raises LaunchError when the
    child times out, exits first, or reports it cannot serve (the child is terminated).
    The caller owns the child (and its stdout pipe) afterwards; stderr is a log file. `extra_env`
    is added to the child's environment (never to argv) and wins over the registered values.
    `merge_registered=False` skips reading credentials.env, for a caller that already did."""
    env = os.environ if env is None else env
    board_root = Path(board_root).resolve(strict=True)
    log_dir = str(paths.log_dir(env))
    scripts = str(Path(__file__).resolve().parents[1])
    child_env = dict(os.environ)
    if merge_registered:  # every caller gets a registered domain's credentials; the file beats the process env
        child_env.update(_registered_credentials(board_root, env))
    child_env.update(extra_env or {})  # e.g. the service environment the boot watcher built on this tick
    child_env.update({"FLEET_BOARD_LOG_DIR": log_dir,
                      "PYTHONPATH": scripts + (os.pathsep + child_env["PYTHONPATH"]
                                               if child_env.get("PYTHONPATH") else "")})
    if env.get("FLEET_BOARD_SOCKET_DIR"):
        child_env["FLEET_BOARD_SOCKET_DIR"] = env["FLEET_BOARD_SOCKET_DIR"]
    log_path = service_log_path(env)
    log_fd = _open_log(log_path)
    offset = os.fstat(log_fd).st_size
    try:
        child = subprocess.Popen(_argv(board_root, log_dir), cwd=str(board_root), env=child_env,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=log_fd,
                                 text=True, start_new_session=True)
    finally:
        os.close(log_fd)
    ready, _, _ = select.select([child.stdout], [], [], timeout)
    if not ready:
        discard(child)
        raise LaunchError("supervisor service readiness timed out after %.0f seconds" % timeout)
    line = child.stdout.readline()
    if not line:
        detail = _log_tail(log_path, offset)
        discard(child)
        raise LaunchError("supervisor service exited before readiness" + (": " + detail[-300:] if detail else ""))
    try:
        ack = json.loads(line)
    except ValueError as exc:
        discard(child)
        raise LaunchError("supervisor service returned an invalid readiness acknowledgement") from exc
    if not isinstance(ack, dict) or not ack.get("ready") or ack.get("socket_unavailable"):
        discard(child)
        raise LaunchError("supervisor service failed to become ready: " + json.dumps(ack))
    return child, ack


def launch_service(board_root, env=None, timeout=READY_TIMEOUT):
    """launch_child() for a caller that does not supervise the child: it owns its own life
    from here, and is reaped when it exits so a long-lived caller (the board server) leaves
    no zombie after a Stop."""
    child, ack = launch_child(board_root, env=env, timeout=timeout)
    try:
        child.stdout.close()
    except (OSError, ValueError):
        pass
    threading.Thread(target=_reap, args=(child,), daemon=True).start()
    return ack


def discard(child):
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

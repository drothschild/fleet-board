"""Command line for the supervisor: `start` is the supervisor process, the rest talk to it."""
import argparse
import contextlib
import json
import os
import signal
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path

from . import errors, launcher, loop, paths, stuck, usage
from .driver import CardDriver
from .scheduler import Scheduler
from .service import Service, default_run_lock_path
from .state import State

USAGE = ("usage: supervisor <start [--detach] [--ignore-stuck] | status [--json] | pause | resume | "
         "stop [--drain|--cancel] | usage [--card N] [--json] | stuck [--json] [--release N [--force]]>")
EPILOG = """\
exit codes: 0 ok, 1 error or supervisor not running, 2 usage, 4 start refused: cards a previous
  supervisor left half done (list them with `stuck`, resolve with `stuck --release N`, or
  start with --ignore-stuck)

environment:
  FLEET_BOARD_DOMAIN             the board root (default: the git toplevel of the current directory)
  FLEET_BOARD_SOCKET_DIR         base directory for the supervisor socket (default /tmp/fleet-board-<uid>);
                                 never derived from TMPDIR
  FLEET_BOARD_SUPERVISOR_SOCKET  talk to this socket instead of the default one. The socket's parent
                                 directory and that directory's parent (its grandparent) must both be
                                 private (mode 0700) and owned by you, and neither may be a symlink;
                                 anything else is refused.
"""


class _Remote(ValueError):
    """An error reply from the service; .code is its wire code (str(exc) is unchanged)."""

    @property
    def code(self):
        error = self.args[0] if self.args else None
        return error.get("code") if isinstance(error, dict) else None

    def describe(self):
        error = self.args[0] if self.args else None
        return error.get("message", str(error)) if isinstance(error, dict) else str(error)


def _socket_transport(path):
    def send(request):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(5)
        try:
            try:
                paths.check_socket_path(path)
            except FileNotFoundError:
                pass  # no socket directory yet: connect() reports the supervisor as not running
            client.connect(path)
            client.sendall(json.dumps(request, separators=(",", ":")).encode("utf-8"))
            chunks, size = [], 0
            while True:
                chunk = client.recv(min(65536, 4 * 1024 * 1024 + 1 - size))
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
                if size > 4 * 1024 * 1024:
                    raise ValueError("response size exceeds limit")
            response = json.loads(b"".join(chunks).decode("utf-8"))
        finally:
            client.close()
        if not response.get("ok"):
            raise _Remote(response.get("error", "supervisor request failed"))
        return response["result"]
    return send


def _board_root(env):
    """FLEET_BOARD_DOMAIN, else the git toplevel of the current directory."""
    domain = env.get("FLEET_BOARD_DOMAIN")
    if not domain:
        try:
            out = subprocess.run(["git", "rev-parse", "--show-toplevel"], stdin=subprocess.DEVNULL,
                                 capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            out = None
        domain = out.stdout.strip() if out is not None and out.returncode == 0 else ""
        if not domain:
            raise ValueError("FLEET_BOARD_DOMAIN is not set and the current directory is not in a git checkout")
    return Path(domain).resolve(strict=True)


def _socket_for(root, env):
    return env.get("FLEET_BOARD_SUPERVISOR_SOCKET") or paths.controller_socket(
        paths.domain_id_for_root(root), env=env)


class _UsageParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


def _parser():
    parser = _UsageParser(prog="supervisor", description="Run and control the Fleet Board supervisor",
                          epilog=EPILOG, formatter_class=argparse.RawDescriptionHelpFormatter, add_help=False)
    subs = parser.add_subparsers(dest="command", required=True, parser_class=_UsageParser)
    start = subs.add_parser("start")
    start.add_argument("--detach", action="store_true")
    start.add_argument("--ignore-stuck", action="store_true")
    status = subs.add_parser("status")
    status.add_argument("--json", action="store_true")
    use = subs.add_parser("usage")
    use.add_argument("--card", type=int)
    use.add_argument("--json", action="store_true")
    left = subs.add_parser("stuck")
    left.add_argument("--json", action="store_true")
    left.add_argument("--release", type=int)
    left.add_argument("--force", action="store_true")
    subs.add_parser("pause")
    subs.add_parser("resume")
    stop = subs.add_parser("stop")
    group = stop.add_mutually_exclusive_group()
    group.add_argument("--drain", action="store_true")
    group.add_argument("--cancel", action="store_true")
    return parser


def main(argv=None, *, env=None, stdout=None, stderr=None, transport=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    env = os.environ if env is None else env
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    if argv and argv[0] in ("-h", "--help", "help"):
        print(USAGE + "\n\n" + EPILOG, file=stdout, end="")
        return 0
    try:
        args = _parser().parse_args(argv)
    except (ValueError, SystemExit):
        print(USAGE, file=stderr)
        return 2
    root = None
    try:
        if args.command == "start" and args.detach:
            return _detach(_board_root(env), env, stdout, stderr, ignore_stuck=args.ignore_stuck)
        if args.command == "start":
            with _process_env(env):
                return _start(_board_root(env), stdout, stderr, ignore_stuck=args.ignore_stuck)
        if args.command == "usage":
            return _usage(args, env, stdout, transport)
        if args.command == "stuck":
            return _stuck(args, env, stdout, stderr, transport)
        if transport is None:
            root = _board_root(env)
            transport = _socket_transport(_socket_for(root, env))
        if args.command == "status":
            try:
                status = transport({"command": "status"})
            except errors.UnsafeSocketDir:
                # An unsafe socket location is never connected to: no supervisor is running here.
                raise FileNotFoundError from None
            print(json.dumps(status) if args.json else _human_status(status), file=stdout)
            return 0
        extra = {}
        if args.command == "stop":
            extra["mode"] = "cancel" if args.cancel else "drain"
        print(json.dumps(_send_mutation(transport, args.command, extra)), file=stdout)
        return 0
    except (_Remote, errors.SupervisorError) as exc:
        print("supervisor: " + (exc.describe() if isinstance(exc, _Remote) else str(exc)), file=stderr)
        return 1
    except socket.timeout:
        print("supervisor: the supervisor did not answer in time", file=stderr)
        return 1
    except OSError as exc:
        if isinstance(exc, (FileNotFoundError, ConnectionRefusedError)):
            print("supervisor not running%s" % (" for " + str(root) if root is not None else ""), file=stderr)
        else:
            print("supervisor: " + str(exc), file=stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 - the CLI reports, it never traces
        print("supervisor: " + str(exc), file=stderr)
        return 1


_ENV_KEYS = ("FLEET_BOARD_SOCKET_DIR", "FLEET_BOARD_LOG_DIR", "FLEET_BOARD_CONFIG", "FLEET_BOARD_DOMAIN")


@contextlib.contextmanager
def _process_env(env):
    """Run the supervisor on the env it was given: the paths, the run lock and the board scripts it starts
    all read os.environ, so the FLEET_BOARD_* location keys of `env` are applied for the run and restored."""
    if env is os.environ:
        yield
        return
    saved = {key: os.environ.get(key) for key in _ENV_KEYS}
    for key in _ENV_KEYS:
        if env.get(key):
            os.environ[key] = env[key]
        else:
            os.environ.pop(key, None)
    try:
        yield
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def _detach(root, env, stdout, stderr, ignore_stuck=False):
    """Start the supervisor in the background; return once it passed the startup check and runs the loop."""
    try:
        ack = launcher.launch_detached(root, paths.log_dir(env) / "supervisor.log", env=env,
                                       ignore_stuck=ignore_stuck)
    except launcher.LaunchError as exc:
        if exc.exit_code == 4:
            print(exc.output.strip(), file=stderr)
            return 4
        print("supervisor: " + str(exc), file=stderr)
        return 1
    print(json.dumps(ack), file=stdout)
    return 0


def _start(root, stdout, stderr, ignore_stuck=False):
    """Run the supervisor in the foreground until it is told to stop; exit 0 after a clean stop, 4 when it
    refuses to start because a previous supervisor left cards half done."""
    state = State(uuid.uuid4().hex, time.time)
    loader = loop.config_loader(root)
    supervisor = loop.Supervisor(root, config_loader=loader, state=state, scheduler=Scheduler(),
                                 driver=CardDriver(root, loader, state))
    service = Service(root, state, supervisor.handle)
    service.startup = "checking"
    # Installed before readiness is announced (and before the socket exists): a signal at any
    # point after this ends the run through close(), never leaving a socket or run lock behind.
    # Ctrl-C (twice: no grace period), SIGTERM and SIGHUP cancel the running sessions and exit 0.
    previous = {}
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        try:
            previous[number] = signal.signal(number, supervisor.on_signal)
        except ValueError:
            pass  # not the main thread: the caller stops it through the socket
    try:
        ack = service.serve()
        if not ack.get("owner"):
            if ack.get("socket_unavailable"):
                print("supervisor: cannot bind the supervisor socket here", file=stderr)
            else:
                pid = service.owner_pid()
                print("supervisor already running for %s (pid %s)" % (root, pid if pid else "unknown"), file=stderr)
            return 1
        # The startup check runs only once this process owns the repository (a running supervisor's own
        # cards would otherwise look stuck), and before any work is admitted or readiness is announced.
        found = stuck.find(root)
        if found:
            for card in stuck.record(root, found):
                print("supervisor: warning: the stuck note for #%d could not be written" % card, file=stderr)
            for item in found:
                print("#%d %s: %s" % (item.card, item.kind, item.detail), file=stderr)
            if not ignore_stuck:
                print("supervisor: %d stuck item%s from an earlier run; nothing was started. Resolve each card "
                      "(move it, or `supervisor stuck --release N`), or start with --ignore-stuck."
                      % (len(found), "" if len(found) == 1 else "s"), file=stderr)
                return 4
            supervisor.ignored = stuck.snapshot(root, found)
        service.startup = "done"
        print(json.dumps(ack), file=stdout, flush=True)
        return supervisor.run()
    finally:
        service.close()
        for number, old in previous.items():
            if old is not None:
                signal.signal(number, old)


def _usage(args, env, stdout, transport):
    """Ask the running supervisor (it knows this run's total); with none running, read the ledger."""
    request = {"command": "usage"}
    if args.card is not None:
        request["card"] = args.card
    root = None
    try:
        if transport is None:
            root = _board_root(env)
            transport = _socket_transport(_socket_for(root, env))
        result = transport(request)
    except (FileNotFoundError, ConnectionRefusedError, errors.UnsafeSocketDir):
        # An unsafe socket location is never connected to: it means no supervisor runs here.
        if root is None:
            raise
        result = _local_usage(root, args.card)
    print(json.dumps(result) if args.json else _human_usage(result), file=stdout)
    return 0


def _stuck(args, env, stdout, stderr, transport):
    """List (or release) stuck cards. The board is read here, never through the supervisor's socket (a slow
    check must not hit the socket timeout); a running supervisor is asked only for the cards it owns. The socket
    alone is never trusted: a live process holding the repository run lock that did not answer as the
    supervisor (a supervisor of another checkout, or one this client cannot reach) refuses a release."""
    if args.force and args.release is None:
        raise errors.Invalid("--force needs --release N")
    root = _board_root(env)
    live, answered = set(), None
    try:
        status = (transport or _socket_transport(_socket_for(root, env)))({"command": "status"})
        live = {a.get("card") for a in status.get("active") or [] if isinstance(a, dict)}
        answered = status.get("pid") if isinstance(status, dict) else None
    except (FileNotFoundError, ConnectionRefusedError, errors.UnsafeSocketDir):
        pass   # no supervisor running: nothing is live
    holder = stuck.run_lock_holder(default_run_lock_path(root, env=env))
    other = holder if holder is not None and holder != answered else None
    if args.release is not None:
        if args.release in live:
            raise errors.Invalid("card #%d is owned by the running supervisor" % args.release)
        if other is not None:
            raise errors.Invalid("a supervisor of another checkout holds the repository run lock (pid %d); stop it "
                                 "before releasing" % other)
        stuck.release(root, args.release, force=args.force, live_cards=live)
        print("released #%d" % args.release, file=stdout)
        return 0
    found = [item._asdict() for item in stuck.find(root, live_cards=live)]
    notice = ("note: a supervisor of another checkout holds the repository run lock (pid %d) and did not answer "
              "here; this list may include its live work" % other) if other is not None else None
    if args.json:
        if notice:
            print(notice, file=stderr)
        print(json.dumps(found), file=stdout)
        return 0
    if notice:
        print(notice, file=stdout)
    if not found:
        print("no stuck cards", file=stdout)
    else:
        for item in found:
            print("#%d %s: %s" % (item["card"], item["kind"], item["detail"]), file=stdout)
    return 0


def _local_usage(root, card):
    try:
        board_dir = (loop.config_loader(root)().get("board") or {}).get("dir")
    except Exception:  # noqa: BLE001 - an unreadable config falls back to the default directory
        board_dir = None
    try:
        return usage.view(root, board_dir or usage.DEFAULT_DIR, card=card)
    except ValueError as exc:
        raise errors.Invalid(str(exc)) from None


def _tokens(totals):
    text = "%d tokens (input %d, output %d, cache write %d, cache read %d)" % (
        totals["total"], totals["input"], totals["output"], totals["cache_write"], totals["cache_read"])
    if totals["unknown"]:
        text += "; %d action%s with unknown usage" % (totals["unknown"], "" if totals["unknown"] == 1 else "s")
    return text + (" [partial]" if totals["partial"] else "")


def _human_usage(result):
    lines = []
    if "card" in result:   # the drill-down; the summary also has "columns" (per-column totals)
        lines.append("card %s: %s" % (result["card"], _tokens(result["totals"])))
        for column in result["columns"]:
            lines.append("  %s: %s" % (column["column"], _tokens(column["totals"])))
            for action in column["actions"]:
                known = [action[k] for k in usage.COUNTS]
                counts = "unknown" if any(v is None for v in known) else "%d tokens" % sum(known)
                detail = ", ".join("%s %s" % (k.replace("_", " "), "unknown" if action[k] is None else action[k])
                                   for k in usage.COUNTS)
                lines.append("    %s (%s): %s [%s] %s" % (action["action"], action["ended_at"], counts, detail,
                                                           action["log"] or "no log"))
    else:
        lines.append("this run: " + (_tokens(result["run"]) if result.get("run") else "no supervisor running"))
        lines.append("all time: " + _tokens(result["all_time"]))
        lines.append("planner:  " + _tokens(result["planner"]))
    if result.get("warning"):
        lines.append("warning: " + result["warning"])
    return "\n".join(lines)


def _human_status(status):
    mode = status.get("mode", "unknown")
    if mode == "paused" and status.get("pause_reason"):
        mode = "paused (%s)" % status["pause_reason"]
    lines = ["supervisor running for %s (pid %s)" % (status.get("root", "?"), status.get("pid", "?")),
             "mode: " + mode]
    active = status.get("active") or []
    lines.append("active: %d" % len(active))
    for action in active:
        lines.append("  card %s: %s (%s)" % (action.get("card"), action.get("action"), action.get("provider")))
    return "\n".join(lines)


def _send_mutation(transport, command, extra, attempts=5):
    """Bind the command to the revision just read. A revision that moved in between is re-read
    and retried with a fresh request id (pause, resume and stop are idempotent)."""
    for attempt in range(attempts):
        current = transport({"command": "status"})
        request = dict(extra, command=command, request_id=str(uuid.uuid4()),
                       expected_revision=current.get("revision", 0) if isinstance(current, dict) else 0)
        try:
            return transport(request)
        except (_Remote, errors.StaleRevision) as exc:
            if getattr(exc, "code", None) != "stale_revision" or attempt == attempts - 1:
                raise


if __name__ == "__main__":
    raise SystemExit(main())

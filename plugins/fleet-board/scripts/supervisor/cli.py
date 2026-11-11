"""Command line client for the persistent supervisor."""
import argparse
import json
import os
import select
import subprocess
import sys
import time
import uuid
from pathlib import Path

from . import paths
from .service import Service


def _socket_transport(path):
    import socket
    def send(request):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(5)
        try:
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
            raise ValueError(response.get("error", "supervisor request failed"))
        return response["result"]
    return send


def main(argv=None, *, env=None, stdout=None, stderr=None, transport=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    env = os.environ if env is None else env
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    # Exit codes: 0 ok; 1 error or unreachable service; 2 usage error;
    # 3 `start` launched/reached the service but supervisor.enabled is false
    # (it stays queryable read-only; execution is not started).
    class UsageParser(argparse.ArgumentParser):
        def error(self, message):
            raise ValueError(message)
    parser = UsageParser(prog="supervisor", description="Control the Fleet Board supervisor",
                          epilog="exit codes: 0 ok, 1 error, 2 usage, 3 start refused because supervisor.enabled is false")
    subs = parser.add_subparsers(dest="command", required=True, parser_class=UsageParser)
    for name in ("start", "pause", "resume", "status", "reconcile", "events"):
        sub = subs.add_parser(name)
        if name == "events":
            sub.add_argument("--after", type=int, default=0)
            sub.add_argument("--limit", type=int, default=100)
    stop = subs.add_parser("stop")
    stop.add_argument("--mode", choices=("drain", "cancel"))
    resolve = subs.add_parser("resolve")
    resolve.add_argument("--card", type=int)
    resolve.add_argument("--action", choices=("retry", "record_usage", "confirm_effect", "abandon"))
    resolve.add_argument("--reason")
    serve = subs.add_parser("serve")
    serve.add_argument("--domain", required=True)
    serve.add_argument("--log-dir", required=True)
    serve.add_argument("--socket-tmp", required=True)
    try:
        args = parser.parse_args(argv)
    except (ValueError, SystemExit) as exc:
        print("usage: supervisor <start|pause|resume|stop|status|reconcile|events|resolve>", file=stderr)
        return 2
    if args.command == "stop" and args.mode is None:
        print("usage: supervisor stop --mode {drain,cancel}", file=stderr)
        return 2
    if args.command == "resolve" and (args.card is None or args.action is None):
        print("usage: supervisor resolve --card N --action ACTION", file=stderr)
        return 2
    if args.command == "resolve":
        args.reason = args.reason or "manual resolution"
    try:
        if args.command == "serve":
            os.environ["FLEET_BOARD_LOG_DIR"] = args.log_dir
            os.environ["TMPDIR"] = args.socket_tmp
            board_root = Path(args.domain).resolve(strict=True)
            domain = paths.board_domain(board_root, Path(args.log_dir) / "supervisor")
            service = Service.open(domain, board_repo=_repo_slug(board_root))
            ack = service.start_serving()
            print(json.dumps(ack), flush=True)
            if not ack.get("owner") or ack.get("socket_unavailable"):
                return 1
            try:
                while not service.stopped.wait(1):
                    pass
            finally:
                service.close()
        domain_root = env.get("FLEET_BOARD_DOMAIN")
        if not domain_root and transport is None:
            raise ValueError("FLEET_BOARD_DOMAIN is required")
        if transport is None:
            board_root = Path(domain_root).resolve(strict=True)
            if args.command == "start":
                log_dir = str(paths.log_dir(env))
                socket_tmp = paths.socket_tmpdir(env)
                plugin_scripts = Path(__file__).resolve().parents[1]
                child_env = dict(os.environ)
                child_env.update({"FLEET_BOARD_LOG_DIR": log_dir, "TMPDIR": socket_tmp,
                                  "PYTHONPATH": str(plugin_scripts) +
                                  (os.pathsep + child_env["PYTHONPATH"] if child_env.get("PYTHONPATH") else "")})
                child = subprocess.Popen(
                    [sys.executable, "-m", "supervisor.cli", "serve", "--domain", str(board_root),
                     "--log-dir", str(Path(log_dir).absolute()), "--socket-tmp", str(Path(socket_tmp).absolute())],
                    cwd=str(board_root), env=child_env, stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                    start_new_session=True)
                ready, _, _ = select.select([child.stdout], [], [], 8.0)
                if not ready:
                    child.terminate()
                    raise TimeoutError("supervisor service readiness timed out")
                line = child.stdout.readline()
                if not line:
                    detail = child.stderr.read().strip()
                    raise RuntimeError("supervisor service exited before readiness" +
                                       (": " + detail if detail else ""))
                try:
                    ack = json.loads(line)
                except ValueError as exc:
                    child.terminate()
                    raise RuntimeError("supervisor service returned an invalid readiness acknowledgement") from exc
                if not ack.get("ready") or not ack.get("owner") or ack.get("socket_unavailable"):
                    child.terminate()
                    raise RuntimeError("supervisor service failed to become ready: " + json.dumps(ack))
                if not ack.get("execution_available", True):
                    print("supervisor: supervisor.enabled: false; service is running read-only",
                          file=stderr)
                    return 3
                return _print_result(ack, stdout)
            else:
                # Pure: the id comes from the identity inputs; no store is opened.
                path = paths.controller_socket(paths.domain_id_for_root(board_root), paths.socket_tmpdir(env))
                transport = _socket_transport(path)
        if args.command == "resolve":
            current = transport({"command": "status"})
            request = {"command": "resolve", "card": args.card, "action": args.action,
                       "reason": args.reason, "request_id": uuid.uuid4().hex,
                       "expected_revision": current.get("revision", 0) if isinstance(current, dict) else 0}
        elif args.command == "events":
            request = {"command": "events", "after": args.after, "limit": args.limit}
        else:
            request = {"command": args.command, "request_id": str(uuid.uuid4())}
            if args.command in ("start", "pause", "resume", "stop"):
                current = transport({"command": "status"})
                request["expected_revision"] = current.get("revision", 0) if isinstance(current, dict) else 0
            if args.command == "stop":
                request["mode"] = args.mode
        result = transport(request)
        if args.command == "reconcile":
            result = {"snapshot": result, "cursor": len(result.get("events", []))}
        print(json.dumps(result), file=stdout)
        return 0
    except Exception as exc:
        print("supervisor: " + str(exc), file=stderr)
        return 2 if "unsupported" in str(exc).lower() else 1


def _print_result(result, stdout):
    print(json.dumps(result), file=stdout)
    return 0


def _repo_slug(board_root):
    config = Path(__file__).resolve().parents[1] / "config.sh"
    try:
        result = subprocess.run(["bash", str(config), "--dir", str(board_root), "board.repo"],
                                capture_output=True, text=True, timeout=5)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return board_root.name


if __name__ == "__main__":
    raise SystemExit(main())

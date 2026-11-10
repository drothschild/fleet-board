"""Command line client for the persistent supervisor."""
import argparse
import json
import os
import sys
import uuid
from pathlib import Path

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
    class UsageParser(argparse.ArgumentParser):
        def error(self, message):
            raise ValueError(message)
    parser = UsageParser(prog="supervisor", description="Control the Fleet Board supervisor")
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
        domain_root = env.get("FLEET_BOARD_DOMAIN")
        if not domain_root and transport is None:
            raise ValueError("FLEET_BOARD_DOMAIN is required")
        if transport is None:
            board_root = Path(domain_root).resolve(strict=True)
            git = board_root / ".git"
            common = git.resolve(strict=True) if git.exists() else board_root
            domain = {"common_dir": str(common), "board_backend": "local",
                      "board_identity": str(board_root),
                      "runtime_root": env.get("FLEET_BOARD_LOG_DIR", str(Path.home() / ".fleet-board")) + "/supervisor"}
            if args.command == "start":
                service = Service.open(domain)
                service.start_serving()
                transport = _socket_transport(service.socket_path)
            else:
                from .store import Store
                store = Store.open(domain)
                try:
                    path = str(Path(os.environ.get("TMPDIR", "/tmp")) / ("fb-supervisor-" + store.domain_id[:12]) / "c.sock")
                finally:
                    store.close()
                transport = _socket_transport(path)
        if args.command == "resolve":
            request = {"command": "resolve", "card": args.card, "action": args.action,
                       "reason": args.reason, "request_id": str(uuid.uuid4())}
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


if __name__ == "__main__":
    raise SystemExit(main())

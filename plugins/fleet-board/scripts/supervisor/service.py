"""Single-owner local control service for one supervisor domain."""
import json
import errno
import fcntl
import os
from pathlib import Path
import socket
import stat
import threading
import time

from .processes import _boot_id
from .recovery import Recovery
from .store import Store

MAX_REQUEST = 1024 * 1024
WORKER_COMMANDS = {"heartbeat", "progress", "result", "scope_expansion"}


class Service:
    @classmethod
    def open(cls, domain, *, clock=None, host_boot_id=None, peer_resolver=None):
        store = Store.open(domain)
        return cls(store, clock or time.time, host_boot_id or _boot_id(), peer_resolver)

    def __init__(self, store, clock, host_boot_id, peer_resolver=None):
        self.store = store
        self.clock = clock
        self.host_boot_id = host_boot_id
        self.peer_resolver = peer_resolver or self._peer_actor
        self.recovery = Recovery(store)
        self.directory = str(store.directory)
        socket_root = Path(os.environ.get("TMPDIR", "/tmp")) / ("fb-supervisor-" + store.domain_id[:12])
        socket_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(str(socket_root), 0o700)
        self.socket_path = str(socket_root / "c.sock")
        self.worker_socket_path = str(socket_root / "w.sock")
        self._owner_fd = None
        self.request_timeout = 5.0
        self.rpc_handler = None
        self.legacy_lock_live = False
        self.execution_available = True
        self.admissions_open = False
        self.cancellation_requests = []
        self.shutdown_observer = lambda: "stopped"
        self._lock = threading.Lock()
        self._server = None
        self._worker_server = None
        self._threads = []
        self._owner = False

    @staticmethod
    def _peer_actor(connection):
        if hasattr(socket, "SO_PEERCRED"):
            import struct
            _, uid, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
            if uid != os.getuid():
                raise PermissionError("peer uid does not own supervisor")
            return str(uid)
        if hasattr(connection, "getpeereid"):
            uid, _ = connection.getpeereid()
            if uid != os.getuid():
                raise PermissionError("peer uid does not own supervisor")
            return str(uid)
        raise PermissionError("peer credentials unavailable")

    def _prepare_socket(self, path):
        target = Path(path)
        if target.exists() or target.is_symlink():
            info = target.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError("unsafe existing socket")
            target.unlink()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(target))
        os.chmod(str(target), 0o600)
        server.listen(16)
        server.settimeout(0.2)
        return server

    def start_serving(self):
        with self._lock:
            if self._server is not None:
                return {"ready": True, "recovery_complete": True, "owner": False}
            if self.legacy_lock_live:
                raise RuntimeError("legacy run lock is live")
            lock_path = Path(self.directory) / "service.lock"
            fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except (BlockingIOError, OSError):
                os.close(fd)
                return {"ready": True, "recovery_complete": True, "owner": False}
            self._owner_fd = fd
            self.recovery.reconcile(self.clock())
            try:
                self._server = self._prepare_socket(self.socket_path)
                self._worker_server = self._prepare_socket(self.worker_socket_path)
            except OSError as exc:
                if exc.errno != errno.EPERM:
                    raise
                if self._server is not None:
                    self._server.close()
                    self._server = None
                if self._worker_server is not None:
                    self._worker_server.close()
                    self._worker_server = None
                for path in (self.socket_path, self.worker_socket_path):
                    try:
                        Path(path).unlink()
                    except FileNotFoundError:
                        pass
                self.execution_available = False
                self._owner = True
                return {"ready": True, "recovery_complete": True, "owner": True, "socket_unavailable": True}
            self._owner = True
            for server, worker in ((self._server, False), (self._worker_server, True)):
                thread = threading.Thread(target=self._serve, args=(server, worker), daemon=True)
                thread.start()
                self._threads.append(thread)
            return {"ready": True, "recovery_complete": True, "owner": True,
                    "host_boot_id": self.host_boot_id}

    def _serve(self, server, worker):
        while server is not None:
            try:
                connection, _ = server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            thread = threading.Thread(target=self._serve_connection, args=(connection, worker), daemon=True)
            thread.start()
            self._threads.append(thread)

    def _serve_connection(self, connection, worker):
        with connection:
            connection.settimeout(self.request_timeout)
            try:
                raw = connection.recv(MAX_REQUEST + 1)
                if len(raw) > MAX_REQUEST:
                    raise ValueError("request size exceeds limit")
                request = json.loads(raw.decode("utf-8"))
                peer = self.peer_resolver(connection)
                result = self.worker_request(request) if worker else self.handle_request(request, peer=peer)
                payload = {"ok": True, "result": result}
            except Exception as exc:
                payload = {"ok": False, "error": str(exc)[:300]}
            connection.sendall(json.dumps(payload, separators=(",", ":")).encode("utf-8"))

    def request(self, request):
        if self.rpc_handler is not None:
            done, result = threading.Event(), {}
            def invoke():
                try:
                    result["value"] = self.rpc_handler(request)
                except Exception as exc:
                    result["error"] = exc
                finally:
                    done.set()
            threading.Thread(target=invoke, daemon=True).start()
            if not done.wait(self.request_timeout):
                raise TimeoutError("controller request timed out")
            if "error" in result:
                raise result["error"]
            return result["value"]
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(self.request_timeout)
        try:
            client.connect(self.socket_path)
            client.sendall(json.dumps(request, separators=(",", ":")).encode("utf-8"))
            raw = client.recv(MAX_REQUEST + 1)
            if len(raw) > MAX_REQUEST:
                raise ValueError("response size exceeds limit")
            response = json.loads(raw.decode("utf-8"))
        finally:
            client.close()
        if not response.get("ok"):
            raise ValueError(response.get("error", "control request failed"))
        return response["result"]

    def authenticated_actor(self, peer):
        if isinstance(peer, str) and peer:
            return peer
        actor = self.peer_resolver(peer)
        if not actor:
            raise PermissionError("actor authentication failed")
        return actor

    def handle_request(self, request, *, peer):
        if not isinstance(request, dict) or len(json.dumps(request).encode("utf-8")) > MAX_REQUEST:
            raise ValueError("request size exceeds limit")
        if "actor" in request:
            raise ValueError("actor must come from authenticated peer")
        actor = self.authenticated_actor(peer)
        command = request.get("command")
        if command == "status":
            return self.status()
        if command == "events":
            return self.events(request.get("after", 0), request.get("limit", 100))
        if command == "reconcile":
            self.recovery.reconcile(self.clock())
            return {"snapshot": self.snapshot(), "cursor": len(self.snapshot()["events"])}
        return self.command(command, request_id=request.get("request_id"),
                            expected_revision=request.get("expected_revision"), actor=actor,
                            mode=request.get("mode"))

    def command(self, command, *, request_id, expected_revision, actor, mode=None):
        if command not in ("start", "pause", "resume", "stop"):
            if command == "resolve":
                raise NotImplementedError("resolution is not available in the lifecycle service")
            raise ValueError("unsupported command")
        if command == "stop" and mode not in ("drain", "cancel"):
            raise ValueError("stop mode must be drain or cancel")
        payload = {"mode": mode} if command == "stop" else {}
        outcome = self.store.record_command({"id": request_id, "actor": actor,
            "command": command, "payload": payload, "expected_revision": expected_revision})
        if command in ("start", "resume"):
            self.admissions_open = True
        elif command == "pause":
            self.admissions_open = False
        elif command == "stop":
            self.admissions_open = False
            if mode == "cancel":
                self.cancellation_requests.append(request_id)
                self.store.append_event({"type": "stop_cancellation_requested", "payload": {"request_id": request_id}})
        return {"command_id": request_id, "state_revision": outcome["revision"],
                "desired_mode": outcome["desired_mode"], "phase": self.snapshot()["domain"]["phase"]}

    def stop(self, *, mode, request_id, expected_revision, actor):
        return self.command("stop", request_id=request_id, expected_revision=expected_revision,
                            actor=actor, mode=mode)

    def status(self):
        state = self.snapshot()
        return {"read_only": not self.execution_available,
                "desired_mode": state["domain"]["desired_mode"],
                "phase": state["domain"]["phase"], "revision": state["domain"]["revision"],
                "host_boot_id": self.host_boot_id, "execution_available": self.execution_available}

    def snapshot(self):
        return self.store.snapshot()

    def events(self, after=0, limit=100):
        if type(after) is not int or after < 0 or type(limit) is not int or not 1 <= limit <= 500:
            raise ValueError("invalid events cursor or limit")
        return [event for event in self.snapshot()["events"] if event["sequence"] > after][:limit]

    def worker_request(self, request):
        if not isinstance(request, dict) or request.get("command") not in WORKER_COMMANDS:
            raise PermissionError("worker operation is not permitted")
        self.store.append_event({"type": "worker_" + request["command"],
                                 "payload": {k: v for k, v in request.items() if k != "command"}})
        return {"accepted": True}

    def register_runner_version(self, runner_id, protocol):
        self.store.append_event({"type": "runner_version", "payload": {"runner_id": runner_id, "protocol": protocol}})

    def runner_compatible(self, runner_id, protocol):
        versions = [event["payload"] for event in self.snapshot()["events"]
                    if event["type"] == "runner_version" and event["payload"].get("runner_id") == runner_id]
        return bool(versions and versions[-1].get("protocol") == protocol)

    def stop_serving(self):
        observer = self.shutdown_observer()
        for server in (self._server, self._worker_server):
            if server is not None:
                server.close()
        self._server = self._worker_server = None
        if observer != "stopped":
            return {"status": "unresolved_shutdown", "terminated": False}
        try:
            if self.snapshot()["domain"]["desired_mode"] == "running":
                self.store.close_admissions("supervisor service stopped")
        except Exception:
            pass
        for path in (self.socket_path, self.worker_socket_path):
            try:
                Path(path).unlink()
            except FileNotFoundError:
                pass
        if self._owner_fd is not None:
            os.close(self._owner_fd)
            self._owner_fd = None
        else:
            for path in (self.socket_path, self.worker_socket_path):
                try:
                    Path(path).unlink()
                except FileNotFoundError:
                    pass
        return {"status": "stopped", "terminated": True}

    def close(self):
        self.stop_serving()
        self.store.close()

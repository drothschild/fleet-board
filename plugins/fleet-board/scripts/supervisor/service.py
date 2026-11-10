"""Single-owner local control service for one supervisor domain."""
import json
import errno
import fcntl
import os
from pathlib import Path
import socket
import subprocess
import stat
import threading
import time

from .processes import _boot_id
from .recovery import Recovery
from .store import Store

MAX_REQUEST = 1024 * 1024
MAX_RESPONSE = 4 * 1024 * 1024
WORKER_COMMANDS = {"heartbeat", "progress", "result", "scope_expansion"}


class Service:
    @classmethod
    def open(cls, domain, *, clock=None, host_boot_id=None, peer_resolver=None, run_lock_path=None,
             board_repo=None, execution_enabled=None):
        store = Store.open(domain)
        if execution_enabled is None:
            execution_enabled = cls._configured_execution_enabled(domain)
        return cls(store, clock or time.time, host_boot_id or _boot_id(), peer_resolver,
                   run_lock_path, board_repo or domain.get("board_repo"), execution_enabled)

    @staticmethod
    def _configured_execution_enabled(domain):
        root = domain.get("board_identity") or domain.get("root") or domain.get("common_dir")
        if not root:
            return False
        config = Path(__file__).resolve().parents[1] / "config.sh"
        try:
            result = subprocess.run(["bash", str(config), "--dir", str(root),
                                     "supervisor.enabled"], stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            return False
        return result.returncode == 0 and result.stdout.strip() == "true"

    def __init__(self, store, clock, host_boot_id, peer_resolver=None, run_lock_path=None,
                 board_repo=None, execution_enabled=True):
        self.store = store
        self._owner_thread_id = threading.get_ident()
        self._thread_store = threading.local()
        self._thread_stores = {}
        self.clock = clock
        self.host_boot_id = host_boot_id
        self.peer_resolver = peer_resolver or self._peer_actor
        self.stopped = threading.Event()
        self.recovery = Recovery(store)
        self.directory = str(store.directory)
        socket_root = Path(os.environ.get("TMPDIR", "/tmp")) / ("fb-supervisor-" + store.domain_id[:12])
        self.socket_root = socket_root
        if run_lock_path is None:
            base = os.environ.get("FLEET_BOARD_LOG_DIR") or str(Path.home() / ".fleet-board" / "runs")
            repo = board_repo or (store.common_dir.parent.name
                                  if store.common_dir.name == ".git"
                                  else store.common_dir.name)
            run_lock_path = str(Path(base) / (repo.replace("/", "-") + ".lock"))
        self.run_lock_path = str(run_lock_path)
        self.socket_path = str(socket_root / "c.sock")
        self.worker_socket_path = str(socket_root / "w.sock")
        self._owner_fd = None
        self.request_timeout = 5.0
        self.rpc_handler = None
        self.execution_enabled = bool(execution_enabled)
        self.execution_available = self.execution_enabled
        self.admissions_open = False
        self.cancellation_requests = []
        self.shutdown_observer = lambda: "stopped"
        self._lock = threading.Lock()
        self._server = None
        self._worker_server = None
        self._threads = []
        self._owner = False
        self.writer_uncertain = False
        self._run_lock_claimed = False

    def _store(self):
        """Return the Store connection owned by the current thread."""
        if threading.get_ident() == self._owner_thread_id:
            return self.store
        store = getattr(self._thread_store, "store", None)
        if store is None:
            store = self.store.fork_connection()
            self._thread_store.store = store
            with self._lock:
                self._thread_stores[threading.get_ident()] = store
        return store

    def _close_thread_store(self):
        store = getattr(self._thread_store, "store", None)
        if store is not None:
            self._thread_store.store = None
            with self._lock:
                self._thread_stores.pop(threading.get_ident(), None)
            store.close()

    def _close_thread_stores(self):
        with self._lock:
            stores = list(self._thread_stores.values())
            self._thread_stores.clear()
        for store in stores:
            store.close()

    def _prepare_socket_root(self):
        root = self.socket_root.absolute()
        if root.is_symlink():
            raise ValueError("unsafe supervisor socket directory")
        try:
            root.mkdir(mode=0o700)
        except FileExistsError:
            pass
        info = root.lstat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o700):
            raise ValueError("supervisor socket directory must be private and owned by user")

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
        # macOS and BSD expose xucred through LOCAL_PEERCRED.  xucred is
        # {u_int version; uid_t uid; short ngroups; gid_t groups[16];};
        # the two-byte pad after ngroups aligns the gid_t array.
        if hasattr(socket, "LOCAL_PEERCRED"):
            import struct
            xucred = connection.getsockopt(
                getattr(socket, "SOL_LOCAL", 0), socket.LOCAL_PEERCRED, struct.calcsize("=IIh2x16I"))
            version, uid, _ngroups, *_groups = struct.unpack("=IIh2x16I", xucred)
            if version != 0:
                raise PermissionError("unsupported peer credential version")
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
            if self.writer_uncertain:
                if self.shutdown_observer() != "stopped":
                    return {"ready": False, "owner": False, "status": "unresolved_shutdown"}
                self._release_ownership()
                self.writer_uncertain = False
            if self._server is not None:
                return {"ready": True, "recovery_complete": True, "owner": False,
                        "execution_available": self.execution_available}
            self._prepare_socket_root()
            lock_path = Path(self.directory) / "service.lock"
            fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except (BlockingIOError, OSError):
                os.close(fd)
                return {"ready": True, "recovery_complete": True, "owner": False,
                        "execution_available": self.execution_available}
            self._owner_fd = fd
            claim_script = Path(__file__).resolve().parents[1] / "claim-run-lock.py"
            Path(self.run_lock_path).parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            claim = subprocess.run([os.environ.get("PYTHON", "python3"), str(claim_script),
                                    self.run_lock_path, str(os.getpid()), "--kind", "service"],
                                   capture_output=True, text=True)
            if claim.returncode:
                os.close(fd)
                self._owner_fd = None
                raise RuntimeError("legacy run lock: " + (claim.stderr.strip() or "claim failed"))
            self._run_lock_claimed = True
            self.recovery.store = self._store()
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
                return {"ready": True, "recovery_complete": True, "owner": True,
                        "socket_unavailable": True, "execution_available": False}
            self._owner = True
            self.writer_uncertain = False
            for server, worker in ((self._server, False), (self._worker_server, True)):
                thread = threading.Thread(target=self._serve, args=(server, worker), daemon=True)
                thread.start()
                self._threads.append(thread)
            return {"ready": True, "recovery_complete": True, "owner": True,
                    "host_boot_id": self.host_boot_id,
                    "execution_available": self.execution_available}

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
                chunks, size = [], 0
                while True:
                    chunk = connection.recv(min(65536, MAX_REQUEST + 1 - size))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    size += len(chunk)
                    if size > MAX_REQUEST:
                        raise ValueError("request size exceeds limit")
                    try:
                        json.loads(b"".join(chunks).decode("utf-8"))
                        break
                    except (ValueError, UnicodeDecodeError):
                        continue
                raw = b"".join(chunks)
                request = json.loads(raw.decode("utf-8"))
                # handle_request resolves the actor from the connection exactly once.
                if worker:
                    self.peer_resolver(connection)
                    result = self.worker_request(request)
                else:
                    result = self.handle_request(request, peer=connection)
                payload = {"ok": True, "result": result}
            except Exception as exc:
                payload = {"ok": False, "error": str(exc)[:300]}
            finally:
                self._close_thread_store()
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
                    self._close_thread_store()
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
            chunks, size = [], 0
            while True:
                chunk = client.recv(min(65536, MAX_RESPONSE + 1 - size))
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
                if size > MAX_RESPONSE:
                    raise ValueError("response size exceeds limit")
            raw = b"".join(chunks)
            response = json.loads(raw.decode("utf-8"))
        finally:
            client.close()
        if not response.get("ok"):
            raise ValueError(response.get("error", "control request failed"))
        return response["result"]

    def authenticated_actor(self, peer):
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
        if self.writer_uncertain and command in ("resolve", "start", "pause", "resume", "stop"):
            raise RuntimeError("uncertain writer prevents lifecycle command")
        if command == "status":
            return self.status()
        if command == "events":
            return self.events(request.get("after", 0), request.get("limit", 100))
        if command == "reconcile":
            self.recovery.store = self._store()
            self.recovery.reconcile(self.clock())
            return {"snapshot": self.snapshot(), "cursor": len(self.snapshot()["events"])}
        if command == "resolve":
            supported = {"retry", "record_usage", "confirm_effect", "abandon"}
            action = request.get("action")
            if action not in supported:
                raise ValueError("unsupported resolution action")
            revision = request.get("expected_revision", self.status()["revision"])
            outcome = self._store().record_command({"id": request.get("request_id"),
                "actor": actor, "command": "resolve", "payload": {
                    "card": request.get("card"), "action": action,
                    "reason": request.get("reason")}, "expected_revision": revision})
            return {"audited": True, "applied": False, "status": "recorded"}
        return self.command(command, request_id=request.get("request_id"),
                            expected_revision=request.get("expected_revision"), actor=actor,
                            mode=request.get("mode"))

    def command(self, command, *, request_id, expected_revision, actor, mode=None):
        if command not in ("start", "pause", "resume", "stop"):
            if command == "resolve":
                action = getattr(self, "resolve_action", None)
                if action is None:
                    raise ValueError("unsupported resolution action")
                return action(request_id=request_id, expected_revision=expected_revision,
                              actor=actor, **(mode or {}))
            raise ValueError("unsupported command")
        if command == "stop" and mode not in ("drain", "cancel"):
            raise ValueError("stop mode must be drain or cancel")
        if command in ("start", "resume") and not self.execution_enabled:
            raise RuntimeError("supervisor.enabled: false; execution lifecycle is disabled")
        payload = {"mode": mode} if command == "stop" else {}
        store = self._store()
        outcome = store.record_command({"id": request_id, "actor": actor,
            "command": command, "payload": payload, "expected_revision": expected_revision})
        if command in ("start", "resume"):
            self.admissions_open = True
        elif command == "pause":
            self.admissions_open = False
        elif command == "stop":
            self.admissions_open = False
            if mode == "cancel":
                self.cancel_live_attempts(request_id, outcome["revision"])
        result = {"command_id": request_id, "state_revision": outcome["revision"],
                "desired_mode": outcome["desired_mode"], "phase": store.snapshot()["domain"]["phase"]}
        if command == "stop":
            shutdown = self.stop_serving()
            result.update(shutdown)
        return result

    def cancel_live_attempts(self, request_id=None, revision=None):
        request_id = request_id or "stop-cancel"
        revision = self.status()["revision"] if revision is None else revision
        for attempt in self.snapshot().get("attempts", []):
            if attempt.get("state") in ("prepared", "launching", "running", "result_ready"):
                current = self.status()["revision"]
                self._store().request_cancellation(attempt["id"], request_id + ":" + attempt["id"],
                                                "supervisor stop requested", current,
                                                now=self.clock())
                self.cancellation_requests.append(attempt["id"])

    def stop(self, *, mode, request_id, expected_revision, actor):
        return self.command("stop", request_id=request_id, expected_revision=expected_revision,
                            actor=actor, mode=mode)

    def status(self):
        state = self.snapshot()
        return {"ready": self._server is not None, "read_only": not self.execution_available,
                "desired_mode": state["domain"]["desired_mode"],
                "phase": state["domain"]["phase"], "revision": state["domain"]["revision"],
                "host_boot_id": self.host_boot_id, "execution_available": self.execution_available}

    def snapshot(self):
        return self._store().snapshot()

    def events(self, after=0, limit=100):
        if type(after) is not int or after < 0 or type(limit) is not int or not 1 <= limit <= 500:
            raise ValueError("invalid events cursor or limit")
        return self._store().events_after(after, limit)

    def worker_request(self, request):
        if not isinstance(request, dict) or request.get("command") not in WORKER_COMMANDS:
            raise PermissionError("worker operation is not permitted")
        self._store().append_event({"type": "worker_" + request["command"],
                                 "payload": {k: v for k, v in request.items() if k != "command"}})
        return {"accepted": True}

    def register_runner_version(self, runner_id, protocol):
        self._store().append_event({"type": "runner_version", "payload": {"runner_id": runner_id, "protocol": protocol}})

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
        for path in (self.socket_path, self.worker_socket_path):
            try:
                Path(path).unlink()
            except FileNotFoundError:
                pass
        if observer != "stopped":
            self.writer_uncertain = True
            return {"status": "unresolved_shutdown", "terminated": False}
        store = self._store()
        self._release_ownership()
        self.writer_uncertain = False
        try:
            if store.snapshot()["domain"]["desired_mode"] == "running":
                store.close_admissions("supervisor service stopped")
        except Exception:
            pass
        for path in (self.socket_path, self.worker_socket_path):
            try:
                Path(path).unlink()
            except FileNotFoundError:
                pass
        self.stopped.set()
        return {"status": "stopped", "terminated": True}

    def _release_ownership(self):
        if self._owner_fd is not None:
            os.close(self._owner_fd)
            self._owner_fd = None
        self._owner = False
        try:
            lines = Path(self.run_lock_path).read_text(encoding="utf-8").splitlines()
            if (self._run_lock_claimed and len(lines) >= 3
                    and lines[0] == str(os.getpid()) and lines[2] == "service"):
                Path(self.run_lock_path).unlink()
        except (OSError, IndexError):
            pass
        self._run_lock_claimed = False

    def close(self):
        self.stop_serving()
        self._close_thread_stores()
        self.store.close()

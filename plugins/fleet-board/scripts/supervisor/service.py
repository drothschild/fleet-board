"""Single-owner local control service for one supervisor domain."""
import json
import re
import errno
import fcntl
import os
from pathlib import Path
import socket
import subprocess
import stat
import threading
import time

from . import errors, paths
from .processes import _boot_id
from .recovery import Recovery
from .store import Store

MAX_REQUEST = 1024 * 1024
MAX_RESPONSE = 4 * 1024 * 1024
WORKER_COMMANDS = {"heartbeat", "progress", "result", "scope_expansion"}


class EventPage(list):
    """List-compatible bounded event page with cursor metadata for newer clients."""
    def __init__(self, events, *, next_cursor, snapshot_required=False, snapshot=None):
        super().__init__(events)
        self.next_cursor = next_cursor
        self.snapshot_required = snapshot_required
        self.snapshot = snapshot

    def __getitem__(self, key):
        if key == "events": return list(self)
        if key == "next_cursor": return self.next_cursor
        if key == "snapshot_required": return self.snapshot_required
        if key == "snapshot": return self.snapshot
        return super().__getitem__(key)

    def get(self, key, default=None):
        try: return self[key]
        except (KeyError, IndexError, TypeError): return default

    def __contains__(self, value):
        if value in ("events", "next_cursor"): return True
        if value == "snapshot_required": return self.snapshot_required
        if value == "snapshot": return self.snapshot is not None
        return super().__contains__(value)


class Service:
    @staticmethod
    def _reject_evidence(*_args, **_kwargs):
        return False

    @classmethod
    def open(cls, domain, *, clock=None, host_boot_id=None, peer_resolver=None, run_lock_path=None,
             board_repo=None, execution_enabled=None, effect_verifier=None, usage_evidence_verifier=None,
             retry_evidence_verifier=None, human_actor_verifier=None):
        store = Store.open(domain, retry_evidence_verifier=retry_evidence_verifier or (lambda *_args: False),
                           human_actor_verifier=human_actor_verifier or (lambda actor, capability: bool(actor) and actor == capability))
        if execution_enabled is None:
            execution_enabled = cls._configured_execution_enabled(domain)
        return cls(store, clock or time.time, host_boot_id or _boot_id(), peer_resolver,
                   run_lock_path, board_repo or domain.get("board_repo"), execution_enabled,
                   effect_verifier, usage_evidence_verifier)

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
                 board_repo=None, execution_enabled=False, effect_verifier=None, usage_evidence_verifier=None):
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
        socket_root = paths.socket_dir(store.domain_id)
        self.socket_root = socket_root
        self.board_repo = board_repo
        if run_lock_path is None:
            base = str(paths.log_dir())
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
        self.effect_verifier = effect_verifier or self._reject_evidence
        self.usage_evidence_verifier = usage_evidence_verifier or self._reject_evidence
        self.admissions_open = False
        self.cancellation_requests = []
        self.shutdown_observer = self._observe_shutdown
        self._lock = threading.Lock()
        self._server = None
        self._worker_server = None
        self._threads = []
        self._threads_lock = threading.Lock()
        self._recovery_lock = threading.Lock()
        self._accept_threads = []  # (thread, is_worker)
        self._owner = False
        self.writer_uncertain = False
        self._run_lock_claimed = False

    _WRITER_STATES = ("launching", "running", "result_ready", "cancel_requested", "interrupted", "quarantined")

    def _observe_shutdown(self):
        """Default shutdown observer: fail closed. Runners outlive the supervisor by design, so
        any attempt still launching, running, result_ready or quarantined (and not released)
        may be a live writer: report unresolved, never a clean stop, until the store says
        otherwise. An injected observer replaces this."""
        # A private short-lived connection off the owner thread: this runs under self._lock
        # in start_serving and must not take that lock again through _store().
        try:
            store = (self.store if threading.get_ident() == self._owner_thread_id
                     else self.store.fork_connection())
            try:
                for attempt in store.snapshot()["attempts"]:
                    if (attempt["state"] in self._WRITER_STATES
                            and json.loads(attempt["data"]).get("execution_released") is not True):
                        return "unknown"
            finally:
                if store is not self.store:
                    store.close()
        except Exception:  # noqa: BLE001 - an unreadable store is not proof of a stopped writer
            return "unknown"
        return "stopped"

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
                raise errors.Unauthenticated("peer uid does not own supervisor")
            return str(uid)
        if hasattr(connection, "getpeereid"):
            uid, _ = connection.getpeereid()
            if uid != os.getuid():
                raise errors.Unauthenticated("peer uid does not own supervisor")
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
                raise errors.Unauthenticated("unsupported peer credential version")
            if uid != os.getuid():
                raise errors.Unauthenticated("peer uid does not own supervisor")
            return str(uid)
        raise errors.Unauthenticated("peer credentials unavailable")

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
        server.settimeout(0.05)
        return server

    def start_serving(self):
        with self._lock:
            if self.writer_uncertain:
                if self.shutdown_observer() != "stopped":
                    return {"ready": False, "owner": False, "status": "unresolved_shutdown"}
                # The writer is confirmed stopped: finish the interrupted shutdown
                # (listeners, sockets, locks) and fall through to a clean start.
                for server in (self._server, self._worker_server):
                    if server is not None:
                        server.close()
                self._server = self._worker_server = None
                self._join_accept_threads()
                for path in (self.socket_path, self.worker_socket_path):
                    try:
                        Path(path).unlink()
                    except FileNotFoundError:
                        pass
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
            self._reconcile_now()
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
                self._track_thread(thread)
                self._accept_threads.append((thread, worker))
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
            self._track_thread(thread)

    def _track_thread(self, thread):
        """Keep only live threads: a long-lived service sees one connection per poll."""
        with self._threads_lock:
            self._threads[:] = [item for item in self._threads if item.is_alive()]
            self._threads.append(thread)

    def _reconcile_now(self):
        """One recovery pass on this thread's store handle. Recovery keeps batch cursors, so
        the handle is shared; passes are serialized and it goes back to the owner's handle
        (never left pointing at a finished thread's connection)."""
        store = self._store()  # before the lock: _store() takes self._lock to register a fork
        with self._recovery_lock:
            self.recovery.store = store
            try:
                self.recovery.reconcile(self.clock())
            finally:
                self.recovery.store = self.store

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
                    payload = self.handle_request_envelope(request, peer=connection)
                if worker:
                    payload = {"ok": True, "result": result}
            except Exception as exc:
                payload = errors.error_envelope(exc, self.status_view)
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
            raise errors.Unauthenticated("actor authentication failed")
        return actor

    def handle_request(self, request, *, peer):
        return self._handle_request(request, peer=peer)

    def handle_request_envelope(self, request, *, peer):
        try:
            return {"ok": True, "result": self._handle_request(request, peer=peer)}
        except Exception as exc:
            return errors.error_envelope(exc, self.status_view)

    def _handle_request(self, request, *, peer):
        if not isinstance(request, dict) or len(json.dumps(request).encode("utf-8")) > MAX_REQUEST:
            raise ValueError("request size exceeds limit")
        if "actor" in request:
            raise ValueError("actor must come from authenticated peer")
        actor = self.authenticated_actor(peer)
        if not self.execution_enabled and request.get("command") not in (
                "status", "events", "reconcile", "pause", "stop", "card_execution", "card_pause"):
            raise errors.Disabled("supervisor.enabled: false; control API is read-only")
        command = request.get("command")
        if self.writer_uncertain and command in ("resolve", "start", "pause", "resume", "release_reservations",
                                                 "card_resume", "reconcile_card"):
            raise errors.UncertainWriter("uncertain writer prevents lifecycle command")
        if command == "status":
            return self.status_view()
        if command == "events":
            page = self.events(request.get("after", 0), request.get("limit", 100))
            return {"events": list(page), "next_cursor": page.next_cursor,
                    "snapshot_required": page.snapshot_required, "snapshot": page.snapshot}
        if command == "reconcile":
            if self.writer_uncertain:
                raise errors.UncertainWriter("uncertain writer prevents reconcile")
            self._reconcile_now()
            return {"snapshot": self.snapshot(), "cursor": len(self.snapshot()["events"])}
        if command == "card_execution":
            return self.card_execution(request.get("card"))
        if command == "card_log":
            return self.card_log(request.get("card"), request.get("log_id"))
        if command == "card_pause":
            self._require_mutation_binding(request)
            return self.card_pause(request.get("card"), mode=request.get("mode", "drain"),
                request_id=request.get("request_id"), expected_revision=request.get("expected_revision"), peer=peer)
        if command == "release_reservations":
            self._require_mutation_binding(request)
            return self.release_reservations(request.get("card"), reason=request.get("reason"),
                expected_revision=request.get("expected_revision"),
                expected_reservation_revision=request.get("expected_reservation_revision"), peer=peer)
        if command == "card_resume":
            self._require_mutation_binding(request)
            return self.card_resume(request.get("card"), request_id=request.get("request_id"),
                expected_revision=request.get("expected_revision"), peer=peer)
        if command == "resolve":
            supported = {"retry", "record_usage", "confirm_effect", "abandon"}
            action = request.get("action")
            if action not in supported:
                raise ValueError("unsupported resolution action")
            if not isinstance(request.get("request_id"), str) or not request["request_id"]:
                raise ValueError("request_id required")
            if type(request.get("expected_revision")) is not int:
                raise ValueError("expected_revision required")
            params = dict(request)
            params.pop("command", None); params.pop("actor", None)
            return self.resolve(peer=peer, **params)
        self._require_mutation_binding(request)
        return self.command(command, request_id=request.get("request_id"),
                            expected_revision=request.get("expected_revision"), actor=actor,
                            mode=request.get("mode"))

    @staticmethod
    def _require_mutation_binding(request):
        if not isinstance(request.get("request_id"), str) or not request["request_id"]:
            raise errors.Invalid("request_id required")
        if type(request.get("expected_revision")) is not int:
            raise errors.Invalid("expected_revision required")

    def get_status(self):
        state = self.snapshot()
        now = self.clock()
        sessions = state["sessions"]
        attempts = state["attempts"]
        claims = state["claims"]
        acknowledged = [item for item in state["events"] if item["type"] in ("command", "supervisor_heartbeat", "supervisor_started")
                        and (item["type"] != "command" or item["payload"].get("command") in ("start", "resume"))]
        latest = acknowledged[-1] if acknowledged else None
        running = [item for item in attempts if item["state"] in ("launching", "running", "result_ready")]
        observed_phase = ("unreachable" if self.writer_uncertain else
                          "running" if state["domain"]["desired_mode"] == "running" else
                          "stopped" if state["domain"]["desired_mode"] in ("paused", "stopped") else
                          state["domain"]["phase"])
        return {"schema_version": 1, "revision": state["domain"]["revision"],
                "desired_mode": state["domain"]["desired_mode"],
                "phase": observed_phase,
                "heartbeat": {"at": latest["timestamp"] if latest else None,
                              "age": max(0, now-latest["timestamp"]) if latest else None,
                              "fresh": bool(latest and now-latest["timestamp"] <= 30)},
                "session": {"active": sessions[-1] if sessions else None,
                            "known_spend": sum(x["known_spend"] for x in sessions),
                            "unknown_spend": any(bool(x["unknown_spend"]) for x in sessions),
                            "deadline": sessions[-1]["deadline"] if sessions else None},
                "capacity": {"slots": len(running), "global_cap": self._global_cap(),
                             "per_provider": {provider: sum(1 for x in claims if x["provider"] == provider)
                                              for provider in sorted({x["provider"] for x in claims})}},
                "queue": {"ready": None, "running": len(running),
                          "waiting": sum(1 for x in state["jobs"] if x["state"] in ("queued", "retry_wait")),
                          "attention": sum(1 for x in state["jobs"] if x["state"] == "needs_attention")},
                "config": {"enabled": self.execution_enabled, "execution_available": self.execution_available},
                "boot_registration": "missing", "last_error": None,
                "read_only": not self.execution_enabled, "claims": {"count": len(claims)}}

    def _config_root(self):
        repo = self.board_repo
        if repo and os.path.isdir(str(repo)):
            return str(repo)
        common = Path(self.store.common_dir)
        return str(common.parent if common.name == ".git" else common)

    def _global_cap(self):
        """limits.concurrency from the repo config; null when it cannot be read."""
        config = Path(__file__).resolve().parents[1] / "config.sh"
        try:
            result = subprocess.run(["bash", str(config), "--dir", self._config_root(), "limits.concurrency"],
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            return None
        text = result.stdout.strip()
        if result.returncode != 0 or not re.fullmatch(r"[0-9]+", text):
            return None
        return int(text)

    def status_view(self):
        """The one canonical status object served by the status command."""
        merged = self.get_status()
        merged.update(self.status())
        return merged

    _LOG_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,200}")
    _SECRET = re.compile(r"(?i)(token|secret|password|api[_-]?key)(\s*[:=]\s*)[^\s]+")

    def _log_refs(self, attempts):
        """Safe log references: opaque IDs only, never filesystem paths."""
        artifacts = Path(self.store.directory) / "artifacts"
        refs = []
        for attempt in attempts:
            attempt_id = attempt["id"]
            if not self._LOG_ID.fullmatch(attempt_id):
                continue
            directory = artifacts / attempt_id
            try:
                names = sorted(x.name for x in directory.iterdir()
                               if x.suffix == ".log" and x.is_file() and not x.is_symlink())
            except OSError:
                continue
            for name in names:
                log_id = attempt_id + "." + name
                if self._LOG_ID.fullmatch(log_id):
                    refs.append({"id": log_id, "attempt_id": attempt_id, "name": name})
        return refs

    def card_log(self, card, log_id):
        if not isinstance(log_id, str) or not self._LOG_ID.fullmatch(log_id) or ".." in log_id:
            raise ValueError("invalid log id")
        state = self.snapshot()
        card = str(card)
        jobs = [x for x in state["jobs"] if x["card"] == card]
        attempts = [x for x in state["attempts"] if any(j["id"] == x["job_id"] for j in jobs)]
        ref = next((r for r in self._log_refs(attempts) if r["id"] == log_id), None)
        if ref is None:
            raise ValueError("log not found")
        artifacts = (Path(self.store.directory) / "artifacts").resolve()
        path = artifacts / ref["attempt_id"] / ref["name"]
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(artifacts):
            raise ValueError("log not found")
        with open(path, "rb") as handle:
            text = handle.read(1024 * 1024).decode("utf-8", errors="replace")
        text = self._SECRET.sub(r"\1\2[redacted]", text)
        text = re.sub(r"\b(?:ghp|gho|ghs|github_pat|sk|xox[bap])[_-][A-Za-z0-9_-]{16,}", "[redacted]", text)
        for private in {str(self.board_repo or ""), str(Path(self.store.common_dir)), str(Path(self.store.common_dir).parent)}:
            if private and private != ".":
                text = text.replace(private, "[repository]")
        return {"id": log_id, "text": text}

    _TERMINAL_ATTEMPT = ("reconciled", "failed", "interrupted")

    def card_execution(self, card):
        """The one canonical card-execution object the UI and the CLI read.

        Every UI-facing field is computed from stored state; nothing is asserted that the
        store does not hold. The older keys (job, attempts, progress_age, heartbeat_age,
        retries, waiting_reason, claims) keep their names and now carry the same values.
        """
        card = str(card)
        state = self.snapshot()
        jobs = [x for x in state["jobs"] if x["card"] == card]
        attempts = [x for x in state["attempts"] if any(j["id"] == x["job_id"] for j in jobs)]
        claims = [x for x in state["claims"] if x["card"] == card]
        data = [json.loads(x["data"]) for x in attempts]
        now = self.clock()

        def number(value):
            return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None

        def age(at):
            return max(0, now - at) if at is not None else None

        def newest(values):
            values = [v for v in values if v is not None]
            return max(values) if values else None

        def progress_at(row):
            progress = row.get("progress")
            return number(progress.get("at") if isinstance(progress, dict) else progress)

        pairs = list(zip(attempts, data))
        live = [(a, d) for a, d in pairs if a["state"] not in self._TERMINAL_ATTEMPT]
        latest = live[-1] if live else None
        job = jobs[-1] if jobs else None
        lifecycle = state["card_lifecycle"].get(card)
        reservation = next((x for x in state["reservations"] if x["card"] == card), None)
        if reservation is not None:
            reservation_state, reservation_revision = "held", reservation["reservation_revision"]
        else:
            released = any(e["type"] == "scope_released" and e["payload"].get("card") == card for e in state["events"])
            reservation_state = "released" if released else "none"
            reservation_revision = max([x["reservation_revision"] for x in claims], default=0)
        waiting_on = None
        for event in state["events"]:
            if event["type"] == "scope_wait" and event["payload"].get("card") == card:
                waiting_on = event["payload"].get("waiting_on")
            elif event["type"] == "scope_wait_cleared" and event["payload"].get("card") == card:
                waiting_on = None
        blocking_card = None
        if lifecycle == "paused":
            reason = "paused by an operator"
        elif lifecycle in ("refresh_pending", "needs_attention", "blocked"):
            reason = "card is " + lifecycle.replace("_", " ")
        elif waiting_on is not None:
            blocking_card, reason = str(waiting_on), "waiting for scope held by card #" + str(waiting_on)
        elif job is not None and job["state"] in ("queued", "retry_wait"):
            reason = "job is " + job["state"].replace("_", " ")
        else:
            reason = None
        heartbeat = newest([number(d.get("heartbeat", d.get("heartbeat_at"))) for d in data])
        progress = newest([progress_at(d) if "progress" in d else number(d.get("progress_at")) for d in data])
        history = [{"id": a["id"], "job_id": a["job_id"], "state": a["state"], "provider": a["provider"],
                    "started_at": number(d.get("started_at")), "deadline": number(d.get("deadline")),
                    "heartbeat_at": number(d.get("heartbeat", d.get("heartbeat_at"))),
                    "progress_at": progress_at(d) if "progress" in d else number(d.get("progress_at")),
                    "quarantine_reason": d.get("quarantine_reason"),
                    "execution_released": d.get("execution_released") is True}
                   for a, d in pairs]
        return {"job": job, "attempts": attempts, "claims": claims,
                "activity": latest[0]["state"] if latest else (job["state"] if job else "idle"),
                "elapsed_seconds": age(number(latest[1].get("started_at"))) if latest else None,
                "progress_age": age(progress), "progress_age_seconds": age(progress),
                "heartbeat_age": age(heartbeat), "heartbeat_age_seconds": age(heartbeat),
                "deadlines": [row.get("deadline") for row in data if row.get("deadline") is not None],
                "retries": {"automatic": job["retries_used"] if job else 0},
                "retry_count": job["retries_used"] if job else 0,
                "waiting_reason": reason, "wait_reason": reason,
                "blocking_card": blocking_card, "blocking_path": None,
                "paused": lifecycle == "paused",
                # The store's own rule for "a writer may still be active" (release_scope).
                "writer": any(d.get("execution_released") is not True for d in data),
                "reservation_state": reservation_state, "reservation_revision": reservation_revision,
                "attempt_history": history,
                "logs": self._log_refs(attempts)}

    def _control(self, card, command, mode, request_id, expected_revision, actor):
        store = self._store()
        prior = next((x for x in store.snapshot()["commands"] if x["id"] == request_id), None)
        result = store.record_command({"id": request_id, "actor": actor, "command": command,
            "payload": {"card": str(card), "mode": mode}, "expected_revision": expected_revision})
        if command in ("pause", "card_pause") and prior is None and store._card_lifecycles().get(str(card)) != "paused":
            store.set_card_lifecycle(str(card), "paused", result["revision"])
        if command == "card_resume" and prior is None and store._card_lifecycles().get(str(card)) == "paused":
            state = store.snapshot()
            current_job = next((item for item in reversed(state["jobs"]) if item["card"] == str(card)), None)
            target = "active" if current_job and current_job["state"] in ("active", "retry_wait") else "ready"
            store.set_card_lifecycle(str(card), target, result["revision"])
        return {"command_id": request_id, "state_revision": store.snapshot()["domain"]["revision"],
                "desired_mode": result["desired_mode"], "phase": store.snapshot()["domain"]["phase"]}

    def card_pause(self, card, *, mode="drain", request_id, expected_revision, peer=None):
        if mode not in ("drain", "cancel"): raise ValueError("pause mode must be drain or cancel")
        if self.writer_uncertain: raise errors.UncertainWriter("uncertain writer prevents card pause")
        actor = self.authenticated_actor(peer)
        self.admissions_open = False
        result = self._control(card, "card_pause", mode, request_id, expected_revision, actor)
        if mode == "cancel": self.cancel_live_attempts(request_id, result["state_revision"], card=str(card))
        return result

    def release_reservations(self, card, *, reason, expected_revision, expected_reservation_revision, peer=None):
        if self.writer_uncertain: raise errors.UncertainWriter("uncertain writer prevents reservation release")
        actor = self.authenticated_actor(peer)
        snap = self.snapshot(); card = str(card)
        if type(expected_revision) is not int or expected_revision != snap["domain"]["revision"]:
            raise errors.StaleRevision("reservation revision mismatch: stale state revision")
        if self._store()._card_lifecycles().get(card) != "paused": raise ValueError("card must be paused")
        self._store().release_scope(card, "release:" + str(expected_revision) + ":" + card, actor, reason,
            expected_revision, reservation_revision=expected_reservation_revision,
            actor_capability=actor)
        return {"released": True, "actor": actor, "paths": next((x["paths"] for x in snap["reservations"] if x["card"] == card), [])}

    def card_resume(self, card, *, request_id, expected_revision, peer=None):
        """Return a paused card to the queue.

        Scope reacquisition, eligibility refresh and the budget-stop check do not exist yet,
        so this never claims them: refreshed is always false and applied is true only when
        the card's lifecycle really left paused. A Human QA card is left exactly as it is.
        """
        if self.writer_uncertain: raise errors.UncertainWriter("uncertain writer prevents card resume")
        self._require_mutation_binding({"request_id": request_id, "expected_revision": expected_revision})
        actor = self.authenticated_actor(peer)
        store = self._store()
        lifecycle = store._card_lifecycles().get(str(card))
        if lifecycle == "human_qa":
            if expected_revision != store.snapshot()["domain"]["revision"]:
                raise errors.StaleRevision("revision mismatch: stale state revision")
            return {"applied": False, "refreshed": False, "preserved_human_qa": True}
        result = self._control(card, "card_resume", None, request_id, expected_revision, actor)
        after = store._card_lifecycles().get(str(card))
        return dict(result, applied=lifecycle == "paused" and after != "paused", refreshed=False,
                    preserved_human_qa=False)

    def reconcile_card(self, card, *, known):
        if type(known) is not bool: raise ValueError("known must be boolean")
        if self.writer_uncertain: raise errors.UncertainWriter("uncertain writer prevents reconcile")
        card = str(card); store = self._store(); state = self.snapshot()
        reservation = next((x for x in state["reservations"] if x["card"] == card), None)
        if not known:
            store.set_card_lifecycle(card, "needs_attention", state["domain"]["revision"])
        return {"state": "needs_attention" if not known else store._card_lifecycles().get(card, "ready"),
                "quarantined": not known, "reservation_retained": bool(reservation), "dispatchable": bool(known)}

    def resolve(self, card, *, action, request_id, reason, expected_revision, evidence=None,
                attempt_id=None, usage=None, effect_id=None, artifact_paths=None, peer=None):
        if self.writer_uncertain: raise errors.UncertainWriter("uncertain writer prevents resolution")
        if not self.execution_enabled: raise errors.Disabled("supervisor.enabled: false; control API is read-only")
        if not isinstance(request_id, str) or not request_id:
            raise ValueError("request_id required")
        if type(expected_revision) is not int:
            raise ValueError("expected_revision required")
        if not isinstance(reason, str) or not reason.strip(): raise ValueError("reason required")
        actor = self.authenticated_actor(peer)
        if not actor: raise PermissionError("authenticated actor required")
        store = self._store(); state = store.snapshot(); card = str(card)
        prior = next((item for item in state["commands"] if item["id"] == request_id), None)
        if prior is not None:
            result = json.loads(prior["outcome"])
            return dict(result, applied=False)
        if action == "retry":
            job = next((x for x in state["jobs"] if x["card"] == card), None)
            if job is None:
                raise ValueError("retry job missing")
            attempt = next((x for x in state["attempts"] if x["id"] == attempt_id), None) if attempt_id else None
            if attempt is None:
                raise ValueError("retry attempt missing; explicit attempt identity and writer containment proof required")
            if attempt["state"] != "quarantined":
                raise ValueError("retry requires a quarantined attempt")
            if attempt["state"] == "quarantined":
                from .models import StopEvidence
                if type(evidence) is not StopEvidence or store.retry_evidence_verifier is None or store.retry_evidence_verifier(evidence) is not True:
                    raise ValueError("writer uncertainty requires trusted stop evidence")
                data = json.loads(attempt["data"])
                if getattr(evidence, "domain_id", None) != store.domain_id or getattr(evidence, "job_id", None) != job["id"] or getattr(evidence, "attempt_id", None) != attempt["id"] or getattr(evidence, "generation", None) != json.loads(attempt["data"]).get("generation"):
                    raise ValueError("stop evidence identity mismatch")
            result = store.authorize_manual_retry({"request_id": request_id,"card": card,"job_id": job["id"],"attempt_id": attempt["id"],"actor": actor,"reason": reason,"expected_revision": expected_revision})
            return dict(result, applied=bool(result.get("authorized")))
        if action == "record_usage":
            if not isinstance(usage, dict) or set(usage) != {"cost_usd"} or not callable(self.usage_evidence_verifier) or self.usage_evidence_verifier(evidence) is not True:
                raise ValueError("usage evidence required")
            attempt = next((x for x in state["attempts"] if x["id"] == attempt_id), None)
            if attempt is None: raise ValueError("usage attempt missing")
            data = json.loads(attempt["data"])
            result = store.reconcile_usage({"request_id":request_id,"session_id":data["session_id"],"attempt_id":attempt_id,"actor":actor,"reason":reason,"cost_usd":usage["cost_usd"],"expected_revision":expected_revision})
            return dict(result, applied=bool(result.get("recorded")))
        if action == "confirm_effect":
            effect = next((x for x in state["effects"] if x["operation_key"] == effect_id and x["card"] == card), None)
            verifier = self.effect_verifier
            if effect is None or not isinstance(evidence, dict):
                raise ValueError("effect verification evidence is invalid")
            verified = (verifier.verify(effect, evidence) if hasattr(verifier, "verify")
                        else verifier(effect, evidence))
            if verified is not True:
                raise ValueError("effect verification failed")
            observation = dict(evidence, status="applied")
            result = store.confirm_effect(effect_id, observation, expected_revision)
            return {"applied": bool(result.get("changed")), "effect_id": effect_id}
        if action == "abandon":
            if not effect_id: raise ValueError("effect identity required")
            effect = next((x for x in state["effects"] if x["operation_key"] == effect_id and x["card"] == card), None)
            if effect is None or effect["observation"] is None: raise ValueError("unresolved effect prevents abandon")
            paths = artifact_paths or []
            if not paths:
                raise ValueError("attempt artifact path required for preservation")
            effect_job = next((item for item in state["jobs"] if item["id"] == effect["job_id"]), None)
            effect_attempts = [item for item in state["attempts"] if effect_job and item["job_id"] == effect_job["id"]]
            if not effect_attempts:
                raise ValueError("attempt artifact identity required")
            root = store.directory / "artifacts"
            for item in paths:
                path = Path(item)
                if (path.is_symlink() or not path.resolve().is_relative_to(root.resolve()) or not path.is_file()
                        or not any(path.resolve().is_relative_to((root / attempt["id"]).resolve()) for attempt in effect_attempts)):
                    raise ValueError("unsafe or foreign attempt artifact path")
            result = store.abandon_prepared_claim(card, request_id, actor, reason, effect_id, expected_revision)
            return dict(result, applied=bool(result["released"]), artifacts_preserved=True, released_claims=1)
        raise ValueError("unsupported resolution action")

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
            raise errors.Disabled("supervisor.enabled: false; execution lifecycle is disabled")
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

    def cancel_live_attempts(self, request_id=None, revision=None, card=None):
        request_id = request_id or "stop-cancel"
        revision = self.status()["revision"] if revision is None else revision
        for attempt in self.snapshot().get("attempts", []):
            if card is not None:
                job = next((item for item in self.snapshot().get("jobs", []) if item["id"] == attempt.get("job_id")), None)
                if job is None or job["card"] != str(card):
                    continue
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
                "phase": ("unreachable" if self.writer_uncertain else state["domain"]["phase"]), "revision": state["domain"]["revision"],
                "host_boot_id": self.host_boot_id, "execution_available": self.execution_available,
                "shutdown": "unresolved" if self.writer_uncertain else "resolved"}

    def snapshot(self):
        return self._store().snapshot()

    def events(self, after=0, limit=100):
        if type(after) is not int or type(limit) is not int or not 1 <= limit <= 500:
            raise ValueError("invalid events cursor or limit")
        store = self._store()
        oldest = store.oldest_event_sequence() or 1
        if after < oldest - 1:
            state = self.snapshot()
            rows = state["events"]
            return EventPage([], next_cursor=rows[-1]["sequence"] if rows else 0,
                             snapshot_required=True, snapshot=state)
        page = store.events_after(after, limit)
        return EventPage(page, next_cursor=page[-1]["sequence"] if page else after)

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
        if observer != "stopped":
            self.admissions_open = False
            self.writer_uncertain = True
            if self._worker_server is not None:
                self._worker_server.close()
                self._worker_server = None
                self._join_accept_threads(worker_only=True)
            try:
                Path(self.worker_socket_path).unlink()
            except FileNotFoundError:
                pass
            return {"status": "unresolved_shutdown", "terminated": False}
        store = self._store()
        try:
            if store.snapshot()["domain"]["desired_mode"] == "running":
                store.close_admissions("supervisor service stopped")
        except Exception:
            pass
        for server in (self._server, self._worker_server):
            if server is not None:
                server.close()
        self._server = self._worker_server = None
        self._join_accept_threads()
        for path in (self.socket_path, self.worker_socket_path):
            try:
                Path(path).unlink()
            except FileNotFoundError:
                pass
        self._release_ownership()
        self.writer_uncertain = False
        self.stopped.set()
        return {"status": "stopped", "terminated": True}

    def _join_accept_threads(self, worker_only=False):
        """Wait for closed listeners' accept loops to exit (they poll every 0.2s)."""
        keep = []
        for thread, is_worker in self._accept_threads:
            if worker_only and not is_worker:
                keep.append((thread, is_worker))
                continue
            if thread is not threading.current_thread():
                thread.join(2.0)
            if thread.is_alive():
                keep.append((thread, is_worker))
        self._accept_threads = keep

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

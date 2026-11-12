"""The supervisor's control surface: one private socket, one owner per repository.

The service answers `status` from the in-memory State and hands the mutating commands
(`pause`, `resume`, `stop`) to a handler, which is supplied by whoever runs the loop.

Wire protocol: one JSON request per connection (at most 1 MiB), answered with
`{"ok": true, "result": ...}` or the error envelope from errors.py. The peer's uid must equal
this process's uid. A mutating request carries `request_id` and `expected_revision`; a stale
revision is refused with the current status attached.
"""
import collections
import errno
import fcntl
import json
import os
import re
import socket
import stat
import subprocess
import threading
import time
from pathlib import Path

from . import errors, paths

MAX_REQUEST = 1024 * 1024
MAX_RESPONSE = 4 * 1024 * 1024
SCHEMA_VERSION = 2
MUTATING = ("pause", "resume", "stop")
STOP_MODES = ("drain", "cancel")
_REPLAYS = 256


class Service:
    def __init__(self, root, state, handler, *, peer_resolver=None, run_lock_path=None, board_repo=None):
        self.root = Path(root).resolve(strict=True)
        self.state = state
        self.handler = handler
        self.peer_resolver = peer_resolver or self._peer_actor
        self.domain_id = paths.domain_id_for_root(self.root)
        self.socket_dir = paths.socket_dir(self.domain_id)
        self.socket_path = str(self.socket_dir / "c.sock")
        self.lock_path = str(self.socket_dir / "owner.lock")
        if run_lock_path is None:
            repo = board_repo or _repo_slug(self.root)
            run_lock_path = str(paths.log_dir() / (repo.replace("/", "-") + ".lock"))
        self.run_lock_path = str(run_lock_path)
        self.request_timeout = 5.0
        self._lock = threading.RLock()
        self._replies = collections.OrderedDict()
        self._server = None
        self._accept_thread = None
        self._threads = []
        self._threads_lock = threading.Lock()
        self._owner_fd = None
        self._run_lock_claimed = False

    # --- peer authentication ---------------------------------------------------------

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

    def authenticated_actor(self, peer):
        actor = self.peer_resolver(peer)
        if not actor:
            raise errors.Unauthenticated("actor authentication failed")
        return actor

    # --- ownership and the socket ----------------------------------------------------

    def _prepare_socket_dir(self):
        paths.ensure_socket_base()
        if self.socket_dir.is_symlink():
            raise errors.UnsafeSocketDir("unsafe supervisor socket directory")
        try:
            self.socket_dir.mkdir(mode=0o700)
        except FileExistsError:
            pass
        paths.check_socket_path(self.socket_path)

    @staticmethod
    def _prepare_socket(path):
        target = Path(path)
        if target.exists() or target.is_symlink():
            info = target.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError("unsafe existing socket")
            target.unlink()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            server.bind(str(target))
            os.chmod(str(target), 0o600)
            server.listen(16)
        except BaseException:
            server.close()
            raise
        server.settimeout(0.05)
        return server

    def owner_pid(self):
        """The pid recorded by the process that owns this repository's supervisor, or None."""
        for _ in range(10):
            try:
                text = Path(self.lock_path).read_text(encoding="utf-8").strip()
            except OSError:
                return None
            if text.isdigit():
                return int(text)
            time.sleep(0.05)
        return None

    def _ack(self, owner, **extra):
        return dict({"ready": True, "owner": owner, "socket": self.socket_path}, **extra)

    def serve(self):
        """Take ownership and start answering. `owner: false` means another process holds it."""
        with self._lock:
            if self._server is not None:
                return self._ack(True)
            self._prepare_socket_dir()
            fd = os.open(self.lock_path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except (BlockingIOError, OSError):
                os.close(fd)
                return self._ack(False)
            self._owner_fd = fd
            try:
                os.fchmod(fd, 0o600)
                os.ftruncate(fd, 0)
                os.write(fd, ("%d\n" % os.getpid()).encode())
                self._claim_run_lock()
                try:
                    self._server = self._prepare_socket(self.socket_path)
                except OSError as exc:
                    if exc.errno != errno.EPERM:
                        raise
                    self._release_ownership()
                    return {"ready": False, "owner": False, "socket": self.socket_path,
                            "socket_unavailable": True}
            except BaseException:
                self._release_ownership()
                raise
            self._accept_thread = threading.Thread(target=self._accept, args=(self._server,), daemon=True)
            self._accept_thread.start()
            return self._ack(True)

    def _claim_run_lock(self):
        """The legacy run lock stays until Phase 7: a tick wrapper and a supervisor exclude each other."""
        claim_script = Path(__file__).resolve().parents[1] / "claim-run-lock.py"
        Path(self.run_lock_path).parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        claim = subprocess.run([os.environ.get("PYTHON", "python3"), str(claim_script),
                                self.run_lock_path, str(os.getpid()), "--kind", "service"],
                               capture_output=True, text=True)
        if claim.returncode:
            raise RuntimeError("legacy run lock: " + (claim.stderr.strip() or "claim failed"))
        self._run_lock_claimed = True

    def _release_ownership(self):
        if self._run_lock_claimed:
            try:
                lines = Path(self.run_lock_path).read_text(encoding="utf-8").splitlines()
                if len(lines) >= 3 and lines[0] == str(os.getpid()) and lines[2] == "service":
                    Path(self.run_lock_path).unlink()
            except (OSError, IndexError):
                pass
            self._run_lock_claimed = False
        if self._owner_fd is not None:
            try:
                os.ftruncate(self._owner_fd, 0)
            except OSError:
                pass
            os.close(self._owner_fd)
            self._owner_fd = None

    def close(self):
        """Stop answering, let in-flight replies finish, remove the socket, release ownership."""
        server, self._server = self._server, None
        if server is not None:
            server.close()
        thread, self._accept_thread = self._accept_thread, None
        if thread is not None and thread is not threading.current_thread():
            thread.join(2.0)
        # Connection threads are registered before they start, so a connection accepted just before
        # the shutdown is always in the list; re-read it until no live thread is left (bounded).
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            with self._threads_lock:
                pending = [item for item in self._threads
                           if (item.is_alive() or item.ident is None) and item is not threading.current_thread()]
            if not pending:
                break
            for item in pending:
                if item.ident is None:
                    time.sleep(0.01)  # registered, about to start
                else:
                    item.join(max(0.05, min(2.0, deadline - time.monotonic())))
        if server is not None:
            try:
                Path(self.socket_path).unlink()
            except FileNotFoundError:
                pass
        self._release_ownership()

    # --- serving ---------------------------------------------------------------------

    def _accept(self, server):
        while True:
            try:
                connection, _ = server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            thread = threading.Thread(target=self._serve_connection, args=(connection,), daemon=True)
            self._track_thread(thread)
            thread.start()

    def _track_thread(self, thread):
        """Keep only live (or not yet started) threads: a long-lived service sees one connection per poll.
        Called before thread.start(), so a thread that has not started yet is kept."""
        with self._threads_lock:
            self._threads[:] = [item for item in self._threads if item.is_alive() or item.ident is None]
            self._threads.append(thread)

    def _serve_connection(self, connection):
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
                request = json.loads(b"".join(chunks).decode("utf-8"))
                payload = self.handle_request_envelope(request, peer=connection)
            except Exception as exc:
                payload = errors.error_envelope(exc, self.status_view)
            try:
                connection.sendall(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
            except OSError:
                pass

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
            raise errors.Invalid("actor must come from authenticated peer")
        self.authenticated_actor(peer)
        command = request.get("command")
        if command == "status":
            return self.status_view()
        if command in MUTATING:
            self._require_mutation_binding(request)
            if command == "stop" and request.get("mode") not in STOP_MODES:
                raise errors.Invalid("stop mode must be drain or cancel")
            return self._mutate(request)
        raise errors.Invalid("unsupported command")

    @staticmethod
    def _require_mutation_binding(request):
        if not isinstance(request.get("request_id"), str) or not request["request_id"]:
            raise errors.Invalid("request_id required")
        if type(request.get("expected_revision")) is not int:
            raise errors.Invalid("expected_revision required")

    def _mutate(self, request):
        with self._lock:
            canonical = paths.canonical_json(request)
            replay = self._replies.get(request["request_id"])
            if replay is not None:
                if replay[0] != canonical:
                    raise errors.Invalid("command ID already used for a different request")
                return replay[1]
            if request["expected_revision"] != self.state.revision:
                raise errors.StaleRevision("state revision is %d, not %d"
                                           % (self.state.revision, request["expected_revision"]))
            result = self.handler(dict(request))
            self._replies[request["request_id"]] = (canonical, result)
            while len(self._replies) > _REPLAYS:
                self._replies.popitem(last=False)
            return result

    def status_view(self):
        """The one canonical status object: the State snapshot, with `active` as a list."""
        # No service lock: State.snapshot() is atomic and a deep copy, and a status reply must never
        # wait behind a mutating command that is waiting for the loop.
        snapshot = self.state.snapshot()
        snapshot["active"] = sorted(snapshot["active"].values(), key=lambda action: action["card"])
        snapshot.update(schema_version=SCHEMA_VERSION, pid=os.getpid(), root=str(self.root))
        return snapshot


def _repo_slug(root):
    config = Path(__file__).resolve().parents[1] / "config.sh"
    try:
        result = subprocess.run(["bash", str(config), "--dir", str(root), "board.repo"],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5)
        if result.returncode == 0 and re.fullmatch(r"[A-Za-z0-9._/-]+", result.stdout.strip() or "!"):
            return result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return Path(root).name

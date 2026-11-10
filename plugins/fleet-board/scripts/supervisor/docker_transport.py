"""Trusted host-side Docker worker transport and attempt-scoped broker relay."""
import base64
import binascii
import fcntl
from contextlib import contextmanager
import hmac
import json
import math
import os
from pathlib import Path
import queue
import re
import selectors
import signal
import shutil
import stat
import subprocess
import struct
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from .docker_agent import MAX_FRAME_BYTES, read_frame
from .inference_broker import ContractError
from .isolation import IsolationUnavailable, docker_run_argv


_CONTAINER_ID = re.compile(r'^[0-9a-f]{64}$')
_ALLOWED_OPERATIONS = frozenset(('infer', 'heartbeat', 'result', 'scope_request'))
_STDOUT_LIMIT = 1048576
_STDERR_LIMIT = 65536
_LABEL_RECONCILE_GRACE_SECONDS = 2.0
_LABEL_RECONCILE_POLL_SECONDS = .05
_ATTEMPT_ID = re.compile(r'^[A-Za-z0-9_-]{1,128}$')


class _CleanupRegistry:
    """Atomic, locked pending-label journal beside a trusted operation journal."""

    def __init__(self, operation_journal):
        journal = Path(operation_journal)
        if (not journal.is_absolute() or journal.is_symlink()
                or journal.parent.is_symlink()):
            raise ValueError('unsafe cleanup registry journal path')
        parent = journal.parent
        if parent.resolve(strict=True) != parent or not parent.is_dir():
            raise ValueError('unsafe cleanup registry parent')
        parent_info = parent.stat()
        if parent_info.st_uid != os.getuid() or parent_info.st_mode & 0o077:
            raise ValueError('unsafe cleanup registry parent')
        if journal.exists():
            info = journal.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077 or info.st_nlink != 1):
                raise ValueError('unsafe cleanup registry journal')
        self.path = journal.with_name(journal.name + '.docker-cleanup.json')
        self.lock_path = journal.with_name(journal.name + '.docker-cleanup.lock')
        self.parent = parent
        if self.path.is_symlink():
            raise ValueError('unsafe cleanup registry file')

    @contextmanager
    def exclusive(self):
        flags = os.O_RDWR | os.O_CREAT | getattr(os, 'O_NOFOLLOW', 0)
        fd = os.open(str(self.lock_path), flags, 0o600)
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077 or info.st_nlink != 1):
                raise ValueError('unsafe cleanup registry lock')
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)

    def _read(self):
        if not self.path.exists():
            return []
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
        fd = os.open(str(self.path), flags)
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077 or info.st_nlink != 1 or info.st_size > 65536):
                raise ValueError('unsafe cleanup registry file')
            raw = b''
            while len(raw) <= 65536:
                chunk = os.read(fd, 65537 - len(raw))
                if not chunk:
                    break
                raw += chunk
        finally:
            os.close(fd)
        value = json.loads(raw.decode('ascii'))
        if (not isinstance(value, dict) or set(value) != {'schema_version', 'attempts'}
                or value.get('schema_version') != 1 or not isinstance(value.get('attempts'), list)
                or any(not isinstance(item, dict)
                       or set(item) != {'attempt_id', 'state', 'pid', 'pid_start'}
                       or not isinstance(item.get('attempt_id'), str)
                       or not _ATTEMPT_ID.fullmatch(item['attempt_id'])
                       or item.get('state') not in ('starting', 'active', 'pending')
                       or (item.get('state') in ('starting', 'active') and
                           (type(item.get('pid')) is not int or item['pid'] < 1
                            or not isinstance(item.get('pid_start'), str)
                            or not item['pid_start']))
                       or (item.get('state') == 'pending' and
                           (item.get('pid') is not None or item.get('pid_start') is not None))
                       for item in value['attempts'])
                or len({item['attempt_id'] for item in value['attempts']}) != len(value['attempts'])):
            raise ValueError('malformed cleanup registry')
        return value['attempts']

    def _write(self, attempts):
        data = json.dumps({'schema_version': 1,
                           'attempts': sorted(attempts, key=lambda item: item['attempt_id'])},
                          separators=(',', ':'), sort_keys=True).encode('ascii')
        temp = self.path.with_name('.' + self.path.name + '.' + os.urandom(8).hex())
        fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        try:
            os.replace(str(temp), str(self.path))
            dir_fd = os.open(str(self.parent), os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        finally:
            try:
                temp.unlink()
            except FileNotFoundError:
                pass

    def _update(self, attempt_id, state, pid=None, pid_start=None):
        with self.exclusive():
            attempts = self._read()
            found = False
            for item in attempts:
                if item['attempt_id'] == attempt_id:
                    item.update(state=state, pid=pid, pid_start=pid_start)
                    found = True
                    break
            if not found:
                attempts.append({'attempt_id': attempt_id, 'state': state,
                                 'pid': pid, 'pid_start': pid_start})
            self._write(attempts)

    def begin(self, attempt_id, pid, pid_start):
        if type(pid) is not int or pid < 1 or not pid_start:
            raise ValueError('controller process identity is unavailable')
        with self.exclusive():
            attempts = self._read()
            if any(item['attempt_id'] == attempt_id for item in attempts):
                raise ValueError('Docker attempt label is already registered')
            attempts.append({'attempt_id': attempt_id, 'state': 'starting',
                             'pid': pid, 'pid_start': pid_start})
            self._write(attempts)

    def activate(self, attempt_id, pid, pid_start):
        if not pid_start:
            raise ValueError('Docker process identity is unavailable')
        self._update(attempt_id, 'active', pid, pid_start)

    def pending(self, attempt_id):
        self._update(attempt_id, 'pending')

    def process_identity(self, pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return None
        try:
            completed = subprocess.run(['ps', '-o', 'lstart=', '-p', str(pid)],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, timeout=1, check=False,
                                       close_fds=True)
        except (OSError, subprocess.SubprocessError):
            return None
        if completed.returncode != 0:
            return None
        output = completed.stdout
        if isinstance(output, bytes):
            try:
                output = output.decode('ascii', 'strict')
            except UnicodeError:
                return None
        identity = output.strip() if isinstance(output, str) else ''
        return identity or None

    def _remove_locked(self, attempt_id):
        attempts = [item for item in self._read() if item['attempt_id'] != attempt_id]
        if attempts:
            self._write(attempts)
        else:
            try:
                self.path.unlink()
                dir_fd = os.open(str(self.parent), os.O_RDONLY)
                try:
                    os.fsync(dir_fd)
                finally:
                    os.close(dir_fd)
            except FileNotFoundError:
                pass

    def _clear_locked(self):
        try:
            self.path.unlink()
            dir_fd = os.open(str(self.parent), os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except FileNotFoundError:
            pass

    def remove(self, attempt_id):
        with self.exclusive():
            self._remove_locked(attempt_id)


def _terminate_group(process):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except OSError:
        pass
    try:
        process.wait(timeout=.3)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass


class DockerWorkerTransport:
    """Launch one Docker container and relay only its authorized broker operations."""

    def __init__(self, *, frame_limit=MAX_FRAME_BYTES):
        if type(frame_limit) is not int or frame_limit < 1024:
            raise ValueError('invalid Docker relay frame limit')
        self.frame_limit = frame_limit
        self.last_container_id = None

    @staticmethod
    def _start_frame(argv, policy, bootstrap, attempt_id, capability):
        if (not isinstance(bootstrap, dict) or not isinstance(argv, (list, tuple))
                or not argv or any(not isinstance(arg, str) or not arg for arg in argv)
                or not isinstance(attempt_id, str) or not attempt_id
                or not isinstance(capability, str) or not capability):
            raise ContractError('invalid Docker worker bootstrap')
        try:
            value = json.loads(json.dumps(bootstrap, allow_nan=False))
        except (TypeError, ValueError) as exc:
            raise ContractError('invalid Docker worker bootstrap') from exc
        inference = value.get('inference')
        if (not isinstance(inference, dict) or inference.get('attempt_id') != attempt_id
                or not isinstance(inference.get('capability'), str)
                or not hmac.compare_digest(inference['capability'], capability)):
            raise ContractError('Docker worker bootstrap attempt binding mismatch')
        inference['socket_path'] = '/tmp/fleet-board-inference.sock'
        worker_input = json.dumps(value, separators=(',', ':'), allow_nan=False).encode('utf-8')
        if len(worker_input) > 4 * 1048576:
            raise ContractError('Docker worker bootstrap exceeded limit')
        return {'type': 'start', 'schema_version': 1, 'attempt_id': attempt_id,
                'capability': capability, 'argv': list(argv),
                'worker_input': base64.b64encode(worker_input).decode('ascii')}

    @staticmethod
    def _read_cid(cidfile):
        try:
            raw = Path(cidfile).read_text(encoding='ascii').strip()
        except OSError:
            return None
        return raw if _CONTAINER_ID.fullmatch(raw) else False

    @staticmethod
    def _remove_container(docker, container_id, timeout=5):
        if not _CONTAINER_ID.fullmatch(container_id or ''):
            return False
        try:
            completed = subprocess.run([docker, 'rm', '-f', container_id],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, timeout=timeout, check=False,
                                       close_fds=True)
        except (OSError, subprocess.SubprocessError):
            return False
        return completed.returncode == 0

    @classmethod
    def _reconcile_labeled_containers(cls, docker, attempt_id, *, return_removed=False):
        label = 'org.fleet-board.supervisor.attempt-id=' + attempt_id
        deadline = time.monotonic() + _LABEL_RECONCILE_GRACE_SECONDS
        removed_any = False
        def result(ok):
            return (ok, removed_any) if return_removed else ok
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return result(True)
            try:
                completed = subprocess.run(
                    [docker, 'ps', '-aq', '--filter', 'label=' + label],
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    timeout=remaining, check=False, close_fds=True)
            except (OSError, subprocess.SubprocessError):
                return result(False)
            if completed.returncode != 0:
                return result(False)
            output = completed.stdout
            try:
                if isinstance(output, bytes):
                    output = output.decode('ascii', 'strict')
            except UnicodeError:
                return result(False)
            if not isinstance(output, str):
                return result(False)
            container_ids = [line.strip() for line in output.splitlines() if line.strip()]
            if any(not _CONTAINER_ID.fullmatch(container_id) for container_id in container_ids):
                return result(False)
            removed_all = True
            for container_id in container_ids:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not cls._remove_container(
                        docker, container_id, timeout=max(.001, remaining)):
                    removed_all = False
                else:
                    removed_any = True
            if not removed_all:
                return result(False)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return result(True)
            time.sleep(min(_LABEL_RECONCILE_POLL_SECONDS, remaining))

    def run(self, argv, policy, *, bootstrap, channel, attempt_id, capability,
            timeout, cancel_event):
        if (type(timeout) not in (int, float) or not math.isfinite(timeout)
                or timeout <= 0 or timeout > 86400
                or not isinstance(cancel_event, threading.Event)
                or not callable(getattr(channel, 'request', None))):
            raise ValueError('invalid Docker transport bounds or broker')
        docker = policy.get('command') if isinstance(policy, dict) else None
        if not isinstance(docker, str) or not os.path.isabs(docker):
            raise IsolationUnavailable('Docker executable unavailable')
        if not isinstance(attempt_id, str) or not _ATTEMPT_ID.fullmatch(attempt_id):
            raise ContractError('invalid Docker attempt label')
        journal = getattr(channel, 'operation_journal', None)
        registry = None
        if journal is not None:
            try:
                registry = _CleanupRegistry(journal)
                unresolved = []
                with registry.exclusive():
                    attempts = registry._read()
                    retained = []
                    for record in attempts:
                        if record['state'] in ('active', 'starting'):
                            identity = registry.process_identity(record['pid'])
                            if identity is None:
                                unresolved.append(record['attempt_id'])
                                retained.append(record)
                                continue
                            if identity == record['pid_start']:
                                if record['state'] == 'starting':
                                    unresolved.append(record['attempt_id'])
                                retained.append(record)
                                continue
                            record.update(state='pending', pid=None, pid_start=None)
                        if record['state'] == 'starting':
                            unresolved.append(record['attempt_id'])
                            retained.append(record)
                            continue
                        ok, removed = self._reconcile_labeled_containers(
                            docker, record['attempt_id'], return_removed=True)
                        if ok and removed:
                            continue
                        if not ok:
                            unresolved.append(record['attempt_id'])
                        retained.append(record)
                    if retained != attempts:
                        if retained:
                            registry._write(retained)
                        else:
                            registry._clear_locked()
                if unresolved:
                    raise IsolationUnavailable(
                        'Docker cleanup pending for attempt label(s): ' + ', '.join(unresolved))
            except (OSError, ValueError, TypeError, UnicodeError,
                    json.JSONDecodeError) as exc:
                if isinstance(exc, IsolationUnavailable):
                    raise
                raise IsolationUnavailable('Docker cleanup registry is unavailable or malformed') from exc
        return self._run_locked(
            argv, policy, bootstrap=bootstrap, channel=channel, attempt_id=attempt_id,
            capability=capability, timeout=timeout, cancel_event=cancel_event,
            cleanup_registry=registry)

    def _run_locked(self, argv, policy, *, bootstrap, channel, attempt_id, capability,
                    timeout, cancel_event, cleanup_registry):
        self.last_container_id = None
        if (type(timeout) not in (int, float) or not math.isfinite(timeout)
                or timeout <= 0 or timeout > 86400
                or not isinstance(cancel_event, threading.Event)
                or not callable(getattr(channel, 'request', None))):
            raise ValueError('invalid Docker transport bounds or broker')
        docker = policy.get('command') if isinstance(policy, dict) else None
        if not isinstance(docker, str) or not os.path.isabs(docker):
            raise IsolationUnavailable('Docker executable unavailable')
        if not isinstance(attempt_id, str) or not _ATTEMPT_ID.fullmatch(attempt_id):
            raise ContractError('invalid Docker attempt label')
        started = time.monotonic()
        deadline = started + timeout
        start_frame = self._start_frame(argv, policy, bootstrap, attempt_id, capability)
        command = None
        process = None
        frame_queue = queue.Queue(maxsize=4)
        writer_lock = threading.Lock()
        stderr = bytearray()
        docker_stderr = bytearray()
        stdout = bytearray()
        stderr_lock = threading.Lock()
        active_requests = set()
        active_lock = threading.Lock()
        reader_threads = []
        writer_thread = None
        writer_done = threading.Event()
        writer_errors = []
        reader_stop = threading.Event()
        relay_admission_stopped = threading.Event()
        relay_futures = []
        executor = ThreadPoolExecutor(max_workers=16, thread_name_prefix='docker-broker')
        successful = False
        cleanup_failure = None
        overflow = None
        cidfile = None
        registered_attempt = False

        def write_host_frame(frame):
            try:
                payload = json.dumps(frame, separators=(',', ':'), ensure_ascii=False,
                                     allow_nan=False).encode('utf-8')
            except (TypeError, ValueError) as exc:
                raise ContractError('invalid Docker worker control frame') from exc
            if not payload or len(payload) > self.frame_limit:
                raise ContractError('Docker worker control frame exceeded limit')
            wire = struct.pack('!I', len(payload)) + payload
            with writer_lock:
                if process is None or process.stdin is None:
                    raise ContractError('Docker worker control stream is unavailable')
                descriptor = process.stdin.fileno()
                selector = selectors.DefaultSelector()
                try:
                    selector.register(descriptor, selectors.EVENT_WRITE)
                    offset = 0
                    while offset < len(wire):
                        if cancel_event.is_set() or relay_admission_stopped.is_set():
                            raise ContractError('Docker worker control stream cancelled')
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise ContractError('Docker worker control stream deadline exceeded')
                        try:
                            offset += os.write(descriptor, wire[offset:offset + 65536])
                        except BlockingIOError:
                            selector.select(min(.05, remaining))
                finally:
                    selector.close()

        def enqueue_reader_event(event):
            while not reader_stop.is_set():
                try:
                    frame_queue.put(event, timeout=.05)
                    return True
                except queue.Full:
                    continue
            return False

        def read_frames():
            try:
                while True:
                    frame = read_frame(process.stdout, self.frame_limit)
                    if not enqueue_reader_event(('frame', frame)):
                        return
            except EOFError:
                enqueue_reader_event(('eof', None))
            except Exception as exc:
                enqueue_reader_event(('error', exc))

        def read_docker_stderr():
            while True:
                chunk = process.stderr.read(8192)
                if not chunk:
                    return
                with stderr_lock:
                    if len(docker_stderr) + len(chunk) > _STDERR_LIMIT:
                        docker_stderr.extend(chunk[:max(0, _STDERR_LIMIT - len(docker_stderr))])
                        enqueue_reader_event(('error', ContractError('Docker stderr exceeded limit')))
                        return
                    else:
                        docker_stderr.extend(chunk)

        def write_start_frame():
            try:
                write_host_frame(start_frame)
            except Exception as exc:
                writer_errors.append(exc)
            finally:
                writer_done.set()

        def relay_request(frame, remaining):
            request_id = frame['id']
            try:
                value = channel.request(attempt_id, capability, frame['request'],
                                        operation=frame['operation'], timeout=remaining)
                response = {'schema_version': 1, 'result': value}
            except Exception:
                response = {'schema_version': 1, 'error': 'request rejected'}
            try:
                if not relay_admission_stopped.is_set():
                    write_host_frame({'type': 'response', 'id': request_id,
                                      'response': response})
            except (OSError, ValueError, ContractError):
                pass
            finally:
                with active_lock:
                    active_requests.discard(request_id)

        scratch_parent = '/private/tmp' if Path('/private/tmp').is_dir() else None
        scratch = tempfile.mkdtemp(prefix='fleet-board-docker-', dir=scratch_parent)
        cidfile = os.path.join(scratch, 'worker.cid')
        try:
            from .isolation import verify_docker_desktop_identity

            remaining = deadline - time.monotonic()
            if remaining <= 0 or cancel_event.is_set():
                raise IsolationUnavailable('Docker transport deadline or cancellation before identity check')
            verify_docker_desktop_identity(
                docker, policy.get('daemon_identity'), timeout=remaining,
                cancel_event=cancel_event)
            if cancel_event.is_set():
                raise IsolationUnavailable('Docker transport cancelled during identity check')
            if time.monotonic() >= deadline:
                raise IsolationUnavailable('Docker transport deadline exceeded during identity check')
            command = docker_run_argv(['python3', '-m', 'supervisor.docker_agent'],
                                      policy, cidfile)
            command.insert(command.index('--cidfile=' + cidfile),
                           '--label=org.fleet-board.supervisor.attempt-id=' + attempt_id)
            if cleanup_registry is not None:
                controller_identity = cleanup_registry.process_identity(os.getpid())
                cleanup_registry.begin(attempt_id, os.getpid(), controller_identity)
                registered_attempt = True
            process = subprocess.Popen(command, cwd=policy['workspace'], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       close_fds=True, start_new_session=True)
            if cleanup_registry is not None:
                cleanup_registry.activate(
                    attempt_id, process.pid, cleanup_registry.process_identity(process.pid))
            os.set_blocking(process.stdin.fileno(), False)
            for target in (read_frames, read_docker_stderr):
                thread = threading.Thread(target=target, daemon=True)
                thread.start()
                reader_threads.append(thread)
            writer_thread = threading.Thread(target=write_start_frame, daemon=True)
            writer_thread.start()
            exit_code = None
            while exit_code is None:
                now = time.monotonic()
                if cancel_event.is_set():
                    raise ContractError('Docker worker cancelled')
                if now >= deadline:
                    raise ContractError('Docker worker deadline exceeded')
                if writer_done.is_set() and writer_errors:
                    raise ContractError('Docker worker bootstrap write failed') from writer_errors[0]
                try:
                    kind, item = frame_queue.get(timeout=min(.05, deadline - now))
                except queue.Empty:
                    if process.poll() is not None:
                        raise ContractError('Docker worker exited without an exit frame')
                    continue
                if kind == 'error':
                    try:
                        process.wait(timeout=.2)
                    except subprocess.TimeoutExpired:
                        pass
                    for thread in reader_threads:
                        thread.join(timeout=.2)
                    detail = bytes(docker_stderr).decode('utf-8', 'replace').strip()
                    raise ContractError('Docker worker relay failed: ' +
                                        (detail[-180:] if detail else str(item)[:180])) from item
                if kind == 'eof':
                    raise ContractError('Docker worker control stream closed')
                if not isinstance(item, dict) or not isinstance(item.get('type'), str):
                    raise ContractError('invalid Docker worker frame')
                frame_type = item['type']
                if frame_type in ('stdout', 'stderr'):
                    if set(item) != {'type', 'data'} or not isinstance(item['data'], str):
                        raise ContractError('invalid Docker worker output frame')
                    try:
                        data = base64.b64decode(item['data'], validate=True)
                    except (binascii.Error, ValueError) as exc:
                        raise ContractError('invalid Docker worker output frame') from exc
                    target, limit = ((stdout, _STDOUT_LIMIT) if frame_type == 'stdout'
                                     else (stderr, _STDERR_LIMIT))
                    if len(target) + len(data) > limit:
                        raise ContractError('Docker worker output exceeded limit')
                    target.extend(data)
                elif frame_type == 'rpc':
                    if (set(item) != {'type', 'id', 'operation', 'attempt_id',
                                       'capability', 'request'}
                            or not isinstance(item.get('id'), str) or not item['id']
                            or len(item['id']) > 128
                            or item.get('operation') not in _ALLOWED_OPERATIONS
                            or item.get('attempt_id') != attempt_id
                            or not isinstance(item.get('capability'), str)
                            or not hmac.compare_digest(item['capability'], capability)
                            or not isinstance(item.get('request'), dict)
                            or item['request'].get('attempt_id') != attempt_id):
                        raise ContractError('Docker worker requested an unauthorized operation')
                    with active_lock:
                        if item['id'] in active_requests or len(active_requests) >= 16:
                            raise ContractError('Docker worker request ID collision or overflow')
                        active_requests.add(item['id'])
                    if relay_admission_stopped.is_set():
                        raise ContractError('Docker worker broker admission stopped')
                    relay_futures.append(
                        executor.submit(relay_request, item, max(.01, deadline - now)))
                elif frame_type == 'exit':
                    if set(item) != {'type', 'code'} or type(item.get('code')) is not int:
                        raise ContractError('invalid Docker worker exit frame')
                    exit_code = item['code']
                elif frame_type == 'fatal':
                    raise ContractError('Docker guest agent failed')
                else:
                    raise ContractError('unknown Docker worker frame type')
            while active_requests and time.monotonic() < deadline:
                time.sleep(.01)
            if active_requests:
                raise ContractError('Docker worker exited with broker requests pending')
            process.stdin.close()
            try:
                process.wait(timeout=max(.1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired as exc:
                raise ContractError('Docker worker container did not exit') from exc
            for thread in reader_threads:
                thread.join(timeout=.5)
            if process.returncode != 0 and exit_code == 0:
                raise ContractError('Docker worker exit status mismatch')
            container_id = self._read_cid(cidfile)
            if container_id is False:
                raise ContractError('Docker returned a malformed container ID')
            if not container_id:
                raise ContractError('Docker did not return a container ID')
            self.last_container_id = container_id
            successful = True
            return subprocess.CompletedProcess(command, exit_code,
                                                bytes(stdout), bytes(stderr + docker_stderr))
        except (OSError, ValueError, TypeError, subprocess.SubprocessError) as exc:
            if isinstance(exc, (ContractError, IsolationUnavailable)):
                raise
            raise IsolationUnavailable('Docker worker launch or relay failed') from exc
        finally:
            if not successful:
                relay_admission_stopped.set()
                reader_stop.set()
                cancel_event.set()
                for future in relay_futures:
                    future.cancel()
            executor.shutdown(wait=True, cancel_futures=True)
            if not successful and process is not None:
                _terminate_group(process)
                try:
                    if cleanup_registry is not None:
                        cleanup_registry.pending(attempt_id)
                    container_id = self._read_cid(cidfile) if cidfile else None
                    if container_id is False:
                        ok, removed = self._reconcile_labeled_containers(
                            docker, attempt_id, return_removed=True)
                        if ok and removed and cleanup_registry is not None:
                            cleanup_registry.remove(attempt_id)
                        elif not ok:
                            cleanup_failure = 'Docker container cleanup failed: label reconciliation failed'
                        else:
                            cleanup_failure = ('Docker cleanup pending for attempt label: ' + attempt_id
                                               if cleanup_registry is not None else
                                               'Docker cleanup pending: no durable registry for attempt label ' + attempt_id)
                    else:
                        self.last_container_id = container_id
                        if container_id and not self._remove_container(docker, container_id):
                            cleanup_failure = 'Docker container cleanup failed'
                        elif container_id and cleanup_registry is not None:
                            cleanup_registry.remove(attempt_id)
                        elif not container_id:
                            ok, removed = self._reconcile_labeled_containers(
                                docker, attempt_id, return_removed=True)
                            if ok and removed and cleanup_registry is not None:
                                cleanup_registry.remove(attempt_id)
                            elif not ok:
                                cleanup_failure = 'Docker container cleanup failed: label reconciliation failed'
                            else:
                                cleanup_failure = ('Docker cleanup pending for attempt label: ' + attempt_id
                                                   if cleanup_registry is not None else
                                                   'Docker cleanup pending: no durable registry for attempt label ' + attempt_id)
                except Exception:
                    cleanup_failure = 'Docker container cleanup failed'
                    if cleanup_registry is not None:
                        try:
                            cleanup_registry.pending(attempt_id)
                        except Exception:
                            pass
            elif not successful and cleanup_registry is not None and registered_attempt:
                try:
                    cleanup_registry.remove(attempt_id)
                except Exception:
                    cleanup_failure = 'Docker cleanup registry could not clear unlaunched attempt'
            elif successful and cleanup_registry is not None:
                try:
                    cleanup_registry.remove(attempt_id)
                except Exception:
                    cleanup_failure = 'Docker cleanup registry could not clear completed attempt'
            for thread in reader_threads:
                thread.join(timeout=.5)
            if writer_thread is not None:
                writer_thread.join(timeout=.5)
            if process is not None:
                try:
                    process.stdin.close()
                except (OSError, AttributeError):
                    pass
                for stream in (process.stdout, process.stderr):
                    try:
                        stream.close()
                    except OSError:
                        pass
            shutil.rmtree(scratch, ignore_errors=True)
            if cleanup_failure:
                raise IsolationUnavailable(cleanup_failure)

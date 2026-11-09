"""Trusted host-side Docker worker transport and attempt-scoped broker relay."""
import base64
import binascii
import hmac
import json
import os
from pathlib import Path
import queue
import re
import signal
import shutil
import subprocess
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from .docker_agent import MAX_FRAME_BYTES, read_frame, write_frame
from .inference_broker import ContractError
from .isolation import IsolationUnavailable, docker_run_argv


_CONTAINER_ID = re.compile(r'^[0-9a-f]{64}$')
_ALLOWED_OPERATIONS = frozenset(('infer', 'heartbeat', 'result', 'scope_request'))
_STDOUT_LIMIT = 1048576
_STDERR_LIMIT = 65536


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
    def _remove_container(docker, container_id):
        if not _CONTAINER_ID.fullmatch(container_id or ''):
            return False
        try:
            completed = subprocess.run([docker, 'rm', '-f', container_id],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, timeout=5, check=False,
                                       close_fds=True)
        except (OSError, subprocess.SubprocessError):
            return False
        return completed.returncode == 0

    def run(self, argv, policy, *, bootstrap, channel, attempt_id, capability,
            timeout, cancel_event):
        if (type(timeout) not in (int, float) or timeout <= 0
                or not isinstance(cancel_event, threading.Event)
                or not callable(getattr(channel, 'request', None))):
            raise ValueError('invalid Docker transport bounds or broker')
        docker = policy.get('command') if isinstance(policy, dict) else None
        if not isinstance(docker, str) or not os.path.isabs(docker):
            raise IsolationUnavailable('Docker executable unavailable')
        start_frame = self._start_frame(argv, policy, bootstrap, attempt_id, capability)
        command = None
        process = None
        frame_queue = queue.Queue()
        writer_lock = threading.Lock()
        stderr = bytearray()
        docker_stderr = bytearray()
        stdout = bytearray()
        stderr_lock = threading.Lock()
        active_requests = set()
        active_lock = threading.Lock()
        reader_threads = []
        executor = ThreadPoolExecutor(max_workers=16, thread_name_prefix='docker-broker')
        successful = False
        overflow = None
        started = time.monotonic()
        cidfile = None

        def write_host_frame(frame):
            with writer_lock:
                if process is None or process.stdin is None:
                    raise ContractError('Docker worker control stream is unavailable')
                write_frame(process.stdin, frame, self.frame_limit)

        def read_frames():
            try:
                while True:
                    frame_queue.put(('frame', read_frame(process.stdout, self.frame_limit)))
            except EOFError:
                frame_queue.put(('eof', None))
            except Exception as exc:
                frame_queue.put(('error', exc))

        def read_docker_stderr():
            while True:
                chunk = process.stderr.read(8192)
                if not chunk:
                    return
                with stderr_lock:
                    if len(docker_stderr) + len(chunk) > _STDERR_LIMIT:
                        docker_stderr.extend(chunk[:max(0, _STDERR_LIMIT - len(docker_stderr))])
                        frame_queue.put(('error', ContractError('Docker stderr exceeded limit')))
                    else:
                        docker_stderr.extend(chunk)

        def relay_request(frame, remaining):
            request_id = frame['id']
            try:
                value = channel.request(attempt_id, capability, frame['request'],
                                        operation=frame['operation'], timeout=remaining)
                response = {'schema_version': 1, 'result': value}
            except Exception:
                response = {'schema_version': 1, 'error': 'request rejected'}
            try:
                write_host_frame({'type': 'response', 'id': request_id, 'response': response})
            finally:
                with active_lock:
                    active_requests.discard(request_id)

        scratch_parent = '/private/tmp' if Path('/private/tmp').is_dir() else None
        scratch = tempfile.mkdtemp(prefix='fleet-board-docker-', dir=scratch_parent)
        cidfile = os.path.join(scratch, 'worker.cid')
        try:
            command = docker_run_argv(['python3', '-m', 'supervisor.docker_agent'],
                                      policy, cidfile)
            process = subprocess.Popen(command, cwd=policy['workspace'], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       close_fds=True, start_new_session=True)
            write_frame(process.stdin, start_frame, self.frame_limit)
            for target in (read_frames, read_docker_stderr):
                thread = threading.Thread(target=target, daemon=True)
                thread.start()
                reader_threads.append(thread)
            deadline = started + timeout
            exit_code = None
            while exit_code is None:
                now = time.monotonic()
                if cancel_event.is_set():
                    raise ContractError('Docker worker cancelled')
                if now >= deadline:
                    raise ContractError('Docker worker deadline exceeded')
                try:
                    kind, item = frame_queue.get(timeout=min(.05, deadline - now))
                except queue.Empty:
                    if process.poll() is not None:
                        raise ContractError('Docker worker exited without an exit frame')
                    continue
                if kind == 'error':
                    raise ContractError('Docker worker relay failed') from item
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
                    executor.submit(relay_request, item, max(.01, deadline - now))
                elif frame_type == 'exit':
                    if set(item) != {'type', 'code'} or type(item.get('code')) is not int:
                        raise ContractError('invalid Docker worker exit frame')
                    exit_code = item['code']
                elif frame_type == 'fatal':
                    raise ContractError('Docker guest agent failed')
                else:
                    raise ContractError('unknown Docker worker frame type')
            deadline = started + timeout
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
            successful = True
            return subprocess.CompletedProcess(command, exit_code,
                                                bytes(stdout), bytes(stderr + docker_stderr))
        except (OSError, ValueError, TypeError, subprocess.SubprocessError) as exc:
            if isinstance(exc, (ContractError, IsolationUnavailable)):
                raise
            raise IsolationUnavailable('Docker worker launch or relay failed') from exc
        finally:
            executor.shutdown(wait=False, cancel_futures=True)
            if not successful and process is not None:
                _terminate_group(process)
                container_id = self._read_cid(cidfile) if cidfile else None
                if container_id is False:
                    raise IsolationUnavailable('refusing cleanup with malformed Docker container ID')
                if container_id and not self._remove_container(docker, container_id):
                    raise IsolationUnavailable('Docker container cleanup failed')
            for thread in reader_threads:
                thread.join(timeout=.5)
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

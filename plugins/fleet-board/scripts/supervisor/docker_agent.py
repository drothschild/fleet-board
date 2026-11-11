"""Guest-side Unix-socket to framed-stdio relay for isolated Docker workers."""
import base64
import binascii
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import sys
import threading
import time


MAX_FRAME_BYTES = 8 * 1048576
MAX_WORKER_REQUEST_BYTES = 4 * 1048576
MAX_WORKER_RESPONSE_BYTES = 1049600
MAX_OUTPUT_CHUNK_BYTES = 48 * 1024
ALLOWED_OPERATIONS = frozenset(('infer', 'heartbeat', 'result', 'scope_request'))


def _read_exact(stream, size):
    data = bytearray()
    while len(data) < size:
        chunk = stream.read(size - len(data))
        if not chunk:
            raise ValueError('truncated Docker relay frame')
        data.extend(chunk)
    return bytes(data)


def read_frame(stream, limit=MAX_FRAME_BYTES):
    header = _read_exact(stream, 4)
    size = struct.unpack('!I', header)[0]
    if size < 1 or size > limit:
        raise ValueError('Docker relay frame exceeded limit')
    try:
        value = json.loads(_read_exact(stream, size).decode('utf-8'),
                           parse_constant=lambda _value: (_ for _ in ()).throw(
                               ValueError('invalid JSON constant')))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError('invalid Docker relay frame') from exc
    if not isinstance(value, dict):
        raise ValueError('Docker relay frame must be an object')
    return value


def write_frame(stream, value, limit=MAX_FRAME_BYTES):
    try:
        payload = json.dumps(value, separators=(',', ':'), ensure_ascii=False,
                             allow_nan=False).encode('utf-8')
    except (TypeError, ValueError) as exc:
        raise ValueError('invalid Docker relay frame') from exc
    if not payload or len(payload) > limit:
        raise ValueError('Docker relay frame exceeded limit')
    stream.write(struct.pack('!I', len(payload)) + payload)
    if hasattr(stream, 'flush'):
        stream.flush()


def validate_worker_envelope(envelope, attempt_id, capability):
    required = {'schema_version', 'operation', 'attempt_id', 'capability', 'request'}
    if (not isinstance(envelope, dict) or set(envelope) != required
            or type(envelope.get('schema_version')) is not int
            or envelope.get('schema_version') != 1
            or envelope.get('operation') not in ALLOWED_OPERATIONS
            or envelope.get('attempt_id') != attempt_id
            or not isinstance(capability, str) or not capability
            or not secrets.compare_digest(str(envelope.get('capability', '')), capability)
            or not isinstance(envelope.get('request'), dict)):
        raise ValueError('invalid or unauthorized worker channel envelope')
    return envelope['operation'], envelope['request']


def output_frame(stream, data):
    if stream not in ('stdout', 'stderr') or not isinstance(data, bytes) or not data:
        raise ValueError('invalid Docker worker output')
    if len(data) > MAX_OUTPUT_CHUNK_BYTES:
        raise ValueError('Docker worker output chunk exceeded limit')
    return {'type': stream, 'data': base64.b64encode(data).decode('ascii')}


class RelayMultiplexer:
    """Correlate concurrent local worker requests with host stdio responses."""

    def __init__(self, send_frame):
        if not callable(send_frame):
            raise ValueError('Docker relay requires a frame writer')
        self._send_frame = send_frame
        self._send_lock = threading.Lock()
        self._lock = threading.Lock()
        self._pending = {}
        self._closed = None

    def request(self, envelope, attempt_id, capability, *, timeout=310):
        operation, request = validate_worker_envelope(envelope, attempt_id, capability)
        if type(timeout) not in (int, float) or timeout <= 0:
            raise ValueError('invalid Docker relay timeout')
        request_id = secrets.token_urlsafe(18)
        event = threading.Event()
        pending = {'event': event}
        with self._lock:
            if self._closed is not None:
                raise ValueError('Docker relay is closed')
            self._pending[request_id] = pending
        frame = {'type': 'rpc', 'id': request_id, 'operation': operation,
                 'attempt_id': attempt_id, 'capability': capability, 'request': request}
        try:
            with self._send_lock:
                self._send_frame(frame)
            if not event.wait(timeout):
                raise TimeoutError('Docker broker response timed out')
            if 'error' in pending:
                raise ValueError('Docker relay response rejected') from pending['error']
            return pending['response']
        finally:
            with self._lock:
                self._pending.pop(request_id, None)

    def deliver(self, frame):
        if (not isinstance(frame, dict) or set(frame) != {'type', 'id', 'response'}
                or frame.get('type') != 'response' or not isinstance(frame.get('id'), str)
                or not isinstance(frame.get('response'), dict)):
            raise ValueError('invalid Docker relay response frame')
        with self._lock:
            pending = self._pending.get(frame['id'])
            if pending is None or pending['event'].is_set():
                raise ValueError('unknown or duplicate Docker relay response')
            pending['response'] = frame['response']
            pending['event'].set()

    def close(self, error=None):
        with self._lock:
            self._closed = error or ValueError('Docker relay closed')
            for pending in self._pending.values():
                pending['error'] = self._closed
                pending['event'].set()


def _socket_read_exact(connection, size):
    data = bytearray()
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            raise ValueError('truncated worker socket request')
        data.extend(chunk)
    return bytes(data)


def _socket_write_frame(connection, value, limit):
    payload = json.dumps(value, separators=(',', ':'), allow_nan=False).encode('utf-8')
    if not payload or len(payload) > limit:
        raise ValueError('worker socket response exceeded limit')
    connection.sendall(struct.pack('!I', len(payload)) + payload)


def serve_worker_connection(connection, relay, attempt_id, capability, *, timeout=310):
    """Serve one existing InferenceClient connection over the framed host relay."""
    try:
        connection.settimeout(timeout)
        size = struct.unpack('!I', _socket_read_exact(connection, 4))[0]
        if size < 1 or size > MAX_WORKER_REQUEST_BYTES:
            raise ValueError('worker socket request exceeded limit')
        envelope = json.loads(_socket_read_exact(connection, size).decode('utf-8'))
        response = relay.request(envelope, attempt_id, capability, timeout=timeout)
        _socket_write_frame(connection, response, MAX_WORKER_RESPONSE_BYTES)
    except (OSError, ValueError, TypeError, UnicodeDecodeError, TimeoutError):
        try:
            _socket_write_frame(connection, {'schema_version': 1, 'error': 'request rejected'}, 1024)
        except (OSError, ValueError):
            pass
    finally:
        connection.close()


def _serve_worker_socket(listener, relay, attempt_id, capability, stop):
    listener.settimeout(.1)
    threads = []
    while not stop.is_set():
        try:
            connection, _ = listener.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        thread = threading.Thread(target=serve_worker_connection,
                                  args=(connection, relay, attempt_id, capability), daemon=True)
        thread.start()
        threads.append(thread)
    for thread in threads:
        thread.join(timeout=.2)


def _pump_output(stream, name, write_lock, stdout):
    while True:
        chunk = stream.read(MAX_OUTPUT_CHUNK_BYTES)
        if not chunk:
            return
        frame = output_frame(name, chunk)
        with write_lock:
            write_frame(stdout, frame)


def run_guest(start, stdin, stdout):
    """Accept one trusted bootstrap frame and run one worker inside the container."""
    required = {'type', 'schema_version', 'attempt_id', 'capability', 'argv', 'worker_input'}
    if (not isinstance(start, dict) or set(start) != required
            or start.get('type') != 'start' or type(start.get('schema_version')) is not int
            or start['schema_version'] != 1
            or not isinstance(start.get('attempt_id'), str) or not start['attempt_id']
            or not isinstance(start.get('capability'), str) or not start['capability']
            or not isinstance(start.get('argv'), list) or not start['argv']
            or any(not isinstance(arg, str) or not arg for arg in start['argv'])
            or not isinstance(start.get('worker_input'), str)):
        raise ValueError('invalid Docker guest start frame')
    try:
        worker_input = base64.b64decode(start['worker_input'], validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ValueError('invalid Docker worker bootstrap') from exc
    if len(worker_input) > MAX_WORKER_REQUEST_BYTES:
        raise ValueError('Docker worker bootstrap exceeded limit')
    socket_path = Path('/tmp/fleet-board-inference.sock')
    if socket_path.exists() or socket_path.is_symlink():
        if not socket_path.is_socket():
            raise ValueError('Docker guest socket path is occupied')
        socket_path.unlink()
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(socket_path))
    socket_path.chmod(0o600)
    listener.listen(32)
    write_lock = threading.Lock()
    relay = RelayMultiplexer(lambda frame: write_frame_locked(stdout, frame, write_lock))
    relay_stop = threading.Event()

    def read_host_frames():
        try:
            while not relay_stop.is_set():
                frame = read_frame(stdin)
                relay.deliver(frame)
        except (OSError, ValueError):
            relay.close()

    reader = threading.Thread(target=read_host_frames, daemon=True)
    socket_server = threading.Thread(target=_serve_worker_socket,
                                     args=(listener, relay, start['attempt_id'],
                                           start['capability'], relay_stop), daemon=True)
    reader.start()
    socket_server.start()
    process = None
    pumps = []
    try:
        env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': '/nonexistent',
               'PYTHONPATH': '/guest',
               'FLEET_BOARD_CHANNEL_SOCKET': str(socket_path),
               'FLEET_BOARD_ATTEMPT_ID': start['attempt_id'],
               'FLEET_BOARD_CHANNEL_CAPABILITY': start['capability']}
        process = subprocess.Popen(start['argv'], cwd='/workspace', stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   close_fds=True, start_new_session=True, env=env)
        process.stdin.write(worker_input)
        process.stdin.close()
        for pipe, name in ((process.stdout, 'stdout'), (process.stderr, 'stderr')):
            thread = threading.Thread(target=_pump_output,
                                      args=(pipe, name, write_lock, stdout), daemon=True)
            thread.start()
            pumps.append(thread)
        code = process.wait()
        for thread in pumps:
            thread.join(timeout=1)
        with write_lock:
            write_frame(stdout, {'type': 'exit', 'code': int(code)})
        return int(code)
    finally:
        relay_stop.set()
        relay.close()
        try:
            listener.close()
        except OSError:
            pass
        socket_server.join(timeout=.5)
        reader.join(timeout=.1)
        try:
            socket_path.unlink()
        except OSError:
            pass
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=1)


def write_frame_locked(stream, frame, lock):
    with lock:
        write_frame(stream, frame)


def main():
    try:
        start = read_frame(sys.stdin.buffer)
        run_guest(start, sys.stdin.buffer, sys.stdout.buffer)
    except Exception as exc:
        try:
            write_frame(sys.stdout.buffer, {'type': 'fatal', 'message': str(exc)[:200]})
        except Exception:
            pass
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

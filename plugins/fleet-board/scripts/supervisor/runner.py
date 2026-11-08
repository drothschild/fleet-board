"""Detached, fixture-only attempt runner. Production execution is not enabled."""
import json
import errno
import math
import hashlib
import fcntl
import tempfile
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import threading
import time

from .processes import identity_for, inspect_identity
from .workers import ingest_artifacts


def _sync_directory(path):
    fd = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _read_regular(path, limit):
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > limit:
            raise ValueError('unsafe or oversized file')
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError('oversized file')
    return data


def _publish(path, value):
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        _sync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def prepared_from_store(store, attempt_id, scratch):
    snapshot = store.snapshot()
    matches = [item for item in snapshot['attempts'] if item['id'] == attempt_id and item['state'] in ('prepared', 'launching')]
    claims = [item for item in snapshot['claims'] if item['attempt_id'] == attempt_id]
    if len(matches) != 1 or len(claims) != 1:
        raise ValueError('attempt is not prepared with a claim')
    job = json.loads(matches[0]['data'])
    if job['nonce'] != attempt_id or matches[0]['job_id'] != job['id']:
        raise ValueError('inconsistent attempt binding')
    if (any(type(job.get(key)) not in (int, float) or not math.isfinite(job[key]) for key in ('started_at', 'deadline'))
            or job['started_at'] < 0 or job['deadline'] <= job['started_at']):
        raise ValueError('attempt timing is not durable')
    return {'domain_id': store.domain_id, 'job_id': job['id'], 'attempt_id': attempt_id,
            'nonce': job['nonce'], 'generation': job['generation'], 'input_sha': job['input_sha'],
            'role': job['role'], 'stage': job['stage'], 'session_id': job['session_id'],
            'scratch': str(Path(scratch)), 'started_at': job['started_at'], 'deadline': job['deadline']}


def read_result(attempt):
    attempt = Path(attempt)
    fields = ('domain_id', 'job_id', 'attempt_id', 'generation', 'input_sha', 'role', 'stage')
    expected = set(fields) | {'schema_version', 'outcome', 'report_path', 'artifact_hashes', 'usage', 'exit_code'}
    try:
        def load(name):
            return json.loads(_read_regular(attempt / name, 1048576))
        result, prepared = load('result.json'), load('prepared.json')
        if not isinstance(result, dict) or set(result) != expected or any(result.get(k) != prepared.get(k) for k in fields):
            return None
        if type(result['schema_version']) is not int or result['schema_version'] != 1 or type(result['generation']) is not int or result['outcome'] != 'success' or type(result['exit_code']) is not int or result['exit_code'] != 0 or result['usage'] is not None:
            return None
        report = Path(result['report_path'])
        artifacts = attempt.parent.parent / 'artifacts' / result['attempt_id']
        if report.parent != artifacts or report.name != 'report' or report.is_symlink() or artifacts.is_symlink() or artifacts.resolve(strict=True) != artifacts:
            return None
        data = _read_regular(report, 1048576)
        if len(data) > 1048576 or json.loads(data) != {'status': 'clean'}:
            return None
        if result['artifact_hashes'] != {str(report): hashlib.sha256(data).hexdigest()}:
            return None
        return result
    except (OSError, ValueError, TypeError, KeyError):
        return None


class Runner:
    def __init__(self, directory, *, fixture_command=None, fixture_finish_barrier=None, fixture_publication_barrier=None):
        self.directory = Path(directory)
        self.fixture_command = fixture_command
        self.fixture_finish_barrier = fixture_finish_barrier
        self.fixture_publication_barrier = fixture_publication_barrier

    def launch(self, prepared_attempt):
        if self.fixture_command is None:
            raise NotImplementedError('production worker isolation is unavailable')
        root = self.directory
        try:
            metadata = root.stat()
            if not root.is_absolute() or root.is_symlink() or root.resolve(strict=True) != root or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
                raise ValueError('unsafe runner root')
        except OSError as exc:
            raise ValueError('unsafe runner root') from exc
        attempt_id = prepared_attempt.get('attempt_id')
        nonce = prepared_attempt.get('nonce')
        if any(not isinstance(v, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', v) for v in (attempt_id, nonce)):
            raise ValueError('invalid attempt identity')
        binding_fields = {'domain_id', 'job_id', 'generation', 'input_sha', 'role', 'stage', 'session_id'}
        if binding_fields & set(prepared_attempt):
            required = binding_fields | {'attempt_id', 'nonce', 'scratch'}
            keys = set(prepared_attempt)
            if keys not in (required, required | {'started_at', 'deadline'}) or attempt_id != nonce:
                raise ValueError('incomplete attempt binding')
            if 'started_at' in prepared_attempt and (any(type(prepared_attempt[k]) not in (int, float) or not math.isfinite(prepared_attempt[k]) for k in ('started_at', 'deadline'))
                                                     or prepared_attempt['deadline'] <= prepared_attempt['started_at']):
                raise ValueError('invalid attempt timing')
            if any(not isinstance(prepared_attempt[k], str) or not prepared_attempt[k] for k in ('domain_id', 'job_id', 'input_sha', 'role', 'session_id', 'scratch')):
                raise ValueError('invalid attempt binding')
            if type(prepared_attempt['generation']) is not int or prepared_attempt['generation'] < 0 or (prepared_attempt['stage'] is not None and (not isinstance(prepared_attempt['stage'], str) or not prepared_attempt['stage'])):
                raise ValueError('invalid attempt binding')
            scratch = Path(prepared_attempt['scratch'])
            if not scratch.is_absolute() or scratch.is_symlink() or scratch.resolve(strict=True) != scratch:
                raise ValueError('unsafe scratch directory')
        config = json.dumps({'directory': str(self.directory), 'attempt_id': attempt_id,
                             'nonce': nonce, 'fixture_command': self.fixture_command, 'prepared': prepared_attempt,
                             'fixture_finish_barrier': str(self.fixture_finish_barrier) if self.fixture_finish_barrier else None,
                             'fixture_publication_barrier': str(self.fixture_publication_barrier) if self.fixture_publication_barrier else None})
        process = subprocess.Popen([sys.executable, '-m', 'supervisor.runner'],
                                env=dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parent.parent)),
                                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, close_fds=True, start_new_session=True)
        process.stdin.write(config.encode('utf-8'))
        process.stdin.close()
        return process

    def resume_publication(self, attempt_id, *, nonblocking=False):
        return _resume_publication(self.directory, attempt_id, nonblocking=nonblocking)

    def inspect(self, identity):
        root = self.directory / 'attempts'
        try:
            for attempt in root.iterdir():
                if attempt.is_symlink() or not attempt.is_dir():
                    continue
                try:
                    receipt = json.loads(_read_regular(attempt / 'receipt.json', 8192))
                    if receipt.get('identity') == identity.__dict__:
                        return inspect_identity(identity)
                except (OSError, ValueError, TypeError):
                    continue
        except (OSError, ValueError, TypeError):
            return 'unknown'
        return 'unknown'

    def cancel(self, identity, deadline):
        """Ask the trusted monitor to stop its owned group; caller must fence first."""
        if self.inspect(identity) != 'alive':
            return 'unknown'
        try:
            root = self.directory / 'attempts'
            for attempt in root.iterdir():
                if attempt.is_symlink() or not attempt.is_dir():
                    continue
                try:
                    receipt = json.loads(_read_regular(attempt / 'receipt.json', 8192))
                    if receipt.get('identity') != identity.__dict__:
                        continue
                    _publish(attempt / 'control.json', {'nonce': identity.nonce, 'signal': 'TERM'})
                    while time.monotonic() < deadline and self.inspect(identity) == 'alive':
                        time.sleep(.05)
                    if self.inspect(identity) == 'alive':
                        _publish(attempt / 'control.json', {'nonce': identity.nonce, 'signal': 'KILL'})
                    break
                except (OSError, ValueError, TypeError):
                    continue
        except OSError:
            pass
        return 'unknown'


def _resume_publication(directory, attempt_id, barrier=None, *, nonblocking=False):
    if not isinstance(attempt_id, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', attempt_id):
        raise ValueError('invalid attempt')
    attempt = Path(directory) / 'attempts' / attempt_id
    fd = os.open(str(attempt / 'publication.lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'r+b') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0))
        except BlockingIOError:
            return False
        existing = read_result(attempt)
        if existing is not None:
            return True
        if (attempt / 'result.json').exists():
            raise ValueError('invalid published result')
        def load(name):
            return json.loads(_read_regular(attempt / name, 65536))
        prepared = load('prepared.json')
        exit_info = load('exit.json')
        fields = ('domain_id', 'job_id', 'attempt_id', 'generation', 'input_sha', 'role', 'stage')
        if any(k not in prepared for k in fields) or prepared['attempt_id'] != attempt_id or exit_info != {'exit_code': 0}:
            raise ValueError('untrusted exit or attempt')
        artifacts_root = Path(directory) / 'artifacts'
        artifacts_root.mkdir(mode=0o700, exist_ok=True)
        _sync_directory(artifacts_root.parent)
        artifacts = artifacts_root / attempt_id
        manifest_path = artifacts / '.manifest.json'
        if not artifacts.exists():
            scratch = Path(prepared['scratch'])
            marker = json.loads(_read_regular(scratch / 'ready.json', 4096))
            if marker != {'exit_code': 0}:
                raise ValueError('invalid fixture result')
            ingest_artifacts(scratch, artifacts, ['report'])
        if not manifest_path.exists():
            raise ValueError('artifact manifest unavailable')
        hashes = json.loads(_read_regular(manifest_path, 65536))
        report = artifacts / 'report'
        if artifacts.is_symlink() or report.is_symlink() or artifacts.resolve(strict=True) != artifacts:
            raise ValueError('unsafe artifacts')
        data = _read_regular(report, 1048576)
        if json.loads(data) != {'status': 'clean'} or hashes != {'report': hashlib.sha256(data).hexdigest()}:
            raise ValueError('invalid fixture report')
        deadline = time.monotonic() + 10
        while barrier and not Path(barrier).exists() and time.monotonic() < deadline:
            time.sleep(.05)
        envelope = {field: prepared[field] for field in fields}
        envelope.update(schema_version=1, outcome='success', report_path=str(report),
                        artifact_hashes={str(report): hashes['report']}, usage=None, exit_code=0)
        _publish(attempt / 'result.json', envelope)
        return True


def _run(config):
    nonce_root = Path(config['directory']) / 'nonces'
    nonce_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    _sync_directory(nonce_root.parent)
    nonce_path = nonce_root / config['nonce']
    try:
        nonce_path.mkdir(mode=0o700)
    except FileExistsError:
        try:
            existing = json.loads(_read_regular(nonce_path / 'prepared.json', 65536))
            if existing == config['prepared']:
                return
        except (OSError, ValueError, TypeError):
            pass
        raise SystemExit(2)
    _sync_directory(nonce_root)
    _publish(nonce_path / 'prepared.json', config['prepared'])
    root = Path(config['directory']) / 'attempts'
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    _sync_directory(root.parent)
    attempt = root / config['attempt_id']
    try:
        attempt.mkdir(mode=0o700)
    except FileExistsError:
        try:
            existing = json.loads(_read_regular(attempt / 'prepared.json', 65536))
            if existing == config['prepared']:
                return
        except (OSError, ValueError, TypeError):
            pass
        raise SystemExit(2)
    _sync_directory(root)
    identity = identity_for(os.getpid(), config['nonce'])
    _publish(attempt / 'prepared.json', config['prepared'])
    _publish(attempt / 'receipt.json', {'state': 'registered', 'identity': identity.__dict__})
    supported = False
    if all(hasattr(os, name) for name in ('waitid', 'P_PID', 'WEXITED', 'WNOHANG', 'WNOWAIT')):
        try:
            os.waitid(os.P_PID, os.getpid(), os.WEXITED | os.WNOHANG | os.WNOWAIT)
        except OSError as exc:
            supported = exc.errno == errno.ECHILD
    if not supported:
        _publish(attempt / 'failure.json', {'kind': 'unsupported_child_observation'})
        return
    _publish(attempt / 'execution.json', {'state': 'execution_started'})
    worker = subprocess.Popen(config['fixture_command'], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, close_fds=True, start_new_session=True)
    def drain(pipe, name):
        fd = os.open(str(attempt / name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as output, pipe:
            remaining = 65536
            while True:
                chunk = pipe.read(8192)
                if not chunk:
                    break
                if remaining:
                    output.write(chunk[:remaining])
                    remaining -= min(remaining, len(chunk))
            output.flush()
            os.fsync(output.fileno())
    readers = [threading.Thread(target=drain, args=(pipe, name), daemon=True)
               for pipe, name in ((worker.stdout, 'stdout.log'), (worker.stderr, 'stderr.log'))]
    for reader in readers:
        reader.start()
    prepared = config['prepared']
    published = False
    progress_sequence = 0
    last_signal = None
    while True:
        # Keep the leader unreaped while descendants can hold inherited pipes.
        # Its allocated PID prevents a reused process-group ID from being signaled.
        exited = os.waitid(os.P_PID, worker.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
        if exited and not any(reader.is_alive() for reader in readers) and last_signal != 'TERM':
            break
        try:
            control = json.loads(_read_regular(attempt / 'control.json', 4096))
            if (control in ({'nonce': config['nonce'], 'signal': 'TERM'}, {'nonce': config['nonce'], 'signal': 'KILL'})
                    and control['signal'] != last_signal):
                try:
                    os.killpg(worker.pid, signal.SIGTERM if control['signal'] == 'TERM' else signal.SIGKILL)
                    last_signal = control['signal']
                except ProcessLookupError:
                    # The owned group is already empty; the unreaped leader
                    # still prevents a new group from reusing this identity.
                    last_signal = 'KILL'
                except PermissionError:
                    # macOS reports EPERM for a group containing only the
                    # exited, unreaped leader. Preserve occupancy uncertainty
                    # in failure.json before allowing the monitor to finish.
                    if control['signal'] == 'KILL' and exited and not any(reader.is_alive() for reader in readers):
                        _publish(attempt / 'failure.json', {'kind': 'process_group_signal_denied'})
                        last_signal = 'KILL'
        except (OSError, ValueError, TypeError):
            pass
        scratch = prepared.get('scratch')
        if scratch:
            try:
                raw = _read_regular(Path(scratch) / 'progress.json', 4096)
                progress = json.loads(raw)
                if (len(raw) <= 4096 and isinstance(progress, dict) and set(progress) == {'sequence', 'kind'}
                        and type(progress['sequence']) is int and progress['sequence'] > progress_sequence
                        and progress['kind'] in ('checkpoint', 'tool_completed', 'long_operation')):
                    progress['observed_at'] = time.time()
                    _publish(attempt / 'progress.json', progress)
                    progress_sequence = progress['sequence']
            except (OSError, ValueError, TypeError):
                pass
        _publish(attempt / 'heartbeat.json', {'at': time.time()})
        time.sleep(.2)
    for reader in readers:
        reader.join()
    worker.wait()
    if 'scratch' in prepared:
        _publish(attempt / 'exit.json', {'exit_code': worker.returncode})
        try:
            published = _resume_publication(Path(config['directory']), config['attempt_id'], config.get('fixture_publication_barrier'))
        except (OSError, ValueError, TypeError):
            published = False
    barrier = config.get('fixture_finish_barrier')
    deadline = time.monotonic() + 10
    while published and barrier and not Path(barrier).exists() and time.monotonic() < deadline:
        _publish(attempt / 'heartbeat.json', {'at': time.time()})
        time.sleep(.2)
    if published:
        _publish(attempt / 'completion.json', {'state': 'worker_exited', 'exit_code': worker.returncode})


if __name__ == '__main__':
    _run(json.load(sys.stdin))

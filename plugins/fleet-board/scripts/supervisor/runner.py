"""Detached, fixture-only attempt runner. Production execution is not enabled."""
import json
import os
from pathlib import Path
import re
import signal
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


def _publish(path, value):
    temporary = path.with_name(path.name + '.tmp')
    fd = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        json.dump(value, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    _sync_directory(path.parent)


def prepared_from_store(store, attempt_id, scratch):
    snapshot = store.snapshot()
    matches = [item for item in snapshot['attempts'] if item['id'] == attempt_id and item['state'] == 'prepared']
    claims = [item for item in snapshot['claims'] if item['attempt_id'] == attempt_id]
    if len(matches) != 1 or len(claims) != 1:
        raise ValueError('attempt is not prepared with a claim')
    job = json.loads(matches[0]['data'])
    if job['nonce'] != attempt_id or matches[0]['job_id'] != job['id']:
        raise ValueError('inconsistent attempt binding')
    return {'domain_id': store.domain_id, 'job_id': job['id'], 'attempt_id': attempt_id,
            'nonce': job['nonce'], 'generation': job['generation'], 'input_sha': job['input_sha'],
            'role': job['role'], 'stage': job['stage'], 'session_id': job['session_id'],
            'scratch': str(Path(scratch))}


def read_result(attempt):
    path = Path(attempt) / 'result.json'
    try:
        with path.open(encoding='utf-8') as stream:
            return json.load(stream)
    except FileNotFoundError:
        return None


class Runner:
    def __init__(self, directory, *, fixture_command=None, fixture_finish_barrier=None):
        self.directory = Path(directory)
        self.fixture_command = fixture_command
        self.fixture_finish_barrier = fixture_finish_barrier

    def launch(self, prepared_attempt):
        if self.fixture_command is None:
            raise NotImplementedError('production worker isolation is unavailable')
        attempt_id = prepared_attempt.get('attempt_id')
        nonce = prepared_attempt.get('nonce')
        if any(not isinstance(v, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', v) for v in (attempt_id, nonce)):
            raise ValueError('invalid attempt identity')
        config = json.dumps({'directory': str(self.directory.resolve()), 'attempt_id': attempt_id,
                             'nonce': nonce, 'fixture_command': self.fixture_command, 'prepared': prepared_attempt,
                             'fixture_finish_barrier': str(self.fixture_finish_barrier) if self.fixture_finish_barrier else None})
        process = subprocess.Popen([sys.executable, '-m', 'supervisor.runner'],
                                env=dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parent.parent)),
                                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, close_fds=True, start_new_session=True)
        process.stdin.write(config.encode('utf-8'))
        process.stdin.close()
        return process

    def inspect(self, identity):
        root = self.directory / 'attempts'
        try:
            for attempt in root.iterdir():
                if attempt.is_symlink() or not attempt.is_dir():
                    continue
                fd = os.open(str(attempt / 'receipt.json'), os.O_RDONLY | os.O_NOFOLLOW)
                with os.fdopen(fd, 'rb') as stream:
                    receipt = json.loads(stream.read(8193))
                if receipt.get('identity') == identity.__dict__:
                    return inspect_identity(identity)
        except (OSError, ValueError, TypeError):
            return 'unknown'
        return 'unknown'

    def cancel(self, identity, deadline):
        if self.inspect(identity) != 'alive':
            return 'unknown'
        try:
            if os.getpgid(identity.pid) != identity.pid:
                return 'unknown'
            os.killpg(identity.pid, signal.SIGTERM)
            while time.monotonic() < deadline and self.inspect(identity) == 'alive':
                time.sleep(.05)
            if self.inspect(identity) == 'alive' and os.getpgid(identity.pid) == identity.pid:
                os.killpg(identity.pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            pass
        return 'unknown'


def _run(config):
    root = Path(config['directory']) / 'attempts'
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    attempt = root / config['attempt_id']
    try:
        attempt.mkdir(mode=0o700)
    except FileExistsError:
        return
    _sync_directory(root)
    identity = identity_for(os.getpid(), config['nonce'])
    _publish(attempt / 'prepared.json', config['prepared'])
    _publish(attempt / 'receipt.json', {'state': 'registered', 'identity': identity.__dict__})
    _publish(attempt / 'execution.json', {'state': 'execution_started'})
    worker = subprocess.Popen(config['fixture_command'], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, close_fds=True)
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
    def publish_ready():
        fields = ('domain_id', 'job_id', 'attempt_id', 'generation', 'input_sha', 'role', 'stage')
        if any(field not in prepared for field in fields) or 'scratch' not in prepared:
            return False
        scratch = Path(prepared['scratch'])
        try:
            fd = os.open(str(scratch / 'ready.json'), os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, 'rb') as stream:
                data = stream.read(4097)
            marker = json.loads(data)
            if len(data) > 4096 or marker != {'exit_code': worker.returncode} or worker.returncode != 0:
                return False
            report_path = scratch / 'report'
            fd = os.open(str(report_path), os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, 'rb') as stream:
                report_data = stream.read(1048577)
            report_obj = json.loads(report_data)
            if len(report_data) > 1048576 or report_obj != {'status': 'clean'}:
                return False
        except (OSError, ValueError, TypeError):
            return False
        artifacts_root = Path(config['directory']) / 'artifacts'
        artifacts_root.mkdir(mode=0o700, exist_ok=True)
        hashes = ingest_artifacts(scratch, artifacts_root / config['attempt_id'], ['report'])
        report = str(artifacts_root / config['attempt_id'] / 'report')
        # Validate the immutable copy as well as the source.
        if json.loads(Path(report).read_bytes()) != {'status': 'clean'}:
            return False
        envelope = {field: prepared[field] for field in fields}
        envelope.update(schema_version=1, outcome='success', report_path=report,
                        artifact_hashes={report: hashes['report']}, usage=None, exit_code=0)
        _publish(attempt / 'result.json', envelope)
        return True
    while worker.poll() is None or any(reader.is_alive() for reader in readers):
        _publish(attempt / 'heartbeat.json', {'at': time.time()})
        time.sleep(.2)
    for reader in readers:
        reader.join()
    if not published:
        published = publish_ready()
    barrier = config.get('fixture_finish_barrier')
    deadline = time.monotonic() + 10
    while published and barrier and not Path(barrier).exists() and time.monotonic() < deadline:
        _publish(attempt / 'heartbeat.json', {'at': time.time()})
        time.sleep(.2)
    if published:
        _publish(attempt / 'completion.json', {'state': 'worker_exited', 'exit_code': worker.returncode})


if __name__ == '__main__':
    _run(json.load(sys.stdin))

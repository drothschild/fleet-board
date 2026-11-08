"""Detached, fixture-only attempt runner. Production execution is not enabled."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from .processes import identity_for, inspect_identity


def _sync_directory(path):
    fd = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _publish(path, value):
    temporary = path.with_name(path.name + '.tmp')
    with open(temporary, 'x', encoding='utf-8') as stream:
        json.dump(value, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    _sync_directory(path.parent)


def read_result(attempt):
    path = Path(attempt) / 'result.json'
    try:
        with path.open(encoding='utf-8') as stream:
            return json.load(stream)
    except FileNotFoundError:
        return None


class Runner:
    def __init__(self, directory, *, fixture_command=None):
        self.directory = Path(directory)
        self.fixture_command = fixture_command

    def launch(self, prepared_attempt):
        if self.fixture_command is None:
            raise NotImplementedError('production worker isolation is unavailable')
        attempt_id = prepared_attempt.get('attempt_id')
        nonce = prepared_attempt.get('nonce')
        if any(not isinstance(v, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', v) for v in (attempt_id, nonce)):
            raise ValueError('invalid attempt identity')
        config = json.dumps({'directory': str(self.directory.resolve()), 'attempt_id': attempt_id,
                             'nonce': nonce, 'fixture_command': self.fixture_command})
        return subprocess.Popen([sys.executable, '-m', 'supervisor.runner', config],
                                env=dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parent.parent)),
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, close_fds=True, start_new_session=True)

    def inspect(self, identity):
        return inspect_identity(identity)


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
    _publish(attempt / 'receipt.json', {'state': 'registered', 'identity': identity.__dict__})
    _publish(attempt / 'execution.json', {'state': 'execution_started'})
    subprocess.run(config['fixture_command'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, close_fds=True, check=False)


if __name__ == '__main__':
    _run(json.loads(sys.argv[1]))

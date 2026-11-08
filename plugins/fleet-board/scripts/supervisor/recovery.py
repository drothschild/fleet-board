"""Bounded recovery of durable attempts using independently supplied evidence."""
import json
import math
import os
import signal

from .processes import ProcessIdentity
from .runner import Runner, _read_regular, read_result


class NativeInspector:
    """Read the runner's durable evidence; absence is never proof of termination."""
    def __init__(self, directory, domain_id):
        self.domain_id = domain_id
        self.runner = Runner(directory)
        self.directory = directory

    def inspect(self, attempt):
        path = self.directory / 'attempts' / attempt['id']
        if path.is_symlink() or not path.is_dir():
            return {'status': 'unknown'}
        try:
            original = json.loads(attempt['data'])
            prepared = json.loads(_read_regular(path / 'prepared.json', 65536))
            if prepared.get('domain_id') != self.domain_id:
                return {'status': 'unknown'}
            for field in ('job_id', 'attempt_id', 'nonce', 'generation', 'input_sha', 'role', 'stage', 'session_id'):
                expected = attempt['job_id'] if field == 'job_id' else attempt['id'] if field == 'attempt_id' else original[field]
                if prepared.get(field) != expected:
                    return {'status': 'unknown'}
            result = read_result(path)
            if result is None:
                try:
                    self.runner.resume_publication(attempt['id'], nonblocking=True)
                except (OSError, ValueError, TypeError):
                    pass
                result = read_result(path)
            receipt = json.loads(_read_regular(path / 'receipt.json', 8192))
            identity = ProcessIdentity(**receipt['identity'])
            if identity.nonce != attempt['nonce']:
                return {'status': 'unknown'}
            return {'status': self.runner.inspect(identity), 'result': result, 'identity': identity}
        except (OSError, ValueError, TypeError, KeyError):
            return {'status': 'unknown'}

    def signal(self, attempt, kind):
        observation = self.inspect(attempt)
        identity = observation.get('identity')
        if observation.get('status') != 'alive' or identity is None or kind not in ('TERM', 'KILL'):
            return 'unknown'
        try:
            if os.getpgid(identity.pid) != identity.pid or self.runner.inspect(identity) != 'alive':
                return 'unknown'
            os.killpg(identity.pid, signal.SIGTERM if kind == 'TERM' else signal.SIGKILL)
        except OSError:
            return 'unknown'
        return 'sent'


class Recovery:
    def __init__(self, store, inspector=None, settings=None):
        self.store = store
        self.inspector = inspector if inspector is not None else NativeInspector(store.directory, store.domain_id)
        self.settings = {'shutdown_grace_seconds': 30, 'heartbeat_timeout_seconds': 60,
                         'progress_timeout_seconds': 900, 'attempt_timeout_seconds': 7200,
                         'retry_backoff_seconds': 60}
        if settings:
            if not set(settings) <= set(self.settings) or any(type(v) not in (int, float) or not math.isfinite(v) or v <= 0 for v in settings.values()):
                raise ValueError('invalid recovery settings')
            self.settings.update(settings)

    def reconcile(self, now):
        snapshot = self.store.snapshot()
        for attempt in snapshot['attempts']:
            if attempt['state'] not in ('prepared', 'launching', 'running', 'result_ready', 'cancel_requested', 'interrupted', 'failed', 'quarantined'):
                continue
            try:
                observation = self.inspector.inspect(attempt)
            except (OSError, ValueError):
                observation = {'status': 'unknown'}
            result = observation.get('result')
            if result is not None:
                self.store.record_result(result)
                attempt = next(x for x in self.store.snapshot()['attempts'] if x['id'] == attempt['id'])
            data = json.loads(attempt['data'])
            if attempt['state'] in ('prepared', 'launching', 'running', 'result_ready'):
                deadline = data.get('deadline')
                if observation.get('status') == 'alive' and type(deadline) in (int, float) and math.isfinite(deadline) and now >= deadline:
                    revision = self.store.snapshot()['domain']['revision']
                    self.store.request_cancellation(attempt['id'], 'deadline-' + attempt['id'], 'deadline', revision,
                                                    now=now, grace_seconds=self.settings['shutdown_grace_seconds'])
                    attempt = next(x for x in self.store.snapshot()['attempts'] if x['id'] == attempt['id'])
                    data = json.loads(attempt['data'])
                elif observation.get('status') == 'unknown' and attempt['state'] in ('prepared', 'launching', 'running'):
                    revision = self.store.snapshot()['domain']['revision']
                    self.store.quarantine_attempt(attempt['id'], 'identity_uncertain', revision)
                    continue
            if attempt['state'] == 'cancel_requested':
                if observation.get('status') == 'unknown':
                    revision = self.store.snapshot()['domain']['revision']
                    self.store.quarantine_attempt(attempt['id'], 'termination_uncertain', revision)
                elif observation.get('status') == 'alive':
                    deadline = data.get('cancel_grace_deadline')
                    if type(deadline) in (int, float) and math.isfinite(deadline):
                        self.inspector.signal(attempt, 'KILL' if now >= deadline else 'TERM')

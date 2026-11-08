"""Bounded recovery of durable attempts using independently supplied evidence."""
import json

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
                    self.runner.resume_publication(attempt['id'])
                except (OSError, ValueError, TypeError):
                    pass
                result = read_result(path)
            if result is not None:
                return {'status': 'result', 'result': result}
            receipt = json.loads(_read_regular(path / 'receipt.json', 8192))
            identity = ProcessIdentity(**receipt['identity'])
            if identity.nonce != attempt['nonce']:
                return {'status': 'unknown'}
            return {'status': self.runner.inspect(identity)}
        except (OSError, ValueError, TypeError, KeyError):
            return {'status': 'unknown'}


class Recovery:
    def __init__(self, store, inspector=None):
        self.store = store
        self.inspector = inspector if inspector is not None else NativeInspector(store.directory, store.domain_id)

    def reconcile(self, now):
        snapshot = self.store.snapshot()
        for attempt in snapshot['attempts']:
            if attempt['state'] not in ('prepared', 'launching', 'running', 'result_ready'):
                continue
            try:
                observation = self.inspector.inspect(attempt)
            except (OSError, ValueError):
                observation = {'status': 'unknown'}
            if observation.get('status') == 'result':
                self.store.record_result(observation['result'])
            elif observation.get('status') == 'unknown' and attempt['state'] != 'result_ready':
                revision = self.store.snapshot()['domain']['revision']
                self.store.update_attempt(attempt['id'], {'state': 'quarantined'}, revision)

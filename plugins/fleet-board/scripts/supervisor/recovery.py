"""Bounded recovery of durable attempts using independently supplied evidence."""
import json
import math

from . import processes
from .models import StopEvidence
from .processes import ProcessIdentity
from .runner import Runner, _publish, _read_regular, read_result


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
            published = path / 'result.json'
            if result is None and (published.exists() or published.is_symlink()):
                result = read_result(path)
                if result is None:
                    return {'status': 'invalid_result'}
            try:
                receipt = json.loads(_read_regular(path / 'receipt.json', 8192))
                identity = ProcessIdentity(**receipt['identity'])
                if (identity.nonce != attempt['nonce'] or ('boot_id' in original and original['boot_id'] != identity.boot_id)
                        or ('process_identity' in original and original['process_identity'] != identity.__dict__)):
                    raise ValueError('receipt identity mismatch')
                boot = processes._boot_id()
                if (boot != identity.boot_id and original.get('boot_id') == identity.boot_id
                        and original.get('process_identity') == identity.__dict__):
                    proof = StopEvidence(domain_id=self.domain_id, job_id=attempt['job_id'], attempt_id=attempt['id'],
                                         generation=original['generation'], boot_id=identity.boot_id, pid=identity.pid,
                                         started_at=identity.started_at, nonce=identity.nonce,
                                         kind='boot_changed', current_boot_id=boot)
                    return {'status': 'stopped', 'result': result, 'stop_evidence': proof}
                observation = {'status': self.runner.inspect(identity), 'result': result, 'identity': identity}
                if observation['status'] == 'alive':
                    for name in ('heartbeat', 'progress'):
                        try:
                            observation[name] = json.loads(_read_regular(path / (name + '.json'), 4096))
                        except (OSError, ValueError, TypeError):
                            pass
                return observation
            except (OSError, ValueError, TypeError, KeyError):
                return {'status': 'unknown', 'result': result}
        except (OSError, ValueError, TypeError, KeyError):
            return {'status': 'unknown'}

    def signal(self, attempt, kind):
        observation = self.inspect(attempt)
        identity = observation.get('identity')
        if observation.get('status') != 'alive' or identity is None or kind not in ('TERM', 'KILL'):
            return 'unknown'
        try:
            path = self.directory / 'attempts' / attempt['id'] / 'control.json'
            _publish(path, {'nonce': identity.nonce, 'signal': kind})
        except (OSError, ValueError):
            return 'unknown'
        return 'sent'


class Recovery:
    def __init__(self, store, inspector=None, settings=None, retry_limits=None, retry_launcher=None, max_attempts=64):
        if type(max_attempts) is not int or max_attempts < 1:
            raise ValueError('invalid recovery batch size')
        self.max_attempts = max_attempts
        self._attempt_cursor = 0
        self._retry_cursor = 0
        self.store = store
        self.inspector = inspector if inspector is not None else NativeInspector(store.directory, store.domain_id)
        self.retry_limits = retry_limits
        self.retry_launcher = retry_launcher
        self.settings = {'shutdown_grace_seconds': 30, 'heartbeat_timeout_seconds': 60,
                         'progress_timeout_seconds': 900, 'attempt_timeout_seconds': 7200,
                         'retry_backoff_seconds': 60}
        if settings:
            if not set(settings) <= set(self.settings) or any(type(v) not in (int, float) or not math.isfinite(v) or v <= 0 for v in settings.values()):
                raise ValueError('invalid recovery settings')
            self.settings.update(settings)

    def _batch(self, items, cursor_name):
        if not items:
            return []
        start = getattr(self, cursor_name) % len(items)
        count = min(len(items), self.max_attempts)
        batch = [items[(start + offset) % len(items)] for offset in range(count)]
        setattr(self, cursor_name, (start + count) % len(items))
        return batch

    def reconcile(self, now):
        snapshot = self.store.snapshot()
        for attempt in self._batch(snapshot['attempts'], '_attempt_cursor'):
            if attempt['state'] not in ('prepared', 'launching', 'running', 'result_ready', 'cancel_requested', 'interrupted', 'failed', 'quarantined'):
                continue
            try:
                observation = self.inspector.inspect(attempt)
            except (OSError, ValueError):
                observation = {'status': 'unknown'}
            if (observation.get('status') == 'never_started' and attempt['state'] == 'prepared'
                    and self.retry_launcher is not None and self.retry_limits is not None):
                try:
                    launch_input = self.retry_launcher.prepare(self.store, attempt['id'])
                    self.store.begin_recovered_launch(attempt['id'], observation.get('launch_evidence'), now=now,
                                                      limits=self.retry_limits, expected_revision=self.store.snapshot()['domain']['revision'])
                except (OSError, ValueError):
                    continue
                try:
                    self.retry_launcher.launch(launch_input)
                except Exception:
                    self.store.quarantine_attempt(attempt['id'], 'recovered_launch_uncertain', self.store.snapshot()['domain']['revision'])
                continue
            if observation.get('status') == 'invalid_result':
                if attempt['state'] in ('prepared', 'launching', 'running', 'result_ready', 'cancel_requested'):
                    self.store.quarantine_attempt(attempt['id'], 'invalid_result', self.store.snapshot()['domain']['revision'])
                continue
            result = observation.get('result')
            if result is not None:
                try:
                    self.store.record_result(result)
                except ValueError:
                    if attempt['state'] in ('prepared', 'launching', 'running', 'result_ready', 'cancel_requested'):
                        self.store.quarantine_attempt(attempt['id'], 'invalid_result', self.store.snapshot()['domain']['revision'])
                    continue
                attempt = next(x for x in self.store.snapshot()['attempts'] if x['id'] == attempt['id'])
            data = json.loads(attempt['data'])
            if attempt['state'] == 'result_ready' and observation.get('status') == 'stopped':
                try:
                    self.store.record_execution_stopped(attempt['id'], observation.get('stop_evidence'),
                                                        self.store.snapshot()['domain']['revision'])
                except ValueError:
                    self.store.quarantine_attempt(attempt['id'], 'termination_uncertain', self.store.snapshot()['domain']['revision'])
                continue
            if observation.get('status') == 'alive' and attempt['state'] in ('prepared', 'launching', 'running', 'result_ready'):
                updates = {}
                identity = observation.get('identity')
                if isinstance(identity, ProcessIdentity) and 'process_identity' not in data and 'boot_id' not in data:
                    updates.update({'boot_id': identity.boot_id, 'process_identity': identity.__dict__})
                heartbeat = observation.get('heartbeat')
                if isinstance(heartbeat, dict):
                    at = heartbeat.get('at')
                    previous_heartbeat = data.get('heartbeat')
                    if type(previous_heartbeat) not in (int, float) or not math.isfinite(previous_heartbeat):
                        previous_heartbeat = -1
                    if type(at) in (int, float) and math.isfinite(at) and 0 <= at <= now and at > previous_heartbeat:
                        updates['heartbeat'] = at
                progress = observation.get('progress')
                if isinstance(progress, dict):
                    at, sequence, kind = progress.get('observed_at'), progress.get('sequence'), progress.get('kind')
                    previous = data.get('progress')
                    previous_sequence = previous.get('sequence', 0) if isinstance(previous, dict) else 0
                    if type(previous_sequence) is not int or previous_sequence < 0:
                        previous_sequence = 0
                    if (type(at) in (int, float) and math.isfinite(at) and 0 <= at <= now
                            and type(sequence) is int and sequence > previous_sequence
                            and kind in ('checkpoint', 'tool_completed', 'long_operation')):
                        updates['progress'] = {'at': at, 'sequence': sequence, 'kind': kind}
                if updates:
                    self.store.update_attempt(attempt['id'], updates, self.store.snapshot()['domain']['revision'])
                    data.update(updates)
            if attempt['state'] in ('prepared', 'launching', 'running', 'result_ready'):
                deadline = data.get('deadline')
                boot_interruption = observation.get('status') == 'stopped' and result is None and observation.get('stop_evidence') is not None
                deadline_elapsed = observation.get('status') == 'alive' and type(deadline) in (int, float) and math.isfinite(deadline) and now >= deadline
                if boot_interruption or deadline_elapsed:
                    revision = self.store.snapshot()['domain']['revision']
                    reason = 'infrastructure' if boot_interruption else 'deadline'
                    self.store.request_cancellation(attempt['id'], reason + '-' + attempt['id'], reason, revision,
                                                    now=now, grace_seconds=self.settings['shutdown_grace_seconds'])
                    attempt = next(x for x in self.store.snapshot()['attempts'] if x['id'] == attempt['id'])
                    data = json.loads(attempt['data'])
                elif observation.get('status') == 'alive' and attempt['state'] in ('running', 'result_ready'):
                    progress = data.get('progress')
                    progress_at = progress.get('at') if isinstance(progress, dict) else progress
                    if type(progress_at) not in (int, float) or not math.isfinite(progress_at):
                        progress_at = data.get('started_at')
                    heartbeat = data.get('heartbeat')
                    stale_progress = type(progress_at) in (int, float) and math.isfinite(progress_at) and now - progress_at >= self.settings['progress_timeout_seconds']
                    stale_heartbeat = type(heartbeat) in (int, float) and math.isfinite(heartbeat) and now - heartbeat >= self.settings['heartbeat_timeout_seconds']
                    tool_until = observation.get('bounded_tool_until')
                    bounded_tool = (observation.get('activity') == 'bounded_tool' and type(tool_until) in (int, float)
                                    and math.isfinite(tool_until) and type(deadline) in (int, float)
                                    and now < tool_until <= deadline)
                    suspected = stale_heartbeat or (stale_progress and not bounded_tool)
                    if suspected != bool(data.get('suspected_stuck', False)):
                        self.store.update_attempt(attempt['id'], {'suspected_stuck': suspected}, self.store.snapshot()['domain']['revision'])
                    if suspected and observation.get('activity') == 'confirmed_stall':
                        revision = self.store.snapshot()['domain']['revision']
                        self.store.request_cancellation(attempt['id'], 'stall-' + attempt['id'], 'unexplained_stall', revision,
                                                        now=now, grace_seconds=self.settings['shutdown_grace_seconds'])
                        attempt = next(x for x in self.store.snapshot()['attempts'] if x['id'] == attempt['id'])
                        data = json.loads(attempt['data'])
                elif observation.get('status') == 'unknown' and attempt['state'] in ('prepared', 'launching', 'running'):
                    revision = self.store.snapshot()['domain']['revision']
                    self.store.quarantine_attempt(attempt['id'], 'identity_uncertain', revision)
                    continue
            if attempt['state'] == 'cancel_requested':
                if observation.get('status') == 'stopped':
                    try:
                        revision = self.store.snapshot()['domain']['revision']
                        self.store.record_execution_stopped(attempt['id'], observation.get('stop_evidence'), revision)
                        current = self.store.snapshot()
                        job = next(x for x in current['jobs'] if x['id'] == attempt['job_id'])
                        if data.get('cancel_reason') == 'infrastructure' and job['state'] == 'active':
                            self.store.schedule_retry(job['id'], attempt['id'], observation.get('retry_evidence'),
                                                      retry_at=now + self.settings['retry_backoff_seconds'],
                                                      expected_revision=current['domain']['revision'])
                    except ValueError:
                        current = self.store.snapshot()
                        self.store.quarantine_attempt(attempt['id'], 'stop_or_retry_uncertain', current['domain']['revision'])
                elif observation.get('status') == 'unknown':
                    revision = self.store.snapshot()['domain']['revision']
                    self.store.quarantine_attempt(attempt['id'], 'termination_uncertain', revision)
                elif observation.get('status') == 'alive':
                    deadline = data.get('cancel_grace_deadline')
                    if type(deadline) in (int, float) and math.isfinite(deadline):
                        self.inspector.signal(attempt, 'KILL' if now >= deadline else 'TERM')

        if self.retry_limits is not None:
            current = self.store.snapshot()
            for job in self._batch([item for item in current['jobs'] if item['state'] == 'retry_wait'], '_retry_cursor'):
                if job['state'] != 'retry_wait':
                    continue
                job_data = json.loads(job['data'])
                if now < job_data['retry_at']:
                    continue
                prior = next((item for item in current['attempts'] if item['id'] == job_data['retry_prior']), None)
                if prior is None:
                    continue
                try:
                    evidence = self.inspector.inspect(prior).get('retry_evidence')
                    if evidence is not None:
                        prepared = self.store.prepare_retry(job['id'], evidence, now=now, limits=self.retry_limits,
                                                            expected_revision=self.store.snapshot()['domain']['revision'])
                        if self.retry_launcher is not None:
                            attempt_id = prepared['attempt_id']
                            launch_input = self.retry_launcher.prepare(self.store, attempt_id)
                            self.store.update_attempt(attempt_id, {'state': 'launching'}, self.store.snapshot()['domain']['revision'])
                            try:
                                self.retry_launcher.launch(launch_input)
                            except Exception:
                                self.store.quarantine_attempt(attempt_id, 'retry_launch_uncertain', self.store.snapshot()['domain']['revision'])
                except (ValueError, OSError):
                    # Admission remains held until fresh trusted evidence and limits permit it.
                    continue

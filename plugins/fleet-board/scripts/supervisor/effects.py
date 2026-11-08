"""Journal and reconcile controller-owned effects.

An external system cannot participate in the Store's SQLite transaction. The
controller records intent before mutation and observations afterward. An
uncertain non-idempotent outcome is fenced for human attention; exactly-once
delivery cannot be promised.
"""
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

from .models import canonical_json

_KINDS = {
    'worktree_prepare', 'branch_refresh', 'commit_publication', 'pr_create',
    'pr_update', 'report_post', 'note_update', 'card_move', 'followup_file', 'cleanup',
}
_NON_IDEMPOTENT = {'branch_refresh', 'commit_publication', 'pr_create', 'report_post', 'followup_file'}
_OPERATION_KEY = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$')
_CARD = re.compile(r'^[1-9][0-9]*$')
_BRANCH = re.compile(r'^fleet/[1-9][0-9]*-[a-z0-9][a-z0-9-]*$')
_STATE = re.compile(r'^(?:backlog|ready|in_progress|in_review|human_qa|blocked|done|wont_do|review_[a-z][a-z0-9_]*)$')


def _observation(value):
    if not isinstance(value, dict) or not value:
        raise ValueError('invalid effect observation')
    if len(canonical_json(value).encode('utf-8')) > 65536:
        raise ValueError('oversized effect observation')
    return value


class Effect:
    """Execute one journaled effect through an adapter and authority callback.

    The adapter supplies inspect(intent) and apply(intent). The authority
    callback returns (allowed, reason) after a fresh card/head/approval read.
    """
    def __init__(self, store, adapter, authority):
        if store is None or adapter is None or not callable(authority):
            raise ValueError('effect requires store, adapter, and authority checker')
        if not callable(getattr(adapter, 'inspect', None)) or not callable(getattr(adapter, 'apply', None)):
            raise ValueError('invalid effect adapter')
        self.store, self.adapter, self.authority = store, adapter, authority
        self._key = None
        self._faults = set()

    def prepare(self, key, preconditions, intent):
        if not isinstance(key, str) or not _OPERATION_KEY.fullmatch(key):
            raise ValueError('invalid controller operation key')
        if not isinstance(preconditions, dict) or not isinstance(intent, dict) or intent.get('kind') not in _KINDS:
            raise ValueError('invalid effect intent')
        canonical_json(preconditions)
        canonical_json(intent)
        card, generation = preconditions.get('card'), preconditions.get('generation')
        if not isinstance(card, str) or not _CARD.fullmatch(card) or type(generation) is not int or generation < 1:
            raise ValueError('effect requires card and generation preconditions')
        if 'operation_key' in intent and intent['operation_key'] != key:
            raise ValueError('intent operation key conflicts with controller key')
        jobs = [job for job in self.store.snapshot()['jobs']
                if job['card'] == card and job['generation'] == generation]
        if len(jobs) != 1:
            raise ValueError('effect must name one current job generation')
        self.store.record_effect({'operation_key': key, 'job_id': jobs[0]['id'],
                                  'generation': generation, 'preconditions': preconditions,
                                  'intent': intent})
        self._key = key
        return key

    def inject_failure(self, point):
        """Inject deterministic boundary faults for offline contract cases."""
        allowed = {'before_mutation', 'after_mutation', 'before_observation_commit'}
        if point not in allowed:
            raise ValueError('unknown effect failure point')
        self._faults.add(point)

    def _record(self):
        if self._key is None:
            raise ValueError('effect is not prepared')
        rows = [row for row in self.store.snapshot()['effects'] if row['operation_key'] == self._key]
        if len(rows) != 1:
            raise ValueError('effect journal record is missing')
        row = rows[0]
        return row, json.loads(row['preconditions']), json.loads(row['intent'])

    def _attention_reason(self):
        for event in self.store.snapshot()['events']:
            if event['type'] == 'effect_attention' and event['payload'].get('operation_key') == self._key:
                return event['payload'].get('reason', 'unresolved external effect')
        return None

    def _attention(self, reason):
        message = str(reason).replace('\n', ' ')[:300]
        if self._attention_reason() is None:
            self.store.append_event({'type': 'effect_attention',
                                     'payload': {'operation_key': self._key, 'reason': message}})
        return {'status': 'attention', 'operation_key': self._key, 'reason': message}

    def _validate_authority(self, row, preconditions, intent):
        jobs = [job for job in self.store.snapshot()['jobs'] if job['id'] == row['job_id']]
        if len(jobs) != 1 or jobs[0]['generation'] != row['generation']:
            return False, 'stale generation'
        try:
            result = self.authority(jobs[0], preconditions, intent)
        except Exception as exc:
            return False, 'authority unavailable: ' + str(exc)
        if not isinstance(result, tuple) or len(result) != 2 or type(result[0]) is not bool:
            return False, 'authority returned invalid result'
        return result

    def _save_observation(self, value, intent):
        observation = dict(_observation(value))
        if 'operation_key' in observation and observation['operation_key'] != self._key:
            raise ValueError('observation operation key does not match controller key')
        if intent['kind'] == 'branch_refresh':
            revision = observation.get('input_revision')
            evidence = observation.get('input_evidence')
            if not isinstance(evidence, dict) or set(evidence) != {
                    'job_id', 'generation', 'head_sha', 'input_sha', 'changed_paths'}:
                raise ValueError('branch refresh lacks validated input evidence')
            job_id = self._record()[0]['job_id']
            attempts = [attempt for attempt in self.store.snapshot()['attempts']
                        if attempt['job_id'] == job_id]
            if not attempts:
                raise ValueError('branch refresh job disappeared')
            generation = self._record()[0]['generation']
            if (evidence['job_id'] != job_id or evidence['generation'] != generation
                    or not isinstance(evidence['head_sha'], str)
                    or not re.fullmatch(r'[0-9a-f]{40}(?:[0-9a-f]{24})?', evidence['head_sha'])
                    or not isinstance(evidence['input_sha'], str)
                    or not re.fullmatch(r'[0-9a-f]{64}', evidence['input_sha'])):
                raise ValueError('branch refresh evidence identity is invalid')
            paths = evidence['changed_paths']
            if (not isinstance(paths, list) or any(not isinstance(path, str) or not path
                    or path.startswith('/') or any(part in ('', '.', '..') for part in path.split('/'))
                    for path in paths) or paths != sorted(set(paths))):
                raise ValueError('branch refresh changed paths are invalid')
            if paths != sorted(set(intent.get('changed_paths', []))):
                raise ValueError('branch refresh paths do not match the validated intent')
            expected_revision = hashlib.sha256(canonical_json(evidence).encode('utf-8')).hexdigest()
            if revision != expected_revision:
                raise ValueError('branch refresh revision does not match validated evidence')
            prior = json.loads(attempts[0]['data']).get('input_version')
            if paths and revision == prior:
                raise ValueError('branch refresh did not produce a new input revision')
            affected = observation.get('invalidated_evidence')
            if affected is None:
                affected = ['review', 'test'] if paths else []
            if not isinstance(affected, list) or any(item not in ('review', 'test') for item in affected):
                raise ValueError('invalid branch refresh evidence invalidation')
            observation['invalidated_evidence'] = sorted(set(affected))
        if 'before_observation_commit' in self._faults:
            self._faults.remove('before_observation_commit')
            raise OSError('injected before observation commit')
        snapshot = self.store.snapshot()
        self.store.observe_effect(self._key, observation, snapshot['domain']['revision'])
        result = {**observation, 'status': 'observed', 'operation_key': self._key}
        if observation.get('input_revision') is not None:
            result['input_revision'] = observation['input_revision']
            invalidated = observation.get('invalidated_evidence')
            if invalidated is None and intent['kind'] == 'branch_refresh':
                invalidated = ['review', 'test']
            result['invalidated_evidence'] = sorted(set(invalidated or []))
        return result

    def observe(self):
        """Read external state without issuing a mutation."""
        _, _, intent = self._record()
        result = self.adapter.inspect(dict(intent, operation_key=self._key))
        return None if result is None else _observation(result)

    def apply(self):
        row, preconditions, intent = self._record()
        if row['observation'] is not None:
            return {**json.loads(row['observation']), 'status': 'observed',
                    'operation_key': self._key}
        attention = self._attention_reason()
        if attention is not None:
            return {'status': 'attention', 'operation_key': self._key, 'reason': attention}
        allowed, reason = self._validate_authority(row, preconditions, intent)
        if not allowed:
            return self._attention(reason or 'effect authority denied')
        try:
            existing = self.observe()
        except Exception as exc:
            return {'status': 'pending', 'operation_key': self._key,
                    'reason': 'fresh inspection failed: ' + str(exc)[:240]}
        if existing is not None:
            if intent['kind'] in _NON_IDEMPOTENT and existing.get('operation_key') != self._key:
                return self._attention('ambiguous non-idempotent existing result')
            try:
                return self._save_observation(existing, intent)
            except Exception as exc:
                return {'status': 'pending', 'operation_key': self._key,
                        'reason': 'observation persistence failed: ' + str(exc)[:240]}
        # Inspection can take time; re-read generation and card authority just
        # before crossing the external mutation boundary.
        allowed, reason = self._validate_authority(row, preconditions, intent)
        if not allowed:
            return self._attention(reason or 'effect authority denied')
        if 'before_mutation' in self._faults:
            self._faults.remove('before_mutation')
            return {'status': 'pending', 'operation_key': self._key, 'reason': 'injected before mutation'}
        routed_intent = dict(intent, operation_key=self._key)
        target_state = intent.get('state') if intent['kind'] == 'card_move' else None
        if target_state == 'in_review' or (isinstance(target_state, str) and target_state.startswith('review_')):
            route = getattr(self.adapter, 'route_review', None)
            if not callable(route):
                return {'status': 'attention', 'operation_key': self._key,
                        'reason': 'review move requires review-stage routing adapter'}
            try:
                route(routed_intent)
            except Exception as exc:
                return {'status': 'pending', 'operation_key': self._key,
                        'reason': 'review-stage routing failed; card move was not attempted: ' + str(exc)[:240]}
            allowed, reason = self._validate_authority(row, preconditions, intent)
            if not allowed:
                return self._attention(reason or 'review move authority denied after routing')
            routed_intent['review_route_completed'] = True
        try:
            response = self.adapter.apply(routed_intent)
        except Exception as exc:
            if intent['kind'] in _NON_IDEMPOTENT:
                return self._attention('uncertain ' + intent['kind'] + ': ' + str(exc))
            return {'status': 'pending', 'operation_key': self._key,
                    'reason': 'adapter outcome requires fresh reconciliation'}
        if not isinstance(response, dict):
            return self._attention('adapter returned invalid observation')
        if 'after_mutation' in self._faults:
            self._faults.remove('after_mutation')
            if intent['kind'] in _NON_IDEMPOTENT:
                return self._attention('uncertain ' + intent['kind'] + ' after mutation')
            return {'status': 'pending', 'operation_key': self._key, 'reason': 'response lost after mutation'}
        try:
            return self._save_observation(response, intent)
        except Exception as exc:
            return {'status': 'pending', 'operation_key': self._key,
                    'reason': 'observation persistence failed: ' + str(exc)[:240]}

    def reconcile(self):
        row, preconditions, intent = self._record()
        if row['observation'] is not None:
            return {**json.loads(row['observation']), 'status': 'observed',
                    'operation_key': self._key}
        attention = self._attention_reason()
        if attention is not None:
            return {'status': 'attention', 'operation_key': self._key, 'reason': attention}
        allowed, reason = self._validate_authority(row, preconditions, intent)
        if not allowed:
            return self._attention(reason or 'effect authority denied during reconciliation')
        try:
            observed = self.observe()
        except Exception as exc:
            return {'status': 'pending', 'operation_key': self._key,
                    'reason': 'observation unavailable: ' + str(exc)[:240]}
        if observed is not None:
            if intent['kind'] in _NON_IDEMPOTENT and observed.get('operation_key') != self._key:
                return self._attention('ambiguous non-idempotent outcome')
            try:
                return self._save_observation(observed, intent)
            except Exception as exc:
                return {'status': 'pending', 'operation_key': self._key,
                        'reason': 'observation persistence failed: ' + str(exc)[:240]}
        if intent['kind'] in _NON_IDEMPOTENT:
            return self._attention('non-idempotent outcome cannot be proven')
        return {'status': 'ready', 'operation_key': self._key,
                'reason': 'fresh inspection found no applied effect'}


class BoundedScriptAdapter:
    """Allowlisted bridge to existing helpers; observer must be read-only.

    Commands use argument vectors with no shell, fixed executable choices,
    bounded deadlines/output, and never write board storage directly.
    """
    def __init__(self, plugin_root, observer, *, runner=None, timeout=30, output_limit=65536):
        if not callable(observer) or type(timeout) is not int or timeout < 1:
            raise ValueError('invalid script adapter configuration')
        if type(output_limit) is not int or output_limit < 1:
            raise ValueError('invalid output limit')
        self.plugin_root = Path(plugin_root).resolve()
        self.scripts = self.plugin_root / 'scripts'
        self.observer = observer
        self.runner = runner or subprocess.run
        self.timeout = timeout
        self.output_limit = output_limit

    def inspect(self, intent):
        value = self.observer(intent['kind'], dict(intent))
        return None if value is None else _observation(value)

    def route_review(self, intent):
        card, pr, state = intent.get('card'), intent.get('pr'), intent.get('state')
        if (not isinstance(card, str) or not _CARD.fullmatch(card)
                or not isinstance(pr, str) or not _CARD.fullmatch(pr)
                or state != 'in_review' and not (isinstance(state, str) and state.startswith('review_'))):
            raise ValueError('invalid review route request')
        command = [str(self.scripts / 'review-stages.sh'), 'route', card, pr]
        try:
            result = self.runner(command, cwd=str(self.plugin_root), capture_output=True,
                                 text=True, timeout=self.timeout, check=False, shell=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RuntimeError('review-stage route outcome is uncertain: ' + str(exc)) from exc
        stdout, stderr = result.stdout or '', result.stderr or ''
        if any(len(value.encode('utf-8', errors='replace')) > self.output_limit for value in (stdout, stderr)):
            raise RuntimeError('review-stage route output exceeded limit')
        if result.returncode != 0:
            raise RuntimeError('review-stage route failed with exit ' + str(result.returncode))
        return {'routed': True, 'output': stdout}

    def _command(self, intent):
        kind, card = intent['kind'], intent.get('card')
        if not isinstance(card, str) or not _CARD.fullmatch(card):
            raise ValueError('invalid effect card')
        if kind == 'worktree_prepare':
            operation = intent.get('operation', 'create')
            if operation == 'create':
                branch, path = intent.get('branch'), intent.get('worktree')
                if not isinstance(branch, str) or not _BRANCH.fullmatch(branch) or not isinstance(path, str) or not Path(path).is_absolute():
                    raise ValueError('invalid worktree preparation')
                return [str(self.scripts / 'worktree.sh'), 'create', card, branch, path], None
            pr = intent.get('pr')
            if operation == 'review' and isinstance(pr, str) and _CARD.fullmatch(pr):
                return [str(self.scripts / 'worktree.sh'), 'review', card, pr], None
            raise ValueError('invalid worktree operation')
        if kind == 'branch_refresh':
            branch, path, pr = intent.get('branch'), intent.get('worktree'), intent.get('pr')
            if not isinstance(branch, str) or not _BRANCH.fullmatch(branch) or not isinstance(path, str) or not Path(path).is_absolute() or not isinstance(pr, str) or not _CARD.fullmatch(pr):
                raise ValueError('invalid branch refresh')
            return [str(self.scripts / 'update-branch.sh'), card, pr, branch, path], None
        if kind == 'commit_publication':
            branch, path = intent.get('branch'), intent.get('worktree')
            if not isinstance(branch, str) or not _BRANCH.fullmatch(branch) or not isinstance(path, str) or not Path(path).is_absolute():
                raise ValueError('invalid commit publication')
            return ['git', 'push', '--set-upstream', 'origin', branch], path
        if kind in ('pr_create', 'pr_update'):
            title, body, base = intent.get('title'), intent.get('body'), intent.get('base', 'main')
            if not all(isinstance(value, str) and value for value in (title, body, base)):
                raise ValueError('invalid PR details')
            if kind == 'pr_create':
                marker = 'Controller-Operation: ' + intent['operation_key']
                return ['gh', 'pr', 'create', '--title', title, '--body', body + '\n\n' + marker, '--base', base], None
            pr = intent.get('pr')
            if not isinstance(pr, str) or not _CARD.fullmatch(pr):
                raise ValueError('invalid PR update')
            return ['gh', 'pr', 'edit', pr, '--title', title, '--body', body, '--base', base], None
        if kind == 'report_post':
            report = intent.get('report_file')
            if not isinstance(report, str) or not Path(report).is_file():
                raise ValueError('invalid report file')
            content = Path(report).read_bytes()
            if len(content) > self.output_limit:
                raise ValueError('oversized report')
            marker = ('\n\n<!-- fleet-board-effect-operation:' + intent['operation_key'] + ' -->\n').encode('ascii')
            fd, marked_report = tempfile.mkstemp(prefix='fleet-board-effect-report-')
            try:
                with os.fdopen(fd, 'wb') as stream:
                    stream.write(content + marker)
            except Exception:
                os.unlink(marked_report)
                raise
            return [str(self.scripts / 'board-comment.sh'), card, marked_report], None, marked_report
        if kind == 'note_update':
            patch = intent.get('patch_file')
            if not isinstance(patch, str) or not Path(patch).is_file():
                raise ValueError('invalid note patch')
            return [str(self.scripts / 'note.sh'), 'merge', card, patch], None
        if kind == 'card_move':
            state = intent.get('state')
            if not isinstance(state, str) or not _STATE.fullmatch(state):
                raise ValueError('invalid board state')
            if ((state == 'in_review' or state.startswith('review_'))
                    and intent.get('review_route_completed') is not True):
                raise ValueError('review move requires completed review-stage routing')
            return [str(self.scripts / 'board-move.sh'), card, state], None
        if kind == 'followup_file':
            report, pr = intent.get('report_file'), intent.get('pr')
            role = intent.get('role')
            if (not isinstance(report, str) or not Path(report).is_file()
                    or not isinstance(pr, str) or not _CARD.fullmatch(pr)
                    or role not in ('implementor', 'reviewer', 'fixer', 'stage-reviewer')):
                raise ValueError('invalid follow-up report')
            parsed = self.runner([str(self.scripts / 'parse-report.sh'), '--role', role, report],
                                 cwd=str(self.plugin_root), capture_output=True, text=True,
                                 timeout=self.timeout, check=False, shell=False)
            output = parsed.stdout or ''
            if parsed.returncode != 0 or len(output.encode('utf-8', errors='replace')) > self.output_limit:
                raise ValueError('follow-up report failed parse-report validation')
            fd, parsed_report = tempfile.mkstemp(prefix='fleet-board-effect-followups-')
            try:
                with os.fdopen(fd, 'w', encoding='utf-8') as stream:
                    stream.write(output)
            except Exception:
                os.unlink(parsed_report)
                raise
            return [str(self.scripts / 'file-followups.sh'), card, pr, parsed_report], None, parsed_report
        if kind == 'cleanup':
            path = intent.get('worktree')
            if not isinstance(path, str) or not Path(path).is_absolute():
                raise ValueError('invalid cleanup worktree')
            return [str(self.scripts / 'worktree.sh'), 'remove', card, path], None
        raise ValueError('unsupported effect kind')

    def apply(self, intent):
        command_result = self._command(intent)
        command, cwd = command_result[:2]
        temporary = command_result[2] if len(command_result) == 3 else None
        try:
            try:
                result = self.runner(command, cwd=cwd or str(self.plugin_root),
                                     capture_output=True, text=True, timeout=self.timeout,
                                     check=False, shell=False)
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise RuntimeError('effect subprocess outcome is uncertain: ' + str(exc)) from exc
            stdout, stderr = result.stdout or '', result.stderr or ''
            if any(len(value.encode('utf-8', errors='replace')) > self.output_limit for value in (stdout, stderr)):
                raise RuntimeError('effect subprocess output exceeded limit')
            if result.returncode != 0:
                raise RuntimeError('effect subprocess failed with exit ' + str(result.returncode))
            observed = self.inspect(intent)
            if observed is None:
                raise RuntimeError('mutation completed without fresh observation evidence')
            return _observation(observed)
        finally:
            if temporary is not None:
                try:
                    os.unlink(temporary)
                except FileNotFoundError:
                    pass

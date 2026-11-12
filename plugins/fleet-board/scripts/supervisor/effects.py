"""Allowlisted bridge from the controller to the plugin's own helper scripts.

Phase 1 keeps only the bounded script adapter; Task 2.2 moves it to its permanent home.
"""
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

from .paths import canonical_json

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
        if intent['kind'] == 'integration_merge':
            card, pr, head, key = (intent.get('card'), intent.get('pr'),
                                   intent.get('head_sha'), intent.get('operation_key'))
            if (not isinstance(card, str) or not _CARD.fullmatch(card)
                    or not isinstance(pr, str) or not _CARD.fullmatch(pr)
                    or not isinstance(head, str) or not re.fullmatch(r'[0-9a-fA-F]{7,64}', head)
                    or not isinstance(key, str) or not _OPERATION_KEY.fullmatch(key)):
                raise ValueError('invalid merge recovery inspection')
            command = [str(self.scripts / 'merge-reviewed.sh'), '--inspect', '--card', card,
                       '--operation-key', key, '--pr', pr, '--head', head]
            try:
                result = self.runner(command, cwd=str(self.plugin_root), capture_output=True,
                                     text=True, timeout=self.timeout, check=False, shell=False)
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise RuntimeError('merge recovery inspection failed: ' + str(exc)) from exc
            stdout, stderr = result.stdout or '', result.stderr or ''
            if any(len(value.encode('utf-8', errors='replace')) > self.output_limit for value in (stdout, stderr)):
                raise RuntimeError('merge recovery inspection output exceeded limit')
            if result.returncode != 0:
                raise RuntimeError('merge recovery inspection failed with exit ' + str(result.returncode))
            try:
                evidence = json.loads(stdout)
            except (TypeError, ValueError) as exc:
                raise RuntimeError('merge recovery inspection returned invalid JSON') from exc
            if not isinstance(evidence, dict) or evidence.get('status') != 'observed':
                return None
            if evidence.get('state') != 'MERGED':
                return None
            return evidence
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
        if kind == 'integration_merge':
            pr, head = intent.get('pr'), intent.get('head_sha')
            if (not isinstance(pr, str) or not _CARD.fullmatch(pr)
                    or not isinstance(head, str)
                    or not re.fullmatch(r'[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?', head)):
                raise ValueError('invalid bounded merge request')
            if not isinstance(intent.get('operation_key'), str) or not _OPERATION_KEY.fullmatch(intent['operation_key']):
                raise ValueError('invalid bounded merge operation identity')
            return [str(self.scripts / 'merge-reviewed.sh'), '--card', card,
                    '--operation-key', intent['operation_key'], '--pr', pr, '--head', head], None
        if kind == 'main_verification':
            pr = intent.get('pr')
            if not isinstance(pr, str) or not _CARD.fullmatch(pr):
                raise ValueError('invalid main verification request')
            return [str(self.scripts / 'verify-main.sh'), card, pr], None
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
                if intent['kind'] == 'integration_merge' and result.returncode == 3:
                    observed = self.inspect(intent)
                    if isinstance(observed, dict) and observed.get('merged') is True:
                        return observed
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

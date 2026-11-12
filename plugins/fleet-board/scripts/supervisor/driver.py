"""The card driver: a deterministic port of the manager agent's per-card job.

`CardDriver.begin(candidate)` runs one planned action for one card. Script-only actions run to the end and
return Started("done"). `start` and `start_review` run their setup steps and return Started("session");
dispatching the role is left to `_dispatch_role`. `merge` belongs to the merge lane and is refused here.

Every value handed to a script is validated first (numbers are positive ints, a branch is
`fleet/<n>-<slug>`, a worktree is an absolute path, a state is one of the board's states, and nothing
starts with "-"). A failed step ends the action; earlier steps stand. A failure that is not an
uncounted action merges `action_failures + 1` and the first stderr line into the card's manager note.
"""
import json
import os
import re
import tempfile
import time
from collections import namedtuple
from pathlib import Path

from . import resolver, roles as _roles, scripts
from .state import Action

Started = namedtuple('Started', 'kind action')

SCRIPT_ACTIONS = frozenset((
    'advance_stage', 'update_branch', 'block', 'to_human_qa', 'mark_ready', 'verify_main', 'finish', 'unblock',
    'file_pending', 'skip_no_acceptance', 'skip_card_lint', 'wait', 'skip',
))
ROLE_ACTIONS = frozenset(('start', 'continue_implementor', 'start_review', 'review', 'review_stage', 'fix'))
_SETUP_ONLY = ('start', 'start_review')  # the role actions whose setup half lives here
_ROLE_OF = {'start': 'implementor', 'start_review': 'reviewer'}
_UNCOUNTED = frozenset(('wait', 'skip'))
_FLAGS = frozenset(('--qa-summary',))
_FIXED_BEFORE = ('backlog', 'ready', 'in_progress', 'in_review')
_FIXED_AFTER = ('human_qa', 'blocked', 'done', 'wont_do')
_BRANCH = re.compile(r'fleet/[0-9]+-[a-z0-9-]{1,40}')
_REPO = re.compile(r'[^/\s]+/[^/\s]+')
_REF = re.compile(r'[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+')
_STAGE = re.compile(r'[a-z][a-z0-9_]*')
_AFTER_MERGE = re.compile(r'(?m)^##[ \t]+After merge[ \t]*$')
_NO_PROGRESS = re.compile(r'no progress after (\d+) attempts?: (.*)', re.S)
_RESET = {'action_failures': 0, 'last_action_error': None}
_SEVERE = ('Critical', 'Important')
_SKIP_MARKER = '<!-- fleet-board:skip-no-acceptance -->'
QA_BUILD_TIMEOUT = 1800
VERIFY_TIMEOUT = 1800


class _Fail(Exception):
    """A step failed; the message is the one line recorded as last_action_error."""


class _Invalid(_Fail):
    def __init__(self, field, value):
        super().__init__('invalid %s: %s' % (field, value))


def _posint(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _first_line(text):
    for line in (text or '').splitlines():
        line = ''.join(ch if ch >= ' ' else ' ' for ch in line).strip()
        if line:
            return line[:300]
    return ''


def _json(text):
    try:
        return json.loads(text)
    except ValueError:
        return None


def _gh(root, *args):
    return scripts.run_argv(root, ['gh'] + [str(a) for a in args], timeout=120)


class _Ctx:
    """One action on one card: validated values, script steps, note reads and merges, comments."""

    def __init__(self, driver, row, config, tmp):
        self.d, self.row, self.config, self.tmp = driver, row, config, tmp
        self.n = row['number']
        self._files = 0

    # values -------------------------------------------------------------------------------------------
    def states(self):
        stages = [s['name'] for s in ((self.config.get('review') or {}).get('stages') or [])
                  if isinstance(s, dict) and isinstance(s.get('name'), str) and _STAGE.fullmatch(s['name'])]
        return _FIXED_BEFORE + tuple('review_' + s for s in stages) + _FIXED_AFTER

    def state_name(self, value):
        if not isinstance(value, str) or value not in self.states():
            raise _Invalid('state', value)
        return value

    def branch(self):
        value = self.row.get('branch')
        if not isinstance(value, str) or not _BRANCH.fullmatch(value):
            raise _Invalid('branch', value)
        return value

    def worktree(self):
        value = self.row.get('worktree')
        if not isinstance(value, str) or not os.path.isabs(value) or any(ch < ' ' for ch in value):
            raise _Invalid('worktree', value)
        return value

    def pr(self, *fallbacks):
        value = self.row.get('pr')
        for fallback in fallbacks:
            if value is None:
                value = fallback
        if not _posint(value):
            raise _Invalid('pr', value)
        return value

    def repo(self):
        value = (self.config.get('board') or {}).get('repo')
        if not isinstance(value, str) or not _REPO.fullmatch(value) or value.startswith('-'):
            raise _Invalid('repo', value)
        return value

    def models_patch(self):
        models = self.row.get('models')
        if not isinstance(models, dict):
            raise _Invalid('models', models)
        patch = {'models': models}
        if self.row.get('escalated'):
            patch.update(escalated=True, escalated_at_round=self.row.get('round') or 0)
        return patch

    # steps --------------------------------------------------------------------------------------------
    def soft(self, name, *args, **kw):
        for arg in args:
            text = str(arg)
            if text.startswith('-') and text not in _FLAGS:
                raise _Invalid('argument', text)
        return self.d.run(self.d.root, name, *args, **kw)

    def step(self, name, *args, **kw):
        result = self.soft(name, *args, **kw)
        if result.timed_out:
            raise _Fail(name + ' timed out')
        if result.rc != 0:
            raise _Fail(_first_line(result.stderr) or '%s exited %d' % (name, result.rc))
        return result

    def note(self):
        data = _json(self.step('note.sh', 'get', self.n).stdout)
        if not isinstance(data, dict):
            raise _Fail('note.sh get printed no manager note')
        return data

    def _file(self, text):
        self._files += 1
        path = Path(self.tmp) / ('%d-%d' % (self.n, self._files))
        path.write_text(text if isinstance(text, str) else json.dumps(text))
        return str(path)

    def merge(self, patch):
        self.step('note.sh', 'merge', self.n, self._file(patch))

    def warn(self, message):
        self.d.state.event('warning', card=self.n, message=message)

    def merge_soft(self, patch):
        try:
            self.merge(patch)
        except _Fail as exc:
            self.warn('note write failed: ' + str(exc))

    def comment(self, text):
        self.step('board-comment.sh', self.n, self._file(text))

    def comment_soft(self, text):
        try:
            self.comment(text)
        except _Fail as exc:
            self.warn('comment failed: ' + str(exc))

    def failure_patch(self, message):
        try:
            count = self.note().get('action_failures') or 0
        except _Fail:
            count = 0
        return {'action_failures': (count if isinstance(count, int) else 0) + 1, 'last_action_error': message}

    def move(self, state_name):
        self.step('board-move.sh', self.n, state_name)


class CardDriver:
    def __init__(self, root, config_loader, state, run=scripts.run, roles=_roles, ledger=None,
                 clock=time.time, gh=_gh):
        self.root = Path(root)
        self.config_loader = config_loader
        self.state = state
        self.run = run
        self.roles = roles
        self.ledger = ledger
        self.clock = clock
        self.gh = gh

    def begin(self, candidate):
        action_name = candidate.get('action')
        if action_name == 'merge':
            raise ValueError('merge is handled by the merge lane')
        if action_name not in SCRIPT_ACTIONS and action_name not in ROLE_ACTIONS:
            raise ValueError('unknown card action: %r' % (action_name,))
        if action_name in ROLE_ACTIONS and action_name not in _SETUP_ONLY:
            raise NotImplementedError('%s needs role dispatch (task 2.7)' % action_name)
        config = self.config_loader()
        row = dict(candidate)
        number = row.get('number')
        action = Action(card=number, action=action_name, column=row.get('state'), role=_ROLE_OF.get(action_name),
                        provider=resolver.provider_for(config, row), paths=list(row.get('declared_paths') or []),
                        started_at=self.clock(), started_mono=time.monotonic(),
                        kind='role' if action_name in ROLE_ACTIONS else 'script')
        if not _posint(number):
            self.state.event('action_failed', card=number, action=action_name, error='invalid number: %s' % (number,))
            return Started('done', action)
        self.state.begin(action)
        outcome = None
        try:
            with tempfile.TemporaryDirectory(prefix='fleet-driver-') as tmp:
                ctx = _Ctx(self, row, config, tmp)
                try:
                    outcome = getattr(self, '_do_' + action_name)(ctx)
                except _Fail as exc:
                    self._failed(ctx, action_name, str(exc))
        except BaseException:
            self.state.end(number)
            raise
        if outcome == 'session':
            return Started('session', action)
        self.state.end(number)
        return Started('done', action)

    def _failed(self, ctx, action_name, message):
        self.state.event('action_failed', card=ctx.n, action=action_name, error=message)
        if action_name in _UNCOUNTED:
            return
        try:
            ctx.merge(ctx.failure_patch(message))
        except _Fail as exc:
            ctx.warn('could not count the failure: ' + str(exc))

    def _dispatch_role(self, action, candidate):
        """Task 2.7 fills this: launch the role for a `start` / `start_review` action that setup prepared."""
        raise NotImplementedError('role dispatch is not part of the script-only driver')

    # role actions: setup half ---------------------------------------------------------------------------
    def _do_start(self, c):
        branch, worktree = c.branch(), c.worktree()
        patch = {'state': 'in_progress', 'branch': branch, 'worktree': worktree, 'round': 0,
                 'implementor_attempts': 1}
        patch.update(c.models_patch())
        c.step('worktree.sh', 'create', c.n, branch, worktree)
        c.move('in_progress')
        c.merge(patch)
        return 'session'

    def _do_start_review(self, c):
        pr = c.pr()
        c.step('review-stages.sh', 'route', c.n, pr)
        c.move('in_review')
        c.merge({'state': 'in_review', 'round': 1, 'pr': pr})
        return 'session'

    # script-only actions --------------------------------------------------------------------------------
    def _do_advance_stage(self, c):
        stage = c.row.get('stage')
        name = stage.get('name') if isinstance(stage, dict) else None
        if not isinstance(name, str) or not _STAGE.fullmatch(name):
            raise _Invalid('stage', name)
        target = c.state_name('review_' + name)
        leaving = c.state_name(c.row.get('state'))
        reviewed = list(c.note().get('reviewed_stages') or [])
        if leaving.startswith('review_') and leaving[len('review_'):] not in reviewed:
            reviewed.append(leaving[len('review_'):])
        c.move(target)
        c.merge(dict(_RESET, state=target, stage=name, round=1, reviewed_stages=reviewed))

    def _do_update_branch(self, c):
        branch, worktree = c.branch(), c.worktree()
        pr = c.pr(c.note().get('pr') if c.row.get('pr') is None else None)
        c.step('worktree.sh', 'create', c.n, branch, worktree)
        c.step('update-branch.sh', c.n, pr, branch, worktree)
        c.merge_soft(dict(_RESET))

    def _do_block(self, c):
        reason = c.row.get('reason')
        if not isinstance(reason, str) or not reason.strip():
            raise _Invalid('reason', reason)
        came_from = c.state_name(c.row.get('state'))
        if came_from not in c.states()[1:c.states().index('human_qa')]:  # ready .. review_<stage>
            raise _Invalid('state', came_from)
        match = _NO_PROGRESS.match(reason)
        if match:
            c.merge({'blocking_pr': None})
            entries = [{'severity': 'Important', 'text': reason}]
            c.move('blocked')
            c.merge_soft(dict(_RESET, state='blocked', blocked_from=came_from, blocked_findings=entries))
            c.comment_soft('This card was blocked because its action made no progress %s times in a row.\n\n'
                           'Last error: `%s`\n\nA person must fix the cause and then move the card back.'
                           % (match.group(1), ' '.join(match.group(2).split())))
            return
        review = c.note().get('last_review')
        found = [{'severity': f['severity'], 'text': f.get('text', '')}
                 for f in ((review or {}).get('findings') or [])
                 if isinstance(f, dict) and f.get('severity') in _SEVERE]
        entries = found or [{'severity': 'Important', 'text': reason}]
        c.move('blocked')
        c.merge_soft(dict(_RESET, state='blocked', blocked_from=came_from, blocked_findings=entries))
        c.comment_soft('Blocked: ' + reason + '\n\n' + '\n'.join('- [%s] %s' % (e['severity'], e['text'])
                                                               for e in entries))

    def _qa_summary(self, command, worktree):
        try:
            result = scripts.run_argv(worktree, ['bash', '-c', command], timeout=QA_BUILD_TIMEOUT)
        except OSError as exc:
            return 'QA build `%s` could not run: %s\n' % (command, exc)
        lines = (result.stdout + result.stderr).splitlines()[-20:]
        status = 'timed out' if result.timed_out else 'exit %d' % result.rc
        return 'QA build `%s`: %s\n\n```\n%s\n```\n' % (command, status, '\n'.join(lines))

    def _do_to_human_qa(self, c):
        worktree, pr = c.worktree(), c.pr()
        command = (c.config.get('commands') or {}).get('qa_build')
        flags = []
        if isinstance(command, str) and command.strip():
            flags = ['--qa-summary', c._file(self._qa_summary(command, worktree))]
        c.move('human_qa')
        result = c.soft('human-qa-handoff.sh', *(flags + [c.n, pr]))
        if result.rc != 0 or result.timed_out:
            c.warn('human-qa-handoff.sh failed: ' + (_first_line(result.stderr) or 'no output'))
        c.merge_soft(dict(_RESET, state='human_qa'))

    def _do_mark_ready(self, c):
        pr, repo = c.pr(), c.repo()
        result = self.gh(self.root, 'pr', 'ready', str(pr), '--repo', repo)
        if result.timed_out or result.rc != 0:
            raise _Fail(_first_line(result.stderr) or 'gh pr ready failed')
        c.merge_soft(dict(_RESET))

    def _do_verify_main(self, c):
        pr = c.pr()
        result = c.soft('verify-main.sh', c.n, pr, timeout=VERIFY_TIMEOUT)
        checked, problem = None, None
        if result.timed_out:
            problem = 'verify-main.sh timed out'
        elif result.rc != 0:
            problem = _first_line(result.stderr) or 'verify-main.sh exited %d' % result.rc
        else:
            data = _json(result.stdout)
            if (isinstance(data, dict) and isinstance(data.get('commit'), str) and data['commit']
                    and isinstance(data.get('ok'), bool) and isinstance(data.get('results'), list)):
                checked = data
                if data['ok'] is not True:
                    problem = 'commit %s is red' % data['commit']
                    if data.get('p0_card') is not None:
                        problem += ' (p0_card #%s)' % data['p0_card']
            else:
                problem = 'malformed verify-main.sh result'
        patch = {'main_check': checked} if checked else {}
        patch.update(c.failure_patch(problem) if problem else _RESET)
        try:
            c.merge(patch)
        except _Fail as exc:
            if problem is None:
                problem = 'could not record main_check: ' + str(exc)
                c.merge_soft(c.failure_patch(problem))
        if problem:
            self.state.event('action_failed', card=c.n, action='verify_main', error=problem)
            self.state.pause('main verification failed for #%d: %s' % (c.n, problem))

    def _do_finish(self, c):
        card = _json(c.step('board-read.sh', c.n).stdout)
        body = card.get('body') if isinstance(card, dict) else None
        if not isinstance(body, str):
            raise _Fail('board-read.sh printed no card body')
        if _AFTER_MERGE.search(body):
            merged = _json(c.step('after-merge.sh', 'run', c._file(body)).stdout)
            if not isinstance(merged, dict) or merged.get('outcome') not in ('done', 'blocked'):
                raise _Fail('after-merge.sh printed an unexpected result')
            # Port of the script's behaviour: the note key is after_merge_results, a list of {command, exit}.
            c.merge({'after_merge_results': [
                {'command': r['command'], 'exit': r['exit']} for r in (merged.get('results') or [])
                if isinstance(r, dict) and isinstance(r.get('command'), str) and r['command']
                and isinstance(r.get('exit'), int) and not isinstance(r.get('exit'), bool)]})
            if merged['outcome'] == 'blocked':
                c.move('blocked')
                c.merge_soft(dict(_RESET, state='blocked', blocked_from='in_review'))
                if isinstance(merged.get('comment'), str) and merged['comment'].strip():
                    c.comment_soft(merged['comment'])
                return
        c.move('done')
        c.merge_soft(dict(_RESET, state='done'))

    def _do_unblock(self, c):
        c.move('ready')
        c.merge_soft(dict(_RESET, state='ready', blocking_pr=None, blocked_from=None, blocked_findings=None))

    def _do_file_pending(self, c):
        note = c.note()
        pending = note.get('pending_followups')
        if not isinstance(pending, dict):
            return
        pr = pending.get('pr') or note.get('pr') or c.row.get('pr')
        if pr is None:
            c.warn('pending follow-ups on #%d wait for a PR' % c.n)
            return
        if not _posint(pr):
            raise _Invalid('pr', pr)
        stored = {'out_of_scope': list(pending.get('out_of_scope') or []), 'bugs': list(pending.get('bugs') or []),
                  'pr': pending.get('pr')}
        result = c.soft('file-followups.sh', c.n, pr, c._file(stored))
        printed = _json(result.stdout) if not result.timed_out else None
        if not isinstance(printed, dict):
            printed = None
        if result.rc == 0 and not result.timed_out:
            if printed is None:
                raise _Fail('file-followups.sh printed invalid JSON')
            c.merge(dict(_RESET, out_of_scope_created=printed.get('out_of_scope_created') or [],
                         bugs_filed=printed.get('bugs_filed') or [], pending_followups=None))
            return
        error = 'file-followups.sh timed out' if result.timed_out else (
            _first_line(result.stderr) or 'file-followups.sh exited %d' % result.rc)
        if printed is None:
            raise _Fail(error)
        scope, bugs = printed.get('out_of_scope_created') or [], printed.get('bugs_filed') or []

        def left(items, filed):
            titles = {str(f.get('title', '')).lower() for f in filed if isinstance(f, dict)}
            return [i for i in items if str(i.get('title', '')).lower() not in titles]
        remaining = {'out_of_scope': left(stored['out_of_scope'], scope), 'bugs': left(stored['bugs'], bugs),
                     'pr': stored['pr'] if stored['pr'] is not None else pr}
        c.warn('file-followups.sh filed only part of the follow-ups on #%d: %s' % (c.n, error))
        c.merge(dict(c.failure_patch(error), out_of_scope_created=scope, bugs_filed=bugs,
                     pending_followups=remaining if remaining['out_of_scope'] or remaining['bugs'] else None))

    def _do_skip_no_acceptance(self, c):
        if c.row.get('comment_needed') is not True:
            return
        c.comment(_SKIP_MARKER + '\n\nThis card has no acceptance criteria, so fleet-board will not start it. '
                  'Add at least one item to its Acceptance list (the card\'s acceptance field); '
                  'the card is picked up again once it has one.')
        c.merge_soft(dict(_RESET))

    def _do_skip_card_lint(self, c):
        if c.row.get('comment_needed') is not True:
            return
        marker, lint = c.row.get('lint_marker'), c.row.get('lint')
        if (not isinstance(marker, str) or not marker.startswith('<!--') or not marker.endswith('-->')
                or '\n' in marker):
            raise _Invalid('lint_marker', marker)
        if not isinstance(lint, list) or not all(isinstance(line, str) for line in lint):
            raise _Invalid('lint', lint)
        c.comment(marker + '\n\nCard lint failed, so the card stays in Ready until it is fixed:\n\n'
                  + '\n'.join('- ' + ' '.join(line.split()) for line in lint)
                  + '\n\nFix the card; the next run lints it again.')
        c.merge_soft(dict(_RESET))

    def _do_wait(self, c):
        waiting = c.row.get('waiting_on')
        if c.row.get('state') != 'ready' or not waiting:
            return
        if not isinstance(waiting, list) or not all(isinstance(r, str) and _REF.fullmatch(r) for r in waiting):
            raise _Invalid('waiting_on', waiting)
        if c.note().get('deps_commented') == waiting:
            return
        c.comment('Waiting for ' + ', '.join(waiting))
        c.merge({'deps_commented': waiting})

    def _do_skip(self, c):
        return

"""The card driver: a deterministic port of the manager agent's per-card job.

`CardDriver.begin(candidate)` runs one planned action for one card. Script-only actions run to the end and
return Started("done"). A role action (`start`, `continue_implementor`, `start_review`, `review`,
`review_stage`, `fix`) runs its setup steps, launches the role and returns Started("session") with
`action.session` set; when that session ends the caller passes its RoleResult to `finish`, which checks the
report, applies it to the card's note and board state and returns an Outcome. A rejected report is
re-dispatched once (Outcome.redispatch, `action.session` is the new session). `merge` belongs to the merge
lane and is refused here.

Every value handed to a script is validated first (numbers are positive ints, a branch is
`fleet/<n>-<slug>`, a worktree is an absolute path, a state is one of the board's states, and nothing
starts with "-"). A failed step ends the action; earlier steps stand. A failure that is not an
uncounted action merges `action_failures + 1` and the first stderr line into the card's manager note.
"""
import json
import os
import re
import shutil
import tempfile
import time
from collections import namedtuple
from pathlib import Path

from . import paths, resolver, roles as _roles, scripts
from .state import Action

Started = namedtuple('Started', 'kind action')
Outcome = namedtuple('Outcome', 'card progressed redispatch provider_failure')

SCRIPT_ACTIONS = frozenset((
    'advance_stage', 'update_branch', 'block', 'to_human_qa', 'mark_ready', 'verify_main', 'finish', 'unblock',
    'file_pending', 'skip_no_acceptance', 'skip_card_lint', 'wait', 'skip',
))
ROLE_ACTIONS = frozenset(('start', 'continue_implementor', 'start_review', 'review', 'review_stage', 'fix'))
_ROLE_OF = {'start': 'implementor', 'continue_implementor': 'implementor', 'start_review': 'reviewer',
            'review': 'reviewer', 'review_stage': 'stage-reviewer', 'fix': 'fixer'}
_SCRIPT_RUNNERS = ('stage-review', 'evidence-review')
_UNCOUNTED = frozenset(('wait', 'skip'))
_FLAGS = frozenset(('--qa-summary', '--role', '--commits-since-review'))
_FIXED_BEFORE = ('backlog', 'ready', 'in_progress', 'in_review')
_FIXED_AFTER = ('human_qa', 'blocked', 'done', 'wont_do')
_BRANCH = re.compile(r'fleet/[0-9]+-[a-z0-9-]{1,40}')
_REPO = re.compile(r'^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$')
_SHA = re.compile(r'[0-9a-f]{4,64}')
_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9._:/\[\]-]*')
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
        super().__init__('invalid %s: %s' % (field, _first_line(str(value))))


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


def _git(cwd, *args):
    try:
        return scripts.run_argv(cwd, ['git'] + [str(a) for a in args], timeout=60)
    except OSError as exc:
        return scripts.ScriptResult(127, '', str(exc), False)


def _left(items, filed):
    titles = {str(f.get('title', '')).lower() for f in filed if isinstance(f, dict)}
    return [i for i in items if str(i.get('title', '')).lower() not in titles]


def _union(first, second):
    seen, out = set(), []
    for item in list(first) + list(second):
        key = str(item.get('title', '')).lower() if isinstance(item, dict) else None
        if key is not None and key not in seen:
            seen.add(key)
            out.append(item)
    return out


class _Ctx:
    """One action on one card: validated values, script steps, note reads and merges, comments."""

    def __init__(self, driver, row, config, tmp):
        self.d, self.row, self.config, self.tmp = driver, row, config, tmp
        self.n = row['number']
        self.action = None
        self.attempts_before = None   # implementor_attempts before this dispatch charged one
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

    def models_patch(self, strict=True):
        models = self.row.get('models')
        if not isinstance(models, dict):
            if strict:
                raise _Invalid('models', models)
            return {}
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
        """The counter patch for one more failed action, or {} when the note cannot be read: writing
        `action_failures: 1` over an unknown count could reset it, so the next cycle replans instead."""
        try:
            count = self.note().get('action_failures') or 0
        except _Fail as exc:
            self.warn('could not read the note to count the failure: ' + str(exc))
            return {}
        return {'action_failures': (count if isinstance(count, int) else 0) + 1, 'last_action_error': message}

    def move(self, state_name):
        self.step('board-move.sh', self.n, state_name)


class _Run:
    """One launched role: what finish() needs to check its report and, once, to re-dispatch it."""

    def __init__(self, c, action, dispatch, role, prompt, **kw):
        self.c, self.action, self.dispatch, self.role = c, action, dispatch, role
        self.prompt = self.base_prompt = prompt
        self.stage_args, self.attempt = [], 1
        self.round = self.sha = self.stage = self.conflict = self.prior = None
        self.__dict__.update(kw)

    @property
    def script(self):
        return self.dispatch.runner in _SCRIPT_RUNNERS


_SECTIONS = {
    'implementor': ('number', 'title', 'body', 'acceptance', 'worktree', 'branch', 'note', 'config', 'scripts'),
    'reviewer': ('number', 'body', 'acceptance', 'pr', 'diff', 'report', 'worktree', 'config', 'round',
                 'prev_sha', 'findings', 'scripts'),
    'fixer': ('number', 'title', 'body', 'acceptance', 'pr', 'worktree', 'findings', 'config', 'scripts'),
    'stage-reviewer': ('number', 'body', 'acceptance', 'pr', 'diff', 'report', 'worktree', 'config', 'stage_name',
                       'brief', 'round', 'prev_sha', 'findings', 'scripts', 'post'),
}
_LABELS = {
    'number': 'Card number', 'title': 'Card title', 'body': 'Card body', 'acceptance': 'Acceptance',
    'worktree': 'Worktree', 'branch': 'Branch', 'note': 'Manager note', 'config': 'Config', 'scripts': 'Scripts dir',
    'pr': 'PR number', 'diff': 'PR diff', 'report': 'Latest implementor or fixer report', 'round': 'Round',
    'prev_sha': 'Previous review sha (prev_sha)', 'findings': 'Findings', 'stage_name': 'Stage name',
    'brief': 'Stage brief', 'post': 'Posting your report',
}
DIFF_FILE_LINES = 1500


def role_prompt(role, inputs, tmp=None):
    """The prompt for one role: its inputs (plan-ref-roles.md section 1) as labelled `## <label>` sections, in
    a fixed order. A diff longer than 1500 lines is written to a file under `tmp` and its path is passed."""
    if role not in _SECTIONS:
        raise ValueError('unknown role: %r' % (role,))
    parts = []
    for key in _SECTIONS[role]:
        value = inputs.get(key)
        if value is None:
            continue
        label = _LABELS[key]
        if key == 'diff' and len(str(value).splitlines()) > DIFF_FILE_LINES:
            fd, path = tempfile.mkstemp(suffix='.diff', dir=tmp)
            with os.fdopen(fd, 'w') as handle:
                handle.write(value)
            label, value = 'PR diff file (the diff has over %d lines; read it from this path)' % DIFF_FILE_LINES, path
        elif not isinstance(value, str):
            value = value if isinstance(value, int) and not isinstance(value, bool) else json.dumps(
                value, indent=2, sort_keys=True)
        parts.append('## %s\n%s' % (label, value))
    return '\n\n'.join(parts) + '\n'


_RULES = (
    ('missing section: ## Status',
     'Every report contains `## Status`.'),
    ('missing section: ## Findings',
     'Every report contains `## Findings`.'),
    ('missing section: ## For the card',
     'Every report contains `## For the card`.'),
    ('unknown status: <word>',
     '`## Status` is one word: `done`, `blocked`, `clean` or `findings`.'),
    ('role <role> does not allow status: <word>',
     '`done` and `blocked` are for the implementor and fixer; `clean` and `findings` are for the reviewer and the stage-reviewer.'),
    ('expected exactly one VERIFIED: line, found <N>',
     'There is exactly one `VERIFIED:` line.'),
    ('VERIFIED line needs a backticked command and an integer after ->',
     'The command sits between backticks, the arrow is `->` or `→`, and the first token after the arrow is an integer ending at whitespace or the line end.'),
    ('bug entry needs title, repro, expected, observed',
     'Each Bugs found line has all four parts.'),
    ('role <role> requires ## <section>',
     'Role sections: implementor `## PR`; fixer `## PR` and `## Resolutions`; reviewer `## Acceptance map`, `## Mutation` and `## Claim check`; the stage-reviewer has none.'),
    ('duplicate section: ## <heading>',
     'Any heading appears at most once.'),
    ('## Status must be one line, extra line: <line>',
     '`## Status` holds exactly one non-blank line.'),
    ('malformed finding line: <line>',
     'Every non-blank `## Findings` line is `- [Critical] <text>`, `- [Important] <text>` or `- [Minor] <text>`, with that exact spelling and one space after `-`, or exactly `- none`.'),
    ('## Findings needs "- none" or at least one "- [Critical|Important|Minor] <text>" line',
     '`## Findings` needs one of the two forms.'),
    ('## Findings mixes "- none" with findings',
     '`## Findings` uses one of the two forms, never both.'),
    ('empty sub-list: Out of scope:',
     'An `Out of scope:` header needs at least one entry.'),
    ('empty sub-list: Bugs found:',
     'A `Bugs found:` header needs at least one entry.'),
    ('stray list line in ## For the card (sub-list entries follow their header or the previous entry directly, unindented): <line>',
     'Entries are unindented `- ` lines directly under the header or the previous entry. A blank or text line ends the list. A `- ` line after that blank line, or an indented `  - ` line inside a list, is an error.'),
    ('bug repro must be a backticked command: <title>',
     "A bug's repro is backticked."),
    ('out of scope entry needs <title> :: <detail>: <entry>',
     "An Out of scope entry needs ` :: ` with a non-empty title and detail. The detail must hold a backticked check command or the words `no testable check`. Write the command before any other backticked text: the first non-blank backticked span becomes the follow-up card's Acceptance bullet. With the words, the card is filed in Backlog for a person to triage."),
    ('out of scope entry needs a backticked check command or the words no testable check: <entry>',
     'The detail holds a backticked command a person can run to check the work, written before any other backticked text, or the words `no testable check`.'),
    ('malformed ## Acceptance map line: <line>',
     'Acceptance map lines are split on the last ` -> `; the target is `<file>::<test name>`, `UNMAPPED`, ``CHECKED: `<command>` `` or `NOT_APPLICABLE: <reason>`.'),
    ('malformed ## Mutation line: <line>',
     'Mutation is exactly one line: `killed: <n> survived: <n> invalid: <n>` or `skipped: review.mutation is off`.'),
    ('## Mutation needs exactly one "killed: <n> survived: <n> invalid: <n>" or "skipped: review.mutation is off" line',
     'Mutation is exactly one line of the two forms.'),
    ('## Claim check command must be one backticked command: <value>',
     'The Claim check `command:` holds one backticked command.'),
    ('## Claim check matches must be yes or no: <value>',
     'The Claim check `matches:` is `yes` or `no`.'),
    ('malformed ## Claim check line: <line>',
     'Claim check holds only the lines `claim:`, `command:`, `result:` and `matches:`, or only the skipped line.'),
    ('## Claim check needs one each of claim:, command:, result: and matches:, or only "skipped: review.verify_claim is off"',
     'Claim check has each of the four keys once, or only the skipped line.'),
    ('malformed ## Resolutions line (want - <finding> :: fixed | not fixed: <why>): <line>',
     'One line per input finding. The finding and its outcome are split at the first ` :: ` followed by `fixed` or `not fixed: <why>`, and `<why>` is non-empty.'),
    ('role <role> requires a PR number (#<n>) in ## PR unless status is blocked',
     "The implementor's and fixer's `## PR` holds `#<number>` unless Status is `blocked`."),
    ('status clean needs zero Critical and Important findings, found <n>',
     "The reviewer's and the stage-reviewer's `clean` means zero Critical and zero Important findings."),
    ('status findings needs at least one Critical or Important finding',
     "The reviewer's and the stage-reviewer's `findings` means at least one Critical or Important finding."),
    ('role reviewer requires at least one ## Acceptance map entry',
     "The reviewer's Acceptance map has at least one entry."),
    ('role fixer requires at least one ## Resolutions entry',
     "The fixer's Resolutions has at least one entry."),
    ('status not_reproducible needs no commits since the reviewed head, found <n>', 'A fixer that committed '
     'anything reports `done` or `blocked`; `not_reproducible` is only for a fixer that committed nothing.'),
)


def _rule_pattern(template):
    return re.compile(r'(?s)' + '.*'.join(re.escape(p) for p in re.split(r'<[^>]*>', template)))


_RULE_TABLE = tuple((_rule_pattern(t), rule) for t, rule in _RULES)
_REJECTED = ('Your previous report was rejected by the manager: %s\nThe rule: every report contains ## Status, '
             '## Findings, ## For the card, and exactly one line of the form VERIFIED: `<command>` -> <integer> '
             '<what it counts>.')


def rejection_text(lines):
    """The re-dispatch text of manager.md 3.3: every parse-report line quoted exactly, each followed by its rule."""
    quoted = []
    for line in lines:
        message = line[len('parse-report: '):] if line.startswith('parse-report: ') else line
        rule = next((r for pattern, r in _RULE_TABLE if pattern.fullmatch(message)), None)
        quoted.append(line + ('\n' + rule if rule else ''))
    return _REJECTED % '\n'.join(quoted)


class CardDriver:
    def __init__(self, root, config_loader, state, run=scripts.run, roles=_roles, ledger=None,
                 clock=time.time, gh=_gh, git=_git, env=None, log_dir=None, plugin_dir=None):
        self.root = Path(root)
        self.config_loader = config_loader
        self.state = state
        self.run = run
        self.roles = roles
        self.ledger = ledger
        self.clock = clock
        self.gh = gh
        self.git = git
        self.env = env if env is not None else {}
        self.log_dir = Path(log_dir) if log_dir else paths.log_dir() / 'sessions'
        self.plugin_dir = Path(plugin_dir) if plugin_dir else scripts.SCRIPTS_DIR.parent
        self._runs = {}

    def begin(self, candidate):
        action_name = candidate.get('action')
        if action_name == 'merge':
            raise ValueError('merge is handled by the merge lane')
        if action_name not in SCRIPT_ACTIONS and action_name not in ROLE_ACTIONS:
            raise ValueError('unknown card action: %r' % (action_name,))
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
        tmp = None
        try:
            tmp = tempfile.mkdtemp(prefix='fleet-driver-')
            ctx = _Ctx(self, row, config, tmp)
            ctx.action = action
            try:
                outcome = getattr(self, '_do_' + action_name)(ctx)
            except _Fail as exc:
                self._failed(ctx, action_name, str(exc))
        except BaseException:
            self.state.end(number)
            raise
        finally:
            if tmp is not None and outcome != 'session':
                shutil.rmtree(tmp, ignore_errors=True)
        if outcome == 'session':
            return Started('session', action)
        self.state.end(number)
        return Started('done', action)

    def _failed(self, ctx, action_name, message):
        self.state.event('action_failed', card=ctx.n, action=action_name, error=message)
        if action_name in _UNCOUNTED:
            return
        try:
            patch = ctx.failure_patch(message)
            if patch:
                ctx.merge(patch)
        except _Fail as exc:
            ctx.warn('could not count the failure: ' + str(exc))

    # role actions ---------------------------------------------------------------------------------------
    def _do_start(self, c):
        branch, worktree = c.branch(), c.worktree()
        c.attempts_before = 0
        patch = {'state': 'in_progress', 'branch': branch, 'worktree': worktree, 'round': 0,
                 'implementor_attempts': 1}
        patch.update(c.models_patch())
        c.step('worktree.sh', 'create', c.n, branch, worktree)
        c.move('in_progress')
        c.merge(patch)
        return self._dispatch_role(c, prior='in_progress')

    def _do_continue_implementor(self, c):
        branch, worktree = c.branch(), c.worktree()
        attempts = c.note().get('implementor_attempts')
        c.attempts_before = attempts if isinstance(attempts, int) else 0
        patch = {'implementor_attempts': c.attempts_before + 1, 'branch': branch, 'worktree': worktree}
        patch.update(c.models_patch(strict=False))
        c.merge(patch)
        c.step('worktree.sh', 'create', c.n, branch, worktree)
        return self._dispatch_role(c, prior='in_progress')

    def _do_start_review(self, c):
        pr = c.pr()
        c.step('review-stages.sh', 'route', c.n, pr)
        c.move('in_review')
        c.merge({'state': 'in_review', 'round': 1, 'pr': pr})
        return self._dispatch_role(c, prior='in_review')

    def _do_review(self, c):
        return self._dispatch_role(c, prior=c.row.get('state'))

    _do_review_stage = _do_review

    def _do_fix(self, c):
        branch, worktree = c.branch(), c.worktree()
        conflict = c.row.get('findings')
        if conflict:
            if not isinstance(conflict, list) or not all(
                    isinstance(f, dict) and f.get('severity') in _SEVERE + ('Minor',) and isinstance(f.get('text'), str)
                    for f in conflict):
                raise _Invalid('findings', conflict)
            conflict = [{'severity': f['severity'], 'text': f['text']} for f in conflict]
        else:
            conflict = None
            c.merge({'branch': branch, 'worktree': worktree})
        c.step('worktree.sh', 'create', c.n, branch, worktree)
        return self._dispatch_role(c, prior=c.row.get('state'), conflict=conflict)

    # dispatch ---------------------------------------------------------------------------------------------
    def _read_card(self, c):
        card = _json(c.step('board-read.sh', c.n).stdout)
        if not isinstance(card, dict):
            raise _Fail('board-read.sh printed no card')
        return card

    @staticmethod
    def _latest_report(card):
        """The newest card comment with `## Status` and a VERIFIED: line and no `## Acceptance map`."""
        for comment in reversed(card.get('comments') or []):
            body = comment.get('body') if isinstance(comment, dict) else None
            if (isinstance(body, str) and re.search(r'(?m)^## Status', body) and re.search(r'(?m)^VERIFIED:', body)
                    and not re.search(r'(?m)^## Acceptance map', body)):
                return body
        return ''

    @staticmethod
    def _severe(findings):
        return [{'severity': f['severity'], 'text': f.get('text', '')} for f in (findings or [])
                if isinstance(f, dict) and f.get('severity') in _SEVERE]

    @staticmethod
    def _lines(findings):
        return '\n'.join('- [%s] %s' % (f['severity'], f['text']) for f in findings) or 'none'

    def _dispatch_role(self, c, prior=None, conflict=None):
        """Launch the role for the action `c` just prepared and record it as `action.session`."""
        name = c.row['action']
        dispatch = resolver.resolve(c.config, c.row)
        role = _ROLE_OF[name]
        stage = c.row.get('stage') if name == 'review_stage' else None
        if name == 'review_stage' and not isinstance(stage, dict):
            raise _Invalid('stage', stage)
        if dispatch is None or (dispatch.runner == 'claude' and not dispatch.agent):
            raise _Fail('%s names no agent' % name)
        for field, value in (('agent', dispatch.agent), ('model', dispatch.model)):
            if value is not None and not (isinstance(value, str) and _NAME.fullmatch(value)):
                raise _Invalid(field, value)
        prior = c.state_name(prior) if prior in c.states() else None
        run = _Run(c, c.action, dispatch, role, '', prior=prior, conflict=conflict,
                   stage=stage if stage is None else self._stage_name(stage))
        note = c.note()
        card = self._read_card(c)
        inputs = {'number': c.n, 'title': card.get('title'), 'body': card.get('body'),
                  'acceptance': ''.join('- %s\n' % a for a in card.get('acceptance') or []) or 'none',
                  'config': json.dumps(c.config, indent=2, sort_keys=True), 'scripts': str(self.plugin_dir / 'scripts')}
        if role == 'implementor':
            inputs.update(worktree=c.worktree(), branch=c.branch())
            if name == 'continue_implementor':
                inputs['note'] = note
            run.round = note.get('round') if isinstance(note.get('round'), int) else 0
        elif role == 'fixer':
            findings = conflict or self._severe((note.get('last_review') or {}).get('findings'))
            if not findings:
                raise _Fail('no Critical/Important findings to fix')
            inputs.update(pr=c.pr(note.get('pr')), worktree=c.worktree(), findings=self._lines(findings))
            run.round = note.get('round') if isinstance(note.get('round'), int) else 0
        else:
            self._review_inputs(c, run, note, card, inputs)
        if not run.script:
            run.prompt = run.base_prompt = role_prompt(role, inputs, c.tmp)
        run.attempts_before = c.attempts_before if role == 'implementor' else None
        self._launch(run)
        return 'session'

    @staticmethod
    def _stage_name(stage):
        name = stage.get('name')
        if not isinstance(name, str) or not _STAGE.fullmatch(name):
            raise _Invalid('stage', name)
        return name

    def _review_inputs(self, c, run, note, card, inputs):
        name, d, stage = c.row['action'], run.dispatch, run.stage
        pr = c.pr(note.get('pr'))
        run.round = 1 if name == 'start_review' else note.get('round') if _posint(note.get('round')) else 1
        last = note.get('last_review') if isinstance(note.get('last_review'), dict) else {}
        previous = last.get('sha') if isinstance(last.get('sha'), str) and _SHA.fullmatch(last['sha']) else None
        findings = self._severe(last.get('findings')) if run.round >= 2 else []
        report = self._latest_report(card)
        if d.runner in _SCRIPT_RUNNERS:
            return self._script_args(c, run, pr, previous, findings, report)
        data = _json(c.step('worktree.sh', 'review', c.n, pr).stdout)
        if not (isinstance(data, dict) and isinstance(data.get('path'), str) and os.path.isabs(data['path'])
                and isinstance(data.get('sha'), str) and _SHA.fullmatch(data['sha'])):
            raise _Fail('worktree.sh review printed an unexpected result')
        run.sha = data['sha']
        prev_sha = previous if (run.round >= 2 or stage) else data.get('base')
        if not (isinstance(prev_sha, str) and _SHA.fullmatch(prev_sha)):
            raise _Fail('no previous review sha for round %d' % run.round)
        diff = self.gh(self.root, 'pr', 'diff', str(pr), '--repo', c.repo())
        if diff.timed_out or diff.rc != 0:
            raise _Fail(_first_line(diff.stderr) or 'gh pr diff failed')
        inputs.update(pr=pr, diff=diff.stdout, report=report, worktree=data['path'], round=run.round,
                      prev_sha=prev_sha, findings=self._lines(findings))
        if stage:
            inputs.update(stage_name=stage, brief=c.row['stage'].get('brief'),
                          post='Check and post your report in one Bash call: `bash %s/parse-report.sh --role '
                               'stage-reviewer <path> && bash %s/board-comment.sh %d <path>`'
                               % (inputs['scripts'], inputs['scripts'], c.n))

    def _script_args(self, c, run, pr, previous, findings, report):
        """argv tail for evidence-review.sh / stage-review.sh (the provider scripts post their own report)."""
        stage, args = run.stage, [c.n, pr]
        if stage:
            head = self.gh(self.root, 'pr', 'view', str(pr), '--repo', c.repo(), '--json', 'headRefOid', '--jq',
                           '.headRefOid')
            run.sha = head.stdout.strip()
            if head.timed_out or head.rc != 0 or not _SHA.fullmatch(run.sha):
                raise _Fail(_first_line(head.stderr) or 'could not read the PR head')
            if previous is None:
                raise _Fail('no previous review sha for stage %s' % stage)
            args += ['--stage', stage, '--round', run.round, '--prev-sha', previous]
            if run.round >= 2:
                args += ['--findings', c._file(findings)]
            args += ['--impl-report', c._file(report)]
        else:
            args += ['--round', run.round, '--impl-report', c._file(report)]
            if run.round >= 2:
                if previous is None:
                    raise _Fail('no previous review sha for round %d' % run.round)
                args += ['--prev-sha', previous, '--findings', c._file(findings)]
        run.stage_args = args

    def _launch(self, run):
        c, d = run.c, run.dispatch
        sup = c.config.get('supervisor') or {}
        env = dict(os.environ)
        env.update(self.env)
        env.setdefault('FLEET_BOARD_RUN_ID', str(self.state.run_id))
        argv = self.roles.command(d, run.prompt, c.config, self.plugin_dir, stage_args=run.stage_args)
        mode = None if run.script else ((c.config.get('headless') or {}).get('permission_mode') or 'auto')
        label = 'card-%d-%s-%d-%d' % (c.n, c.row['action'], int(self.clock() * 1000), run.attempt)
        try:
            run.action.session = self.roles.launch(
                argv, root=self.root, log_dir=self.log_dir, label=label, env=env,
                attempt_timeout=sup.get('attempt_timeout_seconds'),
                progress_timeout=None if run.script else sup.get('progress_timeout_seconds'),
                permission_mode=mode,
                kill_grace=sup.get('shutdown_grace_seconds', getattr(self.roles, 'DEFAULT_KILL_GRACE', 5.0)),
                stage=run.script)
        except BaseException:
            self._give_back_attempt(run)   # no session ever existed: the card was not tried
            raise
        self._runs[c.n] = run

    def _give_back_attempt(self, run):
        """Undo the implementor attempt charged before dispatch (a provider failure is not the card's)."""
        if run.attempts_before is None:
            return
        try:
            run.c.merge({'implementor_attempts': run.attempts_before})
        except _Fail as exc:
            run.c.warn('could not give back the implementor attempt: ' + str(exc))

    # report reconciliation (manager.md section 3) -----------------------------------------------------------
    def finish(self, action, result, allow_redispatch=True):
        """Check a finished role's report and apply it. Returns an Outcome; `redispatch=True` means the report
        was rejected and `action.session` is a new session (the action stays active)."""
        run = self._runs.get(action.card)
        if run is None or run.action is not action:
            raise ValueError('no role session for card %r' % (action.card,))
        c = run.c
        self._record_usage(run, result)
        try:
            outcome = self._reconcile(run, result, allow_redispatch)
        except _Fail as exc:
            self._failed(c, action.action, str(exc))
            outcome = Outcome(c.n, False, False, None)
        except BaseException:
            self._release(run)
            raise
        if not outcome.redispatch:
            self._release(run)
        return outcome

    def _release(self, run):
        self._runs.pop(run.c.n, None)
        if run.c.n in self.state.active:
            self.state.end(run.c.n)
        shutil.rmtree(run.c.tmp, ignore_errors=True)

    def _record_usage(self, run, result):
        """The one place Phase 3 appends a token line to `self.ledger` (result.usage); nothing is recorded yet."""
        return None

    def _reconcile(self, run, result, allow):
        c = run.c
        if result.cancelled:
            return Outcome(c.n, False, False, None)
        if result.failure == 'provider':
            self.state.event('provider_failure', card=c.n, provider=run.dispatch.provider, reason=result.reason)
            self._give_back_attempt(run)
            return Outcome(c.n, False, False, run.dispatch.provider)
        if run.script:
            return self._reconcile_script(run, result)
        if result.failure:
            raise _Fail(result.reason or 'the role failed')
        return self._check(run, self._file_report(c, result.report_text or ''), allow)

    @staticmethod
    def _file_report(c, text):
        return c._file(text)

    def _error_lines(self, result):
        try:
            text = Path(result.log_path).with_suffix('.err').read_text(errors='replace')
        except OSError:
            return []
        return [_first_line(line) for line in text.splitlines() if line.strip()][-20:]

    def _reconcile_script(self, run, result):
        c, code = run.c, result.exit_code
        lines = self._error_lines(result)
        last = lines[-1] if lines else ''
        if result.failure:
            if result.timed_out or code not in (2, 6, 7):
                raise _Fail(last or result.reason or 'exit %s' % code)
            if code == 2:
                return self._driver_bug(run, last)
            if code == 6:
                return self._rejected_twice(run, lines, last or 'report rejected twice')
            return self._block_stage(run, last)
        data = _json(result.report_text)
        report = data.get('report_file') if isinstance(data, dict) else None
        if not isinstance(report, str) or not report:
            raise _Fail('%s printed no report_file' % run.dispatch.runner)
        return self._check(run, report, False, script=data)

    def _driver_bug(self, run, message):
        self.state.event('action_failed', card=run.c.n, action=run.c.row['action'], error='driver bug: ' + message)
        self.state.pause('driver bug: ' + message)
        return Outcome(run.c.n, False, False, None)

    def _rejected_twice(self, run, lines, message):
        c = run.c
        entry = {'role': run.role, 'round': run.round if run.round is not None else 0,
                 'at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(self.clock())), 'errors': lines[:20]}
        self.state.event('action_failed', card=c.n, action=c.row['action'], error=message)
        c.merge(dict(c.failure_patch(message), report_errors=[entry]))
        return Outcome(c.n, False, False, None)

    def _commits_since_review(self, run):
        """`--commits-since-review <n>` for a fixer report (a not_reproducible fixer must have committed nothing)."""
        if run.role != 'fixer' or run.conflict:
            return []
        sha = (run.c.note().get('last_review') or {}).get('sha')
        if not (isinstance(sha, str) and _SHA.fullmatch(sha)):
            return []
        result = self.git(run.c.worktree(), 'rev-list', '--count', sha + '..HEAD')
        count = result.stdout.strip()
        return ['--commits-since-review', count] if result.rc == 0 and count.isdigit() else []

    def _check(self, run, report, allow, script=None):
        c = run.c
        flags = self._commits_since_review(run) if script is None else []
        result = c.soft('parse-report.sh', '--role', run.role, *(flags + [report]))
        if result.timed_out:
            raise _Fail('parse-report.sh timed out')
        lines = [line for line in result.stderr.splitlines() if line.strip()]
        if result.rc == 2:
            return self._driver_bug(run, _first_line(result.stderr))
        if result.rc == 1:
            first = lines[0] if lines else 'parse-report rejected the report'
            if script is not None:
                return self._rejected_twice(run, lines, first)
            if run.attempt == 2:
                return self._rejected_twice(run, lines, '%s report rejected twice: %s' % (run.role, first))
            if not allow:
                raise _Fail('%s report rejected: %s' % (run.role, first))
            run.prompt = run.base_prompt + '\n' + rejection_text(lines) + '\n'
            run.attempt = 2
            self._launch(run)
            return Outcome(c.n, False, True, None)
        parsed = _json(result.stdout) if result.rc == 0 else None
        if not isinstance(parsed, dict):
            raise _Fail('parse-report.sh exited %d' % result.rc if result.rc else 'parse-report.sh printed no JSON')
        self._apply(run, parsed, script)
        return Outcome(c.n, True, False, None)

    def _review_record(self, run, parsed, script):
        counts = parsed.get('counts') or {}
        d, stage = run.dispatch, run.stage
        if script is not None:
            sha, provider, model, agent = run.sha if stage else script.get('sha'), script.get('provider'), \
                script.get('model'), None
        elif stage:
            sha, provider, model, agent = run.sha, None, d.model, d.agent
        else:
            sha, provider, model, agent = run.sha, None, None, None
        return {'round': run.round, 'sha': sha, 'critical': counts.get('critical', 0),
                'important': counts.get('important', 0), 'findings': parsed.get('findings') or [],
                'stage': stage, 'agent': agent, 'model': model, 'provider': provider}

    def _apply(self, run, parsed, script):
        """Section 3.6 in order: last_verified, last_review, pr, blocked handling, follow-ups; then the action's
        own effect (round + 1, the conflict reset, last_fix) folded into the last merge with the counter reset."""
        c, role, status = run.c, run.role, parsed.get('status')
        note = c.note()
        patch = {'last_verified': (parsed.get('verified') or {}).get('line')}
        final = dict(_RESET)
        if role in ('reviewer', 'stage-reviewer'):
            patch['last_review'] = self._review_record(run, parsed, script)
            if not run.stage and isinstance(c.row.get('models'), dict):
                final['models'] = c.row['models']
        if role == 'implementor' and _posint(parsed.get('pr')):
            patch['pr'] = parsed['pr']
        c.merge(patch)
        if status == 'blocked':
            self._blocked(run, parsed, final)
        self._followups(run, parsed, note)
        if status == 'done' and role == 'fixer':
            if run.conflict:
                self._conflict_done(run, final)
            else:
                final.update(round=(note.get('round') if isinstance(note.get('round'), int) else 0) + 1,
                             **c.models_patch(strict=False))
                if c.row.get('escalated'):
                    final.update(escalated=True, escalated_at_round=final['round'])
        elif status == 'not_reproducible':
            final['last_fix'] = {'status': 'not_reproducible', 'round': run.round}
        (c.merge if role == 'fixer' else c.merge_soft)(final)

    def _blocked(self, run, parsed, final):
        c = run.c
        prior = run.prior if run.prior in c.states() else None
        if prior is None:
            raise _Invalid('state', run.prior)
        blocked_by = parsed.get('blocked_by')
        reason = (parsed.get('for_the_card') or '').strip() or 'the %s reported blocked' % run.role
        if run.conflict:
            c.merge({'blocked_from': prior, 'blocked_findings': run.conflict,
                     'blocking_pr': blocked_by if _posint(blocked_by) else None})
            c.move('blocked')
            c.comment_soft('Blocked: the fixer could not resolve the merge conflicts (%s).\n\n%s'
                           % (', '.join(f['text'] for f in run.conflict), reason))
        elif _posint(blocked_by):
            c.merge({'blocking_pr': blocked_by, 'blocked_from': prior})
            c.move('blocked')
        else:
            entries = self._severe(parsed.get('findings')) or [{'severity': 'Important', 'text': reason}]
            c.merge({'blocked_from': prior, 'blocked_findings': entries})
            c.move('blocked')
            c.comment_soft('Blocked by the %s.\n\n%s' % (run.role, '\n'.join(
                '- [%s] %s' % (e['severity'], e['text']) for e in entries)))
        final['state'] = 'blocked'

    def _conflict_done(self, run, final):
        c = run.c
        pr, worktree = c.pr(c.note().get('pr')), c.worktree()
        remote = self.gh(self.root, 'pr', 'view', str(pr), '--repo', c.repo(), '--json', 'headRefOid', '--jq',
                         '.headRefOid')
        local = self.git(worktree, 'rev-parse', 'HEAD')
        remote_head, local_head = remote.stdout.strip(), local.stdout.strip()
        if remote.timed_out or remote.rc != 0 or local.rc != 0 or not remote_head:
            raise _Fail('could not verify the pushed resolution on the PR head')
        if remote_head != local_head:
            raise _Fail('the PR head %s does not hold the fixer\'s pushed resolution %s'
                        % (remote_head[:7], local_head[:7]))
        c.step('review-stages.sh', 'route', c.n, pr)
        c.move('in_review')
        final.update(state='in_review', conflicted_files=None, last_review=None, round=1, stage=None,
                     reviewed_stages=[], blocking_pr=None, blocked_from=None, blocked_findings=[])

    def _block_stage(self, run, line):
        """Provider stage exit 7: the diff is unusable, so block the card from review_<stage>."""
        c = run.c
        c.move('blocked')
        entries = [{'severity': 'Important', 'text': line or 'stage review refused the diff'}]
        c.merge({'blocked_from': 'review_' + run.stage, 'blocked_findings': entries})
        c.merge_soft(dict(_RESET, state='blocked'))
        c.comment_soft('Blocked: %s' % entries[0]['text'])
        return Outcome(c.n, True, False, None)

    def _followups(self, run, parsed, note):
        c = run.c
        pending = note.get('pending_followups') if isinstance(note.get('pending_followups'), dict) else {}
        oos = _union(pending.get('out_of_scope') or [], parsed.get('out_of_scope') or [])
        bugs = _union(pending.get('bugs') or [], parsed.get('bugs') or [])
        if not oos and not bugs:
            return
        pr = note.get('pr') or parsed.get('pr') or pending.get('pr') or c.row.get('pr')
        if pr is None:
            c.warn('follow-ups on #%d wait for a PR' % c.n)
            c.merge_soft({'pending_followups': {'out_of_scope': oos, 'bugs': bugs, 'pr': None}})
            return
        if not _posint(pr):
            raise _Invalid('pr', pr)
        result = c.soft('file-followups.sh', c.n, pr, c._file({'out_of_scope': oos, 'bugs': bugs}))
        printed = None if result.timed_out else _json(result.stdout)
        printed = printed if isinstance(printed, dict) else None
        if result.rc == 0 and not result.timed_out and printed is not None:
            c.merge_soft({'out_of_scope_created': printed.get('out_of_scope_created') or [],
                          'bugs_filed': printed.get('bugs_filed') or [], 'pending_followups': None})
            return
        scope, filed = (printed or {}).get('out_of_scope_created') or [], (printed or {}).get('bugs_filed') or []
        left_oos, left_bugs = _left(oos, scope), _left(bugs, filed)
        c.warn('file-followups.sh filed only part of the follow-ups on #%d: %s'
               % (c.n, 'timed out' if result.timed_out else _first_line(result.stderr) or 'exit %d' % result.rc))
        c.merge_soft({'out_of_scope_created': scope, 'bugs_filed': filed,
                      'pending_followups': {'out_of_scope': left_oos, 'bugs': left_bugs, 'pr': pr}
                      if left_oos or left_bugs else None})

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
        summary = (self._qa_summary(command, worktree) if isinstance(command, str) and command.strip()
                   else 'No QA build is configured.\n')
        flags = ['--qa-summary', c._file(summary)]
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
            if patch:
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

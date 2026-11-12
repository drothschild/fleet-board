"""The merge lane: one card at a time through `merge-reviewed.sh --no-finish` in its keyed form.

`MergeLane.start` moves the card to `merging`, spawns the merge as a child process (its own process group)
and returns at once; the loop calls `poll()` each cycle. When the child ends, `poll()` classifies the
result (the script's exit code plus `--inspect` evidence) as a MergeOutcome. The merge is never killed:
neither `stop --cancel` nor a second Ctrl-C reaches it, the loop waits for `poll()` to return.
"""
import json
import re
import tempfile
import time
from collections import namedtuple
from pathlib import Path

from . import markers, scripts
from .state import Action

MergeOutcome = namedtuple('MergeOutcome', 'card kind detail')
# kind: merged | refused | unclear | verify_failed | not_attempted (exit 0, no marker, the PR still open at the
# planned head: the fresh plan inside merge-reviewed.sh skipped the card, so nothing was merged)
NOT_ATTEMPTED = 'merge not attempted: planner skipped'
# a card entering merging from another column drops the merge records of an earlier stay
_STALE = {'merge_refusal': None, 'merge_retry': None, 'pending_merge': None, 'merger': None}

_SHA = re.compile(r'[0-9a-fA-F]{4,64}')
_KEY = re.compile(r'[^A-Za-z0-9._:-]')
_CONTROL = re.compile(r'[\x00-\x1f\x7f]')
INSPECT_TIMEOUT = 120


def _posint(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _line(text):
    for line in (text or '').splitlines():
        line = _CONTROL.sub(' ', line).strip()
        if line:
            return line[:300]
    return ''


def _json(text):
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return None


def _gh(root, *args):
    return scripts.run_argv(root, ['gh'] + [str(a) for a in args], timeout=60)


def _same_head(left, right):
    return (isinstance(left, str) and isinstance(right, str) and left != '' and right != ''
            and (left.lower().startswith(right.lower()) or right.lower().startswith(left.lower())))


class MergeLane:
    def __init__(self, root, state, run=scripts.run, spawn=scripts.spawn, gh=None, repo=None, clock=time.time,
                 board_dir=None):
        self.root, self.state, self.run, self.spawn, self.clock = Path(root), state, run, spawn, clock
        self.gh = gh or _gh
        self.repo = repo           # a "owner/name" string or a callable returning one (for the required-check lookup)
        self.board_dir = board_dir  # board.dir (a string or a callable returning one): where the active marker goes
        self._seq = 0
        self._child = None         # (handle, action, candidate) while a merge runs

    @property
    def busy(self):
        return self._child is not None

    def start(self, candidate):
        number, pr, head = candidate.get('number'), candidate.get('pr'), candidate.get('head_sha')
        if not _posint(number) or not _posint(pr) or not isinstance(head, str) or not _SHA.fullmatch(head):
            raise ValueError('invalid merge candidate: card %r, pr %r, head %r' % (number, pr, head))
        if self._child is not None:
            raise ValueError('merge lane taken')
        self._seq += 1
        key = '%s-%d-%d' % (_KEY.sub('_', str(self.state.run_id))[:80], number, self._seq)
        column = candidate.get('state')
        board_dir = self.board_dir() if callable(self.board_dir) else self.board_dir
        action = Action(card=number, action='merge', column=column, role=None, provider='scripts',
                        paths=list(candidate.get('declared_paths') or []), started_at=self.clock(),
                        started_mono=time.monotonic(), kind='merge', work_column='merging', marker=markers.path(self.root, board_dir, number))
        self.state.begin(action)
        try:
            if column != 'merging':
                # moved out of merging by hand and back: a refusal, retry, marker or merger result of the
                # earlier stay must not steer this merge (a stale merge_refusal would plan merge_refusal)
                stale = {key: None for key, value in self._note(number).items() if key in _STALE and value is not None}
                if stale:
                    self._merge_note(number, stale)
                self._step('board-move.sh', number, 'merging')
            self._merge_note(number, {'state': 'merging'})
            handle = self.spawn(self.root, 'merge-reviewed.sh', '--no-finish', '--card', number,
                                '--operation-key', key, '--pr', pr, '--head', head)
        except BaseException:
            self.state.end(number)
            raise
        self._child = (handle, action, dict(candidate, operation_key=key))
        self._own_marker(action, getattr(handle, 'pid', None))
        self.state.event('merge_started', card=number, pr=pr, head=head, operation_key=key)
        return action

    def _own_marker(self, action, pgid):
        """The merge child owns the card's active marker until it ends (State.end removes it)."""
        if type(pgid) is not int or pgid <= 1:
            return
        board_dir = self.board_dir() if callable(self.board_dir) else self.board_dir
        try:
            action.marker = markers.write(self.root, board_dir, action.card, pgid)
            action.pgid = pgid
        except OSError as exc:
            self.state.event('warning', card=action.card, message='active marker not written: %s' % exc)

    def poll(self):
        """None while the merge runs; the MergeOutcome once it has ended (the lane is free again)."""
        if self._child is None:
            return None
        handle, action, candidate = self._child
        result = handle.poll()
        if result is None:
            return None
        self._child = None
        try:
            return self._classify(action.card, candidate, result)
        except Exception as exc:  # noqa: BLE001 - an unreadable result is an unclear one, never a crash
            return MergeOutcome(action.card, 'unclear', self._detail(candidate, result, error=str(exc)))
        finally:
            self.state.end(action.card)

    # --- classification ------------------------------------------------------------------------------
    @staticmethod
    def _detail(candidate, result, **extra):
        detail = {'pr': candidate['pr'], 'head': candidate['head_sha'], 'rc': result.rc,
                  'reason': _line(result.stderr) or _line(result.stdout) or 'merge-reviewed.sh exited %d' % result.rc,
                  'ignored_checks': candidate.get('ignored_checks') or []}
        detail.update(extra)
        return detail

    def _inspect(self, number, candidate):
        done = self.run(self.root, 'merge-reviewed.sh', '--inspect', '--card', number, '--operation-key',
                        candidate['operation_key'], '--pr', candidate['pr'], '--head', candidate['head_sha'],
                        timeout=INSPECT_TIMEOUT)
        data = _json(done.stdout) if done.rc == 0 and not done.timed_out else None
        return data if isinstance(data, dict) and data.get('status') in ('observed', 'absent') else None

    def _classify(self, number, candidate, result):
        detail = self._detail(candidate, result)
        if result.timed_out or result.rc not in (0, 1, 3):
            return MergeOutcome(number, 'unclear', detail)
        evidence = self._inspect(number, candidate)
        seen = evidence if evidence and evidence.get('status') == 'observed' else None
        check = seen.get('main_check') if seen else None
        if result.rc == 0:
            if isinstance(check, dict) and check.get('ok') is True:
                return MergeOutcome(number, 'merged', dict(detail, main_check=check))
            # no marker and the PR still open at the planned head: the script's fresh plan skipped the card
            if (evidence and evidence.get('status') == 'absent' and evidence.get('state') == 'OPEN'
                    and _same_head(evidence.get('observed_head'), candidate['head_sha'])
                    and _same_head(evidence.get('planned_head'), candidate['head_sha'])):
                return MergeOutcome(number, 'not_attempted', dict(detail, reason=NOT_ATTEMPTED))
            return MergeOutcome(number, 'unclear', detail)
        if result.rc == 3 and isinstance(check, dict) and check.get('ok') is False:
            return MergeOutcome(number, 'verify_failed', dict(detail, main_check=check))
        if seen and seen.get('state') == 'OPEN' and _same_head(seen.get('observed_head'), seen.get('planned_head')):
            required = self._required_check(candidate['pr'])
            if required:
                detail['required_check'] = required
            try:
                refusal = {'pr': candidate['pr'], 'head': candidate['head_sha'], 'reason': detail['reason'],
                           'at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(self.clock()))}
                if required:
                    refusal['required_check'] = required
                self._merge_note(number, {'merge_refusal': refusal})
            except Exception as exc:  # noqa: BLE001 - an unrecorded refusal would be re-planned every cycle
                return MergeOutcome(number, 'unclear', dict(detail, error='refusal not recorded: %s' % exc))
            return MergeOutcome(number, 'refused', detail)
        return MergeOutcome(number, 'unclear', detail)

    def _required_check(self, pr):
        repo = self.repo() if callable(self.repo) else self.repo
        if not isinstance(repo, str) or not repo:
            return None
        try:
            done = self.gh(self.root, 'pr', 'checks', str(pr), '--repo', repo, '--required', '--json', 'name,bucket')
        except OSError:
            return None
        rows = _json(done.stdout)   # gh exits non-zero while a required check fails; the JSON is still printed
        for row in rows if isinstance(rows, list) else ():
            if isinstance(row, dict) and row.get('bucket') == 'fail' and isinstance(row.get('name'), str):
                return _CONTROL.sub(' ', row['name'])[:200]
        return None

    # --- board and note writes -----------------------------------------------------------------------
    def _step(self, name, *args):
        done = self.run(self.root, name, *args)
        if done.timed_out or done.rc != 0:
            raise RuntimeError(_line(done.stderr) or '%s %s' % (name, 'timed out' if done.timed_out else 'failed'))
        return done

    def _note(self, number):
        data = _json(self._step('note.sh', 'get', number).stdout)
        if not isinstance(data, dict):
            raise RuntimeError('note.sh get %d printed no note' % number)
        return data

    def _merge_note(self, number, patch):
        with tempfile.TemporaryDirectory(prefix='fleet-merge-') as tmp:
            path = Path(tmp) / 'patch.json'
            path.write_text(json.dumps(patch))
            self._step('note.sh', 'merge', number, str(path))

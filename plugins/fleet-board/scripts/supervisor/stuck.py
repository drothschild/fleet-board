"""The startup check: what a supervisor that died left half done.

`find` is read-only (the board server calls it while a supervisor runs, passing that supervisor's live cards).
`record` writes the "stuck" note, `release` returns one card to its last stable column. Nothing here repairs
work and nothing touches git (no branch, worktree or PR is changed).
"""
import json
import os
import re
import tempfile
import time
from collections import namedtuple
from pathlib import Path

from . import scripts

Stuck = namedtuple('Stuck', 'card kind detail')

KINDS = ('in_flight', 'marker', 'dirty_worktree', 'dead_lock')
FIXED_BEFORE = ('backlog', 'ready', 'in_progress', 'in_review')
FIXED_AFTER = ('merging', 'human_qa', 'blocked', 'done', 'wont_do')
CHECKED = ('ready', 'in_progress', 'in_review', 'merging', 'human_qa', 'blocked')   # cards whose worktree is checked
MERGE_RECORDS = ('merge_operation', 'merge_refusal', 'merger')
MERGE_KEYS = ('pending_merge', 'merge_refusal', 'merge_retry', 'merger')
LOCK_GRACE = 10     # seconds a lock may have no pid file (its holder is between mkdir and writing it)
_LOCK = re.compile(r'card-(\d+)\.lock')
_PR = re.compile(r'/pull/(\d+)')


def _iso(seconds=None):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() if seconds is None else seconds))


def _json(result, what):
    if result.timed_out or result.rc != 0:
        lines = [x.strip() for x in (result.stderr or '').splitlines() if x.strip()]
        raise ValueError('%s failed: %s' % (what, lines[-1] if lines else 'exit %d' % result.rc))
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise ValueError('%s printed invalid JSON' % what) from None


def _config(root, run):
    config = _json(run(root, 'config.sh', '--dir', str(root), timeout=30), 'config.sh')
    if not isinstance(config, dict):
        raise ValueError('config.sh printed no configuration')
    return config


def _dirs(root, config):
    board = (config.get('board') or {}).get('dir') or '.fleet-board'
    worktrees = (config.get('worktrees') or {}).get('dir') or '../.fleet-worktrees'
    return Path(root) / board, Path(os.path.normpath(str(Path(root) / worktrees)))


def _states(config):
    stages = ['review_' + s['name'] for s in (config.get('review') or {}).get('stages') or []
              if isinstance(s, dict) and isinstance(s.get('name'), str)]
    return list(FIXED_BEFORE) + stages + list(FIXED_AFTER)


def _cards(root, config, run):
    """[(number, state)] for every card, read through board-list.sh --all (one array per state, in order)."""
    result = run(root, 'board-list.sh', '--all', timeout=60)
    if result.timed_out or result.rc != 0:
        _json(result, 'board-list.sh')
    states = _states(config)
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if len(lines) != len(states):
        raise ValueError('board-list.sh printed %d lists for %d states' % (len(lines), len(states)))
    out = []
    for state, line in zip(states, lines):
        for item in json.loads(line):
            if type(item.get('number')) is int:
                out.append((item['number'], state))
    return sorted(out)


def _note(root, card, run):
    note = _json(run(root, 'note.sh', 'get', card, timeout=60), 'note.sh get #%d' % card)
    return note if isinstance(note, dict) else {}


def _merge_in_flight(note):
    """A merge was in flight at the crash: pending_merge is set and nothing records how it ended."""
    return isinstance(note.get('pending_merge'), dict) and not any(note.get(k) for k in MERGE_RECORDS)


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _lock_dead(path, grace=LOCK_GRACE):
    """True when the holder named in <lock>/pid is not running, or the lock has no usable pid and has been
    that way for longer than `grace` seconds."""
    try:
        pid = int((Path(path) / 'pid').read_text().strip())
        if pid > 0:
            return not _pid_alive(pid)
    except (OSError, ValueError):
        pass
    try:
        return time.time() - os.stat(str(path)).st_mtime >= grace
    except OSError:
        return False


def _dirty(root, worktree, run_argv):
    if not isinstance(worktree, str) or not os.path.isdir(worktree):
        return None
    result = run_argv(root, ['git', '-C', worktree, 'status', '--porcelain'], timeout=60)
    if result.timed_out or result.rc != 0:
        return None
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if not lines:
        return None
    return '%d uncommitted change%s in %s (%s)' % (len(lines), '' if len(lines) == 1 else 's', worktree,
                                                    ', '.join(line.strip() for line in lines[:3])
                                                    + (', ...' if len(lines) > 3 else ''))


def find(root, live_cards=frozenset(), run=scripts.run, run_argv=scripts.run_argv):
    """Everything a dead supervisor left behind, as a list of Stuck (a card may appear more than once).
    `live_cards` are the cards a running supervisor owns: they are never reported. Writes nothing."""
    live = set(live_cards)
    config = _config(root, run)
    board_dir, worktrees = _dirs(root, config)
    found = []
    if (board_dir / 'next').is_file():
        for card, state in _cards(root, config, run):
            if card in live or state not in CHECKED:
                continue
            note = _note(root, card, run)
            if state == 'in_progress':
                found.append(Stuck(card, 'in_flight', 'in progress, and no supervisor session owns it'))
            elif state == 'merging' and _merge_in_flight(note):
                found.append(Stuck(card, 'in_flight', 'in merging with a merge in flight (pending_merge for PR %s) '
                                   'and no record of how it ended' % (note['pending_merge'].get('pr'),)))
            detail = _dirty(root, note.get('worktree'), run_argv)
            if detail:
                found.append(Stuck(card, 'dirty_worktree', detail))
    try:
        markers = sorted(int(p.name) for p in (board_dir / 'active').iterdir() if p.name.isdigit())
    except OSError:
        markers = []
    for card in markers:
        if card not in live:
            found.append(Stuck(card, 'marker', 'active marker %s is present and no supervisor session owns it'
                               % (board_dir / 'active' / str(card))))
    try:
        locks = sorted((int(m.group(1)), p) for p in (worktrees / '.locks').iterdir()
                       for m in [_LOCK.fullmatch(p.name)] if m and p.is_dir())
    except OSError:
        locks = []
    for card, path in locks:
        if card not in live and _lock_dead(path):
            found.append(Stuck(card, 'dead_lock', 'lock %s is held by a process that is not running' % path))
    return sorted(found, key=lambda s: (s.card, KINDS.index(s.kind)))


def _patch(root, card, patch, run):
    with tempfile.TemporaryDirectory(prefix='fleet-stuck-') as tmp:
        path = Path(tmp) / 'patch.json'
        path.write_text(json.dumps(patch))
        result = run(root, 'note.sh', 'merge', card, str(path), timeout=60)
    if result.timed_out or result.rc != 0:
        _json(result, 'note.sh merge #%d' % card)


def record(root, found, now=None, run=scripts.run):
    """Write {"stuck": {"kind", "detail", "at"}} on each card in `found` (kind of its first finding, the details
    joined). Returns the cards whose note could not be written (a lock for a card that does not exist)."""
    at = _iso(now)
    by_card = {}
    for item in found:
        by_card.setdefault(item.card, []).append(item)
    failed = []
    for card, items in sorted(by_card.items()):
        try:
            _patch(root, card, {'stuck': {'kind': items[0].kind, 'detail': '; '.join(i.detail for i in items),
                                          'at': at}}, run)
        except ValueError:
            failed.append(card)
    return failed


def _read(root, card, run):
    result = run(root, 'board-read.sh', card, timeout=60)
    if result.timed_out or result.rc != 0:
        raise ValueError('card #%d not found' % card)
    data = _json(result, 'board-read.sh #%d' % card)
    return data if isinstance(data, dict) else {}


def snapshot(root, found, run=scripts.run):
    """{card: its column now} for the cards in `found`: what `start --ignore-stuck` leaves alone."""
    out = {}
    for card in sorted({i.card for i in found}):
        try:
            out[card] = _read(root, card, run).get('state')
        except ValueError:
            out[card] = None
    return out


def unresolved(root, ignored, run=scripts.run):
    """The ignored cards that are still stuck: a card is resolved once its stuck note is cleared (release) or
    a person moved it out of the column it was found in. A card that cannot be read stays ignored."""
    keep = {}
    for card, column in ignored.items():
        try:
            if _read(root, card, run).get('state') == column and _note(root, card, run).get('stuck'):
                keep[card] = column
        except ValueError:
            keep[card] = column
    return keep


def _pr_number(card, note):
    pending = note.get('pending_merge')
    for value in (pending.get('pr') if isinstance(pending, dict) else None, note.get('pr')):
        if type(value) is int and value > 0:
            return value
    match = _PR.search(str(card.get('pr_url') or ''))
    return int(match.group(1)) if match else None


def _gh_state(run_argv):
    def state(root, pr, repo):
        result = run_argv(root, ['gh', 'pr', 'view', str(pr), '--repo', repo, '--json', 'state', '--jq', '.state'],
                          timeout=60)
        return result.stdout.strip() if not result.timed_out and result.rc == 0 else None
    return state


def release(root, card, run=scripts.run, gh=None, run_argv=scripts.run_argv):
    """Return `card` to its last stable column, clear its marker, a dead lock and its stuck note. Never touches
    git. in_progress goes to ready (no PR) or in_review; merging whose PR is merged stays in merging, else it
    drops its merge records and goes to in_review. Raises ValueError and changes nothing when the card is
    unknown or a merging card's PR state cannot be read."""
    if type(card) is not int or card <= 0:
        raise ValueError('card must be a positive integer')
    data = _read(root, card, run)
    note = _note(root, card, run)
    config = _config(root, run)
    board_dir, worktrees = _dirs(root, config)
    lock = worktrees / '.locks' / ('card-%d.lock' % card)
    if lock.is_dir() and not _lock_dead(lock, grace=0):
        raise ValueError('card #%d is locked by a running process (%s)' % (card, lock))
    state = data.get('state')
    pr = _pr_number(data, note)
    patch, target = {'stuck': None}, None
    if state == 'in_progress':
        target = 'in_review' if pr else 'ready'
    elif state == 'merging':
        if pr is None:
            raise ValueError('card #%d is in merging with no PR on record; move it by hand' % card)
        repo = (config.get('board') or {}).get('repo') or ''
        pr_state = (gh or _gh_state(run_argv))(root, pr, repo)
        if pr_state == 'MERGED':
            pass   # the planner plans after_merge for it
        elif pr_state == 'OPEN':
            patch.update({key: None for key in MERGE_KEYS})
            target = 'in_review'
        else:
            raise ValueError('cannot tell whether PR %d of card #%d is merged (gh said %r)' % (pr, card, pr_state))
    if lock.is_dir():   # a dead holder's lock would block the move and the note write: they wait on it
        for child in lock.iterdir():
            child.unlink()
        lock.rmdir()
    if target:
        moved = run(root, 'board-move.sh', card, target, timeout=60)
        if moved.timed_out or moved.rc != 0:
            _json(moved, 'board-move.sh #%d %s' % (card, target))
    _patch(root, card, patch, run)
    try:
        (board_dir / 'active' / str(card)).unlink()
    except OSError:
        pass

"""The startup check: what a supervisor that died left half done.

`find` is read-only (the board server calls it while a supervisor runs, passing that supervisor's live cards).
`record` writes the "stuck" note, `release` returns one card to its last stable column. Nothing here repairs
work and nothing touches git (no branch, worktree or PR is changed).
"""
import json
import os
import re
import subprocess
import tempfile
import time
from collections import namedtuple
from pathlib import Path

from . import markers, scripts

Stuck = namedtuple('Stuck', 'card kind detail')

KINDS = ('unreadable_note', 'in_flight', 'live_orphan', 'marker', 'dirty_worktree', 'unreadable_worktree',
         'dead_lock')
FIXED_BEFORE = ('backlog', 'ready', 'in_progress', 'in_review')
FIXED_AFTER = ('merging', 'human_qa', 'blocked', 'done', 'wont_do')
UNCHECKED = ('backlog', 'done', 'wont_do')   # every other state (review_<stage> included) has its card checked
MERGE_RECORDS = ('merge_operation', 'merge_refusal', 'merger')
MERGE_KEYS = ('pending_merge', 'merge_refusal', 'merge_retry', 'merger')
LOCK_GRACE = 20     # seconds a lock may have no pid file; board-lib.sh's FB_LOCK_PIDLESS_GRACE is the same value
_LOCK = re.compile(r'card-(\d+)\.lock')
_PR = re.compile(r'/pull/(\d+)')


def _iso(seconds=None):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() if seconds is None else seconds))


def _json(result, what, every_line=False):
    """`every_line`: the error names every stderr line, not only the last (config.sh prints one per problem)."""
    if result.timed_out or result.rc != 0:
        lines = [x.strip() for x in (result.stderr or '').splitlines() if x.strip()]
        if not lines:
            detail = 'exit %d' % result.rc
        else:
            detail = '\n'.join(lines) if every_line else lines[-1]
        raise ValueError('%s failed: %s' % (what, detail))
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise ValueError('%s printed invalid JSON' % what) from None


def _config(root, run):
    config = _json(run(root, 'config.sh', '--dir', str(root), timeout=30), 'config.sh', every_line=True)
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


def checked_states(config):
    """The states whose cards the check reads: every non-terminal state, the review stages included."""
    return [state for state in _states(config) if state not in UNCHECKED]


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


def _lock_grace():
    """LOCK_GRACE, or FLEET_BOARD_LOCK_PIDLESS_GRACE when it is a whole number (board-lib.sh reads it too)."""
    value = os.environ.get('FLEET_BOARD_LOCK_PIDLESS_GRACE', '')
    return int(value) if value.isdigit() else LOCK_GRACE


def _lock_dead(path, grace=None):
    """True when the holder named in <lock>/pid is not running, or the lock has no usable pid and has been
    that way for longer than `grace` seconds (default: the shared pid-less grace)."""
    grace = _lock_grace() if grace is None else grace
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


def _lock_pid(path):
    """The text of <lock>/pid, or None when it has none."""
    try:
        return (Path(path) / 'pid').read_text()
    except OSError:
        return None


def _fence(path):
    """Take the empty pid slot of a pid-less lock the way board-lib.sh's _fb_lock_own does: our pid written to
    a temp file and hard-linked onto <lock>/pid, which fails when pid exists. A slow holder whose own link comes
    later then fails instead of landing in a lock we are removing. False when the slot is already filled."""
    tmp = Path(path) / ('.pid.%d' % os.getpid())
    try:
        tmp.write_text('%d\n' % os.getpid())
        os.link(str(tmp), str(Path(path) / 'pid'))
        return True
    except FileExistsError:
        return False
    finally:
        try:
            tmp.unlink()
        except OSError:
            pass


def _live_claim(path):
    """True when <lock> holds a taker's claim.<k> link naming a running pid (board-lib.sh's fb_lock_acquire is
    mid-takeover of it: that taker removes the lock)."""
    try:
        children = list(Path(path).iterdir())
    except OSError:
        return False
    for child in children:
        if child.name.startswith('claim.') and child.is_symlink():
            try:
                pid = int(os.readlink(str(child)))
            except (OSError, ValueError):
                continue
            if pid > 0 and _pid_alive(pid):
                return True
    return False


def _dirty(root, worktree, run_argv):
    """(kind, detail) for a worktree with uncommitted changes to tracked files (`dirty_worktree`) or one whose
    status cannot be read (`unreadable_worktree`: never taken as clean), else None."""
    if not isinstance(worktree, str) or not os.path.isdir(worktree):
        return None
    result = run_argv(root, ['git', '-C', worktree, '--no-optional-locks', 'status', '--porcelain',
                             '--untracked-files=no'], timeout=60)
    if result.timed_out or result.rc != 0:
        lines = [x.strip() for x in (result.stderr or '').splitlines() if x.strip()]
        why = 'timed out' if result.timed_out else (lines[-1] if lines else 'exit %d' % result.rc)
        return 'unreadable_worktree', 'git status of %s failed (%s)' % (worktree, why[:200])
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if not lines:
        return None
    return 'dirty_worktree', '%d uncommitted change%s in %s (%s)' % (
        len(lines), '' if len(lines) == 1 else 's', worktree,
        ', '.join(line.strip() for line in lines[:3]) + (', ...' if len(lines) > 3 else ''))


def _head(root, repo, pr, run_argv):
    result = run_argv(root, ['gh', 'pr', 'view', str(pr), '--repo', repo, '--json', 'headRefOid', '--jq',
                             '.headRefOid'], timeout=60)
    return result.stdout.strip() if not result.timed_out and result.rc == 0 else None


def find(root, live_cards=frozenset(), run=scripts.run, run_argv=scripts.run_argv, head=None, cards=None):
    """Everything a dead supervisor left behind, as a list of Stuck (a card may appear more than once).
    `live_cards` are the cards a running supervisor owns: they are never reported. `cards` limits the check to
    those cards. Writes nothing."""
    live = set(live_cards)
    only = None if cards is None else set(cards)

    def skip(card):
        return card in live or (only is not None and card not in only)
    config = _config(root, run)
    board_dir, worktrees = _dirs(root, config)
    checked = checked_states(config)
    found = []
    if (board_dir / 'next').is_file():
        for card, state in _cards(root, config, run):
            if skip(card) or state not in checked:
                continue
            try:
                note = _note(root, card, run)
            except ValueError as exc:
                found.append(Stuck(card, 'unreadable_note', str(exc)))
                continue
            if state == 'merging' and _merge_in_flight(note):
                pending = note['pending_merge']
                current = (head or _head)(root, (config.get('board') or {}).get('repo') or '', pending.get('pr'),
                                          run_argv)
                if current and pending.get('head_sha') and current != pending.get('head_sha'):
                    note = dict(note, pending_merge=None)   # a stale marker for an earlier head: not in flight
            if state == 'in_progress' and not note.get('cancelled'):   # a cancel returned it here on purpose
                found.append(Stuck(card, 'in_flight', 'in progress, and no supervisor session owns it'))
            elif state == 'merging' and _merge_in_flight(note):
                found.append(Stuck(card, 'in_flight', 'in merging with a merge in flight (pending_merge for PR %s) '
                                   'and no record of how it ended' % (note['pending_merge'].get('pr'),)))
            dirty = None if note.get('stuck_released') else _dirty(root, note.get('worktree'), run_argv)
            if dirty:
                found.append(Stuck(card, *dirty))
    try:
        present = sorted(int(p.name) for p in (board_dir / 'active').iterdir() if p.name.isdigit())
    except OSError:
        present = []
    for card in present:
        if skip(card):
            continue
        path = board_dir / 'active' / str(card)
        pgid = markers.read_pgid(path)
        if markers.group_alive(pgid):
            found.append(Stuck(card, 'live_orphan', 'active marker %s names process group %d, which is still '
                               'running and no supervisor session owns it; stop that process group first '
                               '(kill -TERM -- -%d)' % (path, pgid, pgid)))
        else:
            found.append(Stuck(card, 'marker', 'active marker %s is present and no supervisor session owns it'
                               % path))
    try:
        locks = sorted((int(m.group(1)), p) for p in (worktrees / '.locks').iterdir()
                       for m in [_LOCK.fullmatch(p.name)] if m and p.is_dir())
    except OSError:
        locks = []
    for card, path in locks:
        if not skip(card) and _lock_dead(path):
            found.append(Stuck(card, 'dead_lock', 'lock %s is held by a process that is not running' % path))
    return sorted(found, key=lambda s: (s.card, KINDS.index(s.kind)))


def _patch(root, card, patch, run, wait=None):
    with tempfile.TemporaryDirectory(prefix='fleet-stuck-') as tmp:
        path = Path(tmp) / 'patch.json'
        path.write_text(json.dumps(patch))
        extra = {'env': {'FLEET_BOARD_LOCK_WAIT': str(wait)}} if wait is not None else {}
        result = run(root, 'note.sh', 'merge', card, str(path), timeout=60, **extra)
    if result.timed_out or result.rc != 0:
        _json(result, 'note.sh merge #%d' % card)


def record(root, found, now=None, run=scripts.run):
    """Write {"stuck": {"kind", "detail", "at"}} on each card in `found` (kind of its first finding, the details
    joined). A note write waits at most a second for a card lock (a dead holder's lock must not stall the start).
    Returns the cards whose note could not be written."""
    at = _iso(now)
    by_card = {}
    for item in found:
        by_card.setdefault(item.card, []).append(item)
    failed = []
    for card, items in sorted(by_card.items()):
        try:
            _patch(root, card, {'stuck': {'kind': items[0].kind, 'detail': '; '.join(i.detail for i in items),
                                          'at': at}}, run, wait=1)
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


def unresolved(ignored, found):
    """The ignored cards that are still stuck: those a fresh `find` still reports. A card is resolved when its
    finding is gone (released, moved by a person, marker or lock cleared), whatever its note says."""
    present = {item.card for item in found}
    return {card: column for card, column in ignored.items() if card in present}


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


def release(root, card, run=scripts.run, gh=None, run_argv=scripts.run_argv, force=False, live_cards=frozenset()):
    """Return `card` to its last stable column, clear its marker, a dead lock and its stuck note. Never touches
    git. in_progress goes to ready (no PR) or in_review; merging whose PR is merged stays in merging (recording
    merge_operation from pending_merge), open or closed drops its merge records and goes to in_review.

    Raises ValueError and changes nothing when the card is unknown, has no current finding (unless `force`),
    has a live orphan (a marker naming a process group that still runs: stop it first), is locked by a running
    process, or is a merging card whose PR state cannot be read."""
    if type(card) is not int or card <= 0:
        raise ValueError('card must be a positive integer')
    data = _read(root, card, run)
    note = _note(root, card, run)
    config = _config(root, run)
    board_dir, worktrees = _dirs(root, config)
    found = find(root, live_cards=live_cards, run=run, run_argv=run_argv, cards={card})
    orphans = [item for item in found if item.kind == 'live_orphan']
    if orphans:
        pgid = markers.read_pgid(board_dir / 'active' / str(card))
        raise ValueError('card #%d has a live process group (%s) from an earlier run; stop that process group '
                         'first (kill -TERM -- -%s), then release' % (card, pgid, pgid))
    if not found and not force:
        raise ValueError('card #%d has no stuck finding; pass --force to release it anyway' % card)
    lock = worktrees / '.locks' / ('card-%d.lock' % card)
    if lock.is_dir() and not _lock_dead(lock):
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
            # End the in-flight state: the merge happened, so record it the way merge-reviewed.sh does (the
            # planner's merged branch then plans verify_main / after_merge).
            pending = note.get('pending_merge')
            if isinstance(pending, dict) and not note.get('merge_operation'):
                patch.update({'merge_operation': pending, 'merged_pr': pr})
        elif pr_state in ('OPEN', 'CLOSED'):
            patch.update({key: None for key in MERGE_KEYS})
            target = 'in_review'
        else:
            raise ValueError('cannot tell whether PR %d of card #%d is merged (gh said %r)' % (pr, card, pr_state))
    dirty = _dirty(root, note.get('worktree'), run_argv)
    if dirty:
        patch['stuck_released'] = {'kind': dirty[0], 'at': _iso()}   # find skips it; the driver clears it
    if lock.is_dir():   # a dead holder's lock would block the move and the note write: they wait on it
        if not _lock_dead(lock):   # re-checked just before removing: its holder may have come back
            raise ValueError('card #%d is locked by a running process (%s)' % (card, lock))
        if _live_claim(lock):      # a running waiter is taking the dead lock over and will remove it
            raise ValueError('card #%d has a dead lock that a running process is taking over (%s)' % (card, lock))
        # A pid-less lock may have a holder that is only slow: fill its pid slot first, so the holder's late pid
        # write fails rather than land in the lock being removed (if the holder's write won, it holds the lock).
        try:
            owner = _lock_pid(lock)
            if owner is None and not _fence(lock):
                owner = ''   # the holder's own write won the slot
            elif owner is None:
                owner = _lock_pid(lock)
            elif owner.strip().isdigit() and int(owner) > 0 and _pid_alive(int(owner)):
                owner = ''   # a pid that appeared since the checks above: its holder is running
            if owner == '':
                raise ValueError('card #%d is locked by a running process (%s)' % (card, lock))
        except OSError as exc:
            raise ValueError('cannot remove the dead lock %s of card #%d: %s' % (lock, card, exc)) from None
        # Rename the lock out of its path first, then delete the private copy: a taker's late claim goes through
        # the path, so it never lands in the copy being deleted, and a failed delete leaves no lock at the path.
        rel = lock.with_name('%s.rel.%d' % (lock.name, os.getpid()))
        try:
            lock.rename(rel)
            if _lock_pid(rel) != owner:
                raise ValueError('the lock %s of card #%d changed owner while it was removed; left it at %s'
                                 % (lock, card, rel))
            for child in rel.iterdir():
                child.unlink()
            rel.rmdir()
        except OSError as exc:
            raise ValueError('cannot remove the dead lock %s of card #%d: %s' % (lock, card, exc)) from None
    if target:
        moved = run(root, 'board-move.sh', card, target, timeout=60)
        if moved.timed_out or moved.rc != 0:
            _json(moved, 'board-move.sh #%d %s' % (card, target))
    _patch(root, card, patch, run)
    try:
        (board_dir / 'active' / str(card)).unlink()
    except OSError:
        pass


def process_start(pid):
    """`ps -o lstart=` for `pid` in C/UTC (the run lock's second line), or '' when it is not running."""
    try:
        result = subprocess.run(['ps', '-o', 'lstart=', '-p', str(pid)], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=10,
                                env=dict(os.environ, LC_ALL='C', TZ='UTC'))
    except (OSError, subprocess.SubprocessError):
        return ''
    return ' '.join(result.stdout.split())


def run_lock_holder(path):
    """The pid of the live supervisor holding the repository run lock at `path` (claim-run-lock.py's format: pid,
    then its start time), else None. A pid whose start time differs from the recorded one is a reused pid."""
    try:
        lines = Path(path).read_text(encoding='utf-8', errors='replace').splitlines()
    except OSError:
        return None
    if not lines or not re.fullmatch(r'[1-9][0-9]*', lines[0]):
        return None
    recorded = lines[1] if len(lines) > 1 else ''
    actual = process_start(lines[0])
    return int(lines[0]) if actual and (not recorded or actual == recorded) else None

"""The supervisor owns each card's active marker (`<board.dir>/active/<n>`).

While a role session or a merge child runs, the marker holds {"pgid", "supervisor_pid"} (written atomically);
it is removed when the action ends, unless it names another process group. While the supervisor owns a card
a marker naming no pgid is its own (a board script's empty marker during a script-only action) and goes too.
Board scripts keep working: they create an empty marker when none exists (never truncating one) and remove it when a role
posts its report. The startup check reads the pgid to tell a live orphan (a group still running) from a
leftover marker.
"""
import json
import os
import tempfile
from pathlib import Path

DEFAULT_DIR = '.fleet-board'


def path(root, board_dir, card):
    return Path(root) / (board_dir or DEFAULT_DIR) / 'active' / str(card)


def write(root, board_dir, card, pgid, supervisor_pid=None):
    """Atomically write the marker for `card` naming `pgid`; returns its path. Raises OSError."""
    target = path(root, board_dir, card)
    target.parent.mkdir(parents=True, exist_ok=True)
    # `pgids` lists every process group of the card's reviewers still running, so a dead last-launched one
    # does not hide a live sibling from the orphan checks.
    pgids = [int(pgid)] + [p for p in read_pgids(target) if p != int(pgid) and group_alive(p)]
    data = json.dumps({'pgid': int(pgid), 'pgids': pgids, 'supervisor_pid': int(supervisor_pid or os.getpid())})
    fd, temp = tempfile.mkstemp(dir=str(target.parent), prefix='.%s.' % card)
    try:
        with os.fdopen(fd, 'w') as out:
            out.write(data + '\n')
        os.replace(temp, str(target))
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
    return target


def read_pgid(marker):
    """The usable pgid a marker names (an int above 1), else None (empty, unreadable or not ours)."""
    try:
        data = json.loads(Path(marker).read_text())
    except (OSError, ValueError):
        return None
    pgid = data.get('pgid') if isinstance(data, dict) else None
    return pgid if type(pgid) is int and pgid > 1 else None


def read_pgids(marker):
    """Every usable pgid a marker names: its `pgid` first, then the `pgids` list. Empty when none."""
    try:
        data = json.loads(Path(marker).read_text())
    except (OSError, ValueError):
        return []
    if not isinstance(data, dict):
        return []
    found = []
    for item in [data.get('pgid')] + (data.get('pgids') if isinstance(data.get('pgids'), list) else []):
        if type(item) is int and item > 1 and item not in found:
            found.append(item)
    return found


def group_alive(pgid):
    """True when process group `pgid` still has a member (or exists and is not ours to signal)."""
    if type(pgid) is not int or pgid <= 1:
        return False
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def clear(marker, pgid, also=()):
    """Remove `marker` at the end of the action that owned the card: when it still names `pgid`, or names no
    usable pgid at all (an empty marker a board script made while the supervisor owned the card is the
    supervisor's own). `also` lists further pgids that count as ours (the card's other reviewers that already
    ended). A marker naming another process group is left alone. Never raises."""
    if marker is None:
        return False
    try:
        named = read_pgid(marker)
        if named is not None and named != pgid and named not in also:
            return False
        if any(group_alive(p) for p in read_pgids(marker) if p != pgid):
            return False   # another reviewer of the card named in the marker still runs
        os.unlink(str(marker))
        return True
    except OSError:
        return False

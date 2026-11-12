"""The supervisor owns each card's active marker (`<board.dir>/active/<n>`).

While a role session or a merge child runs, the marker holds {"pgid", "supervisor_pid"} (written atomically);
it is removed when the action ends, and only while it still names that action's process group. Board scripts
keep working: they create an empty marker when none exists (never truncating one) and remove it when a role
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
    data = json.dumps({'pgid': int(pgid), 'supervisor_pid': int(supervisor_pid or os.getpid())})
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


def clear(marker, pgid):
    """Remove `marker` when it still names `pgid` (a later writer's marker is left alone). Never raises."""
    if marker is None or pgid is None:
        return False
    try:
        if read_pgid(marker) != pgid:
            return False
        os.unlink(str(marker))
        return True
    except OSError:
        return False

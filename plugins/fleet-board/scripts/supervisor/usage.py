"""The usage ledger: one JSON line per completed role action, in `<root>/<board.dir>/usage.jsonl`.

Tokens are the only unit. A count that could not be read is `null` on disk and `unknown` in every view: it
is never summed as zero, and a total that includes one (or that was read from a damaged ledger) is marked
`partial`. Appends are one `os.write` of one line under an advisory lock, so concurrent writers never
interleave; a reader skips any line that is not a well-formed ledger line and reports the count once.
"""
import fcntl
import json
import os
from pathlib import Path

DEFAULT_DIR = '.fleet-board'
KEYS = ('run_id', 'card', 'kind', 'column', 'action', 'role', 'provider', 'model', 'input', 'output',
        'cache_write', 'cache_read', 'started_at', 'ended_at', 'log')
COUNTS = ('input', 'output', 'cache_write', 'cache_read')
KINDS = ('card', 'planner')
_TEXT = ('run_id', 'column', 'action', 'role', 'provider', 'model', 'started_at', 'ended_at', 'log')


def ledger_path(root, board_dir=DEFAULT_DIR):
    return Path(root) / (board_dir or DEFAULT_DIR) / 'usage.jsonl'


def _problem(line):
    """The first reason `line` is not a ledger line, or None."""
    if not isinstance(line, dict):
        return 'not an object'
    if set(line) != set(KEYS):
        return 'keys differ from the ledger keys'
    if line['kind'] not in KINDS:
        return 'kind must be card or planner'
    card = line['card']
    if card is not None and (type(card) is not int or card <= 0):
        return 'card must be null or a positive integer'
    for key in COUNTS:
        value = line[key]
        if value is not None and (type(value) is not int or value < 0):
            return '%s must be null or a non-negative integer' % key
    for key in _TEXT:
        if line[key] is not None and not isinstance(line[key], str):
            return '%s must be null or text' % key
    return None


def append(root, line, board_dir=DEFAULT_DIR):
    """Append `line` as one ledger line. Raises ValueError for a line that is not one; OSError on I/O."""
    problem = _problem(line)
    if problem:
        raise ValueError('usage line: ' + problem)
    path = ledger_path(root, board_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = (json.dumps({key: line[key] for key in KEYS}, separators=(',', ':')) + '\n').encode('utf-8')
    lock = os.open(str(path) + '.lock', os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        fd = os.open(str(path), os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            size = os.fstat(fd).st_size
            if size and os.pread(fd, 1, size - 1) != b'\n':
                data = b'\n' + data   # a crashed writer left a torn tail: keep it a line of its own
            os.write(fd, data)
        finally:
            os.close(fd)
    finally:
        os.close(lock)   # closing releases the flock


def read(root, board_dir=DEFAULT_DIR, warn=None):
    """Return (lines, skipped). A malformed line is skipped; `warn(message)` is called once if any were."""
    try:
        with open(str(ledger_path(root, board_dir)), 'rb') as f:
            raw = f.read()
    except FileNotFoundError:
        return [], 0
    lines, skipped = [], 0
    for chunk in raw.split(b'\n'):
        if not chunk.strip():
            continue
        try:
            value = json.loads(chunk.decode('utf-8'))
        except ValueError:
            skipped += 1
            continue
        if _problem(value):
            skipped += 1
        else:
            lines.append(value)
    if skipped and warn is not None:
        warn('%d unreadable line%s skipped in %s; totals are partial'
             % (skipped, '' if skipped == 1 else 's', ledger_path(root, board_dir).name))
    return lines, skipped


def totals(lines, *, run_id=None, card=None, kind=None, skipped=0):
    """Sum the known counts of the matching lines. `unknown` counts lines with any unknown count; `partial`
    is true when any line has one or `skipped` damaged lines were left out."""
    out = {key: 0 for key in COUNTS}
    unknown = 0
    for line in lines:
        if (run_id is not None and line['run_id'] != run_id) or (card is not None and line['card'] != card) \
                or (kind is not None and line['kind'] != kind):
            continue
        if any(line[key] is None for key in COUNTS):
            unknown += 1
        for key in COUNTS:
            if line[key] is not None:
                out[key] += line[key]
    out['total'] = sum(out[key] for key in COUNTS)
    out['unknown'] = unknown
    out['partial'] = unknown > 0 or skipped > 0
    return out


def drilldown(lines, card, skipped=0):
    """One card: its totals and its actions grouped by the column it was in, in first-seen column order."""
    mine = [line for line in lines if line['card'] == card]
    columns = {}
    for line in mine:
        columns.setdefault(line['column'], []).append(line)
    return {'card': card, 'totals': totals(mine, skipped=skipped),
            'columns': [{'column': name, 'totals': totals(rows, skipped=skipped), 'actions': rows}
                        for name, rows in columns.items()]}


def summary(lines, skipped=0, run_id=None):
    """What the `usage` command shows: this run (None when no supervisor) and all time, both for card work, and
    the planner on its own line."""
    return {'run': None if run_id is None else totals(lines, run_id=run_id, kind='card', skipped=skipped),
            'all_time': totals(lines, kind='card', skipped=skipped), 'planner': totals(lines, kind='planner', skipped=skipped),
            'skipped': skipped}


def view(root, board_dir=DEFAULT_DIR, card=None, run_id=None):
    """The `usage` command's answer: the card drill-down when `card` is given, else the summary. A damaged
    ledger adds one `warning` and marks every total partial. Raises ValueError for a bad card."""
    if card is not None and (type(card) is not int or card <= 0):
        raise ValueError('card must be a positive integer')
    warnings = []
    lines, skipped = read(root, board_dir, warn=warnings.append)
    result = drilldown(lines, card, skipped=skipped) if card is not None else summary(lines, skipped, run_id)
    result['skipped'] = skipped
    if warnings:
        result['warning'] = warnings[0]
    return result

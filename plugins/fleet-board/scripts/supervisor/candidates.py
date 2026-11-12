"""Reads the board through `tick-plan.sh --candidates`."""
import calendar
import json
import re
import time
from collections import namedtuple

from . import scripts

Batch = namedtuple('Batch', 'candidates rate_limit_until error warnings', defaults=((),))

_RESETS = re.compile(r'resets at (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z')


def _last_line(text):
    lines = [line for line in text.splitlines() if line.strip()]
    return lines[-1].strip() if lines else ''


def fetch(root, run=scripts.run, now=time.time):
    result = run(root, 'tick-plan.sh', '--candidates')
    if result.timed_out:
        return Batch([], None, 'tick-plan.sh timed out')
    if result.rc == 0:
        try:
            data = json.loads(result.stdout)
        except ValueError:
            return Batch([], None, 'tick-plan.sh printed invalid JSON')
        if not isinstance(data, dict) or data.get('schema_version') != 2 or not isinstance(data.get('candidates'), list):
            return Batch([], None, 'tick-plan.sh printed an unsupported schema')
        warnings = data.get('warnings')
        return Batch(data['candidates'], None, None,
                     tuple(w for w in warnings if isinstance(w, str)) if isinstance(warnings, list) else ())
    if result.rc == 1:
        match = _RESETS.search(result.stderr)
        if match:
            return Batch([], float(calendar.timegm(time.strptime(match.group(1), '%Y-%m-%dT%H:%M:%S'))), None)
    return Batch([], None, _last_line(result.stderr) or 'tick-plan.sh exited ' + str(result.rc))

#!/bin/bash
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-scheduler.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 "$plugin_dir/fixtures/supervisor/scheduler_cases.py" "$tmp"

# Scope overlap only counts within one repo
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - <<'PY'
from supervisor.scheduler import Scheduler

LIMITS = {'global': 5, 'providers': {'claude': 5}, 'per_card': 1}


def ready(number, repo):
    return {'number': number, 'repo': repo, 'action': 'start', 'provider': 'claude',
            'declared_paths': ['src/a.py'], 'actual_paths': [], 'scope_complete': True,
            'priority': 'normal', 'eligible_since': 0, 'preconditions': {'state': 'ready', 'head_sha': None}}


def admit(rows):
    return Scheduler(clock=lambda: 0).admit(rows, limits=LIMITS)


# Two Ready fixture cards whose Scope names the path src/a.py in different repos both start
result = admit([ready(1, 'acme/one'), ready(2, 'acme/two')])
assert [c['number'] for c in result['admitted']] == [1, 2], result
assert result['waits'] == [], result
print('ok: two Ready cards naming src/a.py in different repos both start')

# Two Ready fixture cards whose Scope names the path src/a.py in the same repo: the higher-numbered one waits with scope overlap
result = admit([ready(1, 'acme/one'), ready(2, 'acme/one')])
assert [c['number'] for c in result['admitted']] == [1], result
assert [w['number'] for w in result['waits']] == [2], result
assert result['waits'][0]['reason'] == 'scope or card conflict', result
print('ok: same repo, the higher-numbered card waits on the scope conflict')

# Repo case is not significant (owner/name compare case-insensitively)
result = admit([ready(1, 'Acme/One'), ready(2, 'acme/one')])
assert [c['number'] for c in result['admitted']] == [1], result
print('ok: repo names compare case-insensitively')
PY

# Scope reservations only hold within one repo
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - <<'PY'
from supervisor.scheduler import Scheduler

LIMITS = {'global': 5, 'providers': {'claude': 5}, 'per_card': 1}


def ready(number, repo):
    return {'number': number, 'repo': repo, 'action': 'start', 'provider': 'claude',
            'declared_paths': ['src/a.py'], 'actual_paths': [], 'scope_complete': True,
            'priority': 'normal', 'eligible_since': 0, 'preconditions': {'state': 'ready', 'head_sha': None}}


def admit(repo):
    return Scheduler(clock=lambda: 0).admit(
        [ready(2, repo)], limits=LIMITS,
        reservations=[{'card': 1, 'repo': 'acme/one', 'paths': ['src/a.py']}])


result = admit('acme/two')
assert [c['number'] for c in result['admitted']] == [2], result
assert result['waits'] == [], result
print('ok: a reservation in a different repo does not hold the card')

result = admit('acme/one')
assert result['admitted'] == [], result
assert result['waits'][0]['reason'] == 'scope reserved by #1', result
print('ok: a reservation in the same repo holds the card')
PY

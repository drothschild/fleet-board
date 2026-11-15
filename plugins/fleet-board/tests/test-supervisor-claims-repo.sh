#!/bin/bash
# Claims and reservations the supervisor loop hands the scheduler keep the card's repo.
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" <<'PY'
import sys, tempfile, time, types
from supervisor import loop, state as st

failed = []

def check(name, ok, detail=''):
    print(('ok   ' if ok else 'FAIL ') + name + ('' if ok else ' ' + str(detail)))
    if not ok:
        failed.append(name)

root = tempfile.mkdtemp()
s = st.State('run-1')

class Driver:
    def begin(self, row):
        a = st.Action(card=row['number'], action=row['action'], column='ready', role='implementor',
                      provider='claude', paths=[], started_at=time.time(), started_mono=time.monotonic(),
                      session=object())
        s.begin(a)
        return types.SimpleNamespace(kind='session')

sup = loop.Supervisor(root, config_loader=lambda: {}, state=s, driver=Driver(), scheduler=object())
sup.config = {}
sup._begin({'number': 7, 'action': 'start', 'repo': 'acme/widgets', 'declared_paths': ['src/a.py'], 'actual_paths': []})
active = {c['number']: c for c in sup._active_claims()}
check('active claim keeps repo', active.get(7, {}).get('repo') == 'acme/widgets', active)
res = {c['card']: c for c in sup._reservations()}
check('reservation keeps repo', res.get(7, {}).get('repo') == 'acme/widgets', res)
sys.exit(1 if failed else 0)
PY

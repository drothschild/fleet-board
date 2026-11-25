#!/bin/bash
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 "$plugin_dir/fixtures/supervisor/roles_cases.py"

# An immediate cancel, where SIGKILL follows SIGTERM before any shell trap is sure to have run. The
# provider sits in a process group of its own below the session's, so the group signals do not reach it.
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" <<'PY'
import os
import shutil
import signal
import sys
import tempfile
import time
from pathlib import Path

from supervisor import roles

CHAT = Path(sys.argv[1]) / 'scripts' / 'providers' / 'chat.sh'
# Records its pid in the (fresh) pid file, ignores TERM, then stays alive.
PROVIDER = '#!/bin/bash\ntrap "" TERM\necho $$ > "$1.new"\nmv "$1.new" "$1"\nexec sleep 30\n'


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def check(name, argv_for):
    tmp = Path(tempfile.mkdtemp(prefix='roles-cancel-')).resolve()
    pidfile = tmp / 'provider.pid'
    provider = tmp / 'provider'
    provider.write_text(PROVIDER)
    provider.chmod(0o755)
    (tmp / 'request.json').write_text('{"messages":[{"role":"user","content":"go"}]}')
    session = pid = None
    try:
        # chat.sh reads its request on stdin, which a session leaves at /dev/null
        session = roles.launch(argv_for(tmp, '"%s" "%s"; :' % (provider, pidfile)), root=tmp,
                               log_dir=tmp / 'logs', label='s1', env=dict(os.environ), stage=True)
        end = time.monotonic() + 15
        while not pidfile.exists() and time.monotonic() < end:
            time.sleep(0.02)
        assert pidfile.exists(), '%s: the provider never started' % name
        pid = int(pidfile.read_text())
        session.cancel(0)
        result = None
        end = time.monotonic() + 15
        while result is None and time.monotonic() < end:
            result = session.poll()   # at once, with no pause between polls
        assert result is not None and result.cancelled, '%s: %r' % (name, result)
        assert not alive(pid), '%s: the provider process survived' % name
        print('ok - %s' % name)
    finally:
        if pid is not None and alive(pid):
            os.kill(pid, signal.SIGKILL)
        if session is not None:
            session.cancel(0)
        shutil.rmtree(str(tmp), ignore_errors=True)


def chat(tmp, command):
    return ['bash', '-c', 'exec bash "$1" --command "$2" --model test --timeout 20 < "$3"', 'chat',
            str(CHAT), command, str(tmp / 'request.json')]


def guarded(tmp, command):
    # as providers/guard/start.sh runs it: chat.sh in one more process group below the session's
    return ['bash', '-c', 'set -m; bash -c \'bash "$1" --command "$2" --model test --timeout 20 < "$3"; :\' '
            'inner "$1" "$2" "$3" & set +m; wait', 'guard', str(CHAT), command, str(tmp / 'request.json')]


check('cancel(0) on a chat.sh --command stage session leaves the provider process gone', chat)
check('cancel(0) reaches a chat.sh --command provider below the guard\'s extra process group', guarded)
PY

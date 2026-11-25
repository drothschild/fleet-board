#!/usr/bin/env bash
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 - "$HERE/../scripts/providers/reviewer-ps.py" <<'PY'
import os, pathlib, subprocess, sys
helper = pathlib.Path(sys.argv[1])
assert helper.is_file(), 'missing unprivileged process-start helper'
if sys.platform != 'darwin':
    print('SKIP Darwin process metadata check'); sys.exit(0)
env = dict(os.environ, LC_ALL='C', TZ='UTC')
expected = subprocess.check_output(['/bin/ps', '-o', 'lstart=', '-p', str(os.getpid())], env=env, text=True).split()
actual = subprocess.check_output([sys.executable, str(helper), '-p', str(os.getpid()), '-o', 'lstart='], env=env, text=True).split()
assert actual == expected, (actual, expected)
for args in [['-axo', 'command'], ['-p', '0', '-o', 'lstart='], ['-p', '-1', '-o', 'lstart=']]:
    assert subprocess.run([sys.executable, str(helper), *args], capture_output=True).returncode != 0
missing = subprocess.run([sys.executable, str(helper), '-o', 'lstart=', '-p', '2147483647'], capture_output=True)
assert missing.returncode != 0 and not missing.stdout
print('PASS real start time, argument restriction, nonexistent PID')
PY

# The listing supervisor/roles.py reads to find every process group of a session.
python3 - "$HERE/../scripts/providers/reviewer-ps.py" <<'PY'
import os, subprocess, sys
if sys.platform != 'darwin':
    print('SKIP Darwin process group listing'); sys.exit(0)
child = subprocess.Popen(['/bin/sleep', '30'], preexec_fn=os.setpgrp)
try:
    out = subprocess.check_output([sys.executable, sys.argv[1], '-A', '-o', 'pid=', '-o', 'pgid='], text=True)
    groups = dict(tuple(int(v) for v in line.split()) for line in out.splitlines())
    assert groups.get(os.getpid()) == os.getpgrp(), groups.get(os.getpid())
    assert groups.get(child.pid) == child.pid, groups.get(child.pid)
finally:
    child.kill(); child.wait()
print('PASS process group listing')
PY

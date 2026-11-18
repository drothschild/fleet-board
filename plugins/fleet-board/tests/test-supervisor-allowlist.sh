#!/usr/bin/env bash
# Every literal script name the supervisor package passes to a script call must be in scripts.ALLOWED.
# The driver's tests stub scripts by name, so nothing else runs the real allowlist.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
SUP="$PLUGIN/scripts/supervisor"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }

# Prints "<file>:<name>" for each literal *.sh name used in a script call, with the names missing from ALLOWED
# marked "MISSING". Args: scripts.py to read ALLOWED from.
scan() {
  python3 -I - "$SUP" "$1" <<'PY'
import ast, re, sys
from pathlib import Path
sup, allowed_src = Path(sys.argv[1]), Path(sys.argv[2])
tree = ast.parse(allowed_src.read_text())
allowed = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Assign) and any(getattr(t, 'id', '') == 'ALLOWED' for t in node.targets):
        allowed = {n.value for n in ast.walk(node.value) if isinstance(n, ast.Constant) and isinstance(n.value, str)}
CALLS = {'run', 'soft', 'step', 'spawn', 'run_script', '_step'}
for path in sorted(sup.glob('*.py')):
    if path.name == 'scripts.py':
        continue
    for node in ast.walk(ast.parse(path.read_text())):
        if not isinstance(node, ast.Call):
            continue
        fn = node.func
        name = fn.attr if isinstance(fn, ast.Attribute) else getattr(fn, 'id', '')
        if name not in CALLS:
            continue
        for arg in node.args[:2]:
            if isinstance(arg, ast.Constant) and isinstance(arg.value, str) and re.fullmatch(r'[\w.-]+\.sh', arg.value):
                print('%s:%s%s' % (path.name, arg.value, '' if arg.value in allowed else ' MISSING'))
PY
}

REAL="$SUP/scripts.py"
out="$(scan "$REAL")"

n="$(printf '%s\n' "$out" | grep -c '\.sh')"
if [ "$n" -gt 20 ]; then ok "the scan finds the supervisor's literal script names ($n)"; else bad "the scan found only $n names"; fi

if printf '%s\n' "$out" | grep -q 'driver.py:stack-land.sh'; then ok "the scan sees driver.py's stack-land.sh call"; else bad "scan misses stack-land.sh in driver.py"; fi

missing="$(printf '%s\n' "$out" | grep ' MISSING' || true)"
if [ -z "$missing" ]; then ok "every literal script name passed to a script call is in ALLOWED"; else bad "not in ALLOWED: $missing"; fi

# The suite goes red when a name is removed from ALLOWED.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sed "s/ 'stack-land.sh',//" "$REAL" > "$TMP/scripts.py"
if grep -q "stack-land.sh" "$TMP/scripts.py"; then bad "mutation did not remove stack-land.sh"; fi
mut="$(scan "$TMP/scripts.py" | grep ' MISSING' || true)"
if printf '%s\n' "$mut" | grep -q 'driver.py:stack-land.sh MISSING'; then ok "removing stack-land.sh from ALLOWED is reported"; else bad "removal of stack-land.sh went unnoticed"; fi

if grep -q 'test-supervisor-allowlist.sh' "$PLUGIN/CLAUDE.md"; then ok "CLAUDE.md names test-supervisor-allowlist.sh"; else bad "CLAUDE.md does not name test-supervisor-allowlist.sh"; fi

echo "passed: $PASS failed: $FAIL"
[ "$FAIL" -eq 0 ]

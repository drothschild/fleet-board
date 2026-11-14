#!/usr/bin/env bash
#
# Plain-bash test: when a planner turn fails with empty stderr, the reply names the binary that actually
# ran (not a hard-coded "claude"). Needs python3.
#
# Usage: bash plugins/fleet-board/tests/test-board-planner-binary-name.sh

set -uo pipefail
unset CDPATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "skipped: python3 not on PATH"; exit 0; }
export SCRIPTS

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

echo "Case: a failed planner turn with empty stderr names the binary that ran"
OUT="$(python3 -I - <<'PY' 2>&1
import importlib.util, json, os, tempfile
from pathlib import Path
spec = importlib.util.spec_from_file_location("board_web", os.path.join(os.environ["SCRIPTS"], "board-web.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.record_planner_usage = lambda *a, **k: None

class FakeProc:
    def __init__(self, exe, rc): self.args = [exe, "-p"]; self._rc = rc; self.returncode = rc
    def wait(self): return self._rc

def reply_for(exe):
    d = Path(tempfile.mkdtemp())
    (d / "out.jsonl").write_text("")
    (d / "err").write_text("")
    m.finish_planner_turn("x", d, FakeProc(exe, 1), d / "out.jsonl", d / "err")
    return json.loads((d / "transcript.json").read_text())[-1]["text"]

print("R1=" + reply_for("/opt/bin/my-planner"))
print("R2=" + reply_for("claude"))
PY
)"
r1="$(printf '%s\n' "$OUT" | sed -n 's/^R1=//p')"
r2="$(printf '%s\n' "$OUT" | sed -n 's/^R2=//p')"
if [ "$r1" = "[error] my-planner exited 1" ]; then pass "When a planner turn fails with empty stderr, the reply names the binary that actually ran"; else fail "When a planner turn fails with empty stderr, the reply names the binary that actually ran" "got '$r1' ($OUT)"; fi
if [ "$r2" = "[error] claude exited 1" ]; then pass "the default binary is still named claude"; else fail "the default binary is still named claude" "got '$r2'"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

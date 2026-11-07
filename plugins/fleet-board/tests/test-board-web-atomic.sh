#!/usr/bin/env bash
#
# Plain-bash, socket-free tests for board-web.py's atomic meta write.
# Loads board-web.py as a module and calls write_private_atomic directly, so it
# runs where loopback sockets are blocked. Deterministic: an in-place write
# keeps the destination's inode and is seen mid-write; a temp-file-and-rename
# write gives the destination a new inode and leaves the old content in place
# until the rename.
#
# Usage: bash plugins/fleet-board/tests/test-board-web-atomic.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "skipped: python3 not on PATH"; exit 0; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1 ($2)"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Case: write_private_atomic replaces meta.json by rename"
OUT="$(SCRIPTS="$SCRIPTS" ATOMIC_DIR="$TMP" python3 -I - <<'PYEOF'
import importlib.util, os, stat
from pathlib import Path
spec = importlib.util.spec_from_file_location("board_web", os.path.join(os.environ["SCRIPTS"], "board-web.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
dest = Path(os.environ["ATOMIC_DIR"]) / "meta.json"
old = '{"status": "previewing"}'
new = '{"status": "ready", "created": true}'
dest.write_text(old, encoding="utf-8")
os.chmod(str(dest), 0o644)
ino_before = os.stat(str(dest)).st_ino

# Whatever write_private is asked to write, meta.json must still hold the old
# content at that moment: the new content only appears through the rename.
seen = []
real = m.write_private
def spy(path, text):
    real(path, text)
    seen.append(dest.read_text(encoding="utf-8"))
m.write_private = spy

m.write_private_atomic(dest, new)

st = os.stat(str(dest))
print("inode_changed=%s" % ("yes" if st.st_ino != ino_before else "no"))
print("old_kept_during_write=%s" % ("yes" if seen and all(s == old for s in seen) else "no"))
print("new_content=%s" % ("yes" if dest.read_text(encoding="utf-8") == new else "no"))
print("mode=%o" % stat.S_IMODE(st.st_mode))
print("leftovers=%d" % len([p for p in dest.parent.iterdir() if p.name != "meta.json"]))
PYEOF
)"
echo "$OUT" | sed 's/^/    /'

check() {
  if printf '%s\n' "$OUT" | grep -qx "$2"; then pass "$1"; else fail "$1" "want $2"; fi
}
check "meta.json gets a new inode (renamed into place, not rewritten)" "inode_changed=yes"
check "meta.json still holds the old content while the new one is written" "old_kept_during_write=yes"
check "meta.json holds the new content afterwards" "new_content=yes"
check "meta.json is mode 600 afterwards" "mode=600"
check "no temp file is left next to meta.json" "leftovers=0"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

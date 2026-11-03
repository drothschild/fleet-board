#!/usr/bin/env bash
# Checks manager.md and its spec record blocked_from on every block path, and test-accept.sh still passes.
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
M="$HERE/../agents/manager.md"
SPEC="${SPECS_DIR:-$HERE/../../../docs/implementation-plans/2026-09-28-fleet-board/specs}/manager.md"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

# line_has LABEL FILE LINE_PATTERN NEEDLE: a line matching LINE_PATTERN also holds NEEDLE.
line_has() {
  if grep -E "$3" "$2" | grep -qF "$4"; then ok "$1"; else bad "$1"; fi
}

check_file() {
  local who="$1" f="$2" before='blocked_from` = the card'"'"'s state before the move'
  local n
  n=$(grep -c 'blocked_from' "$f")
  if [ "$n" -ge 4 ]; then ok "$who mentions blocked_from on at least 4 lines ($n)"; else bad "$who blocked_from count $n < 4"; fi
  line_has "$who: block action records the state before the move" "$f" '^\| `block` ' "$before"
  line_has "$who: action-failure block records the state before the move" "$f" '^ +- `blocked_from` = ' "$before"
  line_has "$who: 3.6 item 4 records blocked_from" "$f" 'Status `blocked` with a non-null `blocked_by`' "$before"
  line_has "$who: 3.6 item 5 records blocked_from" "$f" '`blocked_findings` = the report' "$before"
  line_has "$who: after-merge block records in_review" "$f" 'outcome` is `blocked`' 'blocked_from: "in_review"'
  line_has "$who: unblock clears blocked_from" "$f" '^\| `unblock`' 'blocked_from: null'
  line_has "$who: 2.16 clears blocked_from" "$f" '^2\.16\. ' 'blocked_from'
}

check_file agent "$M"
if [ -f "$SPEC" ]; then check_file spec "$SPEC"; else echo "skip - no spec at $SPEC (installed plugin)"; fi

if bash "$HERE/test-accept.sh" >/dev/null 2>&1; then ok "test-accept.sh exits 0"; else bad "test-accept.sh failed"; fi
exit $fail

#!/usr/bin/env bash
# Checks manager.md records blocked_from on every block path, and test-accept.sh still passes.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
M="$HERE/../agents/manager.md"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

n=$(grep -c 'blocked_from' "$M")
if [ "$n" -ge 4 ]; then ok "manager.md mentions blocked_from on at least 4 lines ($n)"; else bad "manager.md blocked_from count $n < 4"; fi

if grep -E 'Status `blocked` with a non-null `blocked_by`' "$M" | grep -q 'blocked_from'; then
  ok "3.6 item 4 records blocked_from"; else bad "3.6 item 4 does not record blocked_from"; fi
if grep -E '^\| `unblock`' "$M" | grep -q 'blocked_from: null'; then
  ok "unblock clears blocked_from"; else bad "unblock does not clear blocked_from"; fi

if bash "$HERE/test-accept.sh" >/dev/null 2>&1; then ok "test-accept.sh exits 0"; else bad "test-accept.sh failed"; fi
exit $fail

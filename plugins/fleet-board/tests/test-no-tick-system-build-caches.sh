#!/usr/bin/env bash
#
# test-no-tick-system.sh must ignore build caches (git-ignored __pycache__ *.pyc files) but still
# catch a real cost_usd in a source file. Each case runs the check on a throwaway copy of the plugin.
#
# Usage: bash plugins/fleet-board/tests/test-no-tick-system-build-caches.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fresh_copy DIR: a copy of the plugin under DIR/fleet-board, without any existing caches.
fresh_copy() {
  mkdir -p "$1"
  cp -R "$PLUGIN_DIR" "$1/fleet-board"
  find "$1/fleet-board" -name '__pycache__' -type d -prune -exec rm -rf {} +
}

echo "test-no-tick-system.sh and build caches"

fresh_copy "$TMP/a"
mkdir -p "$TMP/a/fleet-board/scripts/__pycache__"
printf 'cost_usd\n' > "$TMP/a/fleet-board/scripts/__pycache__/board-web.cpython-39.pyc"
if bash "$TMP/a/fleet-board/tests/test-no-tick-system.sh" >/dev/null 2>&1; then
  pass "With a planted .pyc file under the plugin scripts __pycache__ directory containing cost_usd, test-no-tick-system.sh passes"
else
  fail "With a planted .pyc file under the plugin scripts __pycache__ directory containing cost_usd, test-no-tick-system.sh passes"
fi

fresh_copy "$TMP/b"
printf '\n# cost_usd\n' >> "$TMP/b/fleet-board/scripts/board-web.py"
if bash "$TMP/b/fleet-board/tests/test-no-tick-system.sh" >/dev/null 2>&1; then
  fail "With cost_usd planted in board-web.py, test-no-tick-system.sh still fails"
else
  pass "With cost_usd planted in board-web.py, test-no-tick-system.sh still fails"
fi

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

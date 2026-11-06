#!/usr/bin/env bash
#
# Plain-bash test: agents/manager.md records note.last_fix after a fixer report.
#
# Usage: bash plugins/fleet-board/tests/test-manager-last-fix.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MANAGER="$(cd "${SCRIPT_DIR}/.." && pwd)/agents/manager.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

n=$(grep -c last_fix "$MANAGER")
if [ "$n" -gt 0 ]; then
  pass "grep -c last_fix agents/manager.md is above 0 ($n)"
else
  fail "grep -c last_fix agents/manager.md is above 0" "printed $n"
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
#
# Checks that the reviewer agent reads the card's Human QA section, and that
# the hand edit is recorded in the clean-room manifest.
# Usage: bash plugins/fleet-board/tests/test-reviewer-qa-section.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REVIEWER="$PLUGIN_DIR/agents/reviewer.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# The reviewer file names the QA section.
n="$(grep -c 'QA section' "$REVIEWER")"
if [ "$n" -ge 1 ]; then pass "reviewer.md mentions the QA section"; else fail "reviewer.md mentions the QA section"; fi

# The report rules name a Minor finding for a QA section bullet that no longer matches.
if grep 'QA section' "$REVIEWER" | grep -q '\[Minor\]'; then
  pass "a Minor finding is named for a QA section bullet that no longer matches the change"
else
  fail "a Minor finding is named for a QA section bullet that no longer matches the change"
fi

# A change a person would need to check with no bullet is also Minor.
if grep -i 'QA section' "$REVIEWER" | grep -qi 'no bullet'; then
  pass "a Minor finding is named for a change with no QA section bullet"
else
  fail "a Minor finding is named for a change with no QA section bullet"
fi

# The clean-room guard passes with the change recorded.
out="$(bash "$SCRIPT_DIR/test-clean-room.sh" 2>&1)"
if printf '%s\n' "$out" | grep -q 'FAIL'; then
  fail "test-clean-room.sh prints no failure"
else
  pass "test-clean-room.sh prints no failure"
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

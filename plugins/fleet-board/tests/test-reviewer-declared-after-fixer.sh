#!/usr/bin/env bash
#
# Checks that the reviewer agent keeps a Declared test change Declared after a fixer
# pass that did not touch the test's file, and still calls a fixer edit Weakened.
# Usage: bash plugins/fleet-board/tests/test-reviewer-declared-after-fixer.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REVIEWER="$SCRIPT_DIR/../agents/reviewer.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
has() { # <name> <text> <fixed string>
  if grep -qiF -- "$3" <<<"$2"; then pass "$1"; else fail "$1"; fi
}
hasnot() {
  if grep -qiF -- "$3" <<<"$2"; then fail "$1"; else pass "$1"; fi
}

DECL="$(grep -F '**Declared:**' "$REVIEWER" || true)"
WEAK="$(grep -F '**Weakened:**' "$REVIEWER" || true)"

hasnot "The reviewer classifies a named test change Declared when the only fixer round since the implementor's report made no change to that test's file: no blanket latest-report-is-fixer's rule" \
  "$DECL" "the latest report is the implementor's, not the fixer's"
has "The reviewer classifies a named test change Declared when the only fixer round since the implementor's report made no change to that test's file: the fixer round made no change to that test's file" \
  "$DECL" "made no change to that test's file"
has "Declared: a fixer that made no edit (No edits made) does not count" "$DECL" "no edits"
has "A fixer round that edits the declared test still yields a Weakened finding: Declared excludes a fixer edit" \
  "$DECL" "a fixer round that edits the test"
has "A fixer round that edits the declared test still yields a Weakened finding: Weakened covers it" \
  "$WEAK" "a fixer round that edits"
has "The fixer is not dispatched for a card whose only open findings are Declared test changes: no fixer sent" \
  "$DECL" "sends no fixer"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]

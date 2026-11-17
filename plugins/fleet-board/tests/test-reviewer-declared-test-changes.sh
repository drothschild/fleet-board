#!/usr/bin/env bash
#
# Checks that the reviewer agent defines a Declared class for a test change the
# card's "## Test changes" section names, and keeps Weakened for the rest.
# Usage: bash plugins/fleet-board/tests/test-reviewer-declared-test-changes.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REVIEWER="$PLUGIN_DIR/agents/reviewer.md"
SPEC="$PLUGIN_DIR/../../docs/implementation-plans/2026-09-28-fleet-board/specs/reviewer.md"
MANIFEST="$PLUGIN_DIR/../../docs/implementation-plans/2026-09-28-fleet-board/specs/clean-room-manifest.txt"
README="$PLUGIN_DIR/README.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

DECL="$(grep -F '**Declared:**' "$REVIEWER" || true)"
WEAK="$(grep -F '**Weakened:**' "$REVIEWER" || true)"
check() { # <name> <text> <fixed string>
  if grep -qiF -- "$3" <<<"$2"; then pass "$1"; else fail "$1"; fi
}

[ -n "$DECL" ] && pass "reviewer.md has a Declared class" || fail "reviewer.md has a Declared class"
# Declared sits between Adapted and Weakened
a="$(grep -nF '**Adapted:**' "$REVIEWER" | head -1 | cut -d: -f1)"
d="$(grep -nF '**Declared:**' "$REVIEWER" | head -1 | cut -d: -f1)"
w="$(grep -nF '**Weakened:**' "$REVIEWER" | head -1 | cut -d: -f1)"
if [ -n "$a" ] && [ -n "$d" ] && [ -n "$w" ] && [ "$a" -lt "$d" ] && [ "$d" -lt "$w" ]; then
  pass "Declared sits between Adapted and Weakened"
else
  fail "Declared sits between Adapted and Weakened"
fi
check "Declared: names the card's Test changes section" "$DECL" '## Test changes'
check "Declared: names the test by file and exact name" "$DECL" 'exact name'
check "Declared: form matches (changes:)" "$DECL" 'changes:'
check "Declared: form matches (removed:)" "$DECL" 'removed:'
check "Declared: required by the Acceptance item the bullet names" "$DECL" 'Acceptance item'
check "Declared: a changed test passes at HEAD" "$DECL" 'passes at HEAD'
check "Declared: the latest report is the implementor's" "$DECL" "implementor's"
check "Declared: one [Minor] finding" "$DECL" '[Minor]'
check "Declared: the finding quotes the changed lines" "$DECL" 'quotes the changed lines'

check "Weakened ([Critical]) still covers a test the section does not name" "$WEAK" 'does not name'
check "Weakened ([Critical]) still covers a deleted test whose bullet says changes:" "$WEAK" 'changes:'
check "Weakened ([Critical]) still covers any change in a fixer's round" "$WEAK" "fixer's"
check "Weakened still produces a [Critical] finding" "$WEAK" '[Critical]'

check "specs/reviewer.md describes the Declared class" "$(cat "$SPEC")" '**Declared:**'
check "manifest names card 487 for reviewer.md" "$(grep 'agents/reviewer.md' "$MANIFEST")" 'card 487'
check "README documents the ## Test changes section" "$(cat "$README")" '## Test changes'
check "README shows the changes: form" "$(cat "$README")" '" changes:'
check "README shows the removed: form" "$(cat "$README")" '" removed:'

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]

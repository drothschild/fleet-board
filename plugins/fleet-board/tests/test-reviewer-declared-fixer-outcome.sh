#!/usr/bin/env bash
#
# Checks what the reviewer agent's Declared and Weakened rules conclude about a fixer round,
# not just that the phrases appear: a fixer that made no edit, or made no change to the
# declared test's file, leaves the test Declared; a fixer round that edits the test is
# Weakened, never Declared. Each check pins the outcome word, so a mutant that flips it fails.
# Usage: bash plugins/fleet-board/tests/test-reviewer-declared-fixer-outcome.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REVIEWER="$SCRIPT_DIR/../agents/reviewer.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
has() { # <name> <text> <fixed string>
  if grep -qF -- "$3" <<<"$2"; then pass "$1"; else fail "$1"; fi
}
hasnot() {
  if grep -qF -- "$3" <<<"$2"; then fail "$1"; else pass "$1"; fi
}
hasnot_re() { # <name> <text> <extended regex>
  if grep -qE -- "$3" <<<"$2"; then fail "$1"; else pass "$1"; fi
}

DECL="$(grep -F '**Declared:**' "$REVIEWER" || true)"
WEAK="$(grep -F '**Weakened:**' "$REVIEWER" || true)"

N1="The reviewer classifies a named test change Declared when the only fixer round since the implementor's report made no change to that test's file"
has "$N1: a fixer that made no edit does not count" \
  "$DECL" 'a fixer that made no edit (status blocked, "No edits made") does not count'
hasnot_re "$N1: no wording says a no-edit fixer counts" \
  "$DECL" 'made no edit \(status blocked, "No edits made"\) (counts|does count)'
has "$N1: a fixer round with no change to the test's file does not count either" \
  "$DECL" "and neither does a fixer round whose diff"
has "$N1: such a round leaves the test Declared" \
  "$DECL" "a fixer round that made no change to the test's file leaves the test Declared"

N2="A fixer round that edits the declared test still yields a Weakened finding"
has "$N2: Declared says a fixer edit is Weakened" \
  "$DECL" "a fixer round that edits the test is Weakened."
hasnot "$N2: Declared never calls a fixer edit Declared" \
  "$DECL" "a fixer round that edits the test is Declared"
has "$N2: a fixer edit to the test's file makes it Weakened, never Declared" \
  "$DECL" "a fixer round that edits the test's file makes it Weakened, never Declared."
has "$N2: Weakened lists a fixer round that edits the declared test" \
  "$WEAK" "any non-restoring change made in a fixer's round (a fixer round that edits the declared test included)"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]

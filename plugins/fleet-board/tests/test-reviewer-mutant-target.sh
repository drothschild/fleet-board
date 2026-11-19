#!/usr/bin/env bash
# Wording contract for the reviewer's mutation step: a mutant must change code the mapped test actually
# reaches. Card 503 (2026-11-18) was blocked twice by a "survivor" on tick-plan.sh line 1572, a line only
# the card's *other* test (repo 5, home 3: fix) reaches; the mapped test (repo 3, home 5: block) is decided
# earlier, so it could never go red. A mutant on a line the mapped test never reaches says nothing about
# that test, so it is a wrong target to be re-aimed, not a survivor. An item whose behavior no line the test
# reaches implements is still a survivor: the test does not depend on the behavior.
# These checks pin the instructions; they are not a behavioral test.
set -uo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$HERE/.."
SPEC="$PLUGIN/../../docs/implementation-plans/2026-09-28-fleet-board/specs/reviewer.md"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
has() { grep -cF -- "$2" "$1" >/dev/null 2>&1; }

RULE_FILE="$HERE/fixtures/reviewer-wrong-target-rule.txt"
RULE="$(cat "$RULE_FILE" 2>/dev/null)"

# The rule is one paragraph, identical in every copy: it must appear verbatim, so changing, negating or
# dropping any part of it fails (a list of short phrases could be satisfied by a negated sentence).
check_rule() { # <label> <file>
  local label="$1" f="$2"
  if [ -n "$RULE" ] && has "$f" "$RULE"; then
    pass "$label: holds the wrong-target rule paragraph verbatim"
  else
    fail "$label: holds the wrong-target rule paragraph verbatim"
  fi
}

check_rule "agents/reviewer.md" "$PLUGIN/agents/reviewer.md"
check_rule "specs/reviewer.md" "$SPEC"
check_rule "evidence-review-prompt.md" "$PLUGIN/scripts/providers/evidence-review-prompt.md"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

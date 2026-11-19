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

check_rule() { # <label> <file>: every clause is pinned whole, so inverting or dropping one fails
  local label="$1" f="$2" clause desc
  while IFS='|' read -r desc clause; do
    if has "$f" "$clause"; then pass "$label: $desc"; else fail "$label: $desc"; fi
  done <<'CLAUSES'
a mutant changes code the mapped test reaches|code the mapped test reaches
reach is judged in the single mapped case or file actually run|in the single mapped case or file actually run
an unclear path is checked with a marker in the test output|echo reached >&2
a mutant on a line the test never reaches is a wrong target that is not scored|is a wrong target
a wrong target is not counted in the total|is not counted in killed + survived + invalid
a wrong target is re-aimed once, onto code the test does reach|at most one re-aim per item
each wrong target is recorded as one plain line|one plain line
no reached code breaks the behavior: the item is a survivor|does not depend on that behavior, so the item is a survivor
CLAUSES
  # the survivor clause must not be negated anywhere near the rule
  if has "$f" 'never score the item as survived'; then fail "$label: the survivor fallback is not negated"; else pass "$label: the survivor fallback is not negated"; fi
}

check_rule "agents/reviewer.md" "$PLUGIN/agents/reviewer.md"
check_rule "specs/reviewer.md" "$SPEC"
check_rule "evidence-review-prompt.md" "$PLUGIN/scripts/providers/evidence-review-prompt.md"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

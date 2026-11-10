#!/usr/bin/env bash
#
# The board is local only: nothing under scripts/ or hooks/ talks to GitHub
# issues, labels or projects, or to the GraphQL API. GitHub stays the home of
# PRs (gh pr, gh api .../pulls, .../compare, .../commits). The one exception
# is the read-only importer, scripts/import-github.sh.
#
# Usage: bash plugins/fleet-board/tests/test-no-github-board.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXEMPT="scripts/import-github.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

# The patterns: gh issue, gh label, gh project, any GraphQL, and a gh api
# call on an issues path.
PATTERN='gh[[:space:]]+(issue|label|project)([[:space:]]|$)|graphql|gh[[:space:]]+api[^|;]*issues'

hits() {
  ( cd "$ROOT" && grep -rnEi -- "$PATTERN" scripts hooks 2>/dev/null ) | grep -v "^$EXEMPT:" || true
}

echo "no GitHub board calls under scripts/ and hooks/"
HITS="$(hits)"
if [ -z "$HITS" ]; then
  pass "no file but $EXEMPT names gh issue, gh label, gh project or GraphQL"
else
  fail "no file but $EXEMPT names gh issue, gh label, gh project or GraphQL" "$(printf '%s\n' "$HITS" | head -40)"
fi

# The live scenarios drive the same local board: no gh issue/label/project call
# and no fleet:<state> label in tests/behavioral-*.sh (gh pr calls are fine).
BHITS="$( ( cd "$ROOT" && grep -nEi -- "$PATTERN|fleet:(backlog|ready|in_progress|in_review|human_qa|blocked|done|wont_do)" tests/behavioral-*.sh 2>/dev/null ) || true)"
if [ -z "$BHITS" ]; then
  pass "tests/behavioral-*.sh name no gh issue, gh label, gh project, GraphQL or fleet:<state> label"
else
  fail "tests/behavioral-*.sh name no gh issue, gh label, gh project, GraphQL or fleet:<state> label" "$(printf '%s\n' "$BHITS" | head -40)"
fi

# The exemption is not vacuous: the importer exists and the pattern finds its reads.
if [ -f "$ROOT/$EXEMPT" ] && grep -qE -- "$PATTERN" "$ROOT/$EXEMPT"; then
  pass "the pattern finds the importer's reads (the check can fail)"
else
  fail "the pattern finds the importer's reads (the check can fail)" "$EXEMPT missing or the pattern matches nothing in it"
fi

# The GitHub backends and the labels-only helper are gone.
for p in scripts/adapters/github-labels scripts/adapters/github-projects scripts/cards.sh scripts/migrate-to-local.sh; do
  if [ -e "$ROOT/$p" ]; then fail "$p is removed" "still present"; else pass "$p is removed"; fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

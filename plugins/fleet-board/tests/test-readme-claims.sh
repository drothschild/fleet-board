#!/usr/bin/env bash
#
# Plain-bash test: the README's card-writing section states that a whole
# dependency chain can be moved to Ready, and that nothing promotes a Backlog card.
#
# Usage: bash plugins/fleet-board/tests/test-readme-claims.sh
# README_FILE overrides the file checked (used to prove the test can fail).

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
README="${README_FILE:-${SCRIPT_DIR}/../README.md}"

PASS=0
FAIL=0

check() {
  if [ "$2" = "ok" ]; then
    PASS=$((PASS + 1)); echo "ok - $1"
  else
    FAIL=$((FAIL + 1)); echo "not ok - $1"
  fi
}

# The "### Writing a card" section: up to the next heading.
section="$(awk '/^### Writing a card/{f=1;next} f && /^##/{exit} f' "$README")"

r=bad
printf '%s\n' "$section" | grep -qF "Move the whole chain to Ready; each card starts on the first tick after its dependencies are Done." && r=ok
check "card-writing section says to move the whole chain to Ready" "$r"

r=bad
printf '%s\n' "$section" | grep -E "Backlog.*promotes|promotes.*Backlog" | grep -qi "nothing" && r=ok
check "card-writing section says nothing promotes a Backlog card" "$r"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

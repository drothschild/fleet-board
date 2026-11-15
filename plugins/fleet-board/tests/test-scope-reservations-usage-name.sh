#!/usr/bin/env bash
#
# The Usage comment in test-scope-reservations.sh names its own suite, not
# test-tick-plan.sh.
#
# Usage: bash plugins/fleet-board/tests/test-scope-reservations-usage-name.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TARGET="$SCRIPT_DIR/test-scope-reservations.sh"

fail=0
count=$(grep -c 'tests/test-tick-plan.sh' "$TARGET")
if [ "$count" = "0" ]; then
  echo "PASS: grep -c 'tests/test-tick-plan.sh' test-scope-reservations.sh prints 0"
else
  echo "FAIL: test-scope-reservations.sh names tests/test-tick-plan.sh $count time(s), expected 0"
  fail=1
fi

if grep -q 'Usage: bash plugins/fleet-board/tests/test-scope-reservations.sh' "$TARGET"; then
  echo "PASS: Usage comment names test-scope-reservations.sh"
else
  echo "FAIL: Usage comment does not name test-scope-reservations.sh"
  fail=1
fi
exit "$fail"

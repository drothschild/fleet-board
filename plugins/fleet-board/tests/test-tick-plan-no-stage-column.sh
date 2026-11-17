#!/usr/bin/env bash
#
# tick-plan.sh carries no dead stage-column code: legacy review_<name> columns are retired,
# so the planner no longer maps a state to a stage.
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan-no-stage-column.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TICK="$SCRIPT_DIR/../scripts/tick-plan.sh"

PASS=0
FAIL=0
count="$(grep -c "fb_stage_of_state" "$TICK" || true)"
if [ "$count" = 0 ]; then
  PASS=$((PASS + 1)); echo "  ok   grep -c fb_stage_of_state tick-plan.sh gives 0"
else
  FAIL=$((FAIL + 1)); echo "  FAIL grep -c fb_stage_of_state tick-plan.sh gives 0 (got $count)"
fi

echo "passed: $PASS failed: $FAIL"
[ "$FAIL" = 0 ]

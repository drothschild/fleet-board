#!/usr/bin/env bash
#
# Plain-bash test: the SKILL.md wording change must not break the existing import-plan suite.
# Maps the Acceptance item "test-import-plan.sh still exits 0".
#
# Usage: bash plugins/fleet-board/tests/test-import-plan-regression.sh

set -uo pipefail
unset CDPATH || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

if bash "$SCRIPT_DIR/test-import-plan.sh" >/dev/null 2>&1; then
  echo "  ok   test-import-plan.sh still exits 0"
  echo "passed: 1 failed: 0"
  exit 0
fi
echo "  FAIL test-import-plan.sh still exits 0: suite exited non-zero"
echo "passed: 0 failed: 1"
exit 1

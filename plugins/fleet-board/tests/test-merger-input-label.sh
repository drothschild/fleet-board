#!/usr/bin/env bash
#
# Plain-bash test: the merger agent prompt must not label its after_merge input
# "Merged head" (it invites an ancestry check that fails under squash merges).
#
# Usage: bash plugins/fleet-board/tests/test-merger-input-label.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MERGER="${SCRIPT_DIR}/../agents/merger.md"

PASS=0
FAIL=0

check() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1))
    echo "ok - ${name}"
  else
    FAIL=$((FAIL + 1))
    echo "not ok - ${name}: expected ${want}, got ${got}"
  fi
}

count="$(grep -c "Merged head" "$MERGER")"
check "grep -c \"Merged head\" merger.md gives 0" "0" "$count"

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

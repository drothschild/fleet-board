#!/usr/bin/env bash
#
# Plain-bash test: the merger spec doc must not use the old "Merged head" label
# for the after_merge input.
#
# Usage: bash plugins/fleet-board/tests/test-merger-spec-label.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SPEC="${SCRIPT_DIR}/../../../docs/implementation-plans/2026-09-28-fleet-board/specs/merger.md"

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

count="$(grep -c "Merged head" "$SPEC")"
check "grep -c \"Merged head\" specs/merger.md gives 0" "0" "$count"

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

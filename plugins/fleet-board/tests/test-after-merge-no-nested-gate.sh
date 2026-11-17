#!/usr/bin/env bash
#
# Card 484: test-after-merge.sh no longer runs test-gate.sh inside itself.
# Usage: bash plugins/fleet-board/tests/test-after-merge-no-nested-gate.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TARGET="$SCRIPT_DIR/test-after-merge.sh"
PASS=0
FAIL=0

check() {
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "PASS: $1"
  else FAIL=$((FAIL + 1)); echo "FAIL: $1 (expected '$3', got '$2')"; fi
}

check "test-after-merge.sh does not mention test-gate.sh" "$(grep -c 'test-gate.sh' "$TARGET")" "0"
check "test-after-merge.sh has no gate unchanged group" "$(grep -c 'gate unchanged' "$TARGET")" "0"
check "test-after-merge.sh keeps its docs group" "$(grep -c '^echo "docs"' "$TARGET")" "1"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

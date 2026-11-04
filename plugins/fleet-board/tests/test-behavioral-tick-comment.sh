#!/usr/bin/env bash
#
# The seed_merge comment in behavioral-tick.sh must not claim merge.policy: human.
#
# Usage: bash plugins/fleet-board/tests/test-behavioral-tick-comment.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TARGET="${SCRIPT_DIR}/behavioral-tick.sh"

n=$(grep -c 'merge.policy: human' "$TARGET")
if [ "$n" = "0" ]; then
  echo "ok - behavioral-tick.sh has 0 lines saying 'merge.policy: human'"
  exit 0
fi
echo "not ok - behavioral-tick.sh has $n lines saying 'merge.policy: human', expected 0"
exit 1

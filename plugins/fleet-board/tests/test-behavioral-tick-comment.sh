#!/usr/bin/env bash
#
# The seed_merge comment in behavioral-tick.sh must not go stale: it must not say
# "Merges stay human" and must not claim merge.policy: human.
#
# Usage: bash plugins/fleet-board/tests/test-behavioral-tick-comment.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TARGET="${SCRIPT_DIR}/behavioral-tick.sh"

fail=0

n=$(grep -c 'Merges stay human' "$TARGET")
if [ "$n" -eq 0 ]; then
  echo "ok - behavioral-tick.sh has 0 occurrences of 'Merges stay human'"
else
  echo "not ok - behavioral-tick.sh has $n occurrences of 'Merges stay human', want 0"
  fail=1
fi

n=$(grep -c 'merge.policy: human' "$TARGET")
if [ "$n" -eq 0 ]; then
  echo "ok - behavioral-tick.sh has 0 lines saying 'merge.policy: human'"
else
  echo "not ok - behavioral-tick.sh has $n lines saying 'merge.policy: human', expected 0"
  fail=1
fi

exit "$fail"

#!/usr/bin/env bash
# fleet-board: aggregate runner (CI runs the suites themselves and skips this file)
#
# Runs every tick-plan planner suite and prints their combined total. The scenarios that used
# to live here are split across tests/test-tick-plan-<area>.sh (card 408), which share
# tests/tick-plan-lib.sh. Run one of those on its own when you only touch its area; run this
# for the whole planner. Kept so commands and cards that name test-tick-plan.sh still work.
#
# Usage: bash plugins/fleet-board/tests/test-tick-plan.sh
# Exit: 0 when every suite passes, 1 when any suite fails or none is found.

set -uo pipefail
unset CDPATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

pass_total=0
fail_total=0
suites=0
failed_suites=""
for suite in "$SCRIPT_DIR"/test-tick-plan-*.sh; do
  [ -f "$suite" ] || continue
  name="$(basename "$suite")"
  # Only the planner scenario suites: they source the shared helper file. The split's own
  # structure test and the helper-order check source nothing and are not planner scenarios.
  grep -Eq '^\. +"?\$SCRIPT_DIR/tick-plan-lib\.sh"?' "$suite" || continue
  suites=$((suites + 1))
  echo "== $name"
  out="$(bash "$suite" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  line="$(printf '%s\n' "$out" | grep -E '^passed: [0-9]+ +failed: [0-9]+' | tail -1)"
  p="$(printf '%s\n' "$line" | sed -E 's/^passed: ([0-9]+).*/\1/')"
  f="$(printf '%s\n' "$line" | sed -E 's/.*failed: ([0-9]+).*/\1/')"
  [ -n "$line" ] || { p=0; f=1; echo "  FAIL $name printed no passed/failed line (exit $rc)"; }
  pass_total=$((pass_total + p))
  fail_total=$((fail_total + f))
  if [ "$rc" -ne 0 ] || [ "$f" -ne 0 ]; then failed_suites="$failed_suites $name"; fi
done

echo ""
echo "tick-plan suites: $suites${failed_suites:+   failed:$failed_suites}"
printf 'passed: %d   failed: %d\n' "$pass_total" "$fail_total"
[ "$suites" -gt 0 ] && [ -z "$failed_suites" ]

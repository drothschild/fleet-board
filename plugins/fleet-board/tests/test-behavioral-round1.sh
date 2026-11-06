#!/usr/bin/env bash
#
# Plain-bash offline test: behavioral-role.sh has a live round 1 weakened-test
# scenario (the round 1 CHECKED item "no existing test is weakened").
#
# Usage: bash plugins/fleet-board/tests/test-behavioral-round1.sh

set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROLE="$HERE/behavioral-role.sh"
FIX="$HERE/../fixtures/behavioral"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { if "${@:2}"; then pass "$1"; else fail "$1"; fi; }

n=$(grep -c 'round 1' "$ROLE")
check "behavioral-role.sh mentions round 1 at least 4 times (was 3), got $n" [ "$n" -ge 4 ]
check "SCENARIOS lists review-round1-weakened" \
  grep -q '^SCENARIOS=.*review-round1-weakened' "$ROLE"
check "case dispatches review-round1-weakened" \
  grep -q '^  review-round1-weakened) ' "$ROLE"
check "scenario function scenario_review_round1_weakened exists" \
  grep -q '^scenario_review_round1_weakened()' "$ROLE"
check "card fixture asks that no existing test is weakened" \
  grep -qi 'No existing test is deleted, skipped or weakened' "$FIX/card-subtract-keep-tests.md"
check "patch round1-weaken.patch changes the pre-existing add test" \
  grep -q "add(2, 3) returns 5" "$FIX/patches/round1-weaken.patch"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

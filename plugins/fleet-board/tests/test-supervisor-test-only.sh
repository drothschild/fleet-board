#!/usr/bin/env bash
# FLEET_TEST_ONLY=<test name> makes the slow Python-backed supervisor suites run that one test, so
# the reviewer's commands.test_case ("FLEET_TEST_ONLY={name} bash {file}") runs one test per mutant
# in place of the whole suite. Each selected run must show exactly one test and pass; a name that
# matches nothing runs zero tests, so the reviewer falls back to the whole file.
#
# Usage: bash plugins/fleet-board/tests/test-supervisor-test-only.sh

set -uo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

# ran <output>: how many tests a run reports (unittest's "Ran N test(s)", else the runner's ok/FAIL lines)
ran() {
  local n
  n="$(printf '%s\n' "$1" | sed -n 's/^Ran \([0-9][0-9]*\) tests\{0,1\}.*/\1/p' | tail -1)"
  if [ -n "$n" ]; then echo "$n"; return; fi
  printf '%s\n' "$1" | grep -cE '^  (ok|FAIL) +[A-Za-z_]' || true
}

check() { # <suite> <test name>
  local suite="$1" name="$2" out rc n
  out="$(FLEET_TEST_ONLY="$name" bash "$HERE/$suite" 2>&1)"; rc=$?
  n="$(ran "$out")"
  if [ "$rc" -eq 0 ] && [ "$n" = 1 ]; then
    pass "$suite: FLEET_TEST_ONLY=$name runs exactly that one test and passes"
  else
    fail "$suite: FLEET_TEST_ONLY=$name runs exactly that one test and passes" "exit $rc, tests $n: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi
  out="$(FLEET_TEST_ONLY=test_no_such_case_anywhere bash "$HERE/$suite" 2>&1)"
  n="$(ran "$out")"
  if [ "$n" = 0 ]; then
    pass "$suite: an unknown FLEET_TEST_ONLY name runs no test"
  else
    fail "$suite: an unknown FLEET_TEST_ONLY name runs no test" "tests $n: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi
}

check test-supervisor-driver.sh test_start_runs_setup_and_returns_a_session
check test-supervisor-merging.sh test_merged_card_goes_to_after_merge
check test-supervisor-loop.sh test_two_cards_progress_concurrently
check test-supervisor-stuck.sh test_in_progress_card_without_a_live_session_is_in_flight

echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]

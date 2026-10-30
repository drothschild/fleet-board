#!/usr/bin/env bash
#
# Proves the CI suite runner (.github/scripts/run-suites.sh) actually runs a
# suite named test-clean-room.sh, passing and failing, rather than skipping it.
#
# Usage: bash plugins/fleet-board/tests/test-ci-runner-clean-room.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RUNNER="${RUNNER:-${ROOT}/.github/scripts/run-suites.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); printf '  FAIL %s\n' "$1"; }

FIX="$TMP/fix"; mkdir -p "$FIX"
printf 'exit 0\n' > "$FIX/test-clean-room.sh"

out="$(bash "$RUNNER" "$FIX/test-*.sh" 2>&1)"; rc=$?
printf '%s\n' "$out" | grep -q 'test-clean-room.sh.*PASS' \
  && pass "runner runs and reports a passing test-clean-room.sh" \
  || fail "runner output lacks 'test-clean-room.sh ... PASS': $out"
[ "$rc" -eq 0 ] && pass "runner exits 0 for a passing test-clean-room.sh" \
  || fail "runner exited $rc for a passing test-clean-room.sh"

printf 'exit 4\n' > "$FIX/test-clean-room.sh"
out="$(bash "$RUNNER" "$FIX/test-*.sh" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "runner fails when test-clean-room.sh fails" \
  || fail "runner exited 0 although test-clean-room.sh fails"
printf '%s\n' "$out" | grep -q 'test-clean-room.sh.*FAIL' \
  && pass "runner reports a failing test-clean-room.sh" \
  || fail "runner output lacks 'test-clean-room.sh ... FAIL': $out"

echo
if [ "$FAILS" -eq 0 ]; then echo "all passed"; exit 0; fi
echo "$FAILS failed"; exit 1

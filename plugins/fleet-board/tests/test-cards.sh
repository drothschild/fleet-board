#!/usr/bin/env bash
#
# Plain-bash tests for scripts/cards.sh, the create | add | move helper
# (usage and flag handling; the board itself is covered by the adapter suites).
#
# Usage: bash plugins/fleet-board/tests/test-cards.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CARDS="$SCRIPT_DIR/../scripts/cards.sh"

unset FLEET_BOARD_CONFIG CDPATH || true

PASS=0
FAIL=0
LAST_ERR=""
LAST_EXIT=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

# run ARGS...: runs cards.sh from an empty directory (no config), capturing
# stderr and the exit status
run() {
  local d
  d="$(mktemp -d)"
  LAST_ERR="$(cd "$d" && bash "$CARDS" "$@" 2>&1 >/dev/null </dev/null)"
  LAST_EXIT=$?
  rm -rf "$d"
}

# usage_exit2 NAME ARGS...: exit 2 and a usage line naming the subcommand
usage_exit2() {
  local name="$1"
  shift
  run "$@"
  if [ "$LAST_EXIT" = 2 ]; then pass "$name: exit 2"; else fail "$name: exit 2" "got $LAST_EXIT (stderr: $LAST_ERR)"; fi
  case "$LAST_ERR" in
    *usage:*) pass "$name: usage message" ;;
    *) fail "$name: usage message" "stderr: $LAST_ERR" ;;
  esac
}

echo "Test: scripts/cards.sh"
echo ""

# the script exists and is a bash script
if [ -f "$CARDS" ]; then pass "cards.sh exists"; else fail "cards.sh exists" "missing $CARDS"; fi

usage_exit2 "no subcommand"
usage_exit2 "unknown subcommand" frobnicate
usage_exit2 "create without arguments" create
usage_exit2 "create with a bad flag" create T /dev/null --bogus
usage_exit2 "create with --label and no value" create T /dev/null --label
usage_exit2 "create with --repo and no value" create T /dev/null --repo
usage_exit2 "add without a number" add
usage_exit2 "add with a bad flag" add 12 --bogus
usage_exit2 "add with a non-numeric card" add abc
usage_exit2 "move without a state" move 12
usage_exit2 "move with a bad flag" move 12 ready --bogus
usage_exit2 "move with a non-numeric card" move abc ready
usage_exit2 "move with an invalid state" move 12 sideways

for sub in create add move; do
  run "$sub" --help
  if [ "$LAST_EXIT" = 0 ]; then pass "$sub --help: exit 0"; else fail "$sub --help: exit 0" "got $LAST_EXIT"; fi
done

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

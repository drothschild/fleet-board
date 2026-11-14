#!/usr/bin/env bash
#
# Plain-bash test that the .superpowers/sdd/ ledger no longer mentions
# the stale docs/superpowers paths.
#
# Usage: bash plugins/fleet-board/tests/test-superpowers-ledger-paths.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# .superpowers/sdd/ gives the result the description above expects:
# git grep -c 'docs/superpowers' -- .superpowers prints no matches
out="$(git -C "$ROOT" grep -c 'docs/superpowers' -- .superpowers 2>&1)"
if [ -z "$out" ]; then
  pass ".superpowers/sdd/ has no docs/superpowers matches"
else
  fail ".superpowers/sdd/ has no docs/superpowers matches (found: $out)"
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

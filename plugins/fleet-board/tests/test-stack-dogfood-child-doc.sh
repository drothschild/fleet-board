#!/usr/bin/env bash
#
# Plain-bash test for the stacked child's line in docs/stack-dogfood.md.
#
# Usage: bash plugins/fleet-board/tests/test-stack-dogfood-child-doc.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DOC="$SCRIPT_DIR/../../../docs/stack-dogfood.md"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want: $3 got: $2)"; fi
}

if [ -f "$DOC" ]; then
  first="$(sed -n '1p' "$DOC")"
  second="$(sed -n '2p' "$DOC")"
  third="$(sed -n '3p' "$DOC")"
else
  first="(missing file)"; second="(missing file)"; third="(missing file)"
fi

check "The first line of docs/stack-dogfood.md is still exactly \"# Stack dogfood\"" "$first" "# Stack dogfood"
check "The second line of docs/stack-dogfood.md is still exactly \"parent: card A\"" "$second" "parent: card A"
check "The third line of docs/stack-dogfood.md is exactly \"child: card B\"" "$third" "child: card B"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

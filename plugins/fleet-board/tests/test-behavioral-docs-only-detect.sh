#!/usr/bin/env bash
#
# Plain-bash offline test: the docs-only scenario's detection of a test file
# that reads a markdown file (bl_reads_md in behavioral-lib.sh) flags a file
# that reads one and passes a file that does not, and behavioral-role.sh uses it.
#
# Usage: bash plugins/fleet-board/tests/test-behavioral-docs-only-detect.sh

set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FIX="$HERE/../fixtures/behavioral/docs-only"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }

check "detection flags a test file that reads a .md file" \
  bash -c '. "$1"; bl_reads_md < "$2"' _ "$HERE/behavioral-lib.sh" "$FIX/reads-md.sh.txt"
check "detection passes a test file that reads no .md file" \
  bash -c '. "$1"; ! bl_reads_md < "$2"' _ "$HERE/behavioral-lib.sh" "$FIX/no-md.sh.txt"
check "behavioral-role.sh feeds each added test file to bl_reads_md" \
  grep -q 'bl_reads_md; then bad=' "$HERE/behavioral-role.sh"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

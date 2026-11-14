#!/usr/bin/env bash
#
# Plain-bash test: the multi-repo board design spec exists and states its decisions.
#
# Usage: bash plugins/fleet-board/tests/test-multi-repo-spec.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SPEC="${SPEC_FILE:-${SCRIPT_DIR}/../../../docs/specs/2026-11-14-multi-repo-board-design.md}"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
nok() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }

# check <name> <grep -E pattern>
check() {
  if [ -f "$SPEC" ] && grep -Eqi -- "$2" "$SPEC"; then ok "$1"; else nok "$1"; fi
}

[ -f "$SPEC" ] && ok "spec file exists" || nok "spec file exists"

for s in Config "Card field" Supervisor Scope "Merge lane" Gate "Board page"; do
  check "The new multi-repo spec has a section named ${s}" "^#{1,6} +${s}[[:space:]]*$"
done

check 'The spec states that board.repos[].path must be an absolute path' \
  'board\.repos\[\]\.path.*must be an absolute path'
check "The spec states that each card uses its own repo's merge.policy and other per-repo settings" \
  "each card uses its own repo's .?merge\.policy"
check 'The spec states that sessions in another repo get FLEET_BOARD_HOME set to the home root' \
  'sessions in another repo get .?FLEET_BOARD_HOME.? set to the home root'
check 'The spec states that a tracked absolute path is machine-specific' \
  'tracked absolute path is machine-specific'

echo "passed: ${PASS} failed: ${FAIL}"
[ "$FAIL" -eq 0 ]

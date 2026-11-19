#!/usr/bin/env bash
#
# Plain-bash test: the plugin CLAUDE.md manager-note contract itself names
# review_passes and finding_rounds (not just the review-stage bullet).
#
# Usage: bash plugins/fleet-board/tests/test-docs-manager-note-contract.sh
# PLUGIN_CLAUDE overrides the file checked.

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_CLAUDE="${PLUGIN_CLAUDE:-${SCRIPT_DIR}/../CLAUDE.md}"

PASS=0
FAIL=0

check() {
  if [ "$2" = "ok" ]; then
    PASS=$((PASS + 1)); echo "ok - $1"
  else
    FAIL=$((FAIL + 1)); echo "not ok - $1"
  fi
}

has() {
  tr '\n' ' ' < "$1" | tr -s ' ' | grep -qiF -- "$2" && echo ok || echo bad
}

check "manager-note contract: review_passes (null or an object) counts clean passes per reviewer" \
  "$(has "$PLUGIN_CLAUDE" '`review_passes` (null or an object) counts, per reviewer, the clean passes at the current head')"
check "manager-note contract: finding_rounds (null or an object) counts rounds with findings per reviewer" \
  "$(has "$PLUGIN_CLAUDE" '`finding_rounds` (null or an object) counts, per reviewer, its own rounds with findings')"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

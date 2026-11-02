#!/usr/bin/env bash
#
# Plain-bash test that docs/config.md documents the accept command
# (scripts/accept.sh) and what it does to the manager note.
#
# Usage: bash plugins/fleet-board/tests/test-accept-docs.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DOC="$SCRIPT_DIR/../docs/config.md"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

doc_has() {
  if grep -qF -- "$2" "$DOC"; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

doc_has "config.md names the accept command" "accept.sh"
doc_has "config.md says the failure count is reset" "action_failures"
doc_has "config.md says the reviewed-sha baseline moves" "last_review.sha"
doc_has "config.md says who accepted is recorded" "accepted"
doc_has "config.md says only the authenticated login counts" "authenticated"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

#!/usr/bin/env bash
#
# Plain-bash test that plugins/fleet-board/CLAUDE.md documents the built-in
# review stages and how `enabled: false` removes one.
#
# Usage: bash plugins/fleet-board/tests/test-claude-md-stages-doc.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DOC="$SCRIPT_DIR/../CLAUDE.md"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

doc_has() {
  if grep -qF -- "$2" "$DOC"; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

n="$(grep -c "enabled: false" "$DOC")"
if [ "$n" -ge 1 ]; then pass "CLAUDE.md mentions enabled: false ($n lines)"; else fail "CLAUDE.md mentions enabled: false (got $n)"; fi
doc_has "CLAUDE.md names the documentation built-in stage" "documentation"
doc_has "CLAUDE.md names the blast_radius built-in stage" "blast_radius"
doc_has "CLAUDE.md says built-in stages come from builtin_stages" "builtin_stages"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

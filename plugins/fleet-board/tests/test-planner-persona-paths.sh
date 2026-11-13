#!/usr/bin/env bash
# Stricter check: no absolute or personal path of any kind in the shipped
# planner persona or config-defaults.json (covers /opt/..., C:\..., ~/...).
# Usage: bash plugins/fleet-board/tests/test-planner-persona-paths.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="${SCRIPT_DIR}/../scripts"
DEFAULT_PERSONA="${SCRIPT_DIR}/../skills/planner/references/persona.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

ABS_RE='(^|[[:space:]"'"'"'(=`])/[A-Za-z0-9_.-]+|~/|[A-Za-z]:\\|\$HOME'

has_abs() { grep -Eq "$ABS_RE" "$@"; }

if [ -f "$DEFAULT_PERSONA" ] && ! has_abs "$DEFAULT_PERSONA" "$SCRIPTS/config-defaults.json"; then
  pass "no absolute or personal path of any kind in shipped default or config-defaults.json"
else fail "no absolute or personal path of any kind in shipped default or config-defaults.json" "missing persona file or path found"; fi

# The detector must catch a non-/Users, non-/home absolute path.
cp "$DEFAULT_PERSONA" "$TMP/mutant.md"
printf 'See /opt/planner/persona.md for details.\n' >> "$TMP/mutant.md"
if has_abs "$TMP/mutant.md"; then pass "detector flags /opt/planner/persona.md"
else fail "detector flags /opt/planner/persona.md" "mutant not detected"; fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

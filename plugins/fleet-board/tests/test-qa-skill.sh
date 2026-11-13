#!/usr/bin/env bash
#
# Plain-bash test: the /fleet-board:qa skill file exists with valid frontmatter,
# names its build config and card-filing calls, and never moves a card.
#
# Usage: bash plugins/fleet-board/tests/test-qa-skill.sh
# SKILL_FILE overrides the file checked.

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL="${SKILL_FILE:-${SCRIPT_DIR}/../skills/qa/SKILL.md}"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

if [ ! -f "$SKILL" ]; then
  bad "skill file exists: $SKILL"
  echo "$PASS passed, $FAIL failed"
  exit 1
fi
ok "skill file exists"

front="$(awk 'NR==1 && $0!="---"{exit} NR==1{next} /^---$/{exit} {print}' "$SKILL")"

if printf '%s\n' "$front" | grep -qx 'name: qa'; then ok "frontmatter has name: qa"; else bad "frontmatter has name: qa"; fi
if printf '%s\n' "$front" | grep -Eq '^description: *[^ ]'; then ok "frontmatter has a description"; else bad "frontmatter has a description"; fi
if printf '%s\n' "$front" | grep -qx 'user-invocable: true'; then ok "frontmatter has user-invocable: true"; else bad "frontmatter has user-invocable: true"; fi

for term in 'commands.qa_build' 'board-create.sh' '--blocked-by'; do
  if grep -qF -- "$term" "$SKILL"; then ok "skill names $term"; else bad "skill names $term"; fi
done

if grep -qF 'board-move.sh' "$SKILL"; then bad "skill names no board-move.sh call"; else ok "skill names no board-move.sh call"; fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

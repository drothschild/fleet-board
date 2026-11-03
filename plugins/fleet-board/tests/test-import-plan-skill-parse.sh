#!/usr/bin/env bash
#
# Plain-bash tests: skills/import-plan/SKILL.md documents `import-plan.sh parse` as an
# optional shortcut, not a requirement.
#
# Usage: bash plugins/fleet-board/tests/test-import-plan-skill-parse.sh

set -uo pipefail
unset CDPATH || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL="$SCRIPT_DIR/../skills/import-plan/SKILL.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; }
atleast1() { # name count
  if [ "$2" -ge 1 ]; then pass "$1"; else fail "$1" "count was $2"; fi
}

atleast1 "skill mentions import-plan.sh parse in the read step" \
  "$(awk '/^## Step 1/{s=1;next} /^## /{s=0} s' "$SKILL" | grep -c 'import-plan.sh parse')"
atleast1 "skill states parse applies to plans with Test steps: blocks" "$(grep -c 'Test steps:' "$SKILL")"
atleast1 "skill states parse applies to plans with Files: blocks" "$(grep -c 'Files:' "$SKILL")"
atleast1 "skill covers any other plan layout (model groups tasks itself)" "$(grep -c -i 'any other' "$SKILL")"
n="$(grep -c -i 'must use.*parse\|always.*parse' "$SKILL")"
if [ "$n" -eq 0 ]; then pass "skill does not require parse"; else fail "skill does not require parse" "count was $n"; fi

echo "passed: $PASS failed: $FAIL"
[ "$FAIL" -eq 0 ]

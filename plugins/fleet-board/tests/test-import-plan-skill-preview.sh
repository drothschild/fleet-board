#!/usr/bin/env bash
#
# Plain-bash tests: skills/import-plan/SKILL.md tells a --preview session (which runs under
# dontAsk with only the dry run and the final cp pre-approved) not to give up when another
# command is denied, and where device checks go (Human QA, not Acceptance: card lint refuses them).
#
# Usage: bash plugins/fleet-board/tests/test-import-plan-skill-preview.sh

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

step3="$(awk '/^## Step 3/{s=1;next} /^## /{s=0} s' "$SKILL")"
step2="$(awk '/^## Step 2/{s=1;next} /^## /{s=0} s' "$SKILL")"

atleast1 "step 3 says a preview session may run only the dry run and the cp" \
  "$(printf '%s\n' "$step3" | grep -c -i 'only .*dry run.*cp\|only the commands')"
atleast1 "step 3 says a denied other command is not a reason to skip the dry run" \
  "$(printf '%s\n' "$step3" | grep -c 'run the dry run anyway')"
atleast1 "step 3 says what to do when the dry run itself is denied" \
  "$(printf '%s\n' "$step3" | grep -c 'dry run itself is denied')"
atleast1 "step 3 tells a session that is denied the dry run to report that and stop" \
  "$(printf '%s\n' "$step3" | grep -c 'report that and stop')"
atleast1 "step 2 sends device checks to a ## Human QA section in why" \
  "$(printf '%s\n' "$step2" | grep -c '## Human QA')"
atleast1 "step 2 keeps device checks out of acceptance" \
  "$(printf '%s\n' "$step2" | grep -c -i 'never in .acceptance\|not in .acceptance\|out of .acceptance')"

atleast1 "step 2 requires the needs-human-qa label with a Human QA section" \
  "$(printf '%s\n' "$step2" | grep -c 'needs-human-qa')"
atleast1 "step 2 keeps file paths out of Human QA bullets" \
  "$(printf '%s\n' "$step2" | grep -c -i 'no file paths')"

echo "passed: $PASS failed: $FAIL"
[ "$FAIL" -eq 0 ]

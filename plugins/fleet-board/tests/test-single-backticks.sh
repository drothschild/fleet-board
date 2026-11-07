#!/usr/bin/env bash
#
# Plain-bash guard: the role guidance says the Out of scope check command is
# written in single backticks with no backtick inside it.
#
# Usage: bash plugins/fleet-board/tests/test-single-backticks.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SPECS_DIR="$PLUGIN_DIR/../../docs/implementation-plans/2026-09-28-fleet-board/specs"
REPO_DIR="$(cd "$PLUGIN_DIR/../.." && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# at_least_one NAME FILE PATTERN
at_least_one() {
  local n
  n="$(grep -c -- "$3" "$2" 2>/dev/null)"
  if [ "${n:-0}" -ge 1 ]; then pass "$1"; else fail "$1 (count ${n:-0})"; fi
}

for r in implementor reviewer fixer reporting; do
  at_least_one "spec $r states 'no backtick inside'" "$SPECS_DIR/$r.md" 'no backtick inside'
done
for f in agents/implementor.md agents/reviewer.md agents/fixer.md skills/reporting/SKILL.md; do
  at_least_one "$f ties the check command to 'single backticks'" "$PLUGIN_DIR/$f" 'check command.*single backticks\|single backticks.*check command'
done

# The last revision section is this card's: heading names single backticks and
# its Isolation line reads built-in plugins only, tools exactly Edit and Read.
# Revision 16 is this change. Find it by number: a later revision appended
# after it must not make this check fail.
r16_head="$(grep -n '^### Revision 16 ' "$SPECS_DIR/README.md")"
case "$r16_head" in
  *'single backtick'*) pass "README has a new revision section about single backticks" ;;
  *) fail "README Revision 16 heading does not mention single backticks: $r16_head" ;;
esac
iso="$(grep '^Isolation:' "$SPECS_DIR/README.md" | tail -1)"
case "$iso" in
  *'cc-plugin-*@builtin'*'tools exactly `Edit` and `Read`'*) pass "README isolation line: built-in plugins only, tools Edit and Read" ;;
  *) fail "README isolation line wrong: $iso" ;;
esac

printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

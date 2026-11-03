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
  at_least_one "$f says 'single backticks'" "$PLUGIN_DIR/$f" 'single backticks'
done

# README: the new revision section raises the 'tools exactly' count above main's.
readme_rel="docs/implementation-plans/2026-09-28-fleet-board/specs/README.md"
base="$(git -C "$REPO_DIR" show "main:$readme_rel" 2>/dev/null | grep -c 'tools exactly')"
now="$(grep -c 'tools exactly' "$SPECS_DIR/README.md")"
if [ "$now" -gt "${base:-0}" ]; then
  pass "README 'tools exactly' count rose ($base -> $now)"
else
  fail "README 'tools exactly' count did not rise (main $base, now $now)"
fi

if grep -q 'built-in plugins only, tools `Edit` and `Read`' "$SPECS_DIR/README.md"; then
  pass "README isolation line reads built-in plugins only, tools Edit and Read"
else
  fail "README isolation line missing 'built-in plugins only, tools \`Edit\` and \`Read\`'"
fi

printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

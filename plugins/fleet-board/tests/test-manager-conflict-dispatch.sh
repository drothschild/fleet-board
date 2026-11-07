#!/usr/bin/env bash
#
# Plain-bash checks for the card "Teach the manager about conflict dispatch":
# the manager spec and agent name conflicted_files, dispatch the fixer for a plan
# fix with findings, clear conflicted_files and last_review after a resolved
# merge, and block naming the files when the fixer is blocked.
#
# Usage: bash plugins/fleet-board/tests/test-manager-conflict-dispatch.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
SPEC="$ROOT/../../docs/implementation-plans/2026-09-28-fleet-board/specs/manager.md"
AGENT="$ROOT/agents/manager.md"
TICK="$SCRIPT_DIR/behavioral-tick.sh"
PASS=0
FAIL=0

check() { # <name> <file> <fixed string>
  if grep -qF -- "$3" "$2"; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s lacks: %s\n' "$2" "$3"; fi
}

count=$(grep -c conflicted_files "$AGENT")
if [ "${count:-0}" -ge 1 ]; then PASS=$((PASS + 1)); printf '  ok   grep -c conflicted_files agents/manager.md is 1 or more (%s)\n' "$count"
else FAIL=$((FAIL + 1)); printf '  FAIL grep -c conflicted_files agents/manager.md is 1 or more (%s)\n' "$count"; fi

check "agent: fix passes the plan card's findings to the fixer" "$AGENT" "plan card's \`findings\`"
check "agent: fix clears conflicted_files after a resolved merge" "$AGENT" "\`conflicted_files: null\`"
check "agent: fix resets last_review after a resolved merge" "$AGENT" "\`last_review: null\`"
check "agent: a blocked fixer blocks the card naming the files" "$AGENT" "names the conflicted files"
check "spec: manager.md names conflicted_files" "$SPEC" "conflicted_files"

# the behavioral scenario that exercises 2.9a with a conflicted seeded PR
check "behavioral-tick: SCENARIOS lists conflict-dispatch" "$TICK" 'SCENARIOS="default ready-path bad-report fix-block merge-auto merge-red out-of-scope bug-found waits-on-dependency provider-reviewer conflict-dispatch"'
check "behavioral-tick: header documents the conflict-dispatch scenario" "$TICK" "#   conflict-dispatch"
check "behavioral-tick: case dispatches conflict-dispatch" "$TICK" "  conflict-dispatch) scenario_conflict_dispatch ;;"
check "behavioral-tick: scenario_conflict_dispatch is defined" "$TICK" "scenario_conflict_dispatch() {"
check "behavioral-tick: scenario seeds conflicted_files in the note" "$TICK" '.conflicted_files = ["src/calc.js"]'
check "behavioral-tick: scenario asserts the fixer gets the conflict finding" "$TICK" "merge conflict in src/calc.js"
check "behavioral-tick: scenario asserts last_review and conflicted_files are cleared" "$TICK" ".conflicted_files == null and .last_review == null"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

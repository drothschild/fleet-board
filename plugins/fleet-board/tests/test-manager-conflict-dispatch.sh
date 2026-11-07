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

# Runtime check: run the real tick-plan.sh against a card whose note records
# conflicted_files and assert it plans the fixer with the conflict as a finding.
# (Text greps above cannot notice conflict detection being disabled.)
PLAN_SH="$ROOT/scripts/tick-plan.sh"
FIXT="$ROOT/fixtures/gh/tick"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
git init -q "$T/repo"
git -C "$T/repo" config user.email t@example.com
git -C "$T/repo" config user.name T
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\nhuman_qa_paths: ["src/components/**"]\n' > "$T/repo/.fleet-board.yml"
git -C "$T/repo" add .fleet-board.yml
git -C "$T/repo" commit -q -m initial
mkdir -p "$T/bin" "$T/routes.d"
ln -s "$SCRIPT_DIR/fake-gh.sh" "$T/bin/gh"
NOTE='{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1,"last_review":{"round":1,"sha":"abc1234","critical":0,"important":0,"findings":[]},"action_failures":1,"last_action_error":"merge conflicts","conflicted_files":["src/calc.js"]}'
jq -cn --arg note "$NOTE" '[{id: 555, user: {login: "fleet-bot"},
  body: ("<!-- fleet-board:manager-note -->\n### fleet-board manager note\nState: x\n\n```json\n" + $note + "\n```\n"),
  created_at: "2026-09-28T00:01:00Z"}]' > "$T/routes.d/comments.json"
sed -e "s#	\.\./#	$FIXT/#" -e "s#	comments-12.json#	$T/routes.d/comments.json#" "$FIXT/action-failures-in-review-3/routes" > "$T/routes.d/routes"
PLAN_OUT="$(cd "$T/repo" && unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT; FAKE_GH_DIR="$T" FAKE_GH_ROUTES="$T/routes.d/routes" PATH="$T/bin:$PATH" bash "$PLAN_SH" 2>/dev/null)"
got="$(jq -c '.cards[] | select(.number == 12) | [.action, .findings]' <<<"$PLAN_OUT" 2>/dev/null || echo INVALID)"
want='["fix",[{"severity":"Important","text":"merge conflict in src/calc.js"}]]'
if [ "$got" = "$want" ]; then PASS=$((PASS + 1)); printf '  ok   runtime: tick-plan.sh plans fix with the conflicted file as a finding\n'
else FAIL=$((FAIL + 1)); printf '  FAIL runtime: tick-plan.sh plans fix with the conflicted file as a finding\n'; printf '       got: %s\n' "$got"; fi

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

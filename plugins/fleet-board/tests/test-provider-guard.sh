#!/usr/bin/env bash
#
# Plain-bash tests for scripts/providers/guard/: the command shims and the post-run check that
# hold a provider session to the limits a Claude role has (offline; local board, local bare remote).
#
# Usage: bash plugins/fleet-board/tests/test-provider-guard.sh
# FLEET_TEST_ONLY is not used; each case below is named by its assertion text.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$PLUGIN/scripts/providers/guard"
GATE="$PLUGIN/hooks/gate.sh"

unset FLEET_BOARD_CONFIG CDPATH GH_REPO GH_HOST || true
export FLEET_BOARD_USER=fleet-bot
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEAN=()
trap 'for d in ${CLEAN[@]+"${CLEAN[@]}"}; do rm -rf "$d"; done' EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }
assert_exit() { if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: $LAST_ERR; stdout: $LAST_OUT)"; fi; }
assert_err_has() { case "$LAST_ERR" in *"$2"*) pass "$1" ;; *) fail "$1" "expected '$2' in stderr, got: '$LAST_ERR'" ;; esac; }
assert_out_has() { case "$LAST_OUT" in *"$2"*) pass "$1" ;; *) fail "$1" "expected '$2' in stdout, got: '$LAST_OUT'" ;; esac; }
assert_equal() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }

# run DIR CMD...: runs the command in DIR and captures stdout, stderr and the exit code
run() {
  local dir="$1" o e
  shift
  o="$(mktemp)"; e="$(mktemp)"
  (cd "$dir" && "$@") > "$o" 2> "$e"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$o")"; LAST_ERR="$(cat "$e")"
  rm -f "$o" "$e"
}

# A repo with a local board (card 12 ready, card 14 in human_qa), merge.policy human, a bare origin
# and a worktree on the card's branch.
BRANCH="fleet/12-a-card"
ROOT="$(mktemp -d)"; CLEAN+=("$ROOT")
ORIGIN="$ROOT/origin.git"
REPO="$ROOT/repo"
WT="$ROOT/wt"
TMPD="$ROOT/tmp"
mkdir -p "$TMPD"
git init -q --bare "$ORIGIN"
git init -q -b main "$REPO"
cat > "$REPO/.fleet-board.yml" << 'YML'
board:
  repo: acme/toy
merge:
  policy: human
YML
printf '.fleet-board/\n.fleet-board.yml\n' > "$REPO/.gitignore"
echo hi > "$REPO/a.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m init
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q origin main
git -C "$REPO" worktree add -q -b "$BRANCH" "$WT"
mkdir -p "$REPO/.fleet-board/cards"
echo 15 > "$REPO/.fleet-board/next"
for spec in "12 ready" "14 human_qa"; do
  set -- $spec
  jq -n --argjson n "$1" --arg s "$2" \
    '{number: $n, title: ("card " + ($n | tostring)), body: "## Scope\n- a.txt\n", acceptance: ["works"], blocked_by: [], state: $s, labels: [], next_comment_id: 1, comments: []}' \
    > "$REPO/.fleet-board/cards/$1.json"
done

SHIMS="$ROOT/shims"
export FLEET_SCRIPTS="$PLUGIN/scripts"

# --- install ---------------------------------------------------------------------------------
run "$REPO" bash "$GUARD/install.sh" "$SHIMS" "$WT" "$BRANCH"
assert_exit "install: builds the guard directory" 0
for n in gh git curl board-move board-move.sh premise-settle.sh; do
  if [ -x "$SHIMS/$n" ]; then pass "install: shim $n exists"; else fail "install: shim $n exists" "missing $SHIMS/$n"; fi
done
run "$REPO" bash "$GUARD/install.sh" "$ROOT/shims2" "$ROOT/no-such-worktree" "$BRANCH"
assert_exit "install: a missing worktree fails closed" 2
run "$REPO" bash "$GUARD/install.sh" "$ROOT/shims3" "$WT" "fleet/99-other"
assert_exit "install: a worktree on another branch fails closed" 2

# --- gate parity: a shimmed gh pr merge / board-move.sh ----------------------------------------
gate_err() { # gate_err CMD: the stderr and exit code of gate.sh on the same command, in $REPO
  local p
  p="$(jq -nc --arg c "$1" --arg d "$REPO" '{session_id:"t",hook_event_name:"PreToolUse",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}')"
  GATE_ERR="$(bash "$GATE" <<<"$p" 2>&1 >/dev/null)"; GATE_EXIT=$?
}

gate_err "gh pr merge 5"
run "$REPO" "$SHIMS/gh" pr merge 5
assert_exit "shimmed gh pr merge exits 2" 2
assert_equal "shimmed gh pr merge prints the gate's line" "$LAST_ERR" "$GATE_ERR"
assert_equal "gate itself blocks gh pr merge 5 (exit)" "$GATE_EXIT" 2

gate_err "board-move.sh 14 ready"
run "$REPO" "$SHIMS/board-move.sh" 14 ready
assert_exit "shimmed board-move.sh 14 ready from human_qa exits 2" 2
assert_equal "shimmed board-move.sh prints the gate's line" "$LAST_ERR" "$GATE_ERR"
assert_err_has "the gate's message names Human QA" "Human QA"

# the implementor's own rule: it moves no card at all, even where the gate allows the move
gate_err "board-move.sh 12 in_progress"
assert_equal "gate allows moving a ready card (the shim's rule is stricter)" "$GATE_EXIT" 0
run "$REPO" "$SHIMS/board-move.sh" 12 in_progress
assert_exit "shimmed board-move.sh 12 in_progress exits 2 (a provider moves no card)" 2
assert_equal "card 12 did not move" "$(jq -r .state "$REPO/.fleet-board/cards/12.json")" ready

run "$REPO" "$SHIMS/premise-settle.sh" approve 12
assert_exit "shimmed premise-settle.sh approve exits 2" 2

# --- $ substitution ------------------------------------------------------------------------------
run "$REPO" "$SHIMS/gh" pr merge '$(echo 5)'
assert_exit "shimmed gh pr merge with a substitution for the PR exits 2" 2
run "$REPO" "$SHIMS/board-move.sh" '$(echo 14)' ready
assert_exit "shimmed board-move.sh with a substitution for the card exits 2" 2
run "$WT" "$SHIMS/git" push origin '$B'
assert_exit "shimmed git push with a variable for the branch exits 2" 2
# a case the shim's own rules allow (the verb is not merge/ready): only the gate blocks it
gate_err 'gh pr $(echo view) 5'
run "$REPO" "$SHIMS/gh" pr '$(echo view)' 5
assert_exit "shimmed gh pr with a substitution for the verb exits 2 (the gate blocks it)" 2
assert_equal "shimmed gh pr with a substitution prints the gate's line" "$LAST_ERR" "$GATE_ERR"
assert_err_has "the gate's line names the unverifiable gh subcommand" "could not verify the gh subcommand"

# --- git push --------------------------------------------------------------------------------------
echo work > "$WT/work.txt"
git -C "$WT" add work.txt && git -C "$WT" commit -q -m "work"
run "$WT" "$SHIMS/git" push origin HEAD:refs/heads/other-branch
assert_exit "shimmed git push to a branch other than the card's exits 2" 2
run "$WT" "$SHIMS/git" push origin "$BRANCH:main"
assert_exit "shimmed git push of the card's branch onto main exits 2" 2
run "$WT" "$SHIMS/git" push --force origin "$BRANCH"
assert_exit "shimmed git push --force exits 2" 2
assert_equal "origin has no other-branch" "$(git -C "$ORIGIN" branch --list other-branch | wc -l | tr -d ' ')" 0
run "$WT" "$SHIMS/git" push -u origin "$BRANCH"
assert_exit "shimmed git push to the card's branch passes through" 0
assert_equal "origin holds the card's branch at the worktree head" \
  "$(git -C "$ORIGIN" rev-parse "$BRANCH")" "$(git -C "$WT" rev-parse HEAD)"

# --- paths -------------------------------------------------------------------------------------------
run "$WT" "$SHIMS/git" -C "$REPO" status
assert_exit "shimmed git -C a path outside the worktree exits 2" 2
run "$REPO" "$SHIMS/git" status
assert_exit "shimmed git run from outside the worktree exits 2" 2
run "$WT" "$SHIMS/git" status
assert_exit "shimmed git status inside the worktree passes through" 0
run "$WT" "$SHIMS/git" add .fleet-board.yml
assert_exit "shimmed git add .fleet-board.yml exits 2" 2
run "$WT" "$SHIMS/git" checkout -- .fleet-board/cards
assert_exit "shimmed git checkout under .fleet-board/ exits 2" 2
run "$WT" "$SHIMS/curl" -s -X POST -H 'X-Fleet-Board: 1' http://127.0.0.1:8765/api/cards/14/move
assert_exit "shimmed curl that writes to the board server exits 2" 2

# --- sandbox flags and fail-closed start ----------------------------------------------------------------
run "$REPO" bash "$GUARD/sandbox-flags.sh" "$WT" "$TMPD"
assert_exit "sandbox-flags: prints flags for a worktree and a temp directory" 0
assert_out_has "sandbox-flags: limit writes to the workspace" "workspace-write"
assert_out_has "sandbox-flags: name the worktree" "$WT"
run "$REPO" bash "$GUARD/sandbox-flags.sh" "$WT" "$ROOT/no-such-tmp"
assert_exit "sandbox-flags: a missing temp directory fails closed" 2

MARK="$ROOT/session-ran"
run "$REPO" bash "$GUARD/start.sh" 12 "$REPO" "$WT" "$BRANCH" "$ROOT/no-such-tmp" -- bash -c "touch '$MARK'"
assert_exit "start: no sandbox flags, no session (exit 2)" 2
if [ -e "$MARK" ]; then fail "start: the provider command did not run" "marker exists"; else pass "start: the provider command did not run"; fi
assert_out_has "start: the failure is reported as an attention" '"attention"'
assert_equal "start: the card got a comment naming the attention" \
  "$(jq -r '[.comments[].body | select(contains("guard"))] | length' "$REPO/.fleet-board/cards/12.json")" 1

# a session that behaves: guard first on PATH, clean post-run check
run "$REPO" bash "$GUARD/start.sh" 12 "$REPO" "$WT" "$BRANCH" "$TMPD" -- bash -c 'echo "$PATH"'
assert_exit "start: a quiet session passes the post-run check" 0
GUARD_DIR_SEEN="${LAST_OUT%%:*}"
case "$GUARD_DIR_SEEN" in */guard-shims*) pass "start: the guard directory is first on the session's PATH" ;; *) fail "start: the guard directory is first on the session's PATH" "PATH began with: $GUARD_DIR_SEEN" ;; esac

# --- the shims add nothing to a Claude role's PATH ------------------------------------------------------
BEFORE="$PATH"
bash "$GUARD/install.sh" "$ROOT/shims4" "$WT" "$BRANCH" > /dev/null 2>&1
assert_equal "install leaves this shell's PATH alone" "$PATH" "$BEFORE"
assert_equal "a session not started by start.sh has no guard directory on PATH" \
  "$(bash -c 'echo "$PATH"' | tr ':' '\n' | grep -c 'guard-shims\|/shims')" 0
assert_equal "no supervisor module or hook names the guard directory" \
  "$(grep -rl 'providers/guard' "$PLUGIN/scripts/supervisor" "$PLUGIN/hooks" 2> /dev/null | wc -l | tr -d ' ')" 0

# --- post-run check ------------------------------------------------------------------------------------------
SNAP="$ROOT/snap.json"
run "$REPO" bash "$GUARD/post-run.sh" snapshot "$SNAP" "$REPO" "$WT" "$BRANCH" 12
assert_exit "post-run: snapshot written" 0
run "$REPO" bash "$GUARD/post-run.sh" check "$SNAP" "$REPO" "$WT" "$BRANCH" 12
assert_exit "post-run: no change, no attention" 0

echo "# changed" >> "$REPO/.fleet-board.yml"
run "$REPO" bash "$GUARD/post-run.sh" check "$SNAP" "$REPO" "$WT" "$BRANCH" 12
assert_exit "post-run: a write to .fleet-board.yml raises an attention (exit 3)" 3
assert_out_has "post-run: the attention names .fleet-board.yml" '.fleet-board.yml'
run "$REPO" bash "$GUARD/post-run.sh" snapshot "$SNAP" "$REPO" "$WT" "$BRANCH" 12

echo "persona" > "$REPO/.fleet-board/merger.md"
run "$REPO" bash "$GUARD/post-run.sh" check "$SNAP" "$REPO" "$WT" "$BRANCH" 12
assert_exit "post-run: a write under .fleet-board/ raises an attention (exit 3)" 3
assert_out_has "post-run: the attention names the path under .fleet-board/" 'merger.md'
run "$REPO" bash "$GUARD/post-run.sh" snapshot "$SNAP" "$REPO" "$WT" "$BRANCH" 12

jq '.state = "done"' "$REPO/.fleet-board/cards/12.json" > "$ROOT/c.json" && mv "$ROOT/c.json" "$REPO/.fleet-board/cards/12.json"
run "$REPO" bash "$GUARD/post-run.sh" check "$SNAP" "$REPO" "$WT" "$BRANCH" 12
assert_exit "post-run: a card state change raises an attention" 3
assert_out_has "post-run: the attention names the card state" 'card state'
run "$REPO" bash "$GUARD/post-run.sh" snapshot "$SNAP" "$REPO" "$WT" "$BRANCH" 12

git -C "$WT" push -q origin "HEAD:refs/heads/stray-branch"
run "$REPO" bash "$GUARD/post-run.sh" check "$SNAP" "$REPO" "$WT" "$BRANCH" 12
assert_exit "post-run: a branch pushed beyond the start raises an attention" 3
assert_out_has "post-run: the attention names the branch" 'stray-branch'
run "$REPO" bash "$GUARD/post-run.sh" snapshot "$SNAP" "$REPO" "$WT" "$BRANCH" 12

echo "stray" > "$REPO/stray-file.txt"
run "$REPO" bash "$GUARD/post-run.sh" check "$SNAP" "$REPO" "$WT" "$BRANCH" 12
assert_exit "post-run: a file changed outside the worktree raises an attention" 3
assert_out_has "post-run: the attention names the file" 'stray-file.txt'
rm -f "$REPO/stray-file.txt"

echo "work2" >> "$WT/work.txt"
run "$REPO" bash "$GUARD/post-run.sh" snapshot "$SNAP" "$REPO" "$WT" "$BRANCH" 12
echo "work3" >> "$WT/work.txt"
run "$REPO" bash "$GUARD/post-run.sh" check "$SNAP" "$REPO" "$WT" "$BRANCH" 12
assert_exit "post-run: edits inside the worktree are not a difference" 0

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

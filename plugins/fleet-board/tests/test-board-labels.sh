#!/usr/bin/env bash
#
# Plain-bash tests for board adapter contract scripts (labels backend)
# No framework, no dependencies beyond POSIX tools.
#
# Usage: bash plugins/fleet-board/tests/test-board-labels.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FIXTURES="$SCRIPT_DIR/../fixtures/gh"

unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()
ORIG_PATH="$PATH"

# Choose a bash executable for consistent invocation.
# Prefer /bin/bash if available (standard on macOS/BSD), else use bash from PATH.
if [ -x /bin/bash ]; then
  BASH_EXE="/bin/bash"
else
  BASH_EXE="bash"
fi

cleanup() {
  for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
    rm -rf "$dir" 2>/dev/null || true
  done
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

assert_exit() {
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT"; fi
}

assert_stdout_exact() {
  if [ "$LAST_OUT" = "$2" ]; then pass "$1"; else fail "$1" "stdout mismatch"; fi
}

assert_stdout_contains() {
  case "$LAST_OUT" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected '$2' in stdout" ;;
  esac
}

assert_stderr_contains() {
  case "$LAST_ERR" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected '$2' in stderr" ;;
  esac
}

run_check() {
  local script="$1"
  shift
  local tmpout tmperr
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  "$BASH_EXE" "$script" "$@" > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

assert_logs_contain() {
  local pattern="$1" desc="$2"
  if grep -q "$pattern" "$FAKE_GH_DIR/calls.log" 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc" "expected '$pattern' in calls.log"
  fi
}

assert_logs_not_contain() {
  local pattern="$1" desc="$2"
  if ! grep -q "$pattern" "$FAKE_GH_DIR/calls.log" 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc" "did not expect '$pattern' in calls.log"
  fi
}

# argv_has_pair: check if argv files contain consecutive <flag> <value> pair
# Scans through argv files looking for <flag> on one line and <value> on the next
argv_has_pair() {
  local flag="$1" value="$2"
  local prev_arg argv_file arg

  # Zero-padded names sort in call order; a pair never spans two calls.
  for argv_file in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$argv_file" ] || continue
    prev_arg=""
    while IFS= read -r arg || [ -n "$arg" ]; do
      if [ "$prev_arg" = "$flag" ] && [ "$arg" = "$value" ]; then
        return 0
      fi
      prev_arg="$arg"
    done < "$argv_file"
  done
  return 1
}

setup_case() {
  REPO=$(mktemp -d)
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"

  cat > "$REPO/.fleet-board.yml" << 'YML'
board:
  repo: acme/toy
worktrees:
  dir: .fw
YML
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"

  FAKE_GH_DIR=$(mktemp -d)
  ROUTES="$FAKE_GH_DIR/routes.txt"
  BIN="$FAKE_GH_DIR/bin"
  mkdir -p "$BIN"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"

  cd "$REPO"

  # Reset environment between cases
  unset FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true
  PATH="$BIN:$ORIG_PATH"

  CLEANUP_DIRS+=("$REPO")
  CLEANUP_DIRS+=("$FAKE_GH_DIR")
}

echo "Test: board adapter contract scripts (labels backend)"
echo ""

# AC2.1 list-only-state
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
issue list*	0	$FIXTURES/labels/issue-list-mixed.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "list-only-state: exit code" 0
assert_logs_contain "issue list --repo acme/toy --label fleet:ready --state open" "list-only-state: calls.log"
expected='[{"number":7,"title":"Seventh issue","url":"https://github.com/acme/toy/issues/7"},{"number":9,"title":"Ninth issue","url":"https://github.com/acme/toy/issues/9"}]'
if [ "$(echo "$LAST_OUT" | jq -c)" = "$expected" ]; then
  pass "list-only-state: stdout exact match"
else
  fail "list-only-state: stdout exact match" "expected $expected, got $(echo "$LAST_OUT" | jq -c)"
fi

# AC2.1 list-mapped-name
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
issue list*	0	$FIXTURES/labels/issue-list-mixed.json
ROUTESEOF
cat > "$REPO/.fleet-board.yml" << 'CONFIGYML'
board:
  repo: acme/toy
  states: { ready: "status: ready" }
worktrees:
  dir: .fw
CONFIGYML
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "list-mapped-name: exit code" 0
assert_logs_contain "issue list --repo acme/toy --label status: ready --state open" "list-mapped-name: calls.log"

# AC2.1 list-closed-states
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
issue list*	0	$FIXTURES/labels/issue-list-mixed.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" done
assert_exit "list-closed-states: exit code" 0
assert_logs_contain "issue list --repo acme/toy --label fleet:done --state all" "list-closed-states: calls.log"

# AC2.1 list-bad-state
setup_case
> "$ROUTES"
echo "api user	0	$FIXTURES/labels/user.json" >> "$ROUTES"
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" shipping
assert_exit "list-bad-state: exit code" 2

# AC2.2 move-order
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FIXTURES/labels/issue-12.json
issue edit*	0	-
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 in_progress
assert_exit "move-order: exit code" 0
remove_line=$(grep "issue edit 12 --repo acme/toy --remove-label fleet:ready" "$FAKE_GH_DIR/calls.log" 2>/dev/null | head -1)
add_line=$(grep "issue edit 12 --repo acme/toy --add-label fleet:in_progress" "$FAKE_GH_DIR/calls.log" 2>/dev/null | head -1)
if [ -n "$remove_line" ] && [ -n "$add_line" ]; then
  pass "move-order: both calls made"
else
  fail "move-order: both calls made" "remove=$remove_line, add=$add_line"
fi
remove_at=$(grep -n -- "--remove-label fleet:ready" "$FAKE_GH_DIR/calls.log" 2>/dev/null | head -1 | cut -d: -f1)
add_at=$(grep -n -- "--add-label fleet:in_progress" "$FAKE_GH_DIR/calls.log" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$remove_at" ] && [ -n "$add_at" ] && [ "$remove_at" -lt "$add_at" ]; then
  pass "move-order: remove precedes add"
else
  fail "move-order: remove precedes add" "remove at line ${remove_at:-none}, add at line ${add_at:-none}"
fi
if ! grep -qE '.*--add-label.*--remove-label.*|.*--remove-label.*--add-label.*' "$FAKE_GH_DIR/calls.log" 2>/dev/null; then
  pass "move-order: separate calls"
else
  fail "move-order: separate calls" "found both flags in single call"
fi
assert_logs_not_contain "bug" "move-order: non-state labels untouched"

# AC2.2 move-noop
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FIXTURES/labels/issue-12.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 ready
assert_exit "move-noop: exit code" 0
assert_logs_not_contain "issue edit" "move-noop: no edit call"

# AC2.3 note-replaces
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api --paginate repos/acme/toy/issues/12/comments	0	$FIXTURES/labels/comments-with-note.json
api -X PATCH repos/acme/toy/issues/comments/555 --input -	0	-
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
printf 'test note' > note.md
run_check "$SCRIPT_DIR/../scripts/board-note.sh" 12 note.md
assert_exit "note-replaces: exit code" 0
assert_logs_contain "api -X PATCH repos/acme/toy/issues/comments/555 --input -" "note-replaces: PATCH"
if [ "$(grep -c '^[^	]*	.*-X PATCH' "$FAKE_GH_DIR/calls.log" 2>/dev/null)" -eq 1 ]; then
  pass "note-replaces: exactly one PATCH"
else
  fail "note-replaces: exactly one PATCH" "found $(grep -c '^[^	]*	.*-X PATCH' "$FAKE_GH_DIR/calls.log" 2>/dev/null) PATCH calls"
fi
assert_logs_not_contain "api -X POST" "note-replaces: no POST"
assert_logs_not_contain "pin" "note-replaces: no pin"
if [ "$(ls "$FAKE_GH_DIR/inputs"/* 2>/dev/null | wc -l)" -eq 1 ]; then
  input_file=$(ls "$FAKE_GH_DIR/inputs"/*)
  if cat "$input_file" | jq -e ".body == (\"<!-- fleet-board:manager-note -->\\ntest note\")" >/dev/null 2>&1; then
    pass "note-replaces: input body correct"
  else
    fail "note-replaces: input body correct" "got $(cat "$input_file" | jq -c .body)"
  fi
else
  fail "note-replaces: exactly one input file" "found $(ls "$FAKE_GH_DIR/inputs"/* 2>/dev/null | wc -l) files"
fi

# AC2.3 note-creates-and-pins
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api --paginate repos/acme/toy/issues/12/comments	0	$FIXTURES/labels/comments-none.json
api -X POST repos/acme/toy/issues/12/comments --input -	0	$FIXTURES/labels/comment-created.json
api -X PUT repos/acme/toy/issues/comments/9001/pin	0	-
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
echo "new note" > note.md
run_check "$SCRIPT_DIR/../scripts/board-note.sh" 12 note.md
assert_exit "note-creates-and-pins: exit code" 0
assert_logs_contain "api -X POST repos/acme/toy/issues/12/comments --input -" "note-creates-and-pins: POST"
assert_logs_contain "api -X PUT repos/acme/toy/issues/comments/9001/pin" "note-creates-and-pins: pin"

# AC2.3 note-pin-failure-is-warning
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api --paginate repos/acme/toy/issues/12/comments	0	$FIXTURES/labels/comments-none.json
api -X POST repos/acme/toy/issues/12/comments --input -	0	$FIXTURES/labels/comment-created.json
api -X PUT repos/acme/toy/issues/comments/9001/pin	1	-
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
echo "note" > note.md
run_check "$SCRIPT_DIR/../scripts/board-note.sh" 12 note.md
assert_exit "note-pin-failure-is-warning: exit code" 0
assert_stderr_contains "note-pin-failure-is-warning: warning" "warning"

# AC2.4 comment-verbatim
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
issue comment 12 --repo acme/toy --body-file*	0	-
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
printf 'Line with trailing spaces  \nLine with backticks `code` and $HOME\nEm dash: —\nno newline at end' > body.txt
run_check "$SCRIPT_DIR/../scripts/board-comment.sh" 12 body.txt
assert_exit "comment-verbatim: exit code" 0
body_files=$(ls "$FAKE_GH_DIR/bodies"/* 2>/dev/null | wc -l)
if [ "$body_files" -eq 1 ]; then
  body_file=$(ls "$FAKE_GH_DIR/bodies"/*)
  if cmp -s "$body_file" body.txt; then
    pass "comment-verbatim: byte-for-byte"
  else
    fail "comment-verbatim: byte-for-byte" "files differ"
  fi
else
  fail "comment-verbatim: exactly one body file" "found $body_files files"
fi

# AC2.4 comment-missing-file
setup_case
> "$ROUTES"
echo "api user	0	$FIXTURES/labels/user.json" >> "$ROUTES"
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-comment.sh" 12 nonexistent.txt
assert_exit "comment-missing-file: exit code" 2

# AC2.5 ready-requires-acceptance
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/13	0	$FIXTURES/labels/issue-13-no-acceptance.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 13 ready
assert_exit "ready-requires-acceptance: exit code" 1
assert_stderr_contains "ready-requires-acceptance: message" "## Acceptance"
assert_logs_not_contain "issue edit" "ready-requires-acceptance: no edit"

# AC2.5 ready-allows-in-progress
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FIXTURES/labels/issue-12-in-progress.json
issue edit*	0	-
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 ready
assert_exit "ready-allows-in-progress: exit code" 0

# AC2.6 concurrent-moves-serialize
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FIXTURES/labels/issue-12.json
issue edit*	0	-
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" FAKE_GH_DELAY=0.3 PATH="$BIN:$PATH"
"$BASH_EXE" "$SCRIPT_DIR/../scripts/board-move.sh" 12 in_progress &
pid1=$!
"$BASH_EXE" "$SCRIPT_DIR/../scripts/board-move.sh" 12 in_review &
pid2=$!
wait $pid1; rc1=$?
wait $pid2; rc2=$?
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]; then
  pass "concurrent-moves-serialize: both exit 0"
else
  fail "concurrent-moves-serialize: both exit 0" "got $rc1 and $rc2"
fi
pids=$(grep "issue edit 12" "$FAKE_GH_DIR/calls.log" 2>/dev/null | awk '{print $1}')
changes=$(echo "$pids" | awk '{if(NR>1&&$1!=prev)n++;prev=$1}END{print n}')
if [ "${changes:-0}" -le 1 ]; then
  pass "concurrent-moves-serialize: pid sequence changes <=1"
else
  fail "concurrent-moves-serialize: pid sequence changes <=1" "changes=$changes"
fi
if [ ! -d "$REPO/.fw/.locks/card-12.lock" ]; then
  pass "concurrent-moves-serialize: no leftover lock"
else
  fail "concurrent-moves-serialize: no leftover lock" "lock exists"
fi

# AC2.6 stale-lock-recovered
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FIXTURES/labels/issue-12.json
issue edit*	0	-
ROUTESEOF
mkdir -p "$REPO/.fw/.locks"
mkdir "$REPO/.fw/.locks/card-12.lock"
touch -t 200001010000 "$REPO/.fw/.locks/card-12.lock"
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
time_start=$(date +%s)
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 in_progress
time_end=$(date +%s)
assert_exit "stale-lock-recovered: exit code" 0
elapsed=$((time_end - time_start))
if [ "$elapsed" -lt 5 ]; then
  pass "stale-lock-recovered: within 5s"
else
  fail "stale-lock-recovered: within 5s" "took ${elapsed}s"
fi

# AC2.6 live-lock-times-out
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FIXTURES/labels/issue-12.json
issue edit*	0	-
ROUTESEOF
mkdir -p "$REPO/.fw/.locks"
mkdir "$REPO/.fw/.locks/card-12.lock"
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" FLEET_BOARD_LOCK_WAIT=1 PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 in_progress
assert_exit "live-lock-times-out: exit code" 1
assert_stderr_contains "live-lock-times-out: message" "lock"

# foreign-note-ignored
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FIXTURES/labels/issue-12.json
api --paginate repos/acme/toy/issues/12/comments	0	$FIXTURES/labels/comments-foreign-note.json
api -X POST repos/acme/toy/issues/12/comments --input -	0	$FIXTURES/labels/comment-created.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-read.sh" 12
assert_exit "foreign-note-ignored: read exit code" 0
if echo "$LAST_OUT" | jq -e '.manager_note == null' >/dev/null 2>&1; then
  pass "foreign-note-ignored: null"
else
  fail "foreign-note-ignored: null" "got $(echo "$LAST_OUT" | jq .manager_note)"
fi
echo "new" > note.md
run_check "$SCRIPT_DIR/../scripts/board-note.sh" 12 note.md
assert_exit "foreign-note-ignored: note exit code" 0
assert_logs_contain "api -X POST repos/acme/toy/issues/12/comments --input -" "foreign-note-ignored: POST"
assert_logs_not_contain "api -X PATCH.*comments/777" "foreign-note-ignored: no PATCH"

# login-failure-fails-closed
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	1	-
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-read.sh" 12
assert_exit "login-failure-fails-closed: read exit" 1
assert_stderr_contains "login-failure-fails-closed: read error" "cannot determine"
echo "n" > note.md
run_check "$SCRIPT_DIR/../scripts/board-note.sh" 12 note.md
assert_exit "login-failure-fails-closed: note exit" 1
assert_logs_not_contain "api -X POST" "login-failure-fails-closed: no POST"
assert_logs_not_contain "api -X PATCH" "login-failure-fails-closed: no PATCH"

# comments-failure-fails-closed
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FIXTURES/labels/issue-12.json
api --paginate repos/acme/toy/issues/12/comments	1	-
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-read.sh" 12
assert_exit "comments-failure-fails-closed: read exit" 1
assert_stderr_contains "comments-failure-fails-closed: error" "cannot read comments"
echo "n" > note.md
run_check "$SCRIPT_DIR/../scripts/board-note.sh" 12 note.md
assert_exit "comments-failure-fails-closed: note exit" 1
assert_logs_not_contain "api -X POST" "comments-failure-fails-closed: no POST"
assert_logs_not_contain "api -X PATCH" "comments-failure-fails-closed: no PATCH"

# read-shape
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api repos/acme/toy/issues/12	0	$FIXTURES/labels/issue-12.json
api --paginate repos/acme/toy/issues/12/comments	0	$FIXTURES/labels/comments-with-note.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-read.sh" 12
assert_exit "read-shape: exit code" 0
if echo "$LAST_OUT" | jq -e '.state == "ready"' >/dev/null 2>&1; then
  pass "read-shape: state"
else
  fail "read-shape: state" "got $(echo "$LAST_OUT" | jq .state)"
fi
if echo "$LAST_OUT" | jq -e '.manager_note == "{\"round\":1}"' >/dev/null 2>&1; then
  pass "read-shape: manager_note"
else
  fail "read-shape: manager_note" "got $(echo "$LAST_OUT" | jq .manager_note)"
fi
if echo "$LAST_OUT" | jq -e '.manager_note_id == 555' >/dev/null 2>&1; then
  pass "read-shape: manager_note_id"
else
  fail "read-shape: manager_note_id" "got $(echo "$LAST_OUT" | jq .manager_note_id)"
fi
if echo "$LAST_OUT" | jq -e '(.comments | length) == 3' >/dev/null 2>&1; then
  pass "read-shape: comments length"
else
  fail "read-shape: comments length" "got $(echo "$LAST_OUT" | jq '.comments | length')"
fi
if echo "$LAST_OUT" | jq -e '.comments[0] | keys == ["author","body","created_at","id"]' >/dev/null 2>&1; then
  pass "read-shape: comment keys"
else
  fail "read-shape: comment keys" "got $(echo "$LAST_OUT" | jq '.comments[0] | keys')"
fi
if echo "$LAST_OUT" | jq -e '.labels == ["fleet:ready","bug"]' >/dev/null 2>&1; then
  pass "read-shape: labels"
else
  fail "read-shape: labels" "got $(echo "$LAST_OUT" | jq .labels)"
fi

# create
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
issue create --repo acme/toy --title*	0	$FIXTURES/labels/issue-created.txt
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
echo "body" > body.md
run_check "$SCRIPT_DIR/../scripts/board-create.sh" "P0: main red" body.md --label bug
assert_exit "create: exit code" 0
expected='{"number":77,"url":"https://github.com/acme/toy/issues/77"}'
if [ "$(echo "$LAST_OUT" | jq -c)" = "$expected" ]; then
  pass "create: output"
else
  fail "create: output" "expected $expected, got $(echo "$LAST_OUT" | jq -c)"
fi
assert_logs_contain "issue create --repo acme/toy --title" "create: issue create"
if argv_has_pair "--label" "fleet:backlog"; then
  pass "create: backlog label pair"
else
  fail "create: backlog label pair" "expected --label fleet:backlog as two consecutive argv elements"
fi
if argv_has_pair "--label" "bug"; then
  pass "create: bug label pair"
else
  fail "create: bug label pair" "expected --label bug as two consecutive argv elements"
fi

# CRITICAL C1: create-spaced-labels (word-splitting/globbing)
setup_case
cat > "$REPO/.fleet-board.yml" << 'CONFIGYML'
board:
  repo: acme/toy
  states: { backlog: "status: backlog" }
worktrees:
  dir: .fw
CONFIGYML
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
issue create --repo acme/toy --title*	0	$FIXTURES/labels/issue-created.txt
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
touch zz-glob-bait
echo "body" > body.md
run_check "$SCRIPT_DIR/../scripts/board-create.sh" "T" body.md --label "needs triage" --label '*'
assert_exit "create-spaced-labels: exit code" 0
# Check argv for exact argument pairs
if argv_has_pair "--label" "status: backlog"; then
  pass "create-spaced-labels: backlog label pair"
else
  fail "create-spaced-labels: backlog label pair" "expected --label and status: backlog consecutive in argv"
fi
if argv_has_pair "--label" "needs triage"; then
  pass "create-spaced-labels: spaced label pair"
else
  fail "create-spaced-labels: spaced label pair" "expected --label and needs triage consecutive in argv"
fi
if argv_has_pair "--label" "*"; then
  pass "create-spaced-labels: glob arg pair"
else
  fail "create-spaced-labels: glob arg pair" "expected --label and * consecutive in argv"
fi
# Check that no argv contains the glob-bait filename
if ! grep -rq "zz-glob-bait" "$FAKE_GH_DIR/argv" 2>/dev/null; then
  pass "create-spaced-labels: no glob expansion"
else
  fail "create-spaced-labels: no glob expansion" "found zz-glob-bait in argv"
fi

# IMPORTANT I1: note-post-failure (POST route exits 1)
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api --paginate repos/acme/toy/issues/12/comments	0	$FIXTURES/labels/comments-none.json
api -X POST repos/acme/toy/issues/12/comments --input -	1	-
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
echo "note" > note.md
run_check "$SCRIPT_DIR/../scripts/board-note.sh" 12 note.md
assert_exit "note-post-failure: exit code" 1
assert_logs_not_contain "/pin" "note-post-failure: no pin"

# note-post-bad-id: POST succeeds but the response carries no numeric id
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api --paginate repos/acme/toy/issues/12/comments	0	$FIXTURES/labels/comments-none.json
api -X POST repos/acme/toy/issues/12/comments --input -	0	$FIXTURES/labels/user.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
echo "note" > note.md
run_check "$SCRIPT_DIR/../scripts/board-note.sh" 12 note.md
assert_exit "note-post-bad-id: exit code" 1
assert_logs_not_contain "/pin" "note-post-bad-id: no pin"

# IMPORTANT I1: note-patch-failure (PATCH route exits 1)
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
api --paginate repos/acme/toy/issues/12/comments	0	$FIXTURES/labels/comments-with-note.json
api -X PATCH repos/acme/toy/issues/comments/555 --input -	1	-
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
echo "updated note" > note.md
run_check "$SCRIPT_DIR/../scripts/board-note.sh" 12 note.md
assert_exit "note-patch-failure: exit code" 1

# IMPORTANT I2: create-gh-failure (issue create route exits 1)
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
issue create --repo acme/toy --title*	1	-
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
echo "body" > body.md
run_check "$SCRIPT_DIR/../scripts/board-create.sh" "title" body.md
assert_exit "create-gh-failure: exit code" 1
if [ -z "$LAST_OUT" ]; then
  pass "create-gh-failure: empty stdout"
else
  fail "create-gh-failure: empty stdout" "got: $LAST_OUT"
fi
assert_stderr_contains "create-gh-failure: stderr" "failed to create issue"
assert_logs_contain "issue create --repo acme/toy" "create-gh-failure: issue create attempted"

# IMPORTANT I3: create-trailing-label (trailing --label with no value)
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
echo "body" > body.md
run_check "$SCRIPT_DIR/../scripts/board-create.sh" "title" body.md --label
assert_exit "create-trailing-label: exit code" 2
assert_stderr_contains "create-trailing-label: stderr" "usage"
if ! grep -q "issue create" "$FAKE_GH_DIR/calls.log" 2>/dev/null; then
  pass "create-trailing-label: no gh calls"
else
  fail "create-trailing-label: no gh calls" "found issue create in calls.log"
fi

# IMPORTANT I3: create-unknown-arg (unknown arg like --lable)
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
echo "body" > body.md
run_check "$SCRIPT_DIR/../scripts/board-create.sh" "title" body.md --lable bug
assert_exit "create-unknown-arg: exit code" 2
assert_stderr_contains "create-unknown-arg: stderr" "usage"
if ! grep -q "issue create" "$FAKE_GH_DIR/calls.log" 2>/dev/null; then
  pass "create-unknown-arg: no gh calls"
else
  fail "create-unknown-arg: no gh calls" "found issue create in calls.log"
fi

# create-empty-label (--label with an empty value)
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
echo "body" > body.md
run_check "$SCRIPT_DIR/../scripts/board-create.sh" "title" body.md --label ""
assert_exit "create-empty-label: exit code" 2
assert_stderr_contains "create-empty-label: stderr" "usage"
assert_logs_not_contain "issue create" "create-empty-label: no gh calls"

# IMPORTANT I4: non-numeric-card (board-read, board-move, board-comment, board-note with non-numeric n)
setup_case
cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-read.sh" 1x
assert_exit "non-numeric-card: read 1x" 2
if ! grep -q "issue\|api" "$FAKE_GH_DIR/calls.log" 2>/dev/null; then
  pass "non-numeric-card: read no gh calls"
else
  fail "non-numeric-card: read no gh calls" "found gh calls in calls.log"
fi
rm -f "$FAKE_GH_DIR/calls.log"
run_check "$SCRIPT_DIR/../scripts/board-move.sh" ../1 ready
assert_exit "non-numeric-card: move ../1" 2
if ! grep -q "issue\|api" "$FAKE_GH_DIR/calls.log" 2>/dev/null; then
  pass "non-numeric-card: move no gh calls"
else
  fail "non-numeric-card: move no gh calls" "found gh calls in calls.log"
fi
echo "test" > test.txt
rm -f "$FAKE_GH_DIR/calls.log"
run_check "$SCRIPT_DIR/../scripts/board-comment.sh" -1 test.txt
assert_exit "non-numeric-card: comment -1" 2
if ! grep -q "issue\|api" "$FAKE_GH_DIR/calls.log" 2>/dev/null; then
  pass "non-numeric-card: comment no gh calls"
else
  fail "non-numeric-card: comment no gh calls" "found gh calls in calls.log"
fi
rm -f "$FAKE_GH_DIR/calls.log"
run_check "$SCRIPT_DIR/../scripts/board-note.sh" 1.5 test.txt
assert_exit "non-numeric-card: note 1.5" 2
if ! grep -q "issue\|api" "$FAKE_GH_DIR/calls.log" 2>/dev/null; then
  pass "non-numeric-card: note no gh calls"
else
  fail "non-numeric-card: note no gh calls" "found gh calls in calls.log"
fi

# no-config: all scripts
REPO=$(mktemp -d)
git init -q "$REPO"
CLEANUP_DIRS+=("$REPO")
cd "$REPO"
FAKE_GH_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$FAKE_GH_DIR")
BIN="$FAKE_GH_DIR/bin"
mkdir -p "$BIN"
ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"
ROUTES="$FAKE_GH_DIR/routes.txt"
> "$ROUTES"
unset FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$ORIG_PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "no-config: list" 3
if [ ! -f "$FAKE_GH_DIR/calls.log" ] || [ ! -s "$FAKE_GH_DIR/calls.log" ]; then
  pass "no-config: list made no gh calls"
else
  fail "no-config: list made no gh calls" "calls.log has content"
fi
run_check "$SCRIPT_DIR/../scripts/board-read.sh" 12
assert_exit "no-config: read" 3
if [ ! -f "$FAKE_GH_DIR/calls.log" ] || [ ! -s "$FAKE_GH_DIR/calls.log" ]; then
  pass "no-config: read made no gh calls"
else
  fail "no-config: read made no gh calls" "calls.log has content"
fi
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 ready
assert_exit "no-config: move" 3
if [ ! -f "$FAKE_GH_DIR/calls.log" ] || [ ! -s "$FAKE_GH_DIR/calls.log" ]; then
  pass "no-config: move made no gh calls"
else
  fail "no-config: move made no gh calls" "calls.log has content"
fi
echo "test" > test.txt
run_check "$SCRIPT_DIR/../scripts/board-comment.sh" 12 test.txt
assert_exit "no-config: comment" 3
if [ ! -f "$FAKE_GH_DIR/calls.log" ] || [ ! -s "$FAKE_GH_DIR/calls.log" ]; then
  pass "no-config: comment made no gh calls"
else
  fail "no-config: comment made no gh calls" "calls.log has content"
fi
run_check "$SCRIPT_DIR/../scripts/board-note.sh" 12 test.txt
assert_exit "no-config: note" 3
if [ ! -f "$FAKE_GH_DIR/calls.log" ] || [ ! -s "$FAKE_GH_DIR/calls.log" ]; then
  pass "no-config: note made no gh calls"
else
  fail "no-config: note made no gh calls" "calls.log has content"
fi
run_check "$SCRIPT_DIR/../scripts/board-create.sh" "title" test.txt
assert_exit "no-config: create" 3
if [ ! -f "$FAKE_GH_DIR/calls.log" ] || [ ! -s "$FAKE_GH_DIR/calls.log" ]; then
  pass "no-config: create made no gh calls"
else
  fail "no-config: create made no gh calls" "calls.log has content"
fi

# list-truncation: gh issue list stops at --limit. A reply of exactly the limit
# may be cut short, and a short column silently drops cards (done/wont_do list
# every closed issue), so the adapter fails closed and names the remedy.
# FLEET_BOARD_LIST_LIMIT raises the limit (default 500).
labels_list_case() { # NAME COUNT [LIMIT_ENV] [LIST_FLAG] [STATE]
  setup_case
  jq -n --argjson n "$2" '[range($n) | {number: (. + 1), title: "t", url: "u", labels: [{name: "fleet:done"}]}]' \
    > "$FAKE_GH_DIR/many.json"
  cat > "$ROUTES" << ROUTESEOF
api user	0	$FIXTURES/labels/user.json
issue list*	0	$FAKE_GH_DIR/many.json
ROUTESEOF
  export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
  if [ -n "${3:-}" ]; then
    FLEET_BOARD_LIST_LIMIT="$3" run_check "$SCRIPT_DIR/../scripts/board-list.sh" ${4:+"$4"} "${5:-done}"
  else
    unset FLEET_BOARD_LIST_LIMIT
    run_check "$SCRIPT_DIR/../scripts/board-list.sh" ${4:+"$4"} "${5:-done}"
  fi
}
labels_list_case at-limit 500
assert_exit "list-at-limit: exit" 1
assert_stderr_contains "list-at-limit: names the limit" "500"
assert_stderr_contains "list-at-limit: names the remedy" "FLEET_BOARD_LIST_LIMIT"
assert_stdout_exact "list-at-limit: no stdout" ""
labels_list_case below-limit 499
assert_exit "list-below-limit: exit" 0
if [ -z "$LAST_ERR" ] && [ "$(jq 'length' <<<"$LAST_OUT")" = 499 ]; then
  pass "list-below-limit: 499 cards, no warning"
else
  fail "list-below-limit: 499 cards, no warning" "stderr: $LAST_ERR; count: $(jq 'length' <<<"$LAST_OUT" 2>&1)"
fi
labels_list_case limit-override 500 501
assert_exit "list-limit-override: exit" 0
assert_logs_contain "limit 501" "list-limit-override: passes the raised limit"
# --allow-truncated (cleanup-done.sh's done listing only): an at-limit reply
# is printed with a warning naming the limit instead of failing
labels_list_case at-limit-allowed 500 "" --allow-truncated
assert_exit "list-at-limit-allowed: exit" 0
assert_stderr_contains "list-at-limit-allowed: warns naming the limit" "list limit (500); the list may be truncated, continuing"
if [ "$(jq 'length' <<<"$LAST_OUT" 2>/dev/null)" = 500 ]; then
  pass "list-at-limit-allowed: prints the 500 cards"
else
  fail "list-at-limit-allowed: prints the 500 cards" "count: $(jq 'length' <<<"$LAST_OUT" 2>&1)"
fi
# the opt-in is the flag only: the adapter's internal variable, inherited from
# the environment, does not widen a plain listing
FB_LIST_ALLOW_TRUNCATED=1 labels_list_case at-limit-inherited 500
assert_exit "list-at-limit-inherited-var: still fails closed" 1
assert_stderr_contains "list-at-limit: names the second remedy" "fleet:done label from old closed issues"
# an active column lists open issues only, so the closed-issue remedy does not apply
labels_list_case at-limit-active 500 "" "" ready
assert_exit "list-at-limit-active: exit" 1
assert_stderr_contains "list-at-limit-active: open-issue remedy" "reduce the open issues labelled fleet:ready"
if printf '%s' "$LAST_ERR" | grep -q 'old closed issues'; then
  fail "list-at-limit-active: no closed-issue remedy" "stderr: $LAST_ERR"
else
  pass "list-at-limit-active: no closed-issue remedy"
fi
labels_list_case limit-invalid 5 0
assert_exit "list-limit-invalid: exit" 1
assert_stderr_contains "list-limit-invalid: stderr" "FLEET_BOARD_LIST_LIMIT must be a positive integer"
unset FLEET_BOARD_LIST_LIMIT

# board-comment refuses a body carrying the manager-note marker. A role that
# posts another process's temp file must not forge the card's note: the
# refusal comes before any gh call. Only a body the note reader would trust
# is refused: one that starts with the marker after optional leading
# whitespace (CRLF included) and an optional UTF-8 BOM. A marker quoted later
# in the body (e.g. an Acceptance quoted in a Human QA comment) posts as is.
# Other fleet-board comments (skip-no-acceptance, Human QA) still post.
COMMENT_GUARD_REPO=acme/toy
comment_guard_setup() {
  setup_case
  printf 'issue comment 12 --repo %s --body-file*\t0\t-\n' "$COMMENT_GUARD_REPO" > "$ROUTES"
  export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
}
comment_guard_case() { # <name> <refuse|post>; the body is in comment.md
  local name="$1" expect="$2" posted
  run_check "$SCRIPT_DIR/../scripts/board-comment.sh" 12 comment.md
  if [ "$expect" = refuse ]; then
    assert_exit "comment-guard-$name: exit" 1
    assert_stderr_contains "comment-guard-$name: stderr names the refusal" "fleet-board: refusing to post"
    if [ -s "$FAKE_GH_DIR/calls.log" ]; then
      fail "comment-guard-$name: no gh call" "calls.log: $(cat "$FAKE_GH_DIR/calls.log")"
    else
      pass "comment-guard-$name: no gh call"
    fi
  else
    assert_exit "comment-guard-$name: exit" 0
    assert_logs_contain "issue comment 12 --repo $COMMENT_GUARD_REPO --body-file" "comment-guard-$name: posted"
    posted="$(ls "$FAKE_GH_DIR"/bodies/* 2>/dev/null | head -1)"
    if [ -n "$posted" ] && cmp -s comment.md "$posted"; then
      pass "comment-guard-$name: body posted unchanged"
    else
      fail "comment-guard-$name: body posted unchanged" "posted body missing or differs from comment.md"
    fi
  fi
}

comment_guard_setup
printf '%s\n```json\n{"branch":"x"}\n```\n' '<!-- fleet-board:manager-note -->' > comment.md
comment_guard_case note-first-line refuse

comment_guard_setup
printf '## Implementor report\n\nSome text.\n%s\n{"branch":"x"}\n' '<!-- fleet-board:manager-note -->' > comment.md
comment_guard_case note-mid-body post

comment_guard_setup
printf ' \t\n\n%s\n```json\n{"branch":"x"}\n```\n' '<!-- fleet-board:manager-note -->' > comment.md
comment_guard_case note-after-whitespace refuse

comment_guard_setup
printf '\357\273\277%s\n```json\n{"branch":"x"}\n```\n' '<!-- fleet-board:manager-note -->' > comment.md
comment_guard_case note-after-bom refuse

comment_guard_setup
printf '%s\r\n```json\r\n{"branch":"x"}\r\n```\r\n' '<!-- fleet-board:manager-note -->' > comment.md
comment_guard_case note-first-line-crlf refuse

comment_guard_setup
printf '\r\n\r\n%s\r\n```json\r\n{"branch":"x"}\r\n```\r\n' '<!-- fleet-board:manager-note -->' > comment.md
comment_guard_case note-after-crlf-blank-lines refuse

comment_guard_setup
printf '## What to check in Human QA\n\n> - a body that starts %s is a note\n' '<!-- fleet-board:manager-note -->' > comment.md
comment_guard_case note-quoted-in-acceptance post

comment_guard_setup
printf '## Implementor report\n\nStatus: done\n' > comment.md
comment_guard_case plain-report post

comment_guard_setup
printf '%s\nThis card needs a ## Acceptance section before it can start.\n' '<!-- fleet-board:skip-no-acceptance -->' > comment.md
comment_guard_case skip-no-acceptance post

comment_guard_setup
printf '## What to check in Human QA\n\n> - the button works\n' > comment.md
comment_guard_case human-qa post

echo ""
echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

#!/usr/bin/env bash
#
# Plain-bash tests for board adapter contract scripts (Projects backend)
# No framework, no dependencies beyond POSIX tools.
#
# Usage: bash plugins/fleet-board/tests/test-board-projects.sh

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

assert_count() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected $3, got $2"; fi
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

# Count lines of calls.log matching a pattern. grep -c prints 0 itself on no
# match (exit 1); only a missing calls.log prints nothing, which becomes 0.
count_logs() {
  local pattern="$1" n
  n="$(grep -c "$pattern" "$FAKE_GH_DIR/calls.log" 2>/dev/null)"
  printf '%s\n' "${n:-0}"
}

# calls_of <word1> <word2>: argv files of calls whose first two arguments are
# <word1> <word2>, in call order (zero-padded names sort in call order)
calls_of() {
  local f
  for f in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$f" ] || continue
    [ "$(sed -n 1p "$f")" = "$1" ] && [ "$(sed -n 2p "$f")" = "$2" ] && printf '%s\n' "$f"
  done
}

# file_has_pair <argv-file> <flag> <value>: <flag> immediately followed by <value>
file_has_pair() {
  local file="$1" flag="$2" value="$3" prev="" arg
  while IFS= read -r arg || [ -n "$arg" ]; do
    if [ "$prev" = "$flag" ] && [ "$arg" = "$value" ]; then return 0; fi
    prev="$arg"
  done < "$file"
  return 1
}

# assert_call_pair <desc> <argv-file> <flag> <value>
assert_call_pair() {
  if [ -n "$2" ] && [ -f "$2" ] && file_has_pair "$2" "$3" "$4"; then
    pass "$1"
  else
    fail "$1" "expected $3 $4 in call: $(tr '\n' ' ' < "${2:-/dev/null}" 2>/dev/null)"
  fi
}

count_lines() { grep -c . || true; }

setup_case() {
  REPO=$(mktemp -d)
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"

  cat > "$REPO/.fleet-board.yml" << 'YML'
board:
  backend: github-projects
  repo: drothschild/HMBWorkout
  project_number: 1
  states: { in_progress: "In progress", in_review: "In review", human_qa: "Require Human Inteteraction", wont_do: "Won't Do" }
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

echo "Test: board adapter contract scripts (Projects backend)"
echo ""

# AC2.7 resolves-once-per-tick
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api graphql*	0	$FIXTURES/projects/issue-project-items-ready.json
api user	0	$FIXTURES/labels/user.json
api repos/drothschild/HMBWorkout/issues/*	0	$FIXTURES/labels/issue-12.json
api --paginate repos/drothschild/HMBWorkout/issues/*/comments	0	$FIXTURES/labels/comments-none.json
project item-edit*	0	$FIXTURES/projects/item-edit-ok.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 in_review
assert_exit "resolves-once-per-tick: first move exit" 0
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 in_progress
assert_exit "resolves-once-per-tick: second move exit" 0

# Verify exactly one field-list call before cache clear
field_list_count=$(count_logs "project field-list")
if [ "$field_list_count" -eq 1 ]; then
  pass "resolves-once-per-tick: one field-list call"
else
  fail "resolves-once-per-tick: one field-list call" "expected 1, got $field_list_count"
fi

# Verify exactly one project view call
view_count=$(count_logs "project view")
if [ "$view_count" -eq 1 ]; then
  pass "resolves-once-per-tick: one view call"
else
  fail "resolves-once-per-tick: one view call" "expected 1, got $view_count"
fi

# Exactly two item-edit calls, in move order, each with the cached ids
pid="$(jq -r .id "$FIXTURES/projects/project-view.json")"
fid="$(jq -r '.fields[] | select(.name=="Status") | .id' "$FIXTURES/projects/field-list.json")"
in_review_opt="$(jq -r '.fields[] | select(.name=="Status") | .options[] | select(.name=="In review") | .id' "$FIXTURES/projects/field-list.json")"
in_progress_opt="$(jq -r '.fields[] | select(.name=="Status") | .options[] | select(.name=="In progress") | .id' "$FIXTURES/projects/field-list.json")"
edits="$(calls_of project item-edit)"
edit_count="$(printf '%s\n' "$edits" | count_lines)"
if [ "$edit_count" -eq 2 ]; then
  pass "resolves-once-per-tick: exactly two item-edit calls"
else
  fail "resolves-once-per-tick: exactly two item-edit calls" "expected 2, got $edit_count"
fi
edit1="$(printf '%s\n' "$edits" | sed -n 1p)"
edit2="$(printf '%s\n' "$edits" | sed -n 2p)"
assert_call_pair "resolves-once-per-tick: first item-edit has In review option" "$edit1" --single-select-option-id "$in_review_opt"
assert_call_pair "resolves-once-per-tick: second item-edit has In progress option" "$edit2" --single-select-option-id "$in_progress_opt"
assert_call_pair "resolves-once-per-tick: first item-edit project-id" "$edit1" --project-id "$pid"
assert_call_pair "resolves-once-per-tick: second item-edit project-id" "$edit2" --project-id "$pid"
assert_call_pair "resolves-once-per-tick: first item-edit field-id" "$edit1" --field-id "$fid"
assert_call_pair "resolves-once-per-tick: second item-edit field-id" "$edit2" --field-id "$fid"

# Now clear cache and run one more move - should see another field-list call
run_check "$SCRIPT_DIR/../scripts/board-cache-clear.sh"
assert_exit "resolves-once-per-tick: cache clear exit" 0
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 ready
assert_exit "resolves-once-per-tick: post-clear move exit" 0
# After cache clear, field-list should be called again
field_list_count_after=$(count_logs "project field-list")
if [ "$field_list_count_after" -eq 2 ]; then
  pass "resolves-once-per-tick: field-list called again after cache clear"
else
  fail "resolves-once-per-tick: field-list called again after cache clear" "expected 2 total, got $field_list_count_after"
fi

# AC2.8 maps-human-qa-column
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api graphql*	0	$FIXTURES/projects/issue-project-items-ready.json
api user	0	$FIXTURES/labels/user.json
api repos/drothschild/HMBWorkout/issues/*	0	$FIXTURES/labels/issue-12.json
api --paginate repos/drothschild/HMBWorkout/issues/*/comments	0	$FIXTURES/labels/comments-none.json
project item-edit*	0	$FIXTURES/projects/item-edit-ok.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 human_qa
assert_exit "maps-human-qa-column: exit" 0
# Verify option id is for "Require Human Inteteraction"
human_qa_opt="$(jq -r '.fields[] | select(.name=="Status") | .options[] | select(.name=="Require Human Inteteraction") | .id' "$FIXTURES/projects/field-list.json")"
if argv_has_pair "--single-select-option-id" "$human_qa_opt"; then
  pass "maps-human-qa-column: correct option id"
else
  fail "maps-human-qa-column: correct option id" "expected $human_qa_opt"
fi

# Test board-read with canonical state
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api graphql*	0	$FIXTURES/projects/issue-project-items-14.json
api user	0	$FIXTURES/labels/user.json
api repos/drothschild/HMBWorkout/issues/12	0	$FIXTURES/labels/issue-12.json
api --paginate repos/drothschild/HMBWorkout/issues/12/comments	0	$FIXTURES/labels/comments-none.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-read.sh" 12
assert_exit "maps-human-qa-column: read exit" 0
if echo "$LAST_OUT" | jq -e '.state == "human_qa"' >/dev/null 2>&1; then
  pass "maps-human-qa-column: read state canonical"
else
  fail "maps-human-qa-column: read state canonical" "got .state = $(echo "$LAST_OUT" | jq -r '.state // "null"')"
fi

# AC2.8 unknown-option
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api graphql*	0	$FIXTURES/projects/issue-project-items-ready.json
api user	0	$FIXTURES/labels/user.json
api repos/drothschild/HMBWorkout/issues/*	0	$FIXTURES/labels/issue-12.json
api --paginate repos/drothschild/HMBWorkout/issues/*/comments	0	$FIXTURES/labels/comments-none.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 blocked
assert_exit "unknown-option: exit" 1
assert_stderr_contains "unknown-option: stderr has Blocked" "Blocked"
# Should list available options
assert_stderr_contains "unknown-option: stderr lists options" "Backlog"
assert_logs_not_contain "project item-edit" "unknown-option: no item-edit"

# AC2.9 missing-project-scope
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-no-project.txt
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "missing-project-scope: exit" 1
assert_stderr_contains "missing-project-scope: stderr" "gh auth refresh -s project"
assert_logs_not_contain "project" "missing-project-scope: no project calls"

# gh-not-logged-in: gh auth status fails with no scopes line; say so, with gh's message
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	1	$FIXTURES/projects/auth-status-not-logged-in.txt
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "gh-not-logged-in: exit" 1
assert_stderr_contains "gh-not-logged-in: fleet-board message" "fleet-board:"
assert_stderr_contains "gh-not-logged-in: gh's message" "You are not logged into any GitHub hosts"
assert_logs_not_contain "project" "gh-not-logged-in: no project calls"

# multi-account: only the ACTIVE account's scopes count, in either listing order
for fx in auth-status-multi-active-first auth-status-multi-inactive-first; do
  setup_case
  cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/$fx.txt
ROUTESEOF
  export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
  run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
  assert_exit "multi-account $fx: exit" 1
  assert_stderr_contains "multi-account $fx: refresh hint" "gh auth refresh -s project"
  assert_logs_not_contain "project" "multi-account $fx: no project calls"
done

# multi-account-active-ok: the active account has 'project', an inactive one lacks it
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-multi-active-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
project item-list 1 --owner drothschild --format json --limit 1000	0	$FIXTURES/projects/item-list-mixed.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "multi-account-active-ok: exit" 0

# auth-status-nonzero-but-scoped: gh exits 1 (e.g. another account's token is
# bad) yet shows the active account's scopes; the exit status alone is not fatal
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	1	$FIXTURES/projects/auth-status-multi-active-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
project item-list 1 --owner drothschild --format json --limit 1000	0	$FIXTURES/projects/item-list-mixed.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "auth-status-nonzero-but-scoped: exit" 0

# multi-host: only github.com's active account counts. Another host's active
# account, listed first, has 'project'; github.com's lacks it.
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-multi-host.txt
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "multi-host: exit" 1
assert_stderr_contains "multi-host: refresh hint" "gh auth refresh -s project"
assert_logs_not_contain "project" "multi-host: no project calls"

# multi-host-ok: github.com's active account has 'project'; the other host's,
# listed first, lacks it
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-multi-host-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
project item-list 1 --owner drothschild --format json --limit 1000	0	$FIXTURES/projects/item-list-mixed.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "multi-host-ok: exit" 0

# legacy-unquoted: older gh lists scopes unquoted (Token scopes: repo, project)
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-legacy-unquoted.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
project item-list 1 --owner drothschild --format json --limit 1000	0	$FIXTURES/projects/item-list-mixed.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "legacy-unquoted: exit" 0

# scope-listed-first: gh sorts scopes, so a minimal token puts 'project' first
setup_case
sed "s/'gist', //" "$FIXTURES/projects/auth-status-ok.txt" > "$FAKE_GH_DIR/auth.txt"
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FAKE_GH_DIR/auth.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
project item-list 1 --owner drothschild --format json --limit 1000	0	$FIXTURES/projects/item-list-mixed.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "scope-listed-first: exit" 0
assert_logs_contain "project item-list" "scope-listed-first: listed items"

# legacy-unquoted-no-project, legacy-unquoted-read-project: unquoted scopes
# without project, and with only read:project (a scope whose name contains
# "project"), are both refused
for variant in no-project read-project; do
  setup_case
  case "$variant" in
    no-project) sed 's/ project,//' "$FIXTURES/projects/auth-status-legacy-unquoted.txt" > "$FAKE_GH_DIR/auth.txt" ;;
    read-project) sed 's/ project,/ read:project,/' "$FIXTURES/projects/auth-status-legacy-unquoted.txt" > "$FAKE_GH_DIR/auth.txt" ;;
  esac
  cat > "$ROUTES" << ROUTESEOF
auth status	0	$FAKE_GH_DIR/auth.txt
ROUTESEOF
  export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
  run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
  assert_exit "legacy-unquoted-$variant: exit" 1
  assert_stderr_contains "legacy-unquoted-$variant: refresh hint" "gh auth refresh -s project"
  assert_logs_not_contain "project" "legacy-unquoted-$variant: no project calls"
done

# no-scopes-line: a token gh cannot report scopes for (e.g. GH_TOKEN) continues
setup_case
grep -v 'Token scopes:' "$FIXTURES/projects/auth-status-ok.txt" > "$FAKE_GH_DIR/auth-noline.txt"
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FAKE_GH_DIR/auth-noline.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
project item-list 1 --owner drothschild --format json --limit 1000	0	$FIXTURES/projects/item-list-mixed.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "no-scopes-line: exit" 0

# list-by-status
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
project item-list 1 --owner drothschild --format json --limit 1000	0	$FIXTURES/projects/item-list-mixed.json
api user	0	$FIXTURES/labels/user.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "list-by-status: exit" 0
# item-list-mixed.json holds Ready issues #124 and #121 (unsorted), plus a Ready
# PR, a Ready draft and a Ready issue from another repo, which must all be dropped.
expected='[{"number":121,"title":"Card 121","url":"https://github.com/drothschild/HMBWorkout/issues/121"},{"number":124,"title":"Card 124","url":"https://github.com/drothschild/HMBWorkout/issues/124"}]'
if [ "$(printf '%s' "$LAST_OUT" | jq -c . 2>/dev/null)" = "$expected" ]; then
  pass "list-by-status: exact output"
else
  fail "list-by-status: exact output" "expected $expected, got $LAST_OUT"
fi

# list-item-list-fails: a failed gh project item-list gets a fleet-board message
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
project item-list*	1	-
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "list-item-list-fails: exit" 1
assert_stderr_contains "list-item-list-fails: stderr" "fleet-board: cannot list items of project 1"
assert_stdout_exact "list-item-list-fails: no stdout" ""

# list-item-list-unparseable: output that is not an item list is an error, not []
setup_case
printf 'not json\n' > "$FAKE_GH_DIR/garbage.txt"
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
project item-list*	0	$FAKE_GH_DIR/garbage.txt
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "list-item-list-unparseable: exit" 1
assert_stderr_contains "list-item-list-unparseable: stderr" "fleet-board: cannot parse the items of project 1"
assert_stdout_exact "list-item-list-unparseable: no stdout" ""

# list-item-list-empty: an item-list that exits 0 with no output is an error,
# not a blank line
setup_case
: > "$FAKE_GH_DIR/empty.txt"
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
project item-list*	0	$FAKE_GH_DIR/empty.txt
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "list-item-list-empty: exit" 1
assert_stderr_contains "list-item-list-empty: stderr" "fleet-board: cannot parse the items of project 1"
assert_stdout_exact "list-item-list-empty: no stdout" ""

# cache-clear-fails: a cache that cannot be removed is reported, not ignored.
# Uses a read-only parent directory; root ignores that, so the case is skipped as root.
setup_case
if [ "$(id -u)" = 0 ]; then
  printf '  skip cache-clear-fails (running as root: directory permissions are not enforced)\n'
else
  mkdir -p "$REPO/.fw/.cache"
  printf '{}\n' > "$REPO/.fw/.cache/projects.json"
  chmod 555 "$REPO/.fw"
  run_check "$SCRIPT_DIR/../scripts/board-cache-clear.sh"
  chmod 755 "$REPO/.fw"
  assert_exit "cache-clear-fails: exit" 1
  assert_stderr_contains "cache-clear-fails: stderr" "fleet-board: cannot clear"
fi

# cdpath-relative-verbs: every board verb run by a relative path still finds
# board-lib.sh when an exported CDPATH holds a same-named directory (cd would
# go there and echo its path, so the captured directory had two lines)
setup_case
mkdir -p "$FAKE_GH_DIR/decoy/fbs"
ln -s "$SCRIPT_DIR/../scripts" "$REPO/fbs"
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
project item-list 1 --owner drothschild --format json --limit 1000	0	$FIXTURES/projects/item-list-mixed.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
export CDPATH="$FAKE_GH_DIR/decoy"
run_check fbs/board-list.sh ready
assert_exit "cdpath-relative-verbs: list exit" 0
expected='[{"number":121,"title":"Card 121","url":"https://github.com/drothschild/HMBWorkout/issues/121"},{"number":124,"title":"Card 124","url":"https://github.com/drothschild/HMBWorkout/issues/124"}]'
if [ "$(printf '%s' "$LAST_OUT" | jq -c . 2>/dev/null)" = "$expected" ]; then
  pass "cdpath-relative-verbs: list output"
else
  fail "cdpath-relative-verbs: list output" "expected $expected, got $LAST_OUT (stderr: $LAST_ERR)"
fi
for v in comment create move note read; do
  run_check "fbs/board-$v.sh"
  assert_exit "cdpath-relative-verbs: $v usage exit" 2
  assert_stderr_contains "cdpath-relative-verbs: $v usage message" "fleet-board: usage: board-$v.sh"
done
run_check fbs/board-cache-clear.sh
assert_exit "cdpath-relative-verbs: cache-clear exit" 0
unset CDPATH

# read-adds-item-id
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api graphql*	0	$FIXTURES/projects/issue-project-items-ready.json
api user	0	$FIXTURES/labels/user.json
api repos/drothschild/HMBWorkout/issues/12	0	$FIXTURES/labels/issue-12.json
api --paginate repos/drothschild/HMBWorkout/issues/12/comments	0	$FIXTURES/labels/comments-none.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-read.sh" 12
assert_exit "read-adds-item-id: exit" 0
# Extract item_id from fixture
item_id="$(jq -r '.data.repository.issue.projectItems.nodes[0].id' "$FIXTURES/projects/issue-project-items-ready.json")"
if echo "$LAST_OUT" | jq -e ".item_id == \"$item_id\"" >/dev/null 2>&1; then
  pass "read-adds-item-id: has item_id"
else
  fail "read-adds-item-id: has item_id" "expected $item_id, got $(echo "$LAST_OUT" | jq -r '.item_id // "null"')"
fi

# comment-and-note-delegate
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api user	0	$FIXTURES/labels/user.json
api repos/drothschild/HMBWorkout/issues/12	0	$FIXTURES/labels/issue-12.json
api --paginate repos/drothschild/HMBWorkout/issues/12/comments	0	$FIXTURES/labels/comments-none.json
api -X POST repos/drothschild/HMBWorkout/issues/12/comments --input -	0	$FIXTURES/labels/comment-created.json
api -X PUT repos/drothschild/HMBWorkout/issues/comments/9001/pin	0	-
issue comment 12 --repo drothschild/HMBWorkout --body-file*	0	-
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
echo "test comment" > comment.md
run_check "$SCRIPT_DIR/../scripts/board-comment.sh" 12 comment.md
assert_exit "comment-and-note-delegate: comment exit" 0
assert_logs_contain "issue comment 12 --repo drothschild/HMBWorkout --body-file" "comment-and-note-delegate: calls.log"
echo "note body" > note.md
run_check "$SCRIPT_DIR/../scripts/board-note.sh" 12 note.md
assert_exit "comment-and-note-delegate: note exit" 0
assert_logs_contain "api -X POST repos/drothschild/HMBWorkout/issues/12/comments --input -" "comment-and-note-delegate: note POST"
assert_logs_contain "api -X PUT repos/drothschild/HMBWorkout/issues/comments/9001/pin" "comment-and-note-delegate: note pinned"

# board-comment refuses a body that starts with the manager-note marker (after
# optional leading whitespace, CRLF included, and an optional UTF-8 BOM), on
# this backend too: the refusal comes before any gh call. A marker later in
# the body is not a note to the reader, so that body posts unchanged.
# Other fleet-board comments (skip-no-acceptance) and plain reports still post.
COMMENT_GUARD_REPO=drothschild/HMBWorkout
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

# projects-create
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api user	0	$FIXTURES/labels/user.json
issue create*	0	$FIXTURES/projects/issue-created.txt
project item-add 1 --owner drothschild --url https://github.com/drothschild/HMBWorkout/issues/901*	0	$FIXTURES/projects/item-add.json
project item-edit*	0	$FIXTURES/projects/item-edit-ok.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
cat > body.md << 'BODY'
Body text
BODY
run_check "$SCRIPT_DIR/../scripts/board-create.sh" "Out of scope: x" body.md --label needs-human-qa
assert_exit "projects-create: exit" 0
expected='{"number":901,"url":"https://github.com/drothschild/HMBWorkout/issues/901"}'
if [ "$(echo "$LAST_OUT" | jq -c)" = "$expected" ]; then
  pass "projects-create: stdout exact"
else
  fail "projects-create: stdout exact" "expected $expected, got $(echo "$LAST_OUT" | jq -c)"
fi

# Verify call order: issue create, then item-add, then item-edit
issue_create_line=$(grep -n "issue create --repo drothschild/HMBWorkout" "$FAKE_GH_DIR/calls.log" 2>/dev/null | head -1 | cut -d: -f1)
item_add_line=$(grep -n "project item-add 1 --owner drothschild" "$FAKE_GH_DIR/calls.log" 2>/dev/null | head -1 | cut -d: -f1)
item_edit_line=$(grep -n "project item-edit" "$FAKE_GH_DIR/calls.log" 2>/dev/null | head -1 | cut -d: -f1)

if [ -n "$issue_create_line" ] && [ -n "$item_add_line" ] && [ -n "$item_edit_line" ]; then
  if [ "$issue_create_line" -lt "$item_add_line" ] && [ "$item_add_line" -lt "$item_edit_line" ]; then
    pass "projects-create: call order"
  else
    fail "projects-create: call order" "create=$issue_create_line, add=$item_add_line, edit=$item_edit_line"
  fi
else
  fail "projects-create: call order" "missing calls: create=$issue_create_line add=$item_add_line edit=$item_edit_line"
fi

# Verify issue create has label but no fleet: labels
if grep -q "issue create --repo drothschild/HMBWorkout.*--label needs-human-qa" "$FAKE_GH_DIR/calls.log" 2>/dev/null; then
  pass "projects-create: has needs-human-qa label"
else
  fail "projects-create: has needs-human-qa label" "label not found"
fi
if ! grep -q "issue create.*fleet:" "$FAKE_GH_DIR/calls.log" 2>/dev/null; then
  pass "projects-create: no fleet labels"
else
  fail "projects-create: no fleet labels" "found fleet: label"
fi

# Verify item-edit moves the added item (id from item-add) to Backlog
backlog_opt="$(jq -r '.fields[] | select(.name=="Status") | .options[] | select(.name=="Backlog") | .id' "$FIXTURES/projects/field-list.json")"
edit1="$(calls_of project item-edit | head -n 1)"
assert_call_pair "projects-create: item-edit to Backlog" "$edit1" --single-select-option-id "$backlog_opt"
assert_call_pair "projects-create: item-edit uses the added item PVTI_new" "$edit1" --id PVTI_new

# create-backlog-option-missing: an unknown Backlog column fails before anything is created
setup_case
cat > "$REPO/.fleet-board.yml" << 'YML'
board:
  backend: github-projects
  repo: drothschild/HMBWorkout
  project_number: 1
  states: { backlog: "Icebox", in_progress: "In progress", in_review: "In review", human_qa: "Require Human Inteteraction", wont_do: "Won't Do" }
worktrees:
  dir: .fw
YML
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
issue create*	0	$FIXTURES/projects/issue-created.txt
project item-add*	0	$FIXTURES/projects/item-add.json
project item-edit*	0	$FIXTURES/projects/item-edit-ok.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
printf 'Body text\n' > body.md
run_check "$SCRIPT_DIR/../scripts/board-create.sh" "Out of scope: x" body.md
assert_exit "create-backlog-option-missing: exit" 1
assert_stderr_contains "create-backlog-option-missing: stderr names Icebox" "Icebox"
assert_logs_not_contain "issue create" "create-backlog-option-missing: no issue create"
assert_logs_not_contain "project item-add" "create-backlog-option-missing: no item-add"
assert_logs_not_contain "project item-edit" "create-backlog-option-missing: no item-edit"

# move-option-missing-not-on-board: an unknown target fails before the card is added
setup_case
printf '%s\n' '{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}' > "$FAKE_GH_DIR/no-items.json"
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api graphql*	0	$FAKE_GH_DIR/no-items.json
api repos/drothschild/HMBWorkout/issues/*	0	$FIXTURES/labels/issue-12.json
project item-add*	0	$FIXTURES/projects/item-add.json
project item-edit*	0	$FIXTURES/projects/item-edit-ok.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 blocked
assert_exit "move-option-missing-not-on-board: exit" 1
assert_stderr_contains "move-option-missing-not-on-board: stderr names Blocked" "Blocked"
assert_logs_not_contain "project item-add" "move-option-missing-not-on-board: no item-add"
assert_logs_not_contain "project item-edit" "move-option-missing-not-on-board: no item-edit"

# move-adds-missing-item
setup_case
printf '%s\n' '{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}' > "$FAKE_GH_DIR/no-items.json"
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api graphql*	0	$FAKE_GH_DIR/no-items.json
api user	0	$FIXTURES/labels/user.json
api repos/drothschild/HMBWorkout/issues/*	0	$FIXTURES/labels/issue-12.json
api --paginate repos/drothschild/HMBWorkout/issues/*/comments	0	$FIXTURES/labels/comments-none.json
project item-add 1 --owner drothschild --url*	0	$FIXTURES/projects/item-add.json
project item-edit*	0	$FIXTURES/projects/item-edit-ok.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 ready
assert_exit "move-adds-missing-item: exit" 0
assert_logs_contain "project item-add 1 --owner drothschild --url https://github.com/drothschild/HMBWorkout/issues/12 --format json" "move-adds-missing-item: item-add called"
# Verify item-edit uses PVTI_new (the id from item-add response)
if argv_has_pair "--id" "PVTI_new"; then
  pass "move-adds-missing-item: item-edit uses PVTI_new"
else
  fail "move-adds-missing-item: item-edit uses PVTI_new" "PVTI_new not found in argv"
fi

# already-in-target: a card already in the target column is left alone
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api graphql*	0	$FIXTURES/projects/issue-project-items-ready.json
api repos/drothschild/HMBWorkout/issues/*	0	$FIXTURES/labels/issue-12.json
project item-add*	0	$FIXTURES/projects/item-add.json
project item-edit*	0	$FIXTURES/projects/item-edit-ok.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 ready
assert_exit "already-in-target: exit" 0
assert_logs_not_contain "project item-add" "already-in-target: no item-add"
assert_logs_not_contain "project item-edit" "already-in-target: no item-edit"

# multi-project: only this project's item counts, even when another project's comes first
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api graphql*	0	$FIXTURES/projects/issue-project-items-multi.json
api user	0	$FIXTURES/labels/user.json
api repos/drothschild/HMBWorkout/issues/12	0	$FIXTURES/labels/issue-12.json
api --paginate repos/drothschild/HMBWorkout/issues/12/comments	0	$FIXTURES/labels/comments-none.json
project item-add*	0	$FIXTURES/projects/item-add.json
project item-edit*	0	$FIXTURES/projects/item-edit-ok.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-read.sh" 12
assert_exit "multi-project: read exit" 0
if printf '%s' "$LAST_OUT" | jq -e '.item_id == "PVTI_lAHOACFUls4BfgODzg6jCC4" and .state == "in_review"' >/dev/null 2>&1; then
  pass "multi-project: read uses the project-1 item and status"
else
  fail "multi-project: read uses the project-1 item and status" "got $(printf '%s' "$LAST_OUT" | jq -c '{state,item_id}' 2>/dev/null)"
fi
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 in_progress
assert_exit "multi-project: move exit" 0
edits="$(calls_of project item-edit)"
assert_count "multi-project: one item-edit" "$(printf '%s\n' "$edits" | count_lines)" 1
assert_call_pair "multi-project: item-edit uses the project-1 item id" "$(printf '%s\n' "$edits" | head -n 1)" --id PVTI_lAHOACFUls4BfgODzg6jCC4
assert_logs_not_contain "project item-add" "multi-project: no item-add"

# ready-without-acceptance: the ## Acceptance gate applies on Projects too
setup_case
printf '%s\n' '{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}' > "$FAKE_GH_DIR/no-items.json"
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api graphql*	0	$FAKE_GH_DIR/no-items.json
api repos/drothschild/HMBWorkout/issues/13	0	$FIXTURES/labels/issue-13-no-acceptance.json
project item-add*	0	$FIXTURES/projects/item-add.json
project item-edit*	0	$FIXTURES/projects/item-edit-ok.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 13 ready
assert_exit "ready-without-acceptance: exit" 1
assert_stderr_contains "ready-without-acceptance: stderr" "## Acceptance"
assert_logs_not_contain "project item-add" "ready-without-acceptance: no item-add"
assert_logs_not_contain "project item-edit" "ready-without-acceptance: no item-edit"

# lock-held: a fresh lock on the card makes move give up without editing
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api graphql*	0	$FIXTURES/projects/issue-project-items-ready.json
api repos/drothschild/HMBWorkout/issues/*	0	$FIXTURES/labels/issue-12.json
project item-add*	0	$FIXTURES/projects/item-add.json
project item-edit*	0	$FIXTURES/projects/item-edit-ok.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
mkdir -p "$REPO/.fw/.locks/card-12.lock"
FLEET_BOARD_LOCK_WAIT=1 run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 in_review
assert_exit "lock-held: exit" 1
assert_stderr_contains "lock-held: stderr" "lock"
assert_logs_not_contain "project item-edit" "lock-held: no item-edit"
if [ -d "$REPO/.fw/.locks/card-12.lock" ]; then
  pass "lock-held: the holder's lock is left in place"
else
  fail "lock-held: the holder's lock is left in place" "lock dir removed"
fi

# move-graphql-failure: an item lookup that fails must not be read as "no item"
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api graphql*	1	-
api user	0	$FIXTURES/labels/user.json
api repos/drothschild/HMBWorkout/issues/*	0	$FIXTURES/labels/issue-12.json
project item-add*	0	$FIXTURES/projects/item-add.json
project item-edit*	0	$FIXTURES/projects/item-edit-ok.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-move.sh" 12 in_review
assert_exit "move-graphql-failure: exit" 1
assert_logs_not_contain "project item-add" "move-graphql-failure: no item-add"
assert_logs_not_contain "project item-edit" "move-graphql-failure: no item-edit"

# read-graphql-failure
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api graphql*	1	-
api user	0	$FIXTURES/labels/user.json
api repos/drothschild/HMBWorkout/issues/12	0	$FIXTURES/labels/issue-12.json
api --paginate repos/drothschild/HMBWorkout/issues/12/comments	0	$FIXTURES/labels/comments-none.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-read.sh" 12
assert_exit "read-graphql-failure: exit" 1

# read-no-item: an issue that is not on the project has no state and no item id
setup_case
printf '%s\n' '{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}' > "$FAKE_GH_DIR/no-items.json"
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
api graphql*	0	$FAKE_GH_DIR/no-items.json
api user	0	$FIXTURES/labels/user.json
api repos/drothschild/HMBWorkout/issues/12	0	$FIXTURES/labels/issue-12.json
api --paginate repos/drothschild/HMBWorkout/issues/12/comments	0	$FIXTURES/labels/comments-none.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-read.sh" 12
assert_exit "read-no-item: exit" 0
if printf '%s' "$LAST_OUT" | jq -e '.state == null and .item_id == null' >/dev/null 2>&1; then
  pass "read-no-item: state and item_id null"
else
  fail "read-no-item: state and item_id null" "got $(printf '%s' "$LAST_OUT" | jq -c '{state,item_id}' 2>/dev/null)"
fi

# no-status-field: a project without a Status field fails and caches nothing
setup_case
cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list-no-status.json
api user	0	$FIXTURES/labels/user.json
ROUTESEOF
export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
run_check "$SCRIPT_DIR/../scripts/board-list.sh" ready
assert_exit "no-status-field: exit" 1
assert_stderr_contains "no-status-field: stderr" "has no Status field"
if [ ! -e "$REPO/.fw/.cache/projects.json" ]; then
  pass "no-status-field: no cache written"
else
  fail "no-status-field: no cache written" "found $REPO/.fw/.cache/projects.json"
fi

# list-truncation: gh project item-list stops at --limit and returns items of
# every status and repo, so a reply of exactly the limit may hide cards. The
# adapter fails closed and names the remedy; FLEET_BOARD_LIST_LIMIT raises it
# (default 1000).
projects_list_case() { # NAME COUNT [LIMIT_ENV] [LIST_FLAG]
  setup_case
  jq -n --argjson n "$2" '{items: [range($n) | {content: {type: "Issue", repository: "drothschild/HMBWorkout", number: (. + 1), title: "t", url: "u"}, status: "Ready"}], totalCount: $n}' \
    > "$FAKE_GH_DIR/many.json"
  cat > "$ROUTES" << ROUTESEOF
auth status	0	$FIXTURES/projects/auth-status-ok.txt
project view 1 --owner drothschild --format json	0	$FIXTURES/projects/project-view.json
project field-list 1 --owner drothschild --format json*	0	$FIXTURES/projects/field-list.json
project item-list*	0	$FAKE_GH_DIR/many.json
ROUTESEOF
  export FAKE_GH_DIR FAKE_GH_ROUTES="$ROUTES" PATH="$BIN:$PATH"
  if [ -n "${3:-}" ]; then
    FLEET_BOARD_LIST_LIMIT="$3" run_check "$SCRIPT_DIR/../scripts/board-list.sh" ${4:+"$4"} ready
  else
    unset FLEET_BOARD_LIST_LIMIT
    run_check "$SCRIPT_DIR/../scripts/board-list.sh" ${4:+"$4"} ready
  fi
}
projects_list_case at-limit 1000
assert_exit "list-at-limit: exit" 1
assert_stderr_contains "list-at-limit: names the limit" "1000"
assert_stderr_contains "list-at-limit: names the remedy" "FLEET_BOARD_LIST_LIMIT"
assert_stdout_exact "list-at-limit: no stdout" ""
projects_list_case below-limit 999
assert_exit "list-below-limit: exit" 0
if [ -z "$LAST_ERR" ] && [ "$(jq 'length' <<<"$LAST_OUT")" = 999 ]; then
  pass "list-below-limit: 999 cards, no warning"
else
  fail "list-below-limit: 999 cards, no warning" "stderr: $LAST_ERR; count: $(jq 'length' <<<"$LAST_OUT" 2>&1)"
fi
projects_list_case limit-override 1000 1001
assert_exit "list-limit-override: exit" 0
assert_logs_contain "limit 1001" "list-limit-override: passes the raised limit"
# --allow-truncated (cleanup-done.sh's done listing only): an at-limit reply
# is filtered and printed with a warning naming the limit instead of failing
projects_list_case at-limit-allowed 1000 "" --allow-truncated
assert_exit "list-at-limit-allowed: exit" 0
assert_stderr_contains "list-at-limit-allowed: warns naming the limit" "list limit (1000); the list may be truncated, continuing"
if [ "$(jq 'length' <<<"$LAST_OUT" 2>/dev/null)" = 1000 ]; then
  pass "list-at-limit-allowed: prints the 1000 cards"
else
  fail "list-at-limit-allowed: prints the 1000 cards" "count: $(jq 'length' <<<"$LAST_OUT" 2>&1)"
fi
# the opt-in is the flag only: the adapter's internal variable, inherited from
# the environment, does not widen a plain listing
FB_LIST_ALLOW_TRUNCATED=1 projects_list_case at-limit-inherited 1000
assert_exit "list-at-limit-inherited-var: still fails closed" 1
assert_stderr_contains "list-at-limit: names the second remedy" "archive done items"
projects_list_case limit-invalid 5 abc
assert_exit "list-limit-invalid: exit" 1
assert_stderr_contains "list-limit-invalid: stderr" "FLEET_BOARD_LIST_LIMIT must be a positive integer"
unset FLEET_BOARD_LIST_LIMIT

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

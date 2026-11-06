#!/usr/bin/env bash
#
# Plain-bash tests for the local board backend (config identity and names)
# No framework, no dependencies beyond POSIX tools.
#
# Usage: bash plugins/fleet-board/tests/test-board-local.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"
export SCRIPTS

unset FLEET_BOARD_CONFIG FLEET_BOARD_USER FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()
ORIG_PATH="$PATH"

# Choose a bash executable for consistent invocation.
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
  if [ "$LAST_OUT" = "$2" ]; then pass "$1"; else fail "$1" "expected stdout: '$2', got: '$LAST_OUT' (stderr: '$LAST_ERR')"; fi
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

# run_check_in <dir> <cmd...>: run the command with <dir> as its cwd.
run_check_in() {
  local dir="$1"
  shift
  local tmpout tmperr
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  ( unset CDPATH; cd "$dir" && "$@" ) > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

# A gh that exits 99 on every call: any stray gh call fails the case.
NOGH_DIR="$(mktemp -d)"
CLEANUP_DIRS+=("$NOGH_DIR")
printf '#!/bin/sh\necho "gh must not be called: $*" >&2\nexit 99\n' > "$NOGH_DIR/gh"
chmod +x "$NOGH_DIR/gh"
PATH="$NOGH_DIR:$ORIG_PATH"

# setup_case: sets REPO to a fresh git repo with a committed local-backend config.
setup_case() {
  REPO="$(mktemp -d)"
  CLEANUP_DIRS+=("$REPO")
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  cat > "$REPO/.fleet-board.yml" <<'YML'
board:
  backend: local
  repo: acme/toy
worktrees:
  dir: .fw
YML
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"
  mkdir -p "$REPO/.fleet-board/cards"
  echo 1 > "$REPO/.fleet-board/next"
}

# assert_json <desc> <jq filter> <expected>: jq -r of LAST_OUT must equal expected.
assert_json() {
  local got
  got="$(printf '%s' "$LAST_OUT" | jq -r "$2" 2>/dev/null)"
  if [ "$got" = "$3" ]; then pass "$1"; else fail "$1" "filter $2: expected '$3', got '$got'"; fi
}

echo "Test: local board backend"
echo ""

setup_case

run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_login'
assert_exit "fb_login exits 0 without gh" "0"
assert_stdout_exact "fb_login is USER on local" "$USER"

FLEET_BOARD_USER=robot run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_login'
assert_stdout_exact "fb_login honors FLEET_BOARD_USER" "robot"

run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_state_name in_progress; fb_state_name wont_do'
assert_stdout_exact "local default names" $'In Progress\nWon'"'"'t Do'

run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; for s in backlog ready in_progress in_review human_qa blocked done wont_do; do fb_state_name $s; done'
assert_stdout_exact "local names for all eight states" $'Backlog\nReady\nIn Progress\nIn Review\nHuman QA\nBlocked\nDone\nWon\'t Do'

# A review stage prints "Review: <name>" like Projects does.
setup_case
cat >> "$REPO/.fleet-board.yml" <<'YML'
review:
  stages:
    - name: security
      agent: acme:sec
YML
run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_state_name review_security'
assert_stdout_exact "local review stage name" "Review: security"

# --- create, read, list, cache-clear ---
setup_case
body="$(mktemp)"; CLEANUP_DIRS+=("$body"); printf '## Why\nx\n\n## Acceptance\n- a "quoted" \\ thing\n' > "$body"
run_check_in "$REPO" "$SCRIPTS/board-create.sh" 'Title with "quotes"' "$body" --label bug
assert_exit "create exit 0" 0
assert_stdout_exact "create prints number and url" '{"number":1,"url":"http://127.0.0.1:8765/cards/1"}'
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 1
assert_exit "read exit 0" 0
assert_json "read title round-trips" '.title' 'Title with "quotes"'
assert_json "read body round-trips" '.body' "$(cat "$body")"
assert_json "read state backlog" '.state' backlog
assert_json "read labels" '.labels|join(",")' bug
assert_json "read note null" '.manager_note' null
assert_json "read item_id null" '.item_id' null
run_check_in "$REPO" "$SCRIPTS/board-create.sh" Second "$body" --state ready
assert_stdout_contains "second number is 2" '"number":2'
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 2
assert_json "create --state ready stores ready" '.state' ready
run_check_in "$REPO" "$SCRIPTS/board-list.sh" backlog
assert_stdout_exact "list backlog" '[{"number":1,"title":"Title with \"quotes\"","url":"http://127.0.0.1:8765/cards/1"}]'
run_check_in "$REPO" "$SCRIPTS/board-list.sh" done
assert_stdout_exact "list empty column" '[]'
echo '{' > "$REPO/.fleet-board/cards/2.json"
run_check_in "$REPO" "$SCRIPTS/board-list.sh" ready
assert_exit "list fails closed on a corrupt card" 1
assert_stderr_contains "list names the file" "2.json"
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 2
assert_exit "read fails on a corrupt card" 1
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 77
assert_exit "read missing card" 1
assert_stderr_contains "read names the card" "card #77"
echo abc > "$REPO/.fleet-board/next"
run_check_in "$REPO" "$SCRIPTS/board-create.sh" Third "$body"
assert_exit "corrupt next fails create" 1
assert_stderr_contains "corrupt next named" "next"
rm "$REPO/.fleet-board/next"
run_check_in "$REPO" "$SCRIPTS/board-list.sh" backlog
assert_exit "missing store exit 1" 1
assert_stderr_contains "missing store says init" "/fleet-board:init"
run_check_in "$REPO" "$SCRIPTS/board-cache-clear.sh"
assert_exit "cache-clear no-op" 0

# --- read: manager note, comments shape, unknown state ---
setup_case
run_check_in "$REPO" "$SCRIPTS/board-create.sh" Noted "$body"
MARK='<!-- fleet-board:manager-note -->'
jq --arg m "$MARK" --arg me "$USER" '.next_comment_id = 6 | .comments = [
  {id:1, author:$me, body:($m + "\nold note"), created_at:"2026-01-01T00:00:00Z"},
  {id:2, author:"someone-else", body:($m + "\nforeign note"), created_at:"2026-01-02T00:00:00Z"},
  {id:3, author:$me, body:"plain comment", created_at:"2026-01-03T00:00:00Z"},
  {id:4, author:$me, body:($m + "\nnew note\nsecond line"), created_at:"2026-01-04T00:00:00Z"},
  {id:5, author:"someone-else", body:($m + "\nlate foreign note"), created_at:"2026-01-05T00:00:00Z"}]' \
  "$REPO/.fleet-board/cards/1.json" > "$REPO/card.tmp" && mv "$REPO/card.tmp" "$REPO/.fleet-board/cards/1.json"
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 1
assert_exit "read with notes exit 0" 0
assert_json "last own note wins, marker line stripped" '.manager_note' $'new note\nsecond line'
assert_json "manager_note_id is the last own note id" '.manager_note_id' 4
assert_json "comments length" '.comments|length' 5
assert_json "comment keys" '.comments[2]|keys|join(",")' 'author,body,created_at,id'
assert_json "comment values" '.comments[2]|[.id,.author,.body,.created_at]|join("|")' "3|$USER|plain comment|2026-01-03T00:00:00Z"
jq '.state = "bogus"' "$REPO/.fleet-board/cards/1.json" > "$REPO/card.tmp" && mv "$REPO/card.tmp" "$REPO/.fleet-board/cards/1.json"
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 1
assert_exit "unknown state still reads" 0
assert_json "unknown state is null" '.state' null
assert_stderr_contains "unknown state warns" "bogus"

echo ""
echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

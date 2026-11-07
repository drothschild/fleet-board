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
# USER may be unset (cron, containers): fall back to the login name, as fb_login does
USER="${USER:-$(id -un)}"
export USER

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

# seed_card <n> <state> <title> <body>: writes cards/<n>.json directly.
seed_card() {
  jq -n --argjson n "$1" --arg s "$2" --arg t "$3" --arg b "$4" \
    '{number: $n, title: $t, body: $b, state: $s, labels: [], next_comment_id: 1, comments: [], created_at: "2026-01-01T00:00:00Z"}' \
    > "$REPO/.fleet-board/cards/$1.json"
}

# assert_card_json <n> <jq filter> <expected>: jq -r of the stored card must equal expected.
assert_card_json() {
  local got
  got="$(jq -r "$2" "$REPO/.fleet-board/cards/$1.json" 2>/dev/null)"
  if [ "$got" = "$3" ]; then pass "card $1 $2"; else fail "card $1 $2" "expected '$3', got '$got'"; fi
}

assert_card_state() { assert_card_json "$1" '.state' "$2"; }

# A writer handshake prevents a green result against only the seeded card.
atomic_write_case() {
  setup_case; seed_card 1 backlog Atomic "$(head -c 20000 /dev/zero | tr '\0' x)"
  AW="$REPO/write.json"; jq '.title = "Updated"' "$REPO/.fleet-board/cards/1.json" > "$AW"
  STOP="$REPO/stop-writer"; WRITES="$REPO/writes"; : > "$WRITES"
  ( cd "$REPO" && bash -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; . "$SCRIPTS/adapters/local/local-lib.sh"
    while [ ! -e "$1" ]; do
      fl_write_card 1 "$2" || exit 1
      printf "written\n" >> "$3"
    done' _ "$STOP" "$AW" "$WRITES" ) >"$REPO/writer.out" 2>"$REPO/writer.err" &
  WRITER=$!
  for i in $(seq 1 100); do
    [ -s "$WRITES" ] && break
    kill -0 "$WRITER" 2>/dev/null || break
    sleep 0.02
  done
  BEFORE="$(wc -l < "$WRITES" | tr -d ' ')"
  BAD=0
  for i in $(seq 1 200); do
    jq -e 'type == "object" and .title == "Updated" and (keys | join(",")) == "body,comments,created_at,labels,next_comment_id,number,state,title"'       "$REPO/.fleet-board/cards/1.json" >/dev/null 2>&1 || BAD=$((BAD + 1))
  done
  AFTER="$(wc -l < "$WRITES" | tr -d ' ')"
  : > "$STOP"
  if wait "$WRITER"; then pass "atomic writer exits successfully"; else fail "atomic writer exits successfully" "$(cat "$REPO/writer.err")"; fi
  if [ "$BEFORE" -gt 0 ] && [ "$AFTER" -gt "$BEFORE" ]; then pass "successful writes overlap the reader interval"; else fail "successful writes overlap the reader interval" "before=$BEFORE after=$AFTER"; fi
  if [ "$BAD" -eq 0 ]; then pass "reader sees complete cards on all 200 parses"; else fail "reader sees complete cards on all 200 parses" "$BAD parses failed"; fi
}
racing_note_case() {
  setup_case; seed_card 1 backlog Race x
  rn="$REPO/note.txt"; echo 'racing note' > "$rn"
  (cd "$REPO" && bash "$SCRIPTS/board-note.sh" 1 "$rn" >"$REPO/note1.out" 2>"$REPO/note1.err") &
  P1=$!
  (cd "$REPO" && bash "$SCRIPTS/board-note.sh" 1 "$rn" >"$REPO/note2.out" 2>"$REPO/note2.err") &
  P2=$!
  if wait "$P1"; then pass "first racing note succeeds"; else fail "first racing note succeeds" "$(cat "$REPO/note1.err")"; fi
  if wait "$P2"; then pass "second racing note succeeds"; else fail "second racing note succeeds" "$(cat "$REPO/note2.err")"; fi
  assert_card_json 1 '[.comments[] | select(.body | startswith("<!-- fleet-board:manager-note -->"))] | length' 1
}
if [ "${1:-}" = --concurrency ]; then
  atomic_write_case
  racing_note_case
  printf 'passed: %s failed: %s\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]; exit $?
fi

echo "Test: local board backend"
echo ""

setup_case

run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_login'
assert_exit "fb_login exits 0 without gh" "0"
assert_stdout_exact "fb_login is USER on local" "$USER"

FLEET_BOARD_USER=robot run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_login'
assert_stdout_exact "fb_login honors FLEET_BOARD_USER" "robot"

# USER unset (cron, systemd, containers): the login name from id -un
run_check_in "$REPO" env -u USER -u FLEET_BOARD_USER "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_login'
assert_exit "fb_login with USER unset exits 0" "0"
assert_stdout_exact "fb_login with USER unset is id -un" "$(id -un)"
NOID_DIR="$(mktemp -d)"; CLEANUP_DIRS+=("$NOID_DIR")
printf '#!/bin/sh\nexit 1\n' > "$NOID_DIR/id"; chmod +x "$NOID_DIR/id"
run_check_in "$REPO" env -u USER -u FLEET_BOARD_USER PATH="$NOID_DIR:$PATH" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_login'
assert_exit "fb_login with no identity at all exits 1" "1"
assert_stderr_contains "fb_login names FLEET_BOARD_USER" "FLEET_BOARD_USER"

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

# --- move, comment, note, edit ---
setup_case; seed_card 1 backlog 'A card' $'## Acceptance\n- one'
seed_card 2 backlog 'No acceptance' 'just text'
run_check_in "$REPO" "$SCRIPTS/board-move.sh" 1 in_progress
assert_exit "move exit 0" 0
assert_card_state 1 in_progress
run_check_in "$REPO" "$SCRIPTS/board-move.sh" 2 ready
assert_exit "move to ready without Acceptance refused" 1
assert_stderr_contains "refusal names Acceptance" "Acceptance"
assert_card_state 2 backlog
run_check_in "$REPO" "$SCRIPTS/board-move.sh" 1 review_security
assert_exit "move to an unknown state exit 2" 2
assert_card_state 1 in_progress
c="$(mktemp)"; CLEANUP_DIRS+=("$c"); echo 'first comment' > "$c"
run_check_in "$REPO" "$SCRIPTS/board-comment.sh" 1 "$c"
assert_exit "comment exit 0" 0
assert_card_json 1 '.comments|length' 1
assert_card_json 1 '.comments[0].id' 1
assert_card_json 1 '.comments[0].author' "$USER"
n="$(mktemp)"; CLEANUP_DIRS+=("$n"); printf '```json\n{"round":1}\n```\n' > "$n"
run_check_in "$REPO" "$SCRIPTS/board-note.sh" 1 "$n"
assert_card_json 1 '.comments|length' 2
assert_card_json 1 '.comments[1].body|startswith("<!-- fleet-board:manager-note -->")' true
printf '```json\n{"round":2}\n```\n' > "$n"
run_check_in "$REPO" "$SCRIPTS/board-note.sh" 1 "$n"
assert_card_json 1 '.comments|length' 2
assert_card_json 1 '.comments[1].body|contains("\"round\":2")' true
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 1
assert_json "read returns the note body without the marker line" '.manager_note' $'```json\n{"round":2}\n```'
assert_json "read returns the note id" '.manager_note_id' 2
# concurrency: eight comments at once lose nothing
for i in 1 2 3 4 5 6 7 8; do (cd "$REPO" && bash "$SCRIPTS/board-comment.sh" 1 "$c") & done; wait
assert_card_json 1 '.comments|length' 10
t="$(mktemp)"; CLEANUP_DIRS+=("$t"); echo 'Renamed' > "$t"; b="$(mktemp)"; CLEANUP_DIRS+=("$b"); echo 'new body' > "$b"
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 1 "$t" "$b" '["x","y"]'
assert_exit "edit exit 0" 0
assert_card_json 1 '.title' Renamed
assert_card_json 1 '.labels|join(",")' x,y
assert_card_json 1 '.comments|length' 10
assert_card_json 1 '.state' in_progress
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 1 "$t" "$b" 'notjson'
assert_exit "edit bad labels exit 2" 2
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 77 "$t" "$b" '[]'
assert_exit "edit missing card exit 1" 1
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 1 "$t" "" null
assert_exit "title-only edit succeeds" 0
[ "$(jq -c .labels "$REPO/.fleet-board/cards/1.json")" = '["x","y"]' ] && pass "title-only edit preserves labels" || fail "title-only edit preserves labels" "labels changed"
# the manager writes the note between worktree.sh (which marks) and the
# dispatch, so note must leave the marker; the role's report comment clears it
mkdir -p "$REPO/.fleet-board/active"; : > "$REPO/.fleet-board/active/1"; : > "$REPO/.fleet-board/active/2"
run_check_in "$REPO" "$SCRIPTS/board-note.sh" 1 "$n"
if [ -e "$REPO/.fleet-board/active/1" ]; then pass "note leaves the active marker"; else fail "note leaves the active marker" "removed"; fi
run_check_in "$REPO" "$SCRIPTS/board-comment.sh" 1 "$c"
assert_exit "comment with a marker exit 0" 0
if [ -e "$REPO/.fleet-board/active/1" ]; then pass "ordinary comment leaves the active marker"; else fail "ordinary comment leaves the active marker" "removed"; fi
report="$(mktemp)"
cat > "$report" <<'REPORT'
## Status
clean
## Findings
- none
## For the card
Review complete.
VERIFIED: `true` -> 0 failures
REPORT
FLEET_BOARD_ROLE_REPORT=0 run_check_in "$REPO" "$SCRIPTS/board-comment.sh" 1 "$report"
if [ -e "$REPO/.fleet-board/active/1" ]; then pass "explicit ordinary comment leaves marker even with report text"; else fail "explicit ordinary comment leaves marker even with report text" "removed"; fi
run_check_in "$REPO" "$SCRIPTS/board-comment.sh" 1 "$report"
rm -f "$report"
assert_exit "report comment exit 0" 0
if [ ! -e "$REPO/.fleet-board/active/1" ]; then pass "comment removes the active marker"; else fail "comment removes the active marker" "still present"; fi
if [ -e "$REPO/.fleet-board/active/2" ]; then pass "comment leaves another card's marker"; else fail "comment leaves another card's marker" "removed"; fi

# --- atomic write ---
atomic_write_case

# --- next counter edge cases ---
for v in 0 -3 007; do
  setup_case; printf '%s\n' "$v" > "$REPO/.fleet-board/next"
  run_check_in "$REPO" "$SCRIPTS/board-create.sh" T "$body"
  assert_exit "next '$v' fails create" 1
  assert_stderr_contains "next '$v' names the next file" "next"
done
setup_case; printf '7 \n' > "$REPO/.fleet-board/next"
run_check_in "$REPO" "$SCRIPTS/board-create.sh" T "$body"
assert_exit "next with trailing space succeeds" 0
assert_stdout_contains "next with trailing space allocates 7" '"number":7'

# --- a card file that is valid JSON but not an object ---
setup_case; seed_card 1 backlog 'Real' 'x'; echo '[]' > "$REPO/.fleet-board/cards/2.json"
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 2
assert_exit "read fails closed on a [] card" 1
assert_stderr_contains "read names the [] card file" "2.json"
run_check_in "$REPO" "$SCRIPTS/board-list.sh" backlog
assert_exit "list fails closed on a [] card" 1
assert_stderr_contains "list names the [] card file" "2.json"

# --- eight concurrent creates allocate eight distinct numbers ---
setup_case; CO="$(mktemp -d)"; CLEANUP_DIRS+=("$CO")
for i in 1 2 3 4 5 6 7 8; do (cd "$REPO" && bash "$SCRIPTS/board-create.sh" "C$i" "$body" > "$CO/$i.out" 2>/dev/null) & done; wait
got="$(cat "$CO"/*.out | jq -r .number | sort -n | tr '\n' ' ')"
if [ "$got" = "1 2 3 4 5 6 7 8 " ]; then pass "eight concurrent creates give numbers 1 through 8"; else fail "eight concurrent creates give numbers 1 through 8" "got: $got"; fi

# --- racing notes ---
racing_note_case

# --- an empty note file still writes a marker comment ---
setup_case; seed_card 1 backlog 'Empty note' 'x'; en="$(mktemp)"; CLEANUP_DIRS+=("$en"); : > "$en"
run_check_in "$REPO" "$SCRIPTS/board-note.sh" 1 "$en"
assert_exit "empty note file exits 0" 0
assert_card_json 1 '[.comments[] | select(.body | startswith("<!-- fleet-board:manager-note -->"))] | length' 1

# --- edit on a card without a labels key ---
setup_case; seed_card 1 backlog 'No labels' 'x'
jq 'del(.labels)' "$REPO/.fleet-board/cards/1.json" > "$REPO/card.tmp" && mv "$REPO/card.tmp" "$REPO/.fleet-board/cards/1.json"
et="$(mktemp)"; CLEANUP_DIRS+=("$et"); echo T2 > "$et"
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 1 "$et" "" '["a","b"]'
assert_exit "edit on a card with no labels key exits 0" 0
assert_card_json 1 '.labels|join(",")' a,b

# --- a comment without a trailing newline round-trips byte for byte ---
setup_case; seed_card 1 backlog 'Bytes' 'x'; nc="$(mktemp)"; CLEANUP_DIRS+=("$nc"); printf 'no newline at end' > "$nc"
run_check_in "$REPO" "$SCRIPTS/board-comment.sh" 1 "$nc"
jq -j '.comments[0].body' "$REPO/.fleet-board/cards/1.json" > "$REPO/out.bin"
if cmp -s "$nc" "$REPO/out.bin"; then pass "comment without trailing newline round-trips byte for byte"; else fail "comment without trailing newline round-trips byte for byte" "bytes differ"; fi

echo ""
echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

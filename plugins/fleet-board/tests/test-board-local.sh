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
    - name: documentation
      enabled: false
    - name: blast_radius
      enabled: false
YML
run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_state_name review_security'
assert_stdout_exact "local review stage name" "Review: security"

# merging sits after the review stages and before human_qa, with the name "Merging"
run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; printf "%s\n" "$FB_STATES"'
assert_stdout_exact "FB_STATES with one stage: in_review, the stage, merging, human_qa" \
  "backlog ready in_progress in_review review_security merging human_qa blocked done wont_do"
run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_state_name merging; fb_valid_state merging && echo valid'
assert_stdout_exact "merging has the default name Merging and is a valid state" $'Merging\nvalid'

# --- create, read, list, cache-clear ---
setup_case
body="$(mktemp)"; CLEANUP_DIRS+=("$body"); printf '## Why\nx\n\n## Acceptance\n- a "quoted" \\ thing\n' > "$body"
run_check_in "$REPO" "$SCRIPTS/board-create.sh" 'Title with "quotes"' "$body" --label bug
assert_exit "create exit 0" 0
assert_stdout_exact "create prints number and url" '{"number":1,"url":"http://127.0.0.1:8765/cards/1"}'
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 1
assert_exit "read exit 0" 0
assert_json "read title round-trips" '.title' 'Title with "quotes"'
assert_json "read body is the prose of what was created (sections split off)" '.body+"|"' $'## Why\nx\n|'
assert_json "read acceptance is the bullet of the created body" '.acceptance|join("|")' 'a "quoted" \ thing'
assert_json "read state backlog" '.state' backlog
assert_json "read labels" '.labels|join(",")' bug
assert_json "read note null" '.manager_note' null
assert_json "read item_id null" '.item_id' null
scoped="$(mktemp)"; CLEANUP_DIRS+=("$scoped"); printf '## Why\nx\n\n## Scope\n- src/a.sh\n\n## Acceptance\n- it works\n' > "$scoped"
run_check_in "$REPO" "$SCRIPTS/board-create.sh" Second "$scoped" --state ready
assert_stdout_contains "second number is 2" '"number":2'
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 2
assert_json "create --state ready stores ready for a card with Scope paths" '.state' ready
# An agent filing a card (verify-main, file-followups) into Ready without Scope paths: it lands in
# Backlog, where a person adds the Scope, instead of a Ready card the planner can never start
run_check_in "$REPO" "$SCRIPTS/board-create.sh" Unscoped "$body" --state ready
assert_exit "create --state ready without Scope paths still creates the card" 0
assert_stderr_contains "create warns that a card with no Scope paths went to backlog" \
  "card #3 has no Scope paths; created in backlog, not ready"
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 3
assert_json "create --state ready without Scope paths stores backlog" '.state' backlog
run_check_in "$REPO" "$SCRIPTS/board-list.sh" backlog
assert_stdout_exact "list backlog" '[{"number":1,"title":"Title with \"quotes\"","url":"http://127.0.0.1:8765/cards/1"},{"number":3,"title":"Unscoped","url":"http://127.0.0.1:8765/cards/3"}]'
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
assert_stderr_contains "refusal says the card has no acceptance criteria" "no acceptance criteria"
assert_card_state 2 backlog
seed_card 5 backlog 'Empty field' $'## Acceptance\n- stale'
jq '.acceptance = [] | .blocked_by = []' "$REPO/.fleet-board/cards/5.json" > "$REPO/five.tmp" && mv "$REPO/five.tmp" "$REPO/.fleet-board/cards/5.json"
run_check_in "$REPO" "$SCRIPTS/board-move.sh" 5 ready
assert_exit "move to ready refused when acceptance is [] whatever the body says" 1
assert_card_state 5 backlog
seed_card 6 backlog 'No scope' $'Work.\n\n## Scope\nEverything in the card.\n'
jq '.acceptance = ["it works"] | .blocked_by = []' "$REPO/.fleet-board/cards/6.json" > "$REPO/six.tmp" && mv "$REPO/six.tmp" "$REPO/.fleet-board/cards/6.json"
run_check_in "$REPO" "$SCRIPTS/board-move.sh" 6 ready
assert_exit "move to ready refused when the card has acceptance but no Scope paths" 1
assert_stderr_contains "refusal says the card has no Scope paths" "card #6 has no Scope paths; refusing to move it to ready"
assert_card_state 6 backlog
jq '.body = "Work.\n\n## Scope\n- plugins/a/b.sh\n- c.json (notes)\n"' "$REPO/.fleet-board/cards/6.json" > "$REPO/six.tmp" && mv "$REPO/six.tmp" "$REPO/.fleet-board/cards/6.json"
run_check_in "$REPO" "$SCRIPTS/board-move.sh" 6 ready
assert_exit "move to ready allowed once the Scope names bare paths" 0
assert_card_state 6 ready
# The Scope check guards only Backlog -> Ready: a card the supervisor returns to Ready (cancel, stuck
# release, unblock) was already admitted, and the planner holds a Scope-less Ready card from starting
for from in in_progress blocked; do
  seed_card 7 "$from" 'Returned' $'Work.\n\n## Scope\nEverything in the card.\n'
  jq '.acceptance = ["it works"] | .blocked_by = []' "$REPO/.fleet-board/cards/7.json" > "$REPO/seven.tmp" && mv "$REPO/seven.tmp" "$REPO/.fleet-board/cards/7.json"
  run_check_in "$REPO" "$SCRIPTS/board-move.sh" 7 ready
  assert_exit "move to ready from $from allowed for a card with no Scope paths" 0
  assert_card_state 7 ready
done
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
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 1 --title-file "$t" --body-file "$b" --labels-json '["x","y"]'
assert_exit "edit exit 0" 0
assert_card_json 1 '.title' Renamed
assert_card_json 1 '.labels|join(",")' x,y
assert_card_json 1 '.comments|length' 10
assert_card_json 1 '.state' in_progress
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 1 --title-file "$t" --body-file "$b" --labels-json 'notjson'
assert_exit "edit bad labels exit 2" 2
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 77 --title-file "$t" --body-file "$b" --labels-json '[]'
assert_exit "edit missing card exit 1" 1
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 1 --title-file "$t"
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

# --- card fields: split, render, create, edit, migrate ---
split_of() { run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; . "$SCRIPTS/adapters/local/local-lib.sh"; fl_split_body "$1"' _ "$1"; }
gone_of() { run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; . "$SCRIPTS/adapters/local/local-lib.sh"; declare -F "$1" >/dev/null && echo present || echo gone' _ "$1"; }
setup_case
S="$REPO/sample.md"
printf 'Intro\n\nMore prose\n\n## Acceptance\n- one\n- two `code`\n\n## Depends on\n- #3\n- #7\n' > "$S"
split_of "$S"
assert_exit "split exit 0" 0
assert_json "split body is the prose" '.body+"|"' $'Intro\n\nMore prose\n|'
assert_json "split acceptance bullets" '.acceptance|join("|")' 'one|two `code`'
assert_json "split blocked_by numbers" '.blocked_by|map(tostring)|join(",")' '3,7'
assert_json "split outside empty" '.outside|length' 0
gone_of fl_render_body
assert_stdout_exact "fl_render_body is gone (nothing re-renders the sections)" "gone"
gone_of fl_render_card_json
assert_stdout_exact "fl_render_card_json is gone" "gone"
printf 'Plain, no sections\nat all' > "$S"
split_of "$S"
assert_json "split body without sections is unchanged" '.body' $'Plain, no sections\nat all'
printf '## Depends on\n- #4\n- acme/toy#5\n- other/repo#9\n- not a ref\n- #4\n\n## Why\nx\n' > "$S"
split_of "$S"
assert_json "split maps board.repo refs to numbers, dedupes" '.blocked_by|map(tostring)|join(",")' '4,5'
assert_json "split sends other refs to outside" '.outside|join("|")' 'other/repo#9|not a ref'
assert_json "split keeps the other sections" '.body+"|"' $'## Why\nx\n|'
# review-focus 1: first real heading wins
printf 'Top\n\n## Acceptance\n- first\n\n## Notes\nn\n\n## Acceptance\n- second\n' > "$S"
split_of "$S"
assert_json "two Acceptance headings: first one is split" '.acceptance|join("|")' first
assert_json "two Acceptance headings: second stays in the body" '.body+"|"' $'Top\n\n## Notes\nn\n\n## Acceptance\n- second\n|'
printf 'Top\n\n```\n## Acceptance\n- fenced\n```\n\n## Acceptance\n- real\n' > "$S"
split_of "$S"
assert_json "fenced Acceptance heading is not split" '.acceptance|join("|")' real
assert_json "fenced Acceptance heading stays in the body" '.body+"|"' $'Top\n\n```\n## Acceptance\n- fenced\n```\n|'
printf '```\n## Acceptance\n- fenced\n```\n' > "$S"
split_of "$S"
assert_json "only a fenced heading: nothing split" '.acceptance|length' 0
# create with the fields; read returns them and the rendered body
setup_case
seed_card 1 backlog 'Dep card' 'dep'; echo 2 > "$REPO/.fleet-board/next"
af="$REPO/acc.txt"; printf -- '- alpha\n- beta "q"\n' > "$af"
bf="$REPO/body.md"; printf 'Prose only\n' > "$bf"
run_check_in "$REPO" "$SCRIPTS/board-create.sh" 'With fields' "$bf" --acceptance-file "$af" --blocked-by 1 --label l1
assert_exit "create with fields exit 0" 0
assert_card_json 2 '.acceptance|join("|")' 'alpha|beta "q"'
assert_card_json 2 '.blocked_by|map(tostring)|join(",")' 1
assert_card_json 2 '.pr_url' null
assert_card_json 2 '.pr_url_source' null
assert_card_json 2 '.body|rtrimstr("\n")' 'Prose only'
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 2
assert_json "read returns acceptance" '.acceptance|join("|")' 'alpha|beta "q"'
assert_json "read returns blocked_by" '.blocked_by|map(tostring)|join(",")' 1
assert_json "read returns pr_url" '.pr_url' null
assert_json "read body is the stored prose, without the sections" '.body+"|"' $'Prose only\n|'
printf 'Why\n\n## Acceptance\n- from body\n\n## Depends on\n- #1\n' > "$bf"
run_check_in "$REPO" "$SCRIPTS/board-create.sh" 'Old style body' "$bf"
assert_card_json 3 '.acceptance|join("|")' 'from body'
assert_card_json 3 '.blocked_by|map(tostring)|join(",")' 1
assert_card_json 3 '.body|rtrimstr("\n")' 'Why'
# review-focus 2: blocked_by must name another existing card
run_check_in "$REPO" "$SCRIPTS/board-create.sh" 'Dangling' "$bf" --blocked-by 99
assert_exit "create blocked-by a missing card exits 2" 2
assert_stderr_contains "create names the missing ref" "#99"
run_check_in "$REPO" "$SCRIPTS/board-create.sh" 'Self' "$bf" --blocked-by 4
assert_exit "create blocked by its own number exits 2" 2
assert_stderr_contains "create names the self ref" "#4"
[ ! -e "$REPO/.fleet-board/cards/4.json" ] && pass "refused create leaves no card" || fail "refused create leaves no card" "cards/4.json exists"
printf 'x\n\n## Depends on\n- #98\n' > "$bf"
run_check_in "$REPO" "$SCRIPTS/board-create.sh" 'Dangling via body' "$bf"
assert_exit "create with a dangling Depends on section exits 2" 2
# edit: one field leaves the others
tf="$REPO/t.txt"; echo 'New title' > "$tf"
printf -- '- only\n' > "$REPO/acc2.txt"
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 2 --acceptance-file "$REPO/acc2.txt"
assert_exit "edit acceptance exit 0" 0
assert_card_json 2 '.acceptance|join("|")' only
assert_card_json 2 '.blocked_by|map(tostring)|join(",")' 1
assert_card_json 2 '.title' 'With fields'
assert_card_json 2 '.labels|join(",")' l1
assert_card_json 2 '.body|rtrimstr("\n")' 'Prose only'
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 2 --blocked-by-json '[]'
assert_exit "edit blocked_by exit 0" 0
assert_card_json 2 '.blocked_by|length' 0
assert_card_json 2 '.acceptance|join("|")' only
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 2 --pr-url 'https://github.com/acme/toy/pull/9'
assert_exit "edit pr-url exit 0" 0
assert_card_json 2 '.pr_url' 'https://github.com/acme/toy/pull/9'
assert_card_json 2 '.pr_url_source' person
assert_card_json 2 '.acceptance|join("|")' only
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 2 --title-file "$tf"
assert_card_json 2 '.title' 'New title'
assert_card_json 2 '.pr_url' 'https://github.com/acme/toy/pull/9'
printf 'Body\n\n## Acceptance\n- via body\n' > "$bf"
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 2 --body-file "$bf"
assert_card_json 2 '.acceptance|join("|")' 'via body'
assert_card_json 2 '.body|rtrimstr("\n")' 'Body'
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 2 --blocked-by-json '[99]'
assert_exit "edit blocked by a missing card exits 2" 2
assert_stderr_contains "edit names the missing ref" "#99"
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 2 --blocked-by-json '[2]'
assert_exit "edit blocked by itself exits 2" 2
assert_card_json 2 '.blocked_by|length' 0
# a ref already stored is kept even when its card is gone; only new refs are checked
jq '.blocked_by = [99]' "$REPO/.fleet-board/cards/2.json" > "$REPO/c.tmp" && mv "$REPO/c.tmp" "$REPO/.fleet-board/cards/2.json"
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 2 --blocked-by-json '[99]'
assert_exit "edit keeping a stored missing ref exits 0" 0
assert_card_json 2 '.blocked_by|map(tostring)|join(",")' 99
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 2 --blocked-by-json '[99,98]'
assert_exit "edit adding a new missing ref exits 2" 2
assert_stderr_contains "edit names the new missing ref" "#98"
assert_card_json 2 '.blocked_by|map(tostring)|join(",")' 99
jq '.blocked_by = []' "$REPO/.fleet-board/cards/2.json" > "$REPO/c.tmp" && mv "$REPO/c.tmp" "$REPO/.fleet-board/cards/2.json"
# a body edit is the whole truth about the sections: removing one clears its field
jq '.acceptance = ["a1"] | .blocked_by = [1]' "$REPO/.fleet-board/cards/2.json" > "$REPO/c.tmp" && mv "$REPO/c.tmp" "$REPO/.fleet-board/cards/2.json"
printf 'Why\n\n## Acceptance\n- a1\n\n## Depends on\n- #1\n' > "$bf"
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 2 --body-file "$bf"
assert_exit "body edit keeping the sections exit 0" 0
assert_card_json 2 '.acceptance|join("|")' a1
assert_card_json 2 '.blocked_by|map(tostring)|join(",")' 1
printf 'Why\n' > "$bf"
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 2 --body-file "$bf"
assert_exit "body edit without sections exit 0" 0
assert_card_json 2 '.acceptance|length' 0
assert_card_json 2 '.blocked_by|length' 0
assert_card_json 2 '.body|rtrimstr("\n")' Why
jq '.acceptance = ["a1"] | .blocked_by = [1]' "$REPO/.fleet-board/cards/2.json" > "$REPO/c.tmp" && mv "$REPO/c.tmp" "$REPO/.fleet-board/cards/2.json"
printf -- '- from flag\n' > "$REPO/acc3.txt"
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 2 --body-file "$bf" --acceptance-file "$REPO/acc3.txt"
assert_card_json 2 '.acceptance|join("|")' 'from flag'
assert_card_json 2 '.blocked_by|length' 0
jq '.acceptance = ["a1"] | .blocked_by = [1]' "$REPO/.fleet-board/cards/2.json" > "$REPO/c.tmp" && mv "$REPO/c.tmp" "$REPO/.fleet-board/cards/2.json"
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 2 --body-file "$bf" --blocked-by-json '[1]'
assert_card_json 2 '.blocked_by|map(tostring)|join(",")' 1
assert_card_json 2 '.acceptance|length' 0
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 2 --title-file "$tf"
assert_card_json 2 '.blocked_by|map(tostring)|join(",")' 1
# a dependency line that starts with a reference but carries a note is refused
setup_case
printf 'Why\n' > "$REPO/ok.md"
run_check_in "$REPO" "$SCRIPTS/board-create.sh" 'Dep target' "$REPO/ok.md"
printf 'Why\n\n## Depends on\n- #1 (PR #87, which adds scripts/lint.sh)\n' > "$REPO/bad1.md"
run_check_in "$REPO" "$SCRIPTS/board-create.sh" 'Bad dep' "$REPO/bad1.md"
assert_exit "create refuses a dependency line with a note after the reference" 2
assert_stderr_contains "create names the bad dependency line" 'bad dependency line: #1 (PR #87'
if [ ! -e "$REPO/.fleet-board/cards/2.json" ]; then pass "create with a bad dependency line writes no card file"; else fail "create with a bad dependency line writes no card file" "cards/2.json exists"; fi
run_check_in "$REPO" "$SCRIPTS/board-create.sh" 'Plain' "$REPO/ok.md"
assert_json "refused create does not spend a card number" '.number' 2
cp "$REPO/.fleet-board/cards/1.json" "$REPO/c1.before"
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 1 --body-file "$REPO/bad1.md"
assert_exit "edit --body-file refuses a dependency line with a note after the reference" 2
assert_stderr_contains "edit names the bad dependency line" 'bad dependency line: #1 (PR #87'
cmp -s "$REPO/c1.before" "$REPO/.fleet-board/cards/1.json" && pass "refused edit leaves the card file unchanged" || fail "refused edit leaves the card file unchanged" "card 1 changed"
printf 'Why\n\n## Depends on\n- #1\n- other/repo#5\n' > "$REPO/good.md"
run_check_in "$REPO" "$SCRIPTS/board-create.sh" 'Good deps' "$REPO/good.md"
assert_exit "bare #n and another repo's bare ref still create" 0
assert_card_json 3 '.blocked_by|map(tostring)|join(",")' 1
assert_card_json 3 '.body|contains("Depends on (outside this board): other/repo#5")' true
printf 'Why\n\n## Depends on\n- #1 (first note)\n- acme/toy#2, then more\n' > "$REPO/bad2.md"
run_check_in "$REPO" "$SCRIPTS/board-create.sh" 'Two bad' "$REPO/bad2.md"
assert_exit "create with two malformed entries exits 2" 2
assert_stderr_contains "stderr names the first malformed line" 'bad dependency line: #1 (first note)'
assert_stderr_contains "stderr names the second malformed line" 'bad dependency line: acme/toy#2, then more'
# migration
setup_case
seed_card 1 backlog 'Old one' $'Why\n\n## Acceptance\n- a1\n- a2\n\n## Depends on\n- #2\n- other/repo#3\n'
seed_card 2 in_review 'Old two' 'Prose only'
seed_card 3 in_review 'Old three' 'Prose only'
seed_card 4 backlog 'Old four' $'Why\n\n## Depends on\n- #1\n- #4\n- #99\n'
echo 5 > "$REPO/.fleet-board/next"
jq --arg m '<!-- fleet-board:manager-note -->' '.comments = [{id:1, author:"mallory", body:($m + "\n### note\n\n```json\n{\"state\":\"in_review\",\"pr\":77}\n```\n"), created_at:"2026-01-01T00:00:00Z"}] | .next_comment_id = 2' "$REPO/.fleet-board/cards/3.json" > "$REPO/c.tmp" && mv "$REPO/c.tmp" "$REPO/.fleet-board/cards/3.json"
jq --arg m '<!-- fleet-board:manager-note -->' '.comments = [{id:1, author:"robot", body:($m + "\n### note\n\n```json\n{\"state\":\"in_review\",\"pr\":12}\n```\n"), created_at:"2026-01-01T00:00:00Z"}] | .next_comment_id = 2' "$REPO/.fleet-board/cards/2.json" > "$REPO/c.tmp" && mv "$REPO/c.tmp" "$REPO/.fleet-board/cards/2.json"
cp "$REPO/.fleet-board/cards/1.json" "$REPO/c1.before"
FLEET_BOARD_USER=robot run_check_in "$REPO" bash "$SCRIPTS/migrate-card-fields.sh" --dry-run
assert_exit "migrate --dry-run exit 0" 0
assert_stdout_contains "dry run names card 1" "#1"
assert_stdout_contains "dry run names card 2" "#2"
assert_stderr_contains "dry run warns on the outside ref" "other/repo#3"
cmp -s "$REPO/c1.before" "$REPO/.fleet-board/cards/1.json" && pass "dry run writes nothing" || fail "dry run writes nothing" "card 1 changed"
FLEET_BOARD_USER=robot run_check_in "$REPO" bash "$SCRIPTS/migrate-card-fields.sh"
assert_exit "migrate exit 0" 0
assert_card_json 3 '.pr_url' null
assert_card_json 3 '.pr_url_source' null
assert_card_json 4 '.blocked_by|map(tostring)|join(",")' 1
assert_card_json 4 '.body|contains("Depends on (outside this board): #4")' true
assert_card_json 4 '.body|contains("Depends on (outside this board): #99")' true
assert_stderr_contains "migrate warns on a missing blocker" "#99"
assert_card_json 1 '.acceptance|join("|")' 'a1|a2'
assert_card_json 1 '.blocked_by|map(tostring)|join(",")' 2
assert_card_json 1 '.pr_url' null
assert_card_json 1 '.body|startswith("Why\n")' true
assert_card_json 1 '.body|contains("Depends on (outside this board): other/repo#3")' true
assert_card_json 1 '.updated_at' null
assert_card_json 2 '.acceptance|length' 0
assert_card_json 2 '.pr_url' 'https://github.com/acme/toy/pull/12'
assert_card_json 2 '.pr_url_source' note
assert_card_json 2 '.comments|length' 1
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 1
assert_json "migrated read body has no Acceptance section" '.body|contains("## Acceptance")' false
assert_json "migrated read returns the acceptance field" '.acceptance|join("|")' 'a1|a2'
cp "$REPO/.fleet-board/cards/1.json" "$REPO/c1.after"; cp "$REPO/.fleet-board/cards/2.json" "$REPO/c2.after"
FLEET_BOARD_USER=robot run_check_in "$REPO" bash "$SCRIPTS/migrate-card-fields.sh"
assert_exit "second migrate exit 0" 0
assert_stdout_exact "second migrate changes nothing" ""
cmp -s "$REPO/c1.after" "$REPO/.fleet-board/cards/1.json" && cmp -s "$REPO/c2.after" "$REPO/.fleet-board/cards/2.json" && pass "second migrate leaves the files identical" || fail "second migrate leaves the files identical" "a card changed"

echo "Test: pr_url from the manager note"
setup_case; seed_card 1 in_progress 'Note PR' 'body'
npr="$(mktemp)"; CLEANUP_DIRS+=("$npr")
note_with() { printf '```json\n%s\n```\n' "$1" > "$npr"; run_check_in "$REPO" "$SCRIPTS/board-note.sh" 1 "$npr"; }
note_with '{"round":1,"pr":41}'
assert_exit "note with pr exit 0" 0
assert_card_json 1 '.pr_url' 'https://github.com/acme/toy/pull/41'
assert_card_json 1 '.pr_url_source' note
assert_card_json 1 '.comments|length' 1
note_with '{"round":2,"pr":42}'
assert_card_json 1 '.pr_url' 'https://github.com/acme/toy/pull/42'
assert_card_json 1 '.pr_url_source' note
note_with '{"round":3}'
assert_card_json 1 '.pr_url' 'https://github.com/acme/toy/pull/42'
assert_card_json 1 '.pr_url_source' note
note_with '{"round":4,"pr":null}'
assert_card_json 1 '.pr_url' null
assert_card_json 1 '.pr_url_source' null
note_with '{"pr":43}'
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 1 --pr-url 'https://github.com/acme/toy/pull/50'
note_with '{"pr":null}'
assert_card_json 1 '.pr_url' 'https://github.com/acme/toy/pull/50'
assert_card_json 1 '.pr_url_source' person
note_with '{"pr":50}'
assert_card_json 1 '.pr_url' 'https://github.com/acme/toy/pull/50'
assert_card_json 1 '.pr_url_source' person
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 1 --pr-url 'https://example.com/other/pr/7'
note_with '{"pr":50}'
assert_card_json 1 '.pr_url' 'https://github.com/acme/toy/pull/50'
assert_card_json 1 '.pr_url_source' note
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 1 --pr-url 'https://github.com/acme/toy/pull/9'
note_with '{"pr":51}'
assert_card_json 1 '.pr_url' 'https://github.com/acme/toy/pull/51'
assert_card_json 1 '.pr_url_source' note
printf 'no fence at all\n' > "$npr"
run_check_in "$REPO" "$SCRIPTS/board-note.sh" 1 "$npr"
assert_exit "unparsable note still written" 0
assert_stderr_contains "unparsable note warns" "warning"
assert_card_json 1 '.pr_url' 'https://github.com/acme/toy/pull/51'
assert_card_json 1 '.pr_url_source' note
assert_card_json 1 '.comments[0].body|contains("no fence at all")' true
printf '```json\n{bad json\n```\n' > "$npr"
run_check_in "$REPO" "$SCRIPTS/board-note.sh" 1 "$npr"
assert_stderr_contains "bad json note warns" "warning"
assert_card_json 1 '.pr_url' 'https://github.com/acme/toy/pull/51'

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

# --- a lost lock must not hand out a number twice (card #252) ---
# Simulates the lock failing: three cards are created, then the counter is put back
# to 2 as a second holder of the lock would leave it. The next create must skip the
# numbers already handed out instead of reusing 2.
setup_case
for i in 1 2 3; do (cd "$REPO" && bash "$SCRIPTS/board-create.sh" "D$i" "$body" >/dev/null 2>&1); done
echo 2 > "$REPO/.fleet-board/next"
dup_out="$(cd "$REPO" && bash "$SCRIPTS/board-create.sh" "D4" "$body" 2>/dev/null | jq -r .number)"
if [ "$dup_out" = "4" ]; then pass "eight concurrent creates give numbers 1 through 8: a reset counter never reissues a number"; else fail "eight concurrent creates give numbers 1 through 8: a reset counter never reissues a number" "got: $dup_out"; fi
dup_title="$(jq -r .title "$REPO/.fleet-board/cards/2.json")"
if [ "$dup_title" = "D2" ]; then pass "a reset counter does not overwrite card 2"; else fail "a reset counter does not overwrite card 2" "title: $dup_title"; fi

# --- stale number claims are pruned (card #275) ---
setup_case
for i in 1 2 3 4 5; do (cd "$REPO" && bash "$SCRIPTS/board-create.sh" "P$i" "$body" >/dev/null 2>&1); done
next_n="$(tr -d '[:space:]' < "$REPO/.fleet-board/next")"
stale=""
for c in "$REPO"/.fleet-board/.claims/*; do
  [ -e "$c" ] || continue
  cn="$(basename "$c")"
  if [ "$cn" -lt $((next_n - 1)) ]; then stale="$stale $cn"; fi
done
if [ -z "$stale" ]; then pass "after five creates .claims holds no entry for a number below the next number minus one"; else fail "after five creates .claims holds no entry for a number below the next number minus one" "stale claims:$stale (next is $next_n)"; fi

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
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 1 --title-file "$et" --labels-json '["a","b"]'
assert_exit "edit on a card with no labels key exits 0" 0
assert_card_json 1 '.labels|join(",")' a,b

# --- a comment without a trailing newline round-trips byte for byte ---
setup_case; seed_card 1 backlog 'Bytes' 'x'; nc="$(mktemp)"; CLEANUP_DIRS+=("$nc"); printf 'no newline at end' > "$nc"
run_check_in "$REPO" "$SCRIPTS/board-comment.sh" 1 "$nc"
jq -j '.comments[0].body' "$REPO/.fleet-board/cards/1.json" > "$REPO/out.bin"
if cmp -s "$nc" "$REPO/out.bin"; then pass "comment without trailing newline round-trips byte for byte"; else fail "comment without trailing newline round-trips byte for byte" "bytes differ"; fi

# --- a comment file of /dev/stdin reads the caller's input ---
setup_case; seed_card 1 backlog 'Stdin title' 'stdin body'
run_check_in "$REPO" bash -c 'printf hello | bash "$SCRIPTS/board-comment.sh" 1 /dev/stdin'
assert_exit "board-comment.sh 1 /dev/stdin exits 0" 0
assert_card_json 1 '.title' 'Stdin title'
assert_card_json 1 '.body' 'stdin body'
assert_card_json 1 '.comments[-1].body' 'hello'

# --- fl_write_card refuses output that is not the same card ---
setup_case; seed_card 1 backlog 'Keep' 'body'
before="$(cksum < "$REPO/.fleet-board/cards/1.json")"
empty="$REPO/empty.json"; : > "$empty"
run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; . "$SCRIPTS/adapters/local/local-lib.sh"; fl_write_card 1 "$1"' _ "$empty"
if [ "$LAST_EXIT" -ne 0 ]; then pass "fl_write_card with empty output exits non-zero"; else fail "fl_write_card with empty output exits non-zero" "exit 0"; fi
assert_stderr_contains "fl_write_card refusal names the card" "1"
if [ "$(cksum < "$REPO/.fleet-board/cards/1.json")" = "$before" ]; then pass "empty write leaves the card file byte-for-byte unchanged"; else fail "empty write leaves the card file byte-for-byte unchanged" "file changed"; fi

other="$REPO/other.json"; jq '.number = 2' "$REPO/.fleet-board/cards/1.json" > "$other"
run_check_in "$REPO" "$BASH_EXE" -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; . "$SCRIPTS/adapters/local/local-lib.sh"; fl_write_card 1 "$1"' _ "$other"
if [ "$LAST_EXIT" -ne 0 ]; then pass "fl_write_card with a different number exits non-zero"; else fail "fl_write_card with a different number exits non-zero" "exit 0"; fi
if [ "$(cksum < "$REPO/.fleet-board/cards/1.json")" = "$before" ]; then pass "different-number write leaves the card file byte-for-byte unchanged"; else fail "different-number write leaves the card file byte-for-byte unchanged" "file changed"; fi

# --- hardening: non-string comment bodies ---
setup_case; seed_card 1 backlog 'Nullbody' 'x'
jq '.comments = [{id: 1, author: "someone", body: null, created_at: "2026-01-01T00:00:00Z"}, {id: 2, author: "someone", body: "plain", created_at: "2026-01-02T00:00:00Z"}] | .next_comment_id = 3' \
  "$REPO/.fleet-board/cards/1.json" > "$REPO/c.tmp" && mv "$REPO/c.tmp" "$REPO/.fleet-board/cards/1.json"
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 1
assert_exit "read exits 0 on a card with a comment whose body is null" 0
assert_json "read returns the other comments of a card with a null-body comment" '[.comments[] | select(.body == "plain")] | length' 1
nb="$(mktemp)"; CLEANUP_DIRS+=("$nb"); printf '```json\n{"round":1}\n```\n' > "$nb"
run_check_in "$REPO" "$SCRIPTS/board-note.sh" 1 "$nb"
assert_exit "note exits 0 on a card with a comment whose body is null" 0
assert_card_json 1 '[.comments[] | select((.body | type) == "string" and (.body | startswith("<!-- fleet-board:manager-note -->")))] | length' 1

# --- hardening: list over a 500-card store ---
setup_case
for i in $(seq 1 500); do
  if [ $((i % 3)) -eq 0 ]; then st=ready; else st=backlog; fi
  printf '{"number":%d,"title":"Card %d","state":"%s"}\n' "$i" "$i" "$st" > "$REPO/.fleet-board/cards/$i.json"
done
expected500="$(jq -nc '[range(1; 501) | select(. % 3 == 0) | {number: ., title: "Card \(.)", url: "http://127.0.0.1:8765/cards/\(.)"}]')"
t0="$(date +%s)"
run_check_in "$REPO" "$SCRIPTS/board-list.sh" ready
t1="$(date +%s)"
assert_stdout_exact "list of a 500-card store equals the expected listing" "$expected500"
if [ $((t1 - t0)) -lt 3 ]; then pass "list of a 500-card store finishes in under 3 seconds"; else fail "list of a 500-card store finishes in under 3 seconds" "took $((t1 - t0))s"; fi

# --- hardening: list with an empty cards directory and with a null card ---
setup_case
run_check_in "$REPO" "$BASH_EXE" -c '"$1" ready < <(sleep 4)' _ "$SCRIPTS/board-list.sh"
assert_exit "list of an empty cards directory exits 0 with stdin held open" 0
assert_stdout_exact "list of an empty cards directory prints []" '[]'
setup_case; seed_card 1 ready 'Real' 'x'; echo 'null' > "$REPO/.fleet-board/cards/2.json"
run_check_in "$REPO" "$SCRIPTS/board-list.sh" ready
assert_exit "list fails closed on a null card" 1
assert_stderr_contains "list names the null card file" "2.json"

# --- a card whose state is not a string is warned about, not silently dropped ---
setup_case; seed_card 1 ready 'Real' 'x'
printf '{"number":2,"title":"Numeric","state":7}\n' > "$REPO/.fleet-board/cards/2.json"
run_check_in "$REPO" "$SCRIPTS/board-list.sh" ready
assert_exit "list with a non-numeric-state card still exits 0" 0
assert_stderr_contains "list warns on stderr about a card whose state is not a string" "warning: card #2"
assert_stdout_exact "list still lists the valid cards when another card has a non-string state" '[{"number":1,"title":"Real","url":"http://127.0.0.1:8765/cards/1"}]'

# --- hardening: one next-comment-id helper ---
for s in comment note; do
  f="$SCRIPTS/adapters/local/$s.sh"
  code="$(grep -v '^[[:space:]]*#' "$f")"
  calls="$(printf '%s\n' "$code" | grep -c 'fl_next_comment_id')"
  if [ "$calls" = 1 ]; then pass "$s.sh calls fl_next_comment_id once"; else fail "$s.sh calls fl_next_comment_id once" "found $calls calls"; fi
  case "$code" in
    *"max // 0"*) fail "$s.sh holds no max // 0 expression outside comments" "found one" ;;
    *) pass "$s.sh holds no max // 0 expression outside comments" ;;
  esac
done
if grep -q '^fl_next_comment_id()' "$SCRIPTS/adapters/local/local-lib.sh"; then pass "local-lib.sh defines fl_next_comment_id"; else fail "local-lib.sh defines fl_next_comment_id" "missing"; fi

echo ""
echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

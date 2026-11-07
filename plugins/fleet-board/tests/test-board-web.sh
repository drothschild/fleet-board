#!/usr/bin/env bash
#
# Plain-bash tests for the local web board: board-web.py's API over HTTP and
# the board-web.sh launcher. No framework; needs python3, curl and jq.
#
# Usage: bash plugins/fleet-board/tests/test-board-web.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
export SCRIPTS

unset FLEET_BOARD_CONFIG FLEET_BOARD_LOCK_WAIT || true
FLEET_BOARD_USER=tester
export FLEET_BOARD_USER

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
LAST_CODE=""
SERVER_PID=""
CLEANUP_DIRS=()
ORIG_PATH="$PATH"

# Choose a bash executable for consistent invocation.
if [ -x /bin/bash ]; then
  BASH_EXE="/bin/bash"
else
  BASH_EXE="bash"
fi

require_tool() {
  command -v "$1" >/dev/null 2>&1 || { echo "skipped: $1 not on PATH"; exit 0; }
}
require_tool python3
require_tool curl
require_tool jq

stop_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}

cleanup() {
  stop_server
  # A run left alive by a failed case lives in its own session: end it.
  for pidfile in "$TMP"/logs/web/*/run.pid; do
    [ -f "$pidfile" ] || continue
    [ "$(head -n 1 "$pidfile")" != "$$" ] || continue
    kill "$(head -n 1 "$pidfile")" 2>/dev/null || true
  done
  for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
    rm -rf "$dir" 2>/dev/null || true
  done
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

assert_exit() {
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: '$LAST_ERR')"; fi
}

assert_stderr_contains() {
  case "$LAST_ERR" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected '$2' in stderr, got: '$LAST_ERR'" ;;
  esac
}

run_check() {
  local script="$1"
  shift
  local tmpout tmperr
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  "$BASH_EXE" "$script" "$@" > "$tmpout" 2> "$tmperr" < /dev/null
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

# A gh that exits 99 on every call: no script may reach GitHub.
NOGH_DIR="$(mktemp -d)"
CLEANUP_DIRS+=("$NOGH_DIR")
printf '#!/bin/sh\necho "gh must not be called: $*" >&2\nexit 99\n' > "$NOGH_DIR/gh"
chmod +x "$NOGH_DIR/gh"
PATH="$NOGH_DIR:$ORIG_PATH"

TMP="$(mktemp -d)"
CLEANUP_DIRS+=("$TMP")
BODY_FILE="$TMP/body"

# The run routes spawn this stand-in instead of the headless wrapper.
FAKE_RUN_DIR="$TMP/fake-run"
mkdir -p "$FAKE_RUN_DIR"
FLEET_BOARD_RUN="$SCRIPT_DIR/fake-run.sh"
export FAKE_RUN_DIR FLEET_BOARD_RUN

# new_repo <yml>: prints a fresh git repo path holding <yml> as .fleet-board.yml
# (no config when <yml> is empty).
new_repo() {
  local r
  r="$(mktemp -d)"
  CLEANUP_DIRS+=("$r")
  git init -q "$r"
  git -C "$r" config user.email "test@example.com"
  git -C "$r" config user.name "Test User"
  if [ -n "$1" ]; then
    printf '%s\n' "$1" > "$r/.fleet-board.yml"
    git -C "$r" add .fleet-board.yml
    git -C "$r" commit -q -m "initial"
  fi
  printf '%s\n' "$r"
}

LOCAL_YML='board:
  repo: acme/toy
worktrees:
  dir: .fw'

# seed_card <n> <state> <title> <body> [comments-json]: writes cards/<n>.json directly.
seed_card() {
  local comments="${5:-[]}"
  jq -n --argjson n "$1" --arg s "$2" --arg t "$3" --arg b "$4" --argjson c "$comments" \
    '{number: $n, title: $t, body: $b, state: $s, labels: [], created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z", next_comment_id: (($c | length) + 1), comments: $c}' \
    > "$REPO/.fleet-board/cards/$1.json"
}

# setup_case: REPO = a local-backend repo with three seeded cards; starts the
# server on an ephemeral port (PORT).
setup_case() {
  REPO="$(new_repo "$LOCAL_YML")"
  mkdir -p "$REPO/.fleet-board/cards" "$REPO/.fleet-board/active"
  echo 4 > "$REPO/.fleet-board/next"
  seed_card 1 backlog "First" "Do it.

## Acceptance
- works"
  local fence='```'
  local note_body
  note_body="$(printf '<!-- fleet-board:manager-note -->\n## Manager note\n\n%sjson\n{"round":1,"pr":41,"models":{"implementor":"sonnet"}}\n%s\n' "$fence" "$fence")"
  seed_card 2 in_progress "Second" "Body two.

## Acceptance
- yes" "$(jq -n --arg b "$note_body" '[{id: 1, author: "tester", body: $b, created_at: "2026-01-01T00:00:00Z"}]')"
  seed_card 3 human_qa "Third" "No acceptance here."
  : > "$REPO/.fleet-board/active/2"
  start_server "$REPO"
}

# start_server <repo>: starts board-web.py on an ephemeral port (PORT).
start_server() {
  local out="$TMP/server.out"
  : > "$out"
  FLEET_BOARD_LOG_DIR="$TMP/logs" python3 "$SCRIPTS/board-web.py" --root "$1" --port 0 --scripts "$SCRIPTS" \
    > "$out" 2> "$TMP/server.err" < /dev/null &
  SERVER_PID=$!
  PORT=""
  local i=0 line
  while [ $i -lt 50 ]; do
    line="$(head -n 1 "$out" 2>/dev/null)"
    case "$line" in
      "listening on http://127.0.0.1:"*) PORT="${line##*:}"; break ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  if [ -z "$PORT" ]; then
    fail "server starts" "no 'listening on' line in 5 s; stderr: $(cat "$TMP/server.err" 2>/dev/null)"
    return 1
  fi
  pass "server starts and prints its port"
}

# api <METHOD> <path> [json-body]: sets LAST_CODE; the body lands in BODY_FILE.
# Sends X-Fleet-Board: 1 unless NOHDR=1; ORIGIN=<o> adds an Origin header;
# HOSTHDR=<h> replaces the Host header.
api() {
  local args
  args=(-s --path-as-is -o "$BODY_FILE" -w '%{http_code}' -X "$1")
  [ "${NOHDR:-0}" = 1 ] || args+=(-H 'X-Fleet-Board: 1')
  [ -z "${ORIGIN:-}" ] || args+=(-H "Origin: $ORIGIN")
  [ -z "${HOSTHDR:-}" ] || args+=(-H "Host: $HOSTHDR")
  if [ $# -ge 3 ]; then args+=(-H 'Content-Type: application/json' --data-binary "$3"); fi
  : > "$BODY_FILE"
  LAST_CODE="$(curl "${args[@]}" "http://127.0.0.1:$PORT$2")"
  LAST_REQ="$1 $2"
}

assert_code() {
  if [ "$LAST_CODE" = "$1" ]; then pass "$LAST_REQ -> $1"; else fail "$LAST_REQ -> $1" "got $LAST_CODE: $(cat "$BODY_FILE")"; fi
}

# assert_body <desc> <jq filter> <expected>: jq -r on the body; *glob* matches with case.
assert_body() {
  local got
  got="$(jq -r "$2" "$BODY_FILE" 2>/dev/null)"
  # shellcheck disable=SC2254
  case "$got" in
    $3) pass "$1" ;;
    *) fail "$1" "filter $2: expected '$3', got '$got' (body: $(head -c 300 "$BODY_FILE"))" ;;
  esac
}

# body_is <jq filter> <expected>: true when jq -r on the body equals expected.
body_is() { [ "$(jq -r "$1" "$BODY_FILE" 2>/dev/null)" = "$2" ]; }

# wait_for <shell condition>: polls up to 5 s at 0.2 s; passes or fails on the condition.
wait_for() {
  local i=0
  while [ $i -lt 25 ]; do
    if eval "$1"; then pass "became true: $1"; return 0; fi
    sleep 0.2
    i=$((i + 1))
  done
  fail "became true: $1" "not true in 5 s (last body: $(head -c 300 "$BODY_FILE" 2>/dev/null))"
  return 1
}

card_json() { jq -r "$2" "$REPO/.fleet-board/cards/$1.json" 2>/dev/null; }

echo "Test: local web board"

echo "Case: the board API"
if setup_case; then
  api GET /api/board
  assert_code 200
  assert_body "board states start with backlog" '.states[0].key' backlog
  assert_body "board states carry display names" '.states[0].name' Backlog
  assert_body "board has 8 states" '.states|length' 8
  assert_body "board lists 3 cards" '.cards|length' 3
  assert_body "card 2 note pr" '.cards[]|select(.number==2)|.note.pr' 41
  assert_body "card 2 note round" '.cards[]|select(.number==2)|.note.round' 1
  assert_body "card 2 note models" '.cards[]|select(.number==2)|.note.models.implementor' sonnet
  assert_body "card 2 note stage is null" '.cards[]|select(.number==2)|.note.stage' null
  assert_body "card 1 has no note" '.cards[]|select(.number==1)|.note' null
  assert_body "card 2 not active without a run (marker ignored)" '.cards[]|select(.number==2)|.active' false
  assert_body "board run is idle" '.run.state' idle
  assert_body "board repo is board.repo" '.repo' acme/toy
  assert_body "board card has updated_at" '.cards[]|select(.number==1)|.updated_at' 2026-01-01T00:00:00Z

  api GET /api/cards/2
  assert_code 200
  assert_body "card 2 has one comment" '.comments|length' 1
  assert_body "card 2 manager_note is a string" '.manager_note|type' string
  assert_body "card 2 manager_note drops the marker line" '.manager_note' '## Manager note*'
  assert_body "card 2 pr_url" '.pr_url' 'https://github.com/acme/toy/pull/41'
  api GET /api/cards/1
  assert_body "card 1 manager_note null" '.manager_note' null
  assert_body "card 1 pr_url null" '.pr_url' null

  api GET /api/cards/999
  assert_code 404
  assert_body "missing card error is a string" '.error|type' string
  api POST /api/cards/999/move '{"state":"ready"}'
  assert_code 404

  NOHDR=1 api POST /api/cards '{"title":"t","body":"b"}'
  assert_code 403
  assert_body "403 error is JSON" '.error|type' string
  ORIGIN="http://evil.example" api POST /api/cards '{"title":"t","body":"b"}'
  assert_code 403
  NOHDR=1 api PATCH /api/cards/1 '{"title":"x"}'
  assert_code 403
  if [ "$(card_json 1 .title)" = First ] && [ ! -f "$REPO/.fleet-board/cards/4.json" ]; then
    pass "refused writes changed nothing"
  else
    fail "refused writes changed nothing" "card 1 title $(card_json 1 .title); cards: $(ls "$REPO/.fleet-board/cards")"
  fi

  # DNS rebinding: a request whose Host is not this server is refused, reads included
  HOSTHDR="evil.test:$PORT" api GET /api/board
  assert_code 403
  assert_body "foreign Host error is JSON" '.error|type' string
  HOSTHDR="evil.test:$PORT" api GET /
  assert_code 403
  HOSTHDR="localhost:$PORT" api GET /api/board
  assert_code 200

  ORIGIN="http://127.0.0.1:$PORT" api POST /api/cards '{"title":"New","body":"## Acceptance\n- x","labels":["bug"]}'
  assert_code 200
  assert_body "create returns number 4" '.number' 4
  if [ "$(card_json 4 .title)|$(card_json 4 '.labels|join(",")')|$(card_json 4 .state)" = "New|bug|backlog" ]; then
    pass "card 4 stored with title, labels, backlog"
  else
    fail "card 4 stored with title, labels, backlog" "got $(cat "$REPO/.fleet-board/cards/4.json" 2>/dev/null)"
  fi

  api POST /api/cards/4/move '{"state":"ready"}'
  assert_code 200
  [ "$(card_json 4 .state)" = ready ] && pass "card 4 moved to ready" || fail "card 4 moved to ready" "state $(card_json 4 .state)"

  api POST /api/cards/3/move '{"state":"ready"}'
  assert_code 409
  assert_body "refused move names Acceptance" '.error' '*Acceptance*'
  [ "$(card_json 3 .state)" = human_qa ] && pass "card 3 stays in human_qa" || fail "card 3 stays in human_qa" "state $(card_json 3 .state)"

  api PATCH /api/cards/4 '{"title":"Renamed"}'
  assert_code 200
  api GET /api/cards/4
  assert_body "patched title" '.title' Renamed
  assert_body "patch kept the body" '.body' '## Acceptance*'
  assert_body "patch kept the labels" '.labels|join(",")' bug

  api POST /api/cards/4/comments '{"body":"hi"}'
  assert_code 200
  api GET /api/cards/4
  assert_body "card 4 has one comment" '.comments|length' 1
  assert_body "card 4 comment body" '.comments[0].body' 'hi*'

  api POST /api/cards '{"title":"Readied","body":"## Acceptance\n- y","state":"ready"}'
  assert_code 200
  [ "$(card_json 5 .state)" = ready ] && pass "create with state ready" || fail "create with state ready" "state $(card_json 5 .state)"
  api POST /api/cards '{"title":"Blocked one","body":"b","state":"blocked"}'
  assert_code 200
  [ "$(card_json 6 .state)" = blocked ] && pass "create with state blocked moves it" || fail "create with state blocked moves it" "state $(card_json 6 .state)"

  api POST /api/cards '{"title":"Typo","body":"b","state":"bogus"}'
  assert_code 400
  assert_body "bogus state error names it" '.error' '*bogus*'
  if [ ! -f "$REPO/.fleet-board/cards/7.json" ] && [ "$(tr -d '[:space:]' < "$REPO/.fleet-board/next")" = 7 ]; then
    pass "bogus state created no card"
  else
    fail "bogus state created no card" "cards: $(ls "$REPO/.fleet-board/cards" | tr '\n' ' '); next: $(cat "$REPO/.fleet-board/next")"
  fi
  # state ready goes through the move, so the Acceptance rule applies as it does to a drag
  api POST /api/cards '{"title":"No criteria","body":"just text","state":"ready"}'
  assert_code 409
  assert_body "ready without Acceptance names the created card" '.error' '*#7*'
  [ "$(card_json 7 .state)" = backlog ] && pass "the card exists in backlog" || fail "the card exists in backlog" "state $(card_json 7 .state)"

  api POST /api/cards '{"title":"x"}'
  assert_code 400
  api POST /api/cards 'not json'
  assert_code 400
  api POST /api/cards/4/move '{}'
  assert_code 400
  api POST /api/cards/4/comments '{}'
  assert_code 400

  api GET /api/run;                 assert_body "run starts idle" '.state' idle
  api POST /api/run/stop;           assert_code 409
  rm -f "$FAKE_RUN_DIR/release"
  api POST /api/run/start;          assert_code 200
  assert_body "start returns a pid" '.pid|type' number
  if grep -q -- "--repo $REPO" "$FAKE_RUN_DIR/args.log"; then pass "wrapper got --repo root"; else fail "wrapper got --repo root" "args: $(cat "$FAKE_RUN_DIR/args.log" 2>/dev/null)"; fi
  api GET /api/run;                 assert_body "run is running" '.state' running
  wait_for 'api GET /api/run; body_is .tick 2'
  api GET /api/run;                 assert_body "run reached tick 2" '.tick' 2
  assert_body "run log path parsed" '.log_path' "$FAKE_RUN_DIR/fake.log"
  if [ ! -e "$REPO/.fleet-board/active/2" ]; then pass "start clears stale markers"; else fail "start clears stale markers" "active/2 survived the start"; fi
  : > "$REPO/.fleet-board/active/2"   # the run's manager writes this marker
  api GET /api/board;               assert_body "marker counts while running" '.cards[]|select(.number==2)|.active' true
  assert_body "board run has no log_tail" '.run|has("log_tail")' false
  api POST /api/run/start;          assert_code 409
  api POST /api/run/stop;           assert_code 200
  if [ -e "$REPO/.fleet-board.stop" ]; then pass "stop file written"; else fail "stop file written" "no $REPO/.fleet-board.stop"; fi
  api GET /api/run;                 assert_body "run is stopping" '.state' stopping
  api POST /api/run/start;          assert_code 409
  : > "$FAKE_RUN_DIR/release"   # let the fake finish stopping
  wait_for 'api GET /api/run; body_is .state stopped'
  api GET /api/run
  assert_body "run state stopped" '.state' stopped
  assert_body "stop reason" '.stop_reason' stop-file
  assert_body "run cost" '.cost' 0.42
  assert_body "run hours" '.hours' 0.01
  assert_body "log tail has the two tick lines" '.log_tail|length' 2
  if [ ! -e "$REPO/.fleet-board/active/2" ]; then pass "markers cleared when the run ended"; else fail "markers cleared when the run ended" "active/2 still exists"; fi
  api GET /api/board;               assert_body "no card active after the run" '.cards[]|select(.number==2)|.active' false
  rm -f "$FAKE_RUN_DIR/release"
  api POST /api/run/start;          assert_code 200
  if [ ! -e "$REPO/.fleet-board.stop" ]; then pass "start removes the stale stop file"; else fail "start removes the stale stop file" "stop file still there"; fi
  api GET /api/run;                 assert_body "restarted run is running" '.state' running
  stop_server
  start_server "$REPO"
  api GET /api/run;                 assert_body "restarted server reattaches to the live run" '.state' running
  api POST /api/run/stop;           assert_code 200
  : > "$FAKE_RUN_DIR/release"
  wait_for 'api GET /api/run; body_is .state stopped'
  api GET /api/run;                 assert_body "reattached run stopped" '.state' stopped

  # A pid file naming a live, unrelated process (this shell) with the wrong start time is not a run.
  stop_server
  SD="$TMP/logs/web/acme-toy"
  printf '%s\nMon Jan  1 00:00:00 2001\n' "$$" > "$SD/run.pid"
  : > "$SD/run.out"
  start_server "$REPO"
  api GET /api/run;                 assert_body "reused pid with another start time is idle" '.state' idle
  api POST /api/run/stop;           assert_code 409
  rm -f "$FAKE_RUN_DIR/release"
  api POST /api/run/start;          assert_code 200
  api POST /api/run/stop;           assert_code 200
  : > "$FAKE_RUN_DIR/release"
  wait_for 'api GET /api/run; body_is .state stopped'

  # A wrapper started outside the page holds the run lock: the page sees it.
  LOCKF="$TMP/logs/acme-toy.lock"
  rm -f "$REPO/.fleet-board.stop"   # the last run's stop file
  printf '%s\n%s\n' "$$" "$(LC_ALL=C TZ=UTC ps -o lstart= -p $$ | awk '{ $1 = $1; print }')" > "$LOCKF"
  api GET /api/run;                 assert_body "a live run lock reads as running" '.state' running
  assert_body "the status names the lock's pid" '.pid' "$$"
  assert_body "the page's older run.out does not describe the lock's run" '.stop_reason' null
  api POST /api/run/start;          assert_code 409
  assert_body "the start refusal names the pid" '.error' "*pid $$*"
  api POST /api/run/stop;           assert_code 200
  if [ -e "$REPO/.fleet-board.stop" ]; then pass "stop on a lock-held run writes the stop file"; else fail "stop on a lock-held run writes the stop file" "no stop file"; fi
  api GET /api/run;                 assert_body "a lock-held run with the stop file is stopping" '.state' stopping
  rm -f "$REPO/.fleet-board.stop"
  printf '%s\nMon Jan  1 00:00:00 2001\n' "$$" > "$LOCKF"
  api GET /api/run;                 assert_body "a lock with another start time is not a run" '.state' stopped
  rm -f "$LOCKF"

  # A wrapper that exits at once (before any stopped: line) shows its output.
  stop_server
  FAIL_RUN="$TMP/fail-run.sh"
  printf '#!/bin/sh\necho "fleet-board-run: log: /nowhere/run.log" >/dev/null\necho "fleet-board-run: cannot read board.repo from the config" >&2\nexit 1\n' > "$FAIL_RUN"
  FLEET_BOARD_RUN="$FAIL_RUN" start_server "$REPO"
  api POST /api/run/start;          assert_code 200
  wait_for 'api GET /api/run; body_is .state stopped'
  api GET /api/run
  assert_body "an early exit has no stop reason" '.stop_reason' null
  assert_body "an early exit shows the wrapper's stderr" '.out_tail[0]' 'fleet-board-run: cannot read board.repo from the config'
  stop_server
  start_server "$REPO"

  api GET /api/nothing
  assert_code 404
  assert_body "unknown route error is JSON" '.error|type' string

  api GET /
  assert_code 200
  api GET /cards/2
  assert_code 200
  api GET /static/index.html
  assert_code 200
  api GET /static/../board-web.py
  assert_code 404
  api GET /static/%2e%2e/board-web.py
  assert_code 404

  if [ -z "$(sed -n '2,$p' "$TMP/server.out")" ]; then pass "server stdout holds only the listening line"; else fail "server stdout holds only the listening line" "$(cat "$TMP/server.out")"; fi
  if grep -q Traceback "$TMP/server.err"; then fail "no traceback on stderr" "$(cat "$TMP/server.err")"; else pass "no traceback on stderr"; fi
  stop_server
fi

echo "Case: card fields in the API"
# set_fields <n> <jq update>: edits cards/<n>.json in place.
set_fields() {
  local f="$REPO/.fleet-board/cards/$1.json"
  jq "$2" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
# card_unchanged <desc> <n> <before>: passes when cards/<n>.json still equals <before>.
card_unchanged() {
  if [ "$(cat "$REPO/.fleet-board/cards/$2.json")" = "$3" ]; then pass "$1"; else fail "$1" "card $2 changed: $(cat "$REPO/.fleet-board/cards/$2.json")"; fi
}
REPO="$(new_repo "$LOCAL_YML")"
mkdir -p "$REPO/.fleet-board/cards" "$REPO/.fleet-board/active"
echo 5 > "$REPO/.fleet-board/next"
seed_card 1 backlog "Blocked twice" "Prose one."
set_fields 1 '.acceptance = ["first", "second"] | .blocked_by = [2, 3] | .pr_url = "https://github.com/acme/toy/pull/7" | .pr_url_source = "person"'
seed_card 2 done "Done blocker" "Prose two."
set_fields 2 '.acceptance = [] | .blocked_by = [] | .pr_url = null | .pr_url_source = null'
seed_card 3 ready "Open blocker" "Prose three."
set_fields 3 '.acceptance = ["three"] | .blocked_by = [2] | .pr_url = null | .pr_url_source = null'
seed_card 4 backlog "Missing blocker" "Prose four."
set_fields 4 '.acceptance = [] | .blocked_by = [99] | .pr_url = null | .pr_url_source = null'
if start_server "$REPO"; then
  api GET /api/board
  assert_code 200
  assert_body "summary acceptance_count" '.cards[]|select(.number==1)|.acceptance_count' 2
  assert_body "summary blocked_by" '.cards[]|select(.number==1)|.blocked_by|map(tostring)|join(",")' 2,3
  assert_body "summary pr_url" '.cards[]|select(.number==1)|.pr_url' 'https://github.com/acme/toy/pull/7'
  assert_body "an open blocker blocks" '.cards[]|select(.number==1)|.blocked' true
  assert_body "a done blocker alone does not block" '.cards[]|select(.number==3)|.blocked' false
  assert_body "a missing blocker blocks" '.cards[]|select(.number==4)|.blocked' true
  assert_body "no blockers, not blocked" '.cards[]|select(.number==2)|.blocked' false
  assert_body "summary acceptance_count 0" '.cards[]|select(.number==2)|.acceptance_count' 0
  assert_body "summary pr_url null" '.cards[]|select(.number==2)|.pr_url' null

  api GET /api/cards/1
  assert_code 200
  assert_body "detail acceptance" '.acceptance|join("|")' 'first|second'
  assert_body "detail blocked_by" '.blocked_by|map(tostring)|join(",")' 2,3
  assert_body "detail pr_url is the card field" '.pr_url' 'https://github.com/acme/toy/pull/7'
  assert_body "detail body_prose is the stored body" '.body_prose' 'Prose one.'
  assert_body "detail body still renders the sections" '.body' '*## Acceptance*'

  api PATCH /api/cards/1 '{"acceptance":["x","y","z"]}'
  assert_code 200
  assert_body "patched acceptance returned" '.acceptance|join("|")' 'x|y|z'
  [ "$(card_json 1 '.acceptance|join("|")')" = "x|y|z" ] && pass "acceptance stored" || fail "acceptance stored" "got $(card_json 1 .acceptance)"
  [ "$(card_json 1 '.blocked_by|map(tostring)|join(",")')" = "2,3" ] && pass "acceptance patch kept blocked_by" || fail "acceptance patch kept blocked_by" "got $(card_json 1 .blocked_by)"

  api PATCH /api/cards/1 '{"blocked_by":[3]}'
  assert_code 200
  [ "$(card_json 1 '.blocked_by|map(tostring)|join(",")')" = 3 ] && pass "blocked_by stored" || fail "blocked_by stored" "got $(card_json 1 .blocked_by)"
  [ "$(card_json 1 '.acceptance|length')" = 3 ] && pass "blocked_by patch kept acceptance" || fail "blocked_by patch kept acceptance" "got $(card_json 1 .acceptance)"

  api PATCH /api/cards/1 '{"body":"New prose."}'
  assert_code 200
  assert_body "prose patch returns body_prose" '.body_prose' 'New prose.*'
  if [ "$(card_json 1 '.acceptance|join("|")')|$(card_json 1 '.blocked_by|map(tostring)|join(",")')" = "x|y|z|3" ]; then
    pass "a prose-only body keeps acceptance and blocked_by"
  else
    fail "a prose-only body keeps acceptance and blocked_by" "got $(cat "$REPO/.fleet-board/cards/1.json")"
  fi

  api PATCH /api/cards/1 '{"pr_url":"https://github.com/ACME/Toy/pull/12"}'
  assert_code 200
  [ "$(card_json 1 .pr_url)|$(card_json 1 .pr_url_source)" = "https://github.com/ACME/Toy/pull/12|person" ] \
    && pass "pr_url stored with source person" || fail "pr_url stored with source person" "got $(card_json 1 .pr_url) $(card_json 1 .pr_url_source)"
  api PATCH /api/cards/1 '{"pr_url":null}'
  assert_code 200
  [ "$(card_json 1 .pr_url)" = null ] && pass "pr_url null clears it" || fail "pr_url null clears it" "got $(card_json 1 .pr_url)"
  assert_body "cleared pr_url in the reply" '.pr_url' null

  before="$(cat "$REPO/.fleet-board/cards/1.json")"
  for bad in '"https://github.com/other/repo/pull/1"' '"https://github.com/acme/toy/pull/0"' \
             '"http://github.com/acme/toy/pull/1"' '"https://github.com/acme/toy/pull/1/files"' '""' '5'; do
    api PATCH /api/cards/1 "{\"pr_url\":$bad}"
    assert_code 400
    assert_body "bad pr_url $bad error names pr_url" '.error' '*pr_url*'
  done
  for bad in '"x"' '[1]' '{"a":1}'; do
    api PATCH /api/cards/1 "{\"acceptance\":$bad}"
    assert_code 400
    assert_body "bad acceptance $bad error names acceptance" '.error' '*acceptance*'
  done
  api PATCH /api/cards/1 '{"blocked_by":[1]}'
  assert_code 400
  assert_body "self blocker refused" '.error' '*#1*'
  api PATCH /api/cards/1 '{"blocked_by":[999]}'
  assert_code 400
  assert_body "missing blocker refused" '.error' '*#999*'
  for bad in '["2"]' '[true]' '[0]' '"3"'; do
    api PATCH /api/cards/1 "{\"blocked_by\":$bad}"
    assert_code 400
  done
  api PATCH /api/cards/1 '{"title":"Never","blocked_by":[999]}'
  assert_code 400
  card_unchanged "refused field patches changed nothing" 1 "$before"

  api GET /api/board
  assert_body "blocked by the open #3 alone" '.cards[]|select(.number==1)|.blocked' true
  api PATCH /api/cards/1 '{"blocked_by":[2]}'
  api GET /api/board
  assert_body "only a done blocker left, not blocked" '.cards[]|select(.number==1)|.blocked' false
  if grep -q Traceback "$TMP/server.err"; then fail "no traceback on stderr" "$(cat "$TMP/server.err")"; else pass "no traceback on stderr"; fi
  stop_server
fi

echo "Case: import API"
# A fake claude: logs its argv, writes the two-card fixture to the --preview path
# (or fails when $FAKE_CLAUDE_DIR/fail exists) and prints stream-json lines.
FAKE_CLAUDE_DIR="$TMP/fake-claude"
mkdir -p "$FAKE_CLAUDE_DIR"
IMPORT_FIXTURE="$TMP/import-cards.json"
cat > "$IMPORT_FIXTURE" <<'EOF'
{"cards":[
 {"key":"a","title":"A","repo":"acme/toy","labels":["backend"],
  "why":"Expose the thing.","scope":["src/a.js"],
  "acceptance":["POST /a returns 201"],"consumes":[],"produces":["POST /a"]},
 {"key":"b","title":"B","repo":"acme/toy","labels":["frontend"],
  "why":"Show the thing.","scope":["src/b.js"],
  "acceptance":["GET /b returns 200"],"consumes":["POST /a"],"produces":[],"depends_on":["a"]}
]}
EOF
FAKE_IMPORT_CLAUDE="$TMP/fake-import-claude.sh"
cat > "$FAKE_IMPORT_CLAUDE" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_CLAUDE_DIR/args.log"
prompt="${!#}"
if [ -e "$FAKE_CLAUDE_DIR/fail" ]; then echo boom >&2; exit 1; fi
dest="$(printf '%s' "$prompt" | sed -n 's/.*--preview \([^ ]*\).*/\1/p')"
# slow: hold the session until the test creates $FAKE_CLAUDE_DIR/release (30 s at most)
if [ -e "$FAKE_CLAUDE_DIR/slow" ]; then
  i=0
  while [ ! -e "$FAKE_CLAUDE_DIR/release" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
fi
fixture="$IMPORT_FIXTURE"
[ -e "$FAKE_CLAUDE_DIR/fixture" ] && fixture="$(cat "$FAKE_CLAUDE_DIR/fixture")"
cp "$fixture" "$dest"
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"grouped into 2 cards"}]}}'
echo '{"type":"result","result":"done"}'
EOF
chmod +x "$FAKE_IMPORT_CLAUDE"
export FLEET_BOARD_CLAUDE="$FAKE_IMPORT_CLAUDE" FAKE_CLAUDE_DIR IMPORT_FIXTURE
export FLEET_BOARD_TEST_IMPORT_ID=fixed
SAVED_YML="$LOCAL_YML"
LOCAL_YML="$LOCAL_YML
headless:
  permission_mode: acceptEdits
limits:
  max_turns: 7"
if setup_case; then
  LOCAL_YML="$SAVED_YML"
  api GET /api/import/nope;         assert_code 404
  api POST /api/import '{"status":"ready"}';  assert_code 400
  api POST /api/import '{"plan":"","status":"ready"}';  assert_code 400
  api POST /api/import '{"plan":"x","status":"bogus"}'; assert_code 400
  api POST /api/import '{"plan":"# Plan\n## Task 1: A\n","status":"ready"}'; assert_code 200
  assert_body "import id is the test override" '.import_id' fixed
  wait_for 'api GET /api/import/fixed; body_is .state ready'
  if grep -q -- '/fleet-board:import-plan .*plan.md --preview .*cards.json --status ready' "$FAKE_CLAUDE_DIR/args.log"; then pass "prompt names the skill, preview file and status"; else fail "prompt names the skill, preview file and status" "args: $(cat "$FAKE_CLAUDE_DIR/args.log" 2>/dev/null)"; fi
  if grep -q -- '--permission-mode acceptEdits' "$FAKE_CLAUDE_DIR/args.log"; then pass "permission mode from config"; else fail "permission mode from config" "args: $(cat "$FAKE_CLAUDE_DIR/args.log" 2>/dev/null)"; fi
  if grep -q -- '--max-turns 7' "$FAKE_CLAUDE_DIR/args.log"; then pass "max turns from config"; else fail "max turns from config" "args: $(cat "$FAKE_CLAUDE_DIR/args.log" 2>/dev/null)"; fi
  if grep -q -- '-p --output-format stream-json --verbose' "$FAKE_CLAUDE_DIR/args.log"; then pass "headless stream-json flags"; else fail "headless stream-json flags" "args: $(cat "$FAKE_CLAUDE_DIR/args.log" 2>/dev/null)"; fi
  api GET /api/import/fixed
  assert_body "ready import lists its cards" '.cards.cards|length' 2
  assert_body "ready import carries the dry-run table" '.table' '*| A |*'
  assert_body "last_text is the last assistant text" '.last_text' 'grouped into 2 cards'
  assert_body "elapsed_s is a number" '.elapsed_s|type' number
  assert_body "ready import has no error" '.error' null
  if [ "$(find "$TMP/logs/web/acme-toy/imports/fixed" -name plan.md | wc -l | tr -d ' ')" = 1 ]; then pass "plan.md is kept in the import dir"; else fail "plan.md is kept in the import dir" "missing"; fi
  api GET /api/board;               assert_body "no card created before the create request" '[.cards[]|select(.state=="ready")]|length' 0
  api POST /api/import/fixed/create '{"embed_docs":true}';   assert_code 200
  assert_body "create reports both card numbers" '.created|length' 2
  assert_body "created numbers follow the seeded cards" '.created[0]' 4
  api GET /api/board;               assert_body "created cards land in the chosen state" '[.cards[]|select(.state=="ready")]|length' 2
  api POST /api/import/fixed/create '{}';   assert_code 409
  assert_body "a second create says already created" '.error' '*already created*'
  api GET /api/board;               assert_body "second create adds no cards" '.cards|length' 5

  # A restarted server does not own the process: ready from the parsed cards.json.
  stop_server
  start_server "$REPO"
  api GET /api/import/fixed;        assert_body "restarted server reads a finished import as ready" '.state' ready

  # Failure path: the session exits 1 and writes no cards.json.
  stop_server
  : > "$FAKE_CLAUDE_DIR/fail"
  export FLEET_BOARD_TEST_IMPORT_ID=fixed2
  start_server "$REPO"
  api POST /api/import '{"plan":"x","status":"backlog"}'; assert_code 200
  wait_for 'api GET /api/import/fixed2; body_is .state failed'
  assert_body "failed import reports the stderr line" '.error' boom
  api POST /api/import/fixed2/create '{}';  assert_code 409
  api GET /api/board;               assert_body "a failed import creates nothing" '.cards|length' 5
  if grep -q -- 'preview .*cards.json$' "$FAKE_CLAUDE_DIR/args.log" && [ "$(grep -c -- '--status ready' "$FAKE_CLAUDE_DIR/args.log")" = 1 ]; then pass "backlog import passes no --status"; else fail "backlog import passes no --status" "args: $(cat "$FAKE_CLAUDE_DIR/args.log")"; fi
  stop_server
  start_server "$REPO"
  api GET /api/import/fixed2;       assert_body "restarted server reads an unfinished import as failed" '.state' failed

  # A partial create: card B's 2 MB title overflows the exec argument limit, so board-create.sh
  # cannot be started for it after A exists.
  rm -f "$FAKE_CLAUDE_DIR/fail"
  jq '.cards[1].title = ("x" * 2000000)' "$IMPORT_FIXTURE" > "$TMP/import-cards-partial.json"
  printf '%s' "$TMP/import-cards-partial.json" > "$FAKE_CLAUDE_DIR/fixture"
  stop_server
  export FLEET_BOARD_TEST_IMPORT_ID=fixed3
  start_server "$REPO"
  api POST /api/import '{"plan":"x","status":"backlog"}'; assert_code 200
  wait_for 'api GET /api/import/fixed3; body_is .state ready'
  api POST /api/import/fixed3/create '{}';   assert_code 409
  assert_body "partial create lists the cards that exist" '.created|length' 1
  assert_body "partial create reports the number of the first card" '.created[0]' 6
  assert_body "partial create carries the error" '.error|type' string
  if [ -f "$REPO/.fleet-board/cards/6.json" ]; then pass "the created card exists"; else fail "the created card exists" "no card 6"; fi
  api POST /api/import/fixed3/create '{}';   assert_code 409
  assert_body "a retry after a partial create says already created" '.error' '*already created*'
  api GET /api/board;               assert_body "the retry adds no cards" '.cards|length' 6
  rm -f "$FAKE_CLAUDE_DIR/fixture"

  # A session outliving a server restart is still running, then ready.
  : > "$FAKE_CLAUDE_DIR/slow"
  rm -f "$FAKE_CLAUDE_DIR/release"
  stop_server
  export FLEET_BOARD_TEST_IMPORT_ID=fixed4
  start_server "$REPO"
  api POST /api/import '{"plan":"x","status":"backlog"}'; assert_code 200
  stop_server
  start_server "$REPO"
  api GET /api/import/fixed4;       assert_body "a live session survives a server restart as running" '.state' running
  : > "$FAKE_CLAUDE_DIR/release"
  wait_for 'api GET /api/import/fixed4; body_is .state ready'
  rm -f "$FAKE_CLAUDE_DIR/slow"
  if [ -z "$(sed -n '2,$p' "$TMP/server.out")" ]; then pass "import server stdout holds only the listening line"; else fail "import server stdout holds only the listening line" "$(cat "$TMP/server.out")"; fi
  if grep -q Traceback "$TMP/server.err"; then fail "no traceback on stderr (import)" "$(cat "$TMP/server.err")"; else pass "no traceback on stderr (import)"; fi
  stop_server
fi
unset FLEET_BOARD_CLAUDE FLEET_BOARD_TEST_IMPORT_ID

echo "Case: review stages appear in the board states"
STAGES_REPO="$(new_repo "$LOCAL_YML
review:
  stages:
    - name: security
      agent: reviewer
      label: review-security")"
mkdir -p "$STAGES_REPO/.fleet-board/cards"
echo 1 > "$STAGES_REPO/.fleet-board/next"
if start_server "$STAGES_REPO"; then
  api GET /api/board
  assert_code 200
  assert_body "stages repo has 9 states" '.states|length' 9
  assert_body "review_security follows in_review" '[.states[].key]|index("in_review") as $i|.[$i+1]' review_security
  assert_body "review_security display name" '.states[]|select(.key=="review_security")|.name' 'Review: security'
  stop_server
fi

echo "Case: board-web.sh"
NOCFG_REPO="$(new_repo '')"
run_check "$SCRIPTS/board-web.sh" --repo "$NOCFG_REPO"
assert_exit "missing config exits 3" 3

run_check "$SCRIPTS/board-web.sh" --bogus
assert_exit "unknown flag exits 2" 2
assert_stderr_contains "usage printed" "usage: board-web.sh [--repo DIR] [--port N]"
run_check "$SCRIPTS/board-web.sh" --port
assert_exit "missing --port value exits 2" 2

# A PATH holding every tool the launcher needs, but no python3.
NOPY_DIR="$TMP/nopy"
mkdir -p "$NOPY_DIR"
for t in bash sh git jq dirname basename cat tr sed awk grep head tail mktemp rm date uname env printf wc sort cut mkdir ls readlink; do
  p="$(command -v "$t" 2>/dev/null)" || continue
  case "$p" in /*) ln -s "$p" "$NOPY_DIR/$t" ;; esac
done
LOCAL_REPO="$(new_repo "$LOCAL_YML")"
PATH="$NOPY_DIR" run_check "$SCRIPTS/board-web.sh" --repo "$LOCAL_REPO"
assert_exit "python3 missing exits 1" 1
assert_stderr_contains "python3 missing names python3" "python3 is not on PATH"

for bad in 0 80 1023 65536 999999999999999999999; do
  run_check "$SCRIPTS/board-web.sh" --repo "$LOCAL_REPO" --port "$bad"
  assert_exit "--port $bad is out of range: exit 2" 2
  assert_stderr_contains "--port $bad prints the usage line" "usage: board-web.sh [--repo DIR] [--port N]"
done

# free_port: a port nothing listens on right now
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

# The launcher execs the server on a local repo, run from a linked worktree:
# the root is the main checkout (the directory holding the common git dir), so
# the page shows the store the scripts write.
mkdir -p "$LOCAL_REPO/.fleet-board/cards"
echo 2 > "$LOCAL_REPO/.fleet-board/next"
REPO="$LOCAL_REPO" seed_card 1 backlog "Main store card" "b"
LOCAL_WT="$TMP/launch-wt"
git -C "$LOCAL_REPO" worktree add -q --detach "$LOCAL_WT" 2>/dev/null
LAUNCH_OUT="$TMP/launch.out"
PORT="$(free_port)"
FLEET_BOARD_LOG_DIR="$TMP/launch-logs" "$BASH_EXE" "$SCRIPTS/board-web.sh" --repo "$LOCAL_WT" --port "$PORT" > "$LAUNCH_OUT" 2> "$TMP/launch.err" < /dev/null &
SERVER_PID=$!
i=0
while [ $i -lt 50 ] && ! head -n 1 "$LAUNCH_OUT" | grep -q '^listening on http://127\.0\.0\.1:[0-9][0-9]*$'; do sleep 0.1; i=$((i + 1)); done
if head -n 1 "$LAUNCH_OUT" | grep -q '^listening on http://127\.0\.0\.1:[0-9][0-9]*$'; then
  pass "board-web.sh starts the server"
else
  fail "board-web.sh starts the server" "stdout: $(cat "$LAUNCH_OUT"); stderr: $(cat "$TMP/launch.err")"
fi
api GET /api/board
assert_code 200
assert_body "launched from a worktree, the page reads the main checkout's store" '.cards[0].title' "Main store card"

# A second server on the same port: one line naming the port, exit 1, no traceback
python3 "$SCRIPTS/board-web.py" --root "$LOCAL_REPO" --port "$PORT" --scripts "$SCRIPTS" > /dev/null 2> "$TMP/inuse.err" < /dev/null
LAST_EXIT=$?
LAST_ERR="$(cat "$TMP/inuse.err")"
assert_exit "port in use exits 1" 1
assert_stderr_contains "port in use names the port" "board-web: port $PORT is in use"
case "$LAST_ERR" in *Traceback*) fail "port in use prints no traceback" "$LAST_ERR" ;; *) pass "port in use prints no traceback" ;; esac
stop_server

# Identity: with USER and FLEET_BOARD_USER unset, the note author is the login name
ID_REPO="$(new_repo "$LOCAL_YML")"
mkdir -p "$ID_REPO/.fleet-board/cards"
echo 2 > "$ID_REPO/.fleet-board/next"
ID_NOTE="$(printf '<!-- fleet-board:manager-note -->\n```json\n{"round":3}\n```\n')"
REPO="$ID_REPO" seed_card 1 in_progress "Noted" "b" "$(jq -n --arg b "$ID_NOTE" --arg a "$(id -un)" '[{id: 1, author: $a, body: $b, created_at: "2026-01-01T00:00:00Z"}]')"
SAVED_USER="${USER:-}"
unset USER FLEET_BOARD_USER
start_server "$ID_REPO"
export USER="$SAVED_USER" FLEET_BOARD_USER=tester
api GET /api/board
assert_code 200
assert_body "USER unset: the login name's note is the card's note" '.cards[0].note.round' 3
stop_server

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

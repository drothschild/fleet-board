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
  backend: local
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
# Sends X-Fleet-Board: 1 unless NOHDR=1; ORIGIN=<o> adds an Origin header.
api() {
  local args
  args=(-s --path-as-is -o "$BODY_FILE" -w '%{http_code}' -X "$1")
  [ "${NOHDR:-0}" = 1 ] || args+=(-H 'X-Fleet-Board: 1')
  [ -z "${ORIGIN:-}" ] || args+=(-H "Origin: $ORIGIN")
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
LABELS_REPO="$(new_repo 'board:
  backend: github-labels
  repo: acme/toy')"
run_check "$SCRIPTS/board-web.sh" --repo "$LABELS_REPO"
assert_exit "labels repo refused" 2
assert_stderr_contains "labels refusal names the backend" "board.backend is github-labels; the board page needs local"

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

# The launcher execs the server on a local repo.
LAUNCH_OUT="$TMP/launch.out"
"$BASH_EXE" "$SCRIPTS/board-web.sh" --repo "$LOCAL_REPO" --port 0 > "$LAUNCH_OUT" 2> "$TMP/launch.err" < /dev/null &
SERVER_PID=$!
i=0
while [ $i -lt 50 ] && ! head -n 1 "$LAUNCH_OUT" | grep -q '^listening on http://127\.0\.0\.1:[0-9][0-9]*$'; do sleep 0.1; i=$((i + 1)); done
if head -n 1 "$LAUNCH_OUT" | grep -q '^listening on http://127\.0\.0\.1:[0-9][0-9]*$'; then
  pass "board-web.sh starts the server"
else
  fail "board-web.sh starts the server" "stdout: $(cat "$LAUNCH_OUT"); stderr: $(cat "$TMP/launch.err")"
fi
stop_server

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

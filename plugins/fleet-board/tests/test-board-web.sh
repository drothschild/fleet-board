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

# new_repo <yml>: prints a fresh git repo path holding <yml> as .fleet-board.yml
# (no config when <yml> is empty).
new_repo() {
  local r repo_temp_base
  repo_temp_base="${TMPDIR:-/tmp}"
  r="$(mktemp -d "${repo_temp_base%/}/tmp.XXXXXX")"
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

# setup_case [server-temp-dir]: create a seeded repo outside the optional
# server-only temp directory, then start the server on an ephemeral port.
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
  if [ -n "${1:-}" ]; then
    TMPDIR="$1" start_server "$REPO"
  else
    start_server "$REPO"
  fi
}

# start_server <repo>: starts board-web.py on an ephemeral port (PORT).
start_server() {
  local out="$TMP/server.out"
  : > "$out"
  FLEET_BOARD_LOG_DIR="$TMP/logs" python3 "${SERVER_PY:-$SCRIPTS/board-web.py}" --root "$1" --port 0 --scripts "$SCRIPTS" \
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
  if [ -z "$PORT" ] && [ "${EXPECT_START_FAIL:-0}" = 1 ]; then
    pass "a start that never listens is reported as failed"
    stop_server
    return 1
  fi
  if [ -z "$PORT" ]; then
    fail "server starts" "no 'listening on' line in 5 s; stderr: $(cat "$TMP/server.err" 2>/dev/null)"
    stop_server
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
  assert_body "board has 11 states" '.states|length' 11
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

  ORIGIN="http://127.0.0.1:$PORT" api POST /api/cards '{"title":"New","body":"## Acceptance\n- x\n\n## Scope\n- src/new.sh","labels":["bug"]}'
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
  assert_body "refused move says no acceptance criteria" '.error' '*no acceptance criteria*'
  [ "$(card_json 3 .state)" = human_qa ] && pass "card 3 stays in human_qa" || fail "card 3 stays in human_qa" "state $(card_json 3 .state)"

  api PATCH /api/cards/4 '{"title":"Renamed"}'
  assert_code 200
  api GET /api/cards/4
  assert_body "patched title" '.title' Renamed
  assert_body "patch kept the acceptance field" '.acceptance|join("|")' x
  assert_body "patch kept the body prose" '.body' '## Scope*src/new.sh*'
  assert_body "patch kept the labels" '.labels|join(",")' bug

  api POST /api/cards/4/comments '{"body":"hi"}'
  assert_code 200
  api GET /api/cards/4
  assert_body "card 4 has one comment" '.comments|length' 1
  assert_body "card 4 comment body" '.comments[0].body' 'hi*'

  api POST /api/cards '{"title":"Readied","body":"## Acceptance\n- y\n\n## Scope\n- src/readied.sh","state":"ready"}'
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

  # The tick wrapper's run routes are gone: the page's Start goes to /api/supervisor/start, which
  # always launches the supervisor (fixtures/supervisor/web_cases.py covers the launch).
  api GET /api/run;                 assert_code 404
  api POST /api/run/start;          assert_code 404
  api POST /api/run/stop;           assert_code 404
  # no stop file of any name anywhere under the repo or the log dir (the old tick-stop file included),
  # before and after a Stop; a missing repo fails rather than reads as "nothing found" (the log dir is
  # searched when it exists: with no supervisor run, nothing creates it)
  no_stop_file() { # <label>
    local d out=""
    if [ ! -d "$REPO" ]; then fail "$1" "$REPO is missing"; return; fi
    for d in "$REPO" "$TMP/logs"; do
      [ -d "$d" ] || continue
      out="$out$(find "$d" -name .git -prune -o -name '*stop*' -print 2>&1)"
    done
    if [ -z "$out" ]; then pass "$1"; else fail "$1" "$(printf '%s' "$out" | tr '\n' ' ')"; fi
  }
  no_stop_file "no tick-stop file is written"
  api POST /api/supervisor/stop '{"request_id":"stop-nofile","expected_revision":0,"mode":"drain"}'
  no_stop_file "no tick-stop file is written after a Stop"
  api GET /api/board;               assert_body "board run is idle with no supervisor" '.run.state' idle
  assert_body "board run carries no tick-wrapper fields" '.run | [has("pid"), has("tick"), has("cost"), has("log_tail"), has("out_tail")] | any' false
  assert_body "a marker does not light a card while no supervisor runs" '.cards[]|select(.number==2)|.active' false
  if [ -e "$REPO/.fleet-board/active/2" ]; then pass "the board leaves markers alone"; else fail "the board leaves markers alone" "active/2 was removed"; fi

  api GET /api/nothing
  assert_code 404
  assert_body "unknown route error is JSON" '.error|type' string

  api GET /
  assert_code 200
  api GET /cards/2
  assert_code 200
  api GET /static/index.html
  assert_code 200
  if grep -q 'id="import-btn"' "$SCRIPTS/board-web/static/index.html" || grep -q 'Import plan' "$SCRIPTS/board-web/static/index.html"; then
    fail "index.html no longer contains the Import plan button" "import-btn or the text Import plan still present"
  else
    pass "index.html no longer contains the Import plan button"
  fi
  if grep -q 'id="planner"' "$SCRIPTS/board-web/static/index.html" && grep -q 'id="pl-transcript"' "$SCRIPTS/board-web/static/index.html"; then
    pass "index.html contains the planner chat panel"
  else
    fail "index.html contains the planner chat panel" "planner or pl-transcript missing"
  fi
  api GET /static/../board-web.py
  assert_code 404
  api GET /static/%2e%2e/board-web.py
  assert_code 404

  if [ -z "$(sed -n '2,$p' "$TMP/server.out")" ]; then pass "server stdout holds only the listening line"; else fail "server stdout holds only the listening line" "$(cat "$TMP/server.out")"; fi
  if grep -q Traceback "$TMP/server.err"; then fail "no traceback on stderr" "$(cat "$TMP/server.err")"; else pass "no traceback on stderr"; fi
  stop_server
fi

echo "Case: API gaps"
if setup_case; then
  ORIGIN="http://localhost:$PORT" api POST /api/cards '{"title":"Via localhost","body":"b"}'
  assert_code 200
  assert_body "an Origin of http://localhost:<port> is accepted" '.number' 4
  ORIGIN="http://localhost:1" api POST /api/cards '{"title":"Wrong port","body":"b"}'
  assert_code 403

  # a missing card is refused before any script runs
  api PATCH /api/cards/999 '{"title":"x"}'
  assert_code 404
  api POST /api/cards/999/comments '{"body":"x"}'
  assert_code 404

  # a script that refuses the write answers 409 with its message, on PATCH and on comment
  stop_server
  REFUSE_SCRIPTS="$TMP/scripts-refuse"
  cp -R "$SCRIPTS" "$REFUSE_SCRIPTS"
  printf '#!/bin/sh\necho "refused by test" >&2\nexit 1\n' > "$REFUSE_SCRIPTS/adapters/local/edit.sh"
  printf '#!/bin/sh\necho "refused by test" >&2\nexit 1\n' > "$REFUSE_SCRIPTS/board-comment.sh"
  SCRIPTS="$REFUSE_SCRIPTS" start_server "$REPO"
  api PATCH /api/cards/1 '{"title":"x"}'
  assert_code 409
  assert_body "PATCH 409 carries the script's message" '.error' 'refused by test'
  api POST /api/cards/1/comments '{"body":"x"}'
  assert_code 409
  assert_body "comment 409 carries the script's message" '.error' 'refused by test'
  stop_server

  # an unexpected exception answers 500 JSON, and the server keeps serving
  jq -n '{number: 9, title: "Broken", body: "b", state: "backlog", labels: [], comments: 5,
          created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z", next_comment_id: 1}' \
    > "$REPO/.fleet-board/cards/9.json"
  start_server "$REPO"
  api GET /api/cards/9
  assert_code 500
  assert_body "the 500 error is a JSON string" '.error|type' string
  api GET /api/cards/1
  assert_code 200
  stop_server

  # a start that never prints its port is killed, not left running
  NEVER_PY="$TMP/never-listens.py"
  printf 'import os, time\nwith open(os.environ["NEVER_PID_FILE"], "w") as f:\n    f.write(str(os.getpid()))\ntime.sleep(60)\n' > "$NEVER_PY"
  NEVER_PID_FILE="$TMP/never.pid" EXPECT_START_FAIL=1 SERVER_PY="$NEVER_PY" start_server "$REPO"
  NEVER_PID="$(cat "$TMP/never.pid" 2>/dev/null)"
  if [ -n "$NEVER_PID" ] && kill -0 "$NEVER_PID" 2>/dev/null; then
    fail "a failed start leaves no server process behind" "pid $NEVER_PID still running"
    kill "$NEVER_PID" 2>/dev/null || true
  else
    pass "a failed start leaves no server process behind"
  fi
  SERVER_PID=""
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
  assert_body "detail body is the stored prose" '.body' 'Prose one.'
  assert_body "detail body has no rendered Acceptance section" '.body|contains("## Acceptance")' false
  assert_body "detail has no body_prose key" 'has("body_prose")' false

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
  assert_body "prose patch returns the prose as body" '.body' 'New prose.*'
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

  # the drawer creates a card with its fields, not with body sections
  api POST /api/cards '{"title":"Made","body":"Prose.","acceptance":["one","two"],"blocked_by":[3]}'
  assert_code 200
  if [ "$(card_json 5 '.acceptance|join("|")')|$(card_json 5 '.blocked_by|map(tostring)|join(",")')|$(card_json 5 .body)" = "one|two|3|Prose." ]; then
    pass "create stores acceptance and blocked_by"
  else
    fail "create stores acceptance and blocked_by" "got $(cat "$REPO/.fleet-board/cards/5.json" 2>/dev/null)"
  fi
  api POST /api/cards '{"title":"Bad","body":"b","blocked_by":[999]}'
  assert_code 400
  assert_body "create with a missing blocker names it" '.error' '*#999*'
  api POST /api/cards '{"title":"Bad","body":"b","acceptance":"x"}'
  assert_code 400
  [ ! -f "$REPO/.fleet-board/cards/6.json" ] && pass "refused creates made no card" || fail "refused creates made no card" "cards/6.json exists"
  # the drawer's new card may have criteria and no prose
  api POST /api/cards '{"title":"No prose","body":"","acceptance":["only this"]}'
  assert_code 200
  [ "$(card_json 6 '.acceptance|join("|")')" = "only this" ] && pass "create with an empty body" || fail "create with an empty body" "got $(cat "$REPO/.fleet-board/cards/6.json" 2>/dev/null)"
  # a stored blocker that no longer exists does not stop a prose save, and stays
  api PATCH /api/cards/4 '{"body":"Prose four, edited."}'
  assert_code 200
  if [ "$(card_json 4 '.blocked_by|map(tostring)|join(",")')|$(card_json 4 .body)" = "99|Prose four, edited." ]; then
    pass "prose save keeps a stored blocker on a missing card"
  else
    fail "prose save keeps a stored blocker on a missing card" "got $(cat "$REPO/.fleet-board/cards/4.json")"
  fi
  api PATCH /api/cards/4 '{"blocked_by":[99,3]}'
  assert_code 200
  [ "$(card_json 4 '.blocked_by|map(tostring)|join(",")')" = "99,3" ] && pass "adding a blocker beside a stale one saves" || fail "adding a blocker beside a stale one saves" "got $(card_json 4 .blocked_by)"
  api PATCH /api/cards/4 '{"blocked_by":[99,98]}'
  assert_code 400
  assert_body "a new missing blocker is still refused" '.error' '*#98*'

  # only a checked PR URL leaves the server: anything else in a card file reads as null
  set_fields 2 '.pr_url = "javascript:alert(1)" | .pr_url_source = "person"'
  set_fields 3 '.pr_url = "https://github.com/other/repo/pull/5" | .pr_url_source = "person"'
  api GET /api/board
  assert_body "javascript: pr_url reads as null in the summary" '.cards[]|select(.number==2)|.pr_url' null
  assert_body "another repo's pr_url reads as null in the summary" '.cards[]|select(.number==3)|.pr_url' null
  api GET /api/cards/2
  assert_body "javascript: pr_url reads as null in the detail" '.pr_url' null
  api GET /api/cards/3
  assert_body "another repo's pr_url reads as null in the detail" '.pr_url' null
  set_fields 3 '.pr_url = "https://github.com/Acme/TOY/pull/5"'
  api GET /api/cards/3
  assert_body "a board.repo pr_url in another case still reads" '.pr_url' 'https://github.com/Acme/TOY/pull/5'

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
# hang: record our pid and sleep until killed
if [ -e "$FAKE_CLAUDE_DIR/hang" ]; then echo $$ > "$FAKE_CLAUDE_DIR/pid"; while :; do sleep 1; done; fi
# slow: hold the session until the test creates $FAKE_CLAUDE_DIR/release (30 s at most)
if [ -e "$FAKE_CLAUDE_DIR/slow" ]; then
  i=0
  while [ ! -e "$FAKE_CLAUDE_DIR/release" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
fi
fixture="$IMPORT_FIXTURE"
[ -e "$FAKE_CLAUDE_DIR/fixture" ] && fixture="$(cat "$FAKE_CLAUDE_DIR/fixture")"
cp "$fixture" "$dest"
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"grouped into 2 cards"}]}}'
echo '{"type":"result","result":"done","usage":{"input_tokens":7,"output_tokens":4,"cache_creation_input_tokens":2,"cache_read_input_tokens":1}}'
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
  api GET /api/import/fixed; api GET /api/import/fixed   # repeated polls must not re-record
  if [ "$(grep -c '"action":"import_preview"' "$REPO/.fleet-board/usage.jsonl" 2>/dev/null)" = 1 ] \
     && grep '"action":"import_preview"' "$REPO/.fleet-board/usage.jsonl" | jq -e '.kind=="planner" and .card==null and .role==null and .provider=="claude" and .input==7 and .output==4 and .cache_write==2 and .cache_read==1' >/dev/null 2>&1; then
    pass "import preview recorded exactly once as a planner line"
  else
    fail "import preview recorded exactly once as a planner line" "ledger: $(cat "$REPO/.fleet-board/usage.jsonl" 2>/dev/null)"
  fi
  # a failed ledger append drops the marker so the next poll retries; the line is recorded once, with the
  # session's own times (started_at = meta created_at, ended_at = session.jsonl mtime, not the poll time)
  IDIR="$TMP/logs/web/acme-toy/imports/fixed"
  rm -f "$REPO/.fleet-board/usage.jsonl" "$IDIR/usage.recorded"
  mkdir "$REPO/.fleet-board/usage.jsonl"            # an append to a directory fails
  python3 -c 'import os,sys; os.utime(sys.argv[1], (1577836800, 1577836800))' "$IDIR/session.jsonl"
  api GET /api/import/fixed
  if [ ! -e "$IDIR/usage.recorded" ]; then pass "a failed import usage append leaves no marker"; else fail "a failed import usage append leaves no marker" "marker exists"; fi
  rmdir "$REPO/.fleet-board/usage.jsonl"
  api GET /api/import/fixed; api GET /api/import/fixed
  if [ "$(grep -c '"action":"import_preview"' "$REPO/.fleet-board/usage.jsonl" 2>/dev/null)" = 1 ]; then pass "a failed import append is retried on the next poll and recorded once"; else fail "a failed import append is retried on the next poll and recorded once" "ledger: $(cat "$REPO/.fleet-board/usage.jsonl" 2>/dev/null)"; fi
  created="$(jq -r .created_at "$IDIR/meta.json")"
  if grep '"action":"import_preview"' "$REPO/.fleet-board/usage.jsonl" | jq -e --arg c "$created" '.started_at==$c and .ended_at=="2020-01-01T00:00:00Z"' >/dev/null 2>&1; then pass "import line carries the session's started_at and ended_at"; else fail "import line carries the session's started_at and ended_at" "created $created; ledger: $(cat "$REPO/.fleet-board/usage.jsonl" 2>/dev/null)"; fi
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

  # A partial create: FLEET_BOARD_CREATE names a fake create script that creates card A through
  # board-create.sh and then fails, as import-plan.sh does when the second card fails.
  rm -f "$FAKE_CLAUDE_DIR/fail"
  FAKE_CREATE_PARTIAL="$TMP/fake-create-partial.sh"
  cat > "$FAKE_CREATE_PARTIAL" <<'EOF'
#!/bin/bash
cat > /dev/null
title="$(jq -r '.cards[0].title' "$1")"
bf="$(mktemp)"; printf 'body\n' > "$bf"
out="$(bash "$SCRIPTS/board-create.sh" "$title" "$bf")" || exit 1
rm -f "$bf"
echo "Created #$(jq -r .number <<<"$out"): $title"
echo "failed to create: second card" >&2
exit 1
EOF
  stop_server
  export FLEET_BOARD_TEST_IMPORT_ID=fixed3
  FLEET_BOARD_CREATE="$FAKE_CREATE_PARTIAL" start_server "$REPO"
  api POST /api/import '{"plan":"x","status":"backlog"}'; assert_code 200
  wait_for 'api GET /api/import/fixed3; body_is .state ready'
  api POST /api/import/fixed3/create '{}';   assert_code 409
  assert_body "partial create lists the cards that exist" '.created|length' 1
  assert_body "partial create reports the number of the first card" '.created[0]' 6
  assert_body "partial create carries the error" '.error|type' string
  assert_body "partial create names the card that failed" '.error' 'failed to create: second card'
  if [ -f "$REPO/.fleet-board/cards/6.json" ]; then pass "the created card exists"; else fail "the created card exists" "no card 6"; fi
  api POST /api/import/fixed3/create '{}';   assert_code 409
  assert_body "a retry after a partial create says already created" '.error' '*already created*'
  api GET /api/board;               assert_body "the retry adds no cards" '.cards|length' 6

  # embed_docs picks the answer sent to import-plan.sh's docs prompt: true is e, false (or absent) is m.
  FAKE_CREATE_LOG="$TMP/fake-create-stdin.log"
  FAKE_CREATE_STDIN="$TMP/fake-create-stdin.sh"
  cat > "$FAKE_CREATE_STDIN" <<'EOF'
#!/bin/bash
cat > "$FAKE_CREATE_LOG"
echo "Created #99: stub"
EOF
  stop_server
  export FLEET_BOARD_TEST_IMPORT_ID=fixed6 FAKE_CREATE_LOG
  FLEET_BOARD_CREATE="$FAKE_CREATE_STDIN" start_server "$REPO"
  api POST /api/import '{"plan":"x","status":"backlog"}'; assert_code 200
  wait_for 'api GET /api/import/fixed6; body_is .state ready'
  api POST /api/import/fixed6/create '{"embed_docs":"yes"}';  assert_code 400
  assert_body "a non-boolean embed_docs is named in the error" '.error' '*embed_docs*'
  if [ ! -e "$FAKE_CREATE_LOG" ]; then pass "a refused embed_docs never ran the create script"; else fail "a refused embed_docs never ran the create script" "log: $(cat "$FAKE_CREATE_LOG")"; fi
  api POST /api/import/fixed6/create '{"embed_docs":false}';  assert_code 200
  if [ "$(tr '\n' ',' < "$FAKE_CREATE_LOG" 2>/dev/null)" = "y,m," ]; then pass "embed_docs false sends m"; else fail "embed_docs false sends m" "stdin: $(tr '\n' ',' < "$FAKE_CREATE_LOG" 2>/dev/null)"; fi
  rm -f "$FAKE_CLAUDE_DIR/fixture"

  # FLEET_BOARD_PLUGIN_DIR adds --plugin-dir to the session's argv; without it there is none.
  if ! grep -q -- '--plugin-dir' "$FAKE_CLAUDE_DIR/args.log"; then pass "no --plugin-dir without FLEET_BOARD_PLUGIN_DIR"; else fail "no --plugin-dir without FLEET_BOARD_PLUGIN_DIR" "args: $(cat "$FAKE_CLAUDE_DIR/args.log")"; fi
  : > "$FAKE_CLAUDE_DIR/args.log"
  stop_server
  export FLEET_BOARD_TEST_IMPORT_ID=fixed7
  FLEET_BOARD_PLUGIN_DIR=/x start_server "$REPO"
  api POST /api/import '{"plan":"x","status":"backlog"}'; assert_code 200
  wait_for 'api GET /api/import/fixed7; body_is .state ready'
  if grep -q -- '--plugin-dir /x ' "$FAKE_CLAUDE_DIR/args.log"; then pass "FLEET_BOARD_PLUGIN_DIR=/x adds --plugin-dir /x to the session argv"; else fail "FLEET_BOARD_PLUGIN_DIR=/x adds --plugin-dir /x to the session argv" "args: $(cat "$FAKE_CLAUDE_DIR/args.log")"; fi

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
  # Cancel: a ready or failed import cannot be cancelled.
  api POST /api/import/fixed4/cancel "{}";  assert_code 409
  api POST /api/import/fixed2/cancel "{}";  assert_code 409

  if [ -z "$(sed -n '2,$p' "$TMP/server.out")" ]; then pass "import server stdout holds only the listening line"; else fail "import server stdout holds only the listening line" "$(cat "$TMP/server.out")"; fi
  if grep -q Traceback "$TMP/server.err"; then fail "no traceback on stderr (import)" "$(cat "$TMP/server.err")"; else pass "no traceback on stderr (import)"; fi

  # GET after a create lists the created numbers; meta.json is never seen empty during a create
  export FLEET_BOARD_TEST_IMPORT_ID=fixed5
  stop_server
  start_server "$REPO"
  api POST /api/import '{"plan":"x","status":"backlog"}'; assert_code 200
  wait_for 'api GET /api/import/fixed5; body_is .state ready'
  api GET /api/import/fixed5;       assert_body "an uncreated import has created null" '.created' null
  META="$TMP/logs/web/acme-toy/imports/fixed5/meta.json"
  api POST /api/import/fixed5/create '{}' &
  CREATE_PID=$!
  EMPTY=0; i=0
  while [ $i -lt 100 ]; do
    [ -s "$META" ] || EMPTY=$((EMPTY + 1))
    i=$((i + 1))
  done
  wait "$CREATE_PID"
  if [ "$EMPTY" = 0 ]; then pass "meta.json never empty in 100 polls during a create"; else fail "meta.json never empty in 100 polls during a create" "$EMPTY empty reads"; fi
  api GET /api/import/fixed5
  assert_body "GET after a create returns created numbers" '.created|join(",")' '*,*'
  assert_body "created numbers are integers" '.created[0]|type' number
  if [ -z "$(sed -n '2,$p' "$TMP/server.out")" ]; then pass "import server stdout holds only the listening line"; else fail "import server stdout holds only the listening line" "$(cat "$TMP/server.out")"; fi
  if grep -q Traceback "$TMP/server.err"; then fail "no traceback on stderr (import)" "$(cat "$TMP/server.err")"; else pass "no traceback on stderr (import)"; fi
  # Cancel a running session: a fake claude that sleeps until killed.
  stop_server
  : > "$FAKE_CLAUDE_DIR/hang"
  rm -f "$FAKE_CLAUDE_DIR/pid"
  export FLEET_BOARD_TEST_IMPORT_ID=cancel1
  start_server "$REPO"
  api POST /api/import '{"plan":"x","status":"backlog"}'; assert_code 200
  wait_for '[ -s "$FAKE_CLAUDE_DIR/pid" ]'
  HANG_PID="$(cat "$FAKE_CLAUDE_DIR/pid")"
  api GET /api/import/cancel1;      assert_body "hanging import is running" '.state' running
  api POST /api/import/cancel1/cancel "{}"; assert_code 200
  wait_for '! kill -0 "$HANG_PID" 2>/dev/null'
  if ! kill -0 "$HANG_PID" 2>/dev/null; then pass "cancel kills the session pid"; else fail "cancel kills the session pid" "pid $HANG_PID alive"; fi
  api GET /api/import/cancel1;      assert_body "cancelled import reports cancelled" '.state' cancelled
  # A valid cards.json must not let a cancelled import be created.
  api GET /api/board; CARDS_BEFORE="$(jq '.cards|length' "$BODY_FILE")"
  cp "$IMPORT_FIXTURE" "$TMP/logs/web/acme-toy/imports/cancel1/cards.json"
  api POST /api/import/cancel1/create '{}'; assert_code 409
  assert_body "create on a cancelled import says cancelled" '.error' '*cancelled*'
  api GET /api/board;               assert_body "create on a cancelled import adds no cards" '.cards|length' "$CARDS_BEFORE"
  api POST /api/import/cancel1/cancel "{}"; assert_code 409
  rm -f "$FAKE_CLAUDE_DIR/hang"
  if [ "$(pgrep -f "$FAKE_IMPORT_CLAUDE" | wc -l | tr -d ' ')" = 0 ]; then pass "no fake claude process left running"; else fail "no fake claude process left running" "$(pgrep -fl "$FAKE_IMPORT_CLAUDE")"; fi

  # Discard and Escape in the real board.js cancel the grouping session first.
  for mode in click escape; do
    stop_server
    : > "$FAKE_CLAUDE_DIR/hang"
    rm -f "$FAKE_CLAUDE_DIR/pid"
    export FLEET_BOARD_TEST_IMPORT_ID="js-$mode"
    start_server "$REPO"
    api POST /api/import '{"plan":"x","status":"backlog"}'; assert_code 200
    wait_for '[ -s "$FAKE_CLAUDE_DIR/pid" ]'
    JS_OUT="$(node "$(dirname "$0")/board-web-discard.js" "$SCRIPTS/board-web/static/board.js" "http://127.0.0.1:$PORT" "js-$mode" "$mode" 2>&1)"
    if [ "$JS_OUT" = closed ]; then pass "$mode closes the import view after cancelling"; else fail "$mode closes the import view after cancelling" "$JS_OUT"; fi
    if [ "$(grep -c "POST /api/import/js-$mode/cancel" "$TMP/server.err")" = 1 ]; then pass "$mode sends exactly one cancel request"; else fail "$mode sends exactly one cancel request" "$(cat "$TMP/server.err")"; fi
    api GET "/api/import/js-$mode";   assert_body "$mode leaves the import cancelled" '.state' cancelled
    rm -f "$FAKE_CLAUDE_DIR/hang"
  done
  stop_server
fi
unset FLEET_BOARD_CLAUDE FLEET_BOARD_TEST_IMPORT_ID

echo "Case: Discard and Escape end the session process"
IMPORTS_DIR="$TMP/logs/web/acme-toy/imports"
# session_pid <import id>: the session pid recorded in the import's meta.json.
session_pid() { jq -r '.pid // empty' "$IMPORTS_DIR/$1/meta.json" 2>/dev/null; }
# proc_state <pid> <recorded start>: gone, alive, or unknown: <why>. A kill -0
# that is refused (EPERM) means the process exists, so it is never read as gone.
proc_state() {
  local msg now
  if msg="$(kill -0 "$1" 2>&1)"; then
    now="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')"
    if [ -n "$2" ] && [ -n "$now" ] && [ "$now" != "$2" ]; then echo gone; else echo alive; fi
    return
  fi
  case "$msg" in
    *"No such process"*) echo gone ;;
    *"not permitted"*) echo alive ;;
    *) echo "unknown: $msg" ;;
  esac
}
# assert_session_gone <desc> <import id>
assert_session_gone() {
  local pid start st
  pid="$(session_pid "$2")"
  start="$(jq -r '.pid_start // ""' "$IMPORTS_DIR/$2/meta.json" 2>/dev/null)"
  if [ -z "$pid" ]; then fail "$1" "no pid recorded for import $2"; return; fi
  st="$(proc_state "$pid" "$start")"
  if [ "$st" = gone ]; then pass "$1"; else fail "$1" "session pid $pid of import $2: $st"; fi
}
export FLEET_BOARD_CLAUDE="$FAKE_IMPORT_CLAUDE" FAKE_CLAUDE_DIR IMPORT_FIXTURE
if setup_case; then
  for mode in click escape; do
    stop_server
    : > "$FAKE_CLAUDE_DIR/hang"
    rm -f "$FAKE_CLAUDE_DIR/pid"
    export FLEET_BOARD_TEST_IMPORT_ID="js2-$mode"
    start_server "$REPO"
    api POST /api/import '{"plan":"x","status":"backlog"}'; assert_code 200
    wait_for '[ -s "$FAKE_CLAUDE_DIR/pid" ]'
    JS_OUT="$(node "$SCRIPT_DIR/board-web-discard.js" "$SCRIPTS/board-web/static/board.js" "http://127.0.0.1:$PORT" "js2-$mode" "$mode" 2>&1)"
    if [ "$JS_OUT" = closed ]; then pass "$mode (second run) closes the import view"; else fail "$mode (second run) closes the import view" "$JS_OUT"; fi
    wait_for '[ "$(proc_state "$(session_pid js2-'"$mode"')" "")" != alive ]'
    assert_session_gone "$mode ends the grouping session process" "js2-$mode"
    rm -f "$FAKE_CLAUDE_DIR/hang"
  done
  stop_server
  # Every session the import cases started has ended, the earlier cases' included.
  for id in cancel1 js-click js-escape js2-click js2-escape; do
    assert_session_gone "session of import $id is not left running" "$id"
  done
  # Enumeration must work for "nothing matched" to mean anything: pgrep exits 1
  # on no match, 0 on a match and 2 or more when it cannot list processes.
  PG_OUT="$(pgrep -fl "$FAKE_IMPORT_CLAUDE" 2>&1)"; PG_RC=$?
  case "$PG_RC" in
    1) pass "process list shows no fake claude left running" ;;
    0) fail "process list shows no fake claude left running" "$PG_OUT" ;;
    *) fail "process list shows no fake claude left running" "cannot list processes (pgrep exit $PG_RC): $PG_OUT" ;;
  esac
  # Leave nothing behind even when a case above failed.
  for id in cancel1 js-click js-escape js2-click js2-escape; do
    pid="$(session_pid "$id")"
    [ -n "$pid" ] || continue
    [ "$(proc_state "$pid" "$(jq -r '.pid_start // ""' "$IMPORTS_DIR/$id/meta.json" 2>/dev/null)")" = alive ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
fi
unset FLEET_BOARD_CLAUDE FLEET_BOARD_TEST_IMPORT_ID

echo "Case: atomic meta write"
ATOMIC_OUT="$(SCRIPTS="$SCRIPTS" ATOMIC_DIR="$TMP" python3 -I - <<'PYEOF'
import importlib.util, os, threading
from pathlib import Path
spec = importlib.util.spec_from_file_location("board_web", os.path.join(os.environ["SCRIPTS"], "board-web.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
path = Path(os.environ["ATOMIC_DIR"]) / "atomic-meta.json"
big = "x" * 4000000
m.write_private_atomic(path, big)
stop = threading.Event(); bad = [0]
def reader():
    while not stop.is_set():
        if os.path.getsize(str(path)) != len(big):
            bad[0] += 1
t = threading.Thread(target=reader); t.start()
for _ in range(30):
    m.write_private_atomic(path, big)
stop.set(); t.join()
print(bad[0])
PYEOF
)"
if [ "$ATOMIC_OUT" = 0 ]; then pass "write_private_atomic is never observed partial by a concurrent reader"; else fail "write_private_atomic is never observed partial by a concurrent reader" "$ATOMIC_OUT partial reads"; fi
rm -f "$TMP/atomic-meta.json" "$TMP/atomic-meta.json.tmp"

echo "Case: server hardening"
mkdir -p "$TMP/srvtmp"
if setup_case "$TMP/srvtmp"; then
  # a Content-Length far beyond the body: refused up front, not waited for
  LAST_CODE="$(curl -s -o "$BODY_FILE" -w '%{http_code}' --max-time 5 -X POST -H 'X-Fleet-Board: 1' \
    -H 'Content-Type: application/json' -H 'Content-Length: 2000000' --data-binary '{"a":"bc"}' \
    "http://127.0.0.1:$PORT/api/cards")"
  LAST_REQ="POST /api/cards with Content-Length 2000000"
  assert_code 413
  api GET /api/board
  assert_code 200

  # a corrupt card file is a 500 naming the file, not a 404
  printf '{' > "$REPO/.fleet-board/cards/3.json"
  api GET /api/cards/3
  assert_code 500
  assert_body "corrupt card error names the file" '.error' '*3.json*'
  seed_card 3 human_qa "Third" "No acceptance here."

  # PATCH leaves no temp file of the server's behind
  i=0
  while [ $i -lt 50 ]; do
    api PATCH /api/cards/1 "{\"title\":\"T$i\",\"body\":\"B$i\"}" >/dev/null
    i=$((i + 1))
  done
  assert_code 200
  LEFT="$(find "$TMP/srvtmp" -type f | wc -l | tr -d ' ')"
  if [ "$LEFT" = 0 ]; then pass "50 PATCH calls leave no temp files"; else fail "50 PATCH calls leave no temp files" "$LEFT left: $(ls "$TMP/srvtmp")"; fi

  # the url names the port the server listens on, not board.port
  api POST /api/cards '{"title":"Url","body":"b"}'
  assert_code 200
  assert_body "create url carries the listening port" '.url' "http://127.0.0.1:$PORT/cards/*"

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
  assert_body "stages repo has 12 states" '.states|length' 12
  assert_body "review_security follows in_review" '[.states[].key]|index("in_review") as $i|.[$i+1]' review_security
  assert_body "review_security display name" '.states[]|select(.key=="review_security")|.name' 'Review: security'
  stop_server
fi

echo "Case: cards whose state is unknown"
if setup_case; then
  seed_card 4 bogus "Lost card" "Hand-edited state."
  echo 5 > "$REPO/.fleet-board/next"
  api GET /api/board
  assert_code 200
  assert_body "unknown card is listed" '.cards[]|select(.number==4)|.title' "Lost card"
  assert_body "unknown card keeps its stored state" '.cards[]|select(.number==4)|.state' bogus
  assert_body "unknown card has known false" '.cards[]|select(.number==4)|.known' false
  assert_body "every other card has known true" '[.cards[]|select(.number!=4)|.known]|unique|join(",")' true
  cp "$BODY_FILE" "$TMP/board.json"
  DOM_OUT="$(node "$SCRIPT_DIR/board-dom-harness.js" "$SCRIPTS/board-web/static/board.js" "$TMP/board.json" bogus 2>&1)"
  got="$(printf '%s' "$DOM_OUT" | jq -r '[.groups[]|select(.heading|contains("Unknown state"))|.cards[]]|join("|")' 2>/dev/null)"
  case "$got" in
    *"Lost card"*bogus*) pass "page shows the unknown card under an Unknown state heading with its stored state" ;;
    *) fail "page shows the unknown card under an Unknown state heading with its stored state" "got '$got' from: $DOM_OUT" ;;
  esac
  got="$(printf '%s' "$DOM_OUT" | jq -r '[.groups[]|select(.heading|contains("Unknown state")|not)|.cards[]|select(contains("Lost card"))]|length' 2>/dev/null)"
  if [ "$got" = 0 ]; then pass "the unknown card is in no regular column"; else fail "the unknown card is in no regular column" "count '$got'"; fi
  got="$(printf '%s' "$DOM_OUT" | jq -r '.options|map(.value)|join(" ")' 2>/dev/null)"
  case "$got" in
    *backlog*bogus*|*bogus*backlog*) pass "drawer state select offers the stored state and the valid states" ;;
    *) fail "drawer state select offers the stored state and the valid states" "options: '$got'" ;;
  esac
  if [ "$(printf '%s' "$DOM_OUT" | jq -r .selected 2>/dev/null)" = bogus ]; then pass "drawer select shows the stored state"; else fail "drawer select shows the stored state" "$DOM_OUT"; fi

  api POST /api/cards/4/move '{"state":"backlog"}'
  assert_code 200
  api GET /api/board
  assert_body "moved card is known" '.cards[]|select(.number==4)|.known' true
  assert_body "moved card is in the chosen state" '.cards[]|select(.number==4)|.state' backlog
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

echo "Case: /api/board says which reviewer runs In Review"
RV_REPO="$(new_repo "$LOCAL_YML
models:
  reviewer: opus")"
mkdir -p "$RV_REPO/.fleet-board/cards"
start_server "$RV_REPO"
api GET /api/board
assert_code 200
assert_body "When models.reviewer is the string opus, the in_review state includes reviewer: {provider: claude, model: opus}" '.states[]|select(.key=="in_review")|.reviewer|"\(.provider)/\(.model)"' 'claude/opus'
stop_server

RV_REPO2="$(new_repo "$LOCAL_YML
providers:
  codex:
    review_command: \"codex exec -C {dir} -m {model}\"
models:
  escalation: opus
  reviewer:
    provider: codex
    model: gpt-6-astra
    price: { input: 1, output: 2 }")"
mkdir -p "$RV_REPO2/.fleet-board/cards"
start_server "$RV_REPO2"
api GET /api/board
assert_code 200
assert_body "When models.reviewer is {provider: codex, model: gpt-6-astra}, the in_review state includes reviewer: {provider: codex, model: gpt-6-astra}" '.states[]|select(.key=="in_review")|.reviewer|"\(.provider)/\(.model)"' 'codex/gpt-6-astra'
assert_body "States that are not review columns (backlog, ready, human_qa, ...) have no reviewer field" '[.states[]|select(.key|startswith("in_review")|not)|select(has("reviewer"))]|length' 0
stop_server

echo "Case: the move endpoint refuses a card an agent is working on, unless it is stuck"
MV_REPO="$(new_repo "$LOCAL_YML")"
REPO="$MV_REPO"
mkdir -p "$REPO/.fleet-board/cards" "$REPO/.fleet-board/active"
echo 7 > "$REPO/.fleet-board/next"
for n in 1 2 3 4 5 6; do seed_card "$n" backlog "Card $n" "Do it.

## Acceptance
- works

## Scope
- src/card$n.sh"
  jq '.acceptance = ["works"]' "$REPO/.fleet-board/cards/$n.json" > "$TMP/mv.json" && mv "$TMP/mv.json" "$REPO/.fleet-board/cards/$n.json"
done
MV_OUT="$(SCRIPTS="$SCRIPTS" MV_REPO="$MV_REPO" python3 -I - <<'PYEOF'
import importlib.util, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("board_web", os.path.join(os.environ["SCRIPTS"], "board-web.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
repo = os.environ["MV_REPO"]
m.APP.update(root=repo, scripts=os.environ["SCRIPTS"])
marker = lambda n: Path(repo) / ".fleet-board" / "active" / str(n)
def attempt(label, n, alive, mark, stuck):
    if mark: marker(n).write_text("")
    elif marker(n).exists(): marker(n).unlink()
    m.run_alive = lambda status=None: alive
    m.supervisor_status = lambda: None
    findings = [{"card": n, "kind": "marker", "detail": "x"}] if stuck else []
    m.stuck_view = lambda status, refresh=True: {"findings": findings, "checked_at": None, "error": None,
                                                 "checking": False, "known": True, "suppressed": None}
    try:
        code, _ = m.move_card({"n": n}, {"state": "ready"})
        err = ""
    except m.ApiError as e:
        code, err = e.code, e.msg
    import json
    state = json.load(open(os.path.join(repo, ".fleet-board", "cards", "%d.json" % n)))["state"]
    print("%s|%s|%s|%s" % (label, code, state, err))
attempt("busy", 1, True, True, False)
attempt("nomarker", 2, True, False, False)
attempt("norun", 3, False, True, False)
attempt("stuck", 4, True, True, True)
PYEOF
)"
mv_field() { printf '%s\n' "$MV_OUT" | grep "^$1|" | cut -d'|' -f"$2"; }
[ "$(mv_field busy 2)" = 409 ] && pass "move returns 409 when the run is alive, active/<n> exists and the card is not stuck" || fail "move returns 409 when the run is alive, active/<n> exists and the card is not stuck" "got: $MV_OUT"
case "$(mv_field busy 4)" in *"agent is working on"*) pass "the 409 error text says an agent is working on the card" ;; *) fail "the 409 error text says an agent is working on the card" "got: $MV_OUT" ;; esac
[ "$(mv_field busy 3)" = backlog ] && pass "after a refused move the card file still has its old state" || fail "after a refused move the card file still has its old state" "got: $MV_OUT"
[ "$(mv_field nomarker 2)" = 200 ] && pass "the same move returns 200 when the active/<n> marker is gone" || fail "the same move returns 200 when the active/<n> marker is gone" "got: $MV_OUT"
[ "$(mv_field norun 2)" = 200 ] && pass "the same move returns 200 when the marker exists but no run is alive" || fail "the same move returns 200 when the marker exists but no run is alive" "got: $MV_OUT"
[ "$(mv_field stuck 2)" = 200 ] && pass "the same move returns 200 when the marker exists, the run is alive and the card has a stuck finding" || fail "the same move returns 200 when the marker exists, the run is alive and the card has a stuck finding" "got: $MV_OUT"

echo "Case: a stuck card under a live supervisor run is surfaced to move_card (stuck_view unpatched)"
LS_OUT="$(SCRIPTS="$SCRIPTS" MV_REPO="$MV_REPO" python3 -I - <<'PYEOF'
import importlib.util, os, time
from pathlib import Path
spec = importlib.util.spec_from_file_location("board_web_live", os.path.join(os.environ["SCRIPTS"], "board-web.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
repo = os.environ["MV_REPO"]
m.APP.update(root=repo, scripts=os.environ["SCRIPTS"])
seen = []
def fake_find(root, live_cards=frozenset(), **k):
    seen.append(sorted(live_cards))
    return [] if 5 in live_cards else [m.supervisor_stuck.Stuck(5, "marker", "x")]
m.supervisor_stuck.find = fake_find
status = {"schema_version": 2, "mode": "running", "active": [{"card": 6, "action": "review"}]}
m.run_alive = lambda status=None: True
m.supervisor_status = lambda: status
(Path(repo) / ".fleet-board" / "active" / "5").write_text("")
deadline = time.time() + 5
while time.time() < deadline:
    view = m.stuck_view(status)
    if view["findings"] and not view["checking"]:
        break
    time.sleep(0.1)
print("cards|%s" % ",".join(str(i["card"]) for i in view["findings"]))
print("live|%s" % ";".join(",".join(map(str, s)) for s in seen[:1]))
try:
    code, _ = m.move_card({"n": 5}, {"state": "ready"})
except m.ApiError as e:
    code = e.code
print("move|%s" % code)
PYEOF
)"
ls_field() { printf '%s\n' "$LS_OUT" | grep "^$1|" | cut -d'|' -f2; }
[ "$(ls_field cards)" = 5 ] && pass "a card with a marker and no live action is a stuck finding while a supervisor answers" || fail "a card with a marker and no live action is a stuck finding while a supervisor answers" "got: $LS_OUT"
[ "$(ls_field live)" = 6 ] && pass "the stuck check is given the supervisor's active cards as live" || fail "the stuck check is given the supervisor's active cards as live" "got: $LS_OUT"
[ "$(ls_field move)" = 200 ] && pass "move_card moves a stuck card while the supervisor runs" || fail "move_card moves a stuck card while the supervisor runs" "got: $LS_OUT"

echo "Case: card detail reports the cards it blocks"
REPO="$(new_repo "$LOCAL_YML")"
mkdir -p "$REPO/.fleet-board/cards" "$REPO/.fleet-board/active"
echo 20 > "$REPO/.fleet-board/next"
seed_card 1 backlog "The blocker" "Prose one."
seed_card 3 backlog "Blocked three" "Prose three."
set_fields 3 '.blocked_by = [1]'
seed_card 10 backlog "Blocked ten" "Prose ten."
set_fields 10 '.blocked_by = [1]'
seed_card 2 backlog "Blocked two" "Prose two."
set_fields 2 '.blocked_by = [1]'
seed_card 5 backlog "Depends only in prose" "## Depends on

- #1
"
seed_card 6 backlog "Nobody blocked by six" "Prose six."
if start_server "$REPO"; then
  api GET /api/cards/1
  assert_code 200
  assert_body "GET /api/cards/1 returns blocks 2, 3, 10 when those cards list 1 in blocked_by" '.blocks|map(tostring)|join(",")' 2,3,10
  assert_body "blocks is in ascending card-number order whatever order the files are read in" '.blocks == (.blocks|sort)' true
  assert_body "a card that lists the card only under a Depends on heading is not in blocks" '.blocks|index(5)' null
  api GET /api/cards/6
  assert_body "blocks is [] when no card lists the card in blocked_by" '.blocks|tojson' '[]'
  api GET /api/board
  assert_body "GET /api/board card summaries have no blocks key" '[.cards[]|has("blocks")]|any' false
  stop_server
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

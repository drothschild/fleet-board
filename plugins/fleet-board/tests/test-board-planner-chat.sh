#!/usr/bin/env bash
#
# Plain-bash tests for the planner chat API on board-web.py:
# POST /api/planner, POST /api/planner/<id>/messages, GET /api/planner/<id>.
# Needs python3, curl, jq.
#
# Usage: bash plugins/fleet-board/tests/test-board-planner-chat.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
unset FLEET_BOARD_CONFIG FLEET_BOARD_LOCK_WAIT || true
FLEET_BOARD_USER=tester
export FLEET_BOARD_USER

PASS=0
FAIL=0
SERVER_PID=""
for t in python3 curl jq; do command -v "$t" >/dev/null 2>&1 || { echo "skipped: $t not on PATH"; exit 0; }; done

cleanup() {
  [ -z "$SERVER_PID" ] || { kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }
  rm -rf "$TMP" "$REPO" 2>/dev/null
}
trap cleanup EXIT
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

TMP="$(mktemp -d)"
REPO=""
BODY_FILE="$TMP/body"
ARGV_LOG="$TMP/argv.log"
HOLD="$TMP/hold"
: > "$ARGV_LOG"

NOGH_DIR="$TMP/nogh"
mkdir -p "$NOGH_DIR"
printf '#!/bin/sh\necho "gh must not be called: $*" >&2\nexit 99\n' > "$NOGH_DIR/gh"
chmod +x "$NOGH_DIR/gh"
PATH="$NOGH_DIR:$PATH"

# Fake claude: one argv line per call (arguments joined by the unit separator), waits while
# $HOLD exists, then replies with a stream-json session whose id is sess-<call number>.
FAKE_CLAUDE="$TMP/fake-claude.sh"
cat > "$FAKE_CLAUDE" <<'EOF'
#!/bin/bash
n=$(( $(wc -l < "$ARGV_LOG") + 1 ))
printf '%s\037' "$@" | tr '\n' '\036' >> "$ARGV_LOG"; echo >> "$ARGV_LOG"
while [ -e "$HOLD" ]; do sleep 0.1; done
printf '{"type":"system","session_id":"sess-%d"}\n' "$n"
printf '{"type":"assistant","session_id":"sess-%d","message":{"content":[{"type":"text","text":"reply %d"}]}}\n' "$n" "$n"
printf '{"type":"result","session_id":"sess-%d","result":"reply %d","usage":{"input_tokens":11,"output_tokens":5,"cache_creation_input_tokens":3,"cache_read_input_tokens":2}}\n' "$n" "$n"
EOF
chmod +x "$FAKE_CLAUDE"
export FLEET_BOARD_CLAUDE="$FAKE_CLAUDE" ARGV_LOG HOLD
export FLEET_BOARD_TEST_PLANNER_ID=conv1

REPO="$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXX")"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name T
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
git -C "$REPO" add .fleet-board.yml
git -C "$REPO" commit -q -m initial
mkdir -p "$REPO/.fleet-board/cards" "$REPO/.fleet-board/active"
echo 1 > "$REPO/.fleet-board/next"

: > "$TMP/server.out"
FLEET_BOARD_LOG_DIR="$TMP/logs" python3 "$SCRIPTS/board-web.py" --root "$REPO" --port 0 --scripts "$SCRIPTS" \
  > "$TMP/server.out" 2> "$TMP/server.err" < /dev/null &
SERVER_PID=$!
PORT=""
for _ in $(seq 1 50); do
  line="$(head -n 1 "$TMP/server.out" 2>/dev/null)"
  case "$line" in "listening on http://127.0.0.1:"*) PORT="${line##*:}"; break ;; esac
  sleep 0.1
done
[ -n "$PORT" ] || { echo "server did not start: $(cat "$TMP/server.err")"; exit 1; }

api() {
  local args=(-s --path-as-is -o "$BODY_FILE" -w '%{http_code}' -X "$1" -H 'X-Fleet-Board: 1')
  [ $# -ge 3 ] && args+=(-H 'Content-Type: application/json' --data-binary "$3")
  : > "$BODY_FILE"
  LAST_CODE="$(curl "${args[@]}" "http://127.0.0.1:$PORT$2")"
  LAST_REQ="$1 $2"
}
assert_code() { if [ "$LAST_CODE" = "$1" ]; then pass "$2 ($LAST_REQ -> $1)"; else fail "$2 ($LAST_REQ -> $1)" "got $LAST_CODE: $(cat "$BODY_FILE")"; fi; }
assert_body() {
  local got
  got="$(jq -r "$2" "$BODY_FILE" 2>/dev/null)"
  # shellcheck disable=SC2254
  case "$got" in $3) pass "$1" ;; *) fail "$1" "filter $2: expected '$3', got '$got'" ;; esac
}
wait_idle() {
  for _ in $(seq 1 80); do
    api GET "/api/planner/$1"
    [ "$(jq -r .running "$BODY_FILE" 2>/dev/null)" = false ] && return 0
    sleep 0.1
  done
}

PDIR="$TMP/logs/web/acme-toy/planner/conv1"

echo "Case: POST /api/planner returns 200 with a conversation id and a 0700 state directory"
api POST /api/planner '{}'
assert_code 200 "conversation started"
assert_body "response carries the conversation id" '.id' 'conv1'
mode="$(stat -c %a "$PDIR" 2>/dev/null || stat -f %Lp "$PDIR" 2>/dev/null)"
if [ "$mode" = 700 ]; then pass "state directory has mode 0700"; else fail "state directory has mode 0700" "mode '$mode' for $PDIR"; fi

echo "Case: a message passes the persona text and the board context JSON to claude"
printf '## Why\nctx\n' > "$TMP/ctx-body.md"
(cd "$REPO" && bash "$SCRIPTS/board-create.sh" "Context card" "$TMP/ctx-body.md" >/dev/null 2>&1)
api POST /api/planner/conv1/messages '{"text":"first question"}'
assert_code 200 "first message accepted"
wait_idle conv1
argv="$(sed -n 1p "$ARGV_LOG" | tr '\037' '\n')"
persona_line="$(sed -n '1,/./p' "$SCRIPTS/../skills/planner/references/persona.md" | grep -m1 '^You are the planner')"
case "$argv" in *"$persona_line"*) pass "argv includes the persona text" ;; *) fail "argv includes the persona text" "$argv" ;; esac
case "$argv" in *'"depends_on"'*) pass "argv includes the board context JSON" ;; *) fail "argv includes the board context JSON" "$argv" ;; esac
case "$argv" in *"first question"*) pass "argv includes the user turn" ;; *) fail "argv includes the user turn" "$argv" ;; esac
case "$argv" in *--resume*) fail "first turn does not pass --resume" "$argv" ;; *) pass "first turn does not pass --resume" ;; esac

echo "Case: the second message resumes the session captured from the first reply"
api POST /api/planner/conv1/messages '{"text":"second question"}'
assert_code 200 "second message accepted"
wait_idle conv1
argv2="$(sed -n 2p "$ARGV_LOG" | tr '\037' '\n')"
if printf '%s\n' "$argv2" | grep -A1 -x -e '--resume' | grep -qx 'sess-1'; then pass "second turn passes --resume sess-1"; else fail "second turn passes --resume sess-1" "$argv2"; fi

echo "Case: GET returns user and assistant turns in order, running true while a reply is in progress"
api GET /api/planner/conv1
assert_body "four turns so far" '.turns | length' '4'
assert_body "turn roles alternate in order" '[.turns[].role] | join(",")' 'user,assistant,user,assistant'
assert_body "assistant turn holds the reply" '.turns[1].text' 'reply 1'
touch "$HOLD"
api POST /api/planner/conv1/messages '{"text":"third question"}'
assert_code 200 "third message accepted"
api GET /api/planner/conv1
assert_body "running is true during the reply" '.running' 'true'

echo "Case: a message posted while a reply is running returns 409"
api POST /api/planner/conv1/messages '{"text":"too soon"}'
assert_code 409 "concurrent message refused"
rm -f "$HOLD"
wait_idle conv1
assert_body "running false once the reply lands" '.running' 'false'

echo "Case: an unknown conversation id returns 404"
api GET /api/planner/nope
assert_code 404 "GET unknown id"
api POST /api/planner/nope/messages '{"text":"hi"}'
assert_code 404 "POST unknown id"

echo "Case: the first turn's board context carries the real card data"
first_argv="$(sed -n 1p "$ARGV_LOG" | tr '\037' '\n')"
case "$first_argv" in *'"title": "Context card"'*) pass "argv board context holds the created card's title" ;; *) fail "argv board context holds the created card's title" "$first_argv" ;; esac

echo "Case: each planner turn adds one planner line to the token ledger, never a card total"
LEDGER="$REPO/.fleet-board/usage.jsonl"
if [ "$(wc -l < "$LEDGER" 2>/dev/null | tr -d ' ')" = 3 ]; then pass "three turns, three ledger lines"; else fail "three turns, three ledger lines" "ledger: $(cat "$LEDGER" 2>/dev/null)"; fi
first="$(sed -n 1p "$LEDGER" 2>/dev/null)"
for f in '.kind=="planner"' '.started_at!=null and .started_at<=.ended_at' '.card==null' '.column==null' '.action=="planner"' '.role==null' '.provider=="claude"' \
         '.input==11' '.output==5' '.cache_write==3' '.cache_read==2'; do
  if printf '%s' "$first" | jq -e "$f" >/dev/null 2>&1; then pass "planner line: $f"; else fail "planner line: $f" "$first"; fi
done
USAGE_JSON="$(FLEET_BOARD_DOMAIN="$REPO" FLEET_BOARD_SUPERVISOR_SOCKET="$TMP/no-such.sock" bash "$SCRIPTS/supervisor.sh" usage --json 2>&1)"
if printf '%s' "$USAGE_JSON" | jq -e '.planner.input==33 and .planner.output==15 and .all_time.total==0' >/dev/null 2>&1; then pass "supervisor usage shows planner tokens apart from card totals"; else fail "supervisor usage shows planner tokens apart from card totals" "$USAGE_JSON"; fi

echo "Case: a stuck ledger lock never leaves the conversation still replying"
python3 - "$LEDGER.lock" "$TMP/unlock" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[1] + ".held", "w").close()
while not os.path.exists(sys.argv[2]):
    time.sleep(0.05)
PY
HOLDER=$!
for _ in $(seq 1 50); do [ -e "$LEDGER.lock.held" ] && break; sleep 0.1; done
api POST /api/planner/conv1/messages '{"text":"fourth question"}'
assert_code 200 "message accepted while the ledger lock is held"
wait_idle conv1
assert_body "conversation is not still replying" '.running' 'false'
assert_body "the reply is posted" '.turns[-1].text' 'reply 4'
touch "$TMP/unlock"
wait "$HOLDER" 2>/dev/null
for _ in $(seq 1 50); do [ "$(wc -l < "$LEDGER" | tr -d ' ')" = 4 ] && break; sleep 0.1; done
if [ "$(wc -l < "$LEDGER" | tr -d ' ')" = 4 ]; then pass "the usage line lands once the lock is released"; else fail "the usage line lands once the lock is released" "ledger: $(cat "$LEDGER")"; fi

model_of() {
  # prints the value following --model in argv line $1, or NONE when the flag is absent
  local a
  a="$(sed -n "${1}p" "$ARGV_LOG" | tr '\037' '\n')"
  if printf '%s\n' "$a" | grep -qx -e '--model'; then printf '%s\n' "$a" | grep -A1 -x -e '--model' | sed -n 2p; else echo NONE; fi
}
LINES_BEFORE="$(wc -l < "$ARGV_LOG" | tr -d ' ')"

echo "Case: when planner.model is null, the claude argv has no --model flag"
api POST /api/planner/conv1/messages '{"text":"model null"}'
wait_idle conv1
got="$(model_of $((LINES_BEFORE + 1)))"
if [ "$got" = NONE ]; then pass "planner.model null -> no --model flag"; else fail "planner.model null -> no --model flag" "got --model $got"; fi

echo "Case: when planner.model is set, the claude argv contains --model <model>"
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\nplanner:\n  model: opus\n' > "$REPO/.fleet-board.yml"
api POST /api/planner/conv1/messages '{"text":"model set"}'
wait_idle conv1
got="$(model_of $((LINES_BEFORE + 2)))"
if [ "$got" = opus ]; then pass "planner.model opus -> --model opus"; else fail "planner.model opus -> --model opus" "got '$got'"; fi

echo "Case: after planner.model changes, the next turn of an open chat uses the new model"
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\nplanner:\n  model: haiku\n' > "$REPO/.fleet-board.yml"
api POST /api/planner/conv1/messages '{"text":"model changed"}'
wait_idle conv1
got="$(model_of $((LINES_BEFORE + 3)))"
if [ "$got" = haiku ]; then pass "changed planner.model haiku -> --model haiku on the next turn"; else fail "changed planner.model haiku -> --model haiku on the next turn" "got '$got'"; fi

echo ""
echo "Results:$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

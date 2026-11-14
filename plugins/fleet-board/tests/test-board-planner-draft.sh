#!/usr/bin/env bash
#
# Plain-bash tests for POST /api/planner/<id>/draft on board-web.py: the planner
# conversation becomes plan.md in an import directory and the existing import-plan
# --preview session runs. Needs python3, curl, jq.
#
# Usage: bash plugins/fleet-board/tests/test-board-planner-draft.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
unset FLEET_BOARD_CONFIG FLEET_BOARD_LOCK_WAIT || true
FLEET_BOARD_USER=tester
export FLEET_BOARD_USER

PASS=0
FAIL=0
SERVER_PID=""
REPO=""
TMP=""
for t in python3 curl jq; do command -v "$t" >/dev/null 2>&1 || { echo "skipped: $t not on PATH"; exit 0; }; done

cleanup() {
  [ -z "$SERVER_PID" ] || { kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }
  [ -z "$TMP" ] || rm -rf "$TMP" 2>/dev/null
  [ -z "$REPO" ] || rm -rf "$REPO" 2>/dev/null
}
trap cleanup EXIT
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

TMP="$(mktemp -d)"
BODY_FILE="$TMP/body"

NOGH_DIR="$TMP/nogh"
mkdir -p "$NOGH_DIR"
printf '#!/bin/sh\necho "gh must not be called: $*" >&2\nexit 99\n' > "$NOGH_DIR/gh"
chmod +x "$NOGH_DIR/gh"
PATH="$NOGH_DIR:$PATH"

FIXTURE="$TMP/cards.json"
cat > "$FIXTURE" <<'JSON'
{"cards":[
 {"key":"a","title":"A","repo":"acme/toy","labels":["backend"],
  "why":"Expose the thing.","scope":["src/a.js"],
  "acceptance":["POST /a returns 201"],"consumes":[],"produces":["POST /a"]},
 {"key":"b","title":"B","repo":"acme/toy","labels":["frontend"],
  "why":"Show the thing.","scope":["src/b.js"],
  "acceptance":["GET /b returns 200"],"consumes":["POST /a"],"produces":[],"depends_on":["a"]}
]}
JSON

# Fake claude: an import-plan --preview prompt writes the fixture to the preview path
# (after $HOLD is gone); anything else is a planner chat turn.
FAKE_CLAUDE="$TMP/fake-claude.sh"
cat > "$FAKE_CLAUDE" <<'FAKE'
#!/bin/bash
prompt="${!#}"
case "$prompt" in
  */fleet-board:import-plan*)
    printf '%s\n' "$prompt" >> "$IMPORT_LOG"
    while [ -e "$HOLD" ]; do sleep 0.1; done
    dest="$(printf '%s' "$prompt" | sed -n 's/.*--preview \([^ ]*\).*/\1/p')"
    cp "$FIXTURE" "$dest"
    echo '{"type":"result","result":"done"}'
    ;;
  *)
    echo '{"type":"system","session_id":"sess-1"}'
    echo '{"type":"assistant","session_id":"sess-1","message":{"content":[{"type":"text","text":"agreed plan: A then B"}]}}'
    echo '{"type":"result","session_id":"sess-1","result":"ok"}'
    ;;
esac
FAKE
chmod +x "$FAKE_CLAUDE"
HOLD="$TMP/hold"
IMPORT_LOG="$TMP/import.log"
: > "$IMPORT_LOG"
export FLEET_BOARD_CLAUDE="$FAKE_CLAUDE" FIXTURE HOLD IMPORT_LOG
export FLEET_BOARD_TEST_PLANNER_ID=conv1
export FLEET_BOARD_TEST_IMPORT_ID=imp1

REPO="$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXX")"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name T
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
git -C "$REPO" add .fleet-board.yml
git -C "$REPO" commit -q -m initial
mkdir -p "$REPO/.fleet-board/cards" "$REPO/.fleet-board/active"
echo 1 > "$REPO/.fleet-board/next"

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

IDIR="$TMP/logs/web/acme-toy/imports/imp1"

echo "Case: drafting a conversation with no user turns returns 409"
api POST /api/planner '{}'
assert_code 200 "conversation started"
api POST /api/planner/conv1/draft '{}'
assert_code 409 "draft of an empty conversation refused"
if [ ! -e "$IDIR" ]; then pass "empty draft creates no import directory"; else fail "empty draft creates no import directory" "found $IDIR"; fi

echo "Case: drafting an unknown conversation returns 404"
api POST /api/planner/nope/draft '{}'
assert_code 404 "draft of unknown conversation"

echo "Case: POST draft returns an import_id and writes plan.md from the conversation"
api POST /api/planner/conv1/messages '{"text":"please build the A and B endpoints"}'
assert_code 200 "message accepted"
wait_idle conv1
touch "$HOLD"
api POST /api/planner/conv1/draft '{}'
assert_code 200 "draft accepted"
assert_body "response carries the import id" '.import_id' 'imp1'
if grep -q 'please build the A and B endpoints' "$IDIR/plan.md" 2>/dev/null; then pass "plan.md holds the user turn"; else fail "plan.md holds the user turn" "$(cat "$IDIR/plan.md" 2>/dev/null)"; fi
if grep -q 'agreed plan: A then B' "$IDIR/plan.md" 2>/dev/null; then pass "plan.md holds the assistant turn"; else fail "plan.md holds the assistant turn" "$(cat "$IDIR/plan.md" 2>/dev/null)"; fi

echo "Case: GET import reports running, then ready with the dry-run table"
for _ in $(seq 1 50); do [ -s "$IMPORT_LOG" ] && break; sleep 0.1; done
api GET /api/import/imp1
assert_body "import is running while the session holds" '.state' 'running'
rm -f "$HOLD"
for _ in $(seq 1 80); do
  api GET /api/import/imp1
  [ "$(jq -r .state "$BODY_FILE")" = ready ] && break
  sleep 0.1
done
assert_body "import becomes ready" '.state' 'ready'
assert_body "ready import carries the dry-run table" '.table' '*| A |*'
case "$(cat "$IMPORT_LOG")" in *"import-plan "*"plan.md --preview "*"cards.json"*) pass "session runs import-plan --preview" ;; *) fail "session runs import-plan --preview" "$(cat "$IMPORT_LOG")" ;; esac

echo "Case: creating from a draft holding a card with no Scope paths is refused and writes no card"
cp "$IDIR/cards.json" "$TMP/cards.good.json"
cat > "$IDIR/cards.json" <<'JSON'
{"cards":[
 {"key":"a","title":"Has paths","repo":"acme/toy","labels":[],"why":"w","scope":["src/a.js"],
  "acceptance":["A works"],"consumes":[],"produces":[]},
 {"key":"n","title":"Scopeless draft card","repo":"acme/toy","labels":[],"why":"w","scope":["Everything in the card"],
  "acceptance":["N works"],"consumes":[],"produces":[]}
]}
JSON
api POST /api/import/imp1/create '{}'
assert_code 409 "create of a draft with a scopeless card refused"
assert_body "the refusal names the card" '.error' '*Scopeless draft card*'
assert_body "the refusal says the Scope lists no paths" '.error' '*Scope*'
api GET /api/board
assert_body "no card was written to the store" '.cards | length' '0'
cp "$TMP/cards.good.json" "$IDIR/cards.json"

echo "Case: POST create creates the drafted cards as for a pasted plan"
api POST /api/import/imp1/create '{}'
assert_code 200 "create accepted"
assert_body "create reports both cards" '.created | length' '2'
api GET /api/board
assert_body "both cards are on the board" '.cards | length' '2'
assert_body "drafted cards keep the default pasted-plan status" '[.cards[].state] | unique | join(",")' 'backlog'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

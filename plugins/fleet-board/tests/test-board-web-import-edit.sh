#!/usr/bin/env bash
#
# Plain-bash tests for editing a previewed import card:
# PATCH /api/import/<id>/cards/<key> on board-web.py. Needs python3, curl, jq.
#
# Usage: bash plugins/fleet-board/tests/test-board-web-import-edit.sh

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

NOGH_DIR="$TMP/nogh"
mkdir -p "$NOGH_DIR"
printf '#!/bin/sh\necho "gh must not be called: $*" >&2\nexit 99\n' > "$NOGH_DIR/gh"
chmod +x "$NOGH_DIR/gh"
PATH="$NOGH_DIR:$PATH"

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
prompt="${!#}"
dest="$(printf '%s' "$prompt" | sed -n 's/.*--preview \([^ ]*\).*/\1/p')"
cp "$IMPORT_FIXTURE" "$dest"
echo '{"type":"result","result":"done"}'
EOF
chmod +x "$FAKE_IMPORT_CLAUDE"
export FLEET_BOARD_CLAUDE="$FAKE_IMPORT_CLAUDE" FAKE_CLAUDE_DIR IMPORT_FIXTURE
export FLEET_BOARD_TEST_IMPORT_ID=fixed

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

CARDS="$TMP/logs/web/acme-toy/imports/fixed/cards.json"

api POST /api/import '{"plan":"x","status":"backlog"}'
for _ in $(seq 1 50); do api GET /api/import/fixed; [ "$(jq -r .state "$BODY_FILE")" = ready ] && break; sleep 0.1; done

echo "Case: PATCH with a new title rewrites cards.json and the response table shows it"
api PATCH /api/import/fixed/cards/a '{"title":"Renamed A"}'
assert_code 200 "title edit accepted"
assert_body "response table shows the new title" '.table' '*| Renamed A |*'
if [ "$(jq -r '.cards[0].title' "$CARDS")" = "Renamed A" ]; then pass "cards.json holds the new title"; else fail "cards.json holds the new title" "$(cat "$CARDS")"; fi

echo "Case: PATCH that empties acceptance returns 422 with the lint message and leaves cards.json unchanged"
BEFORE="$(cat "$CARDS")"
api PATCH /api/import/fixed/cards/a '{"acceptance":[]}'
assert_code 422 "empty acceptance refused"
assert_body "422 carries a lint message" '.error' '*cceptance*'
if [ "$(cat "$CARDS")" = "$BEFORE" ]; then pass "cards.json unchanged after the lint failure"; else fail "cards.json unchanged after the lint failure" "$(cat "$CARDS")"; fi

echo "Case: PATCH with a depends_on that creates a cycle returns 422 naming the cycle"
api PATCH /api/import/fixed/cards/a '{"depends_on":["b"]}'
assert_code 422 "cycle refused"
assert_body "422 names the cycle" '.error' '*cycle*'
if [ "$(cat "$CARDS")" = "$BEFORE" ]; then pass "cards.json unchanged after the cycle"; else fail "cards.json unchanged after the cycle" "$(cat "$CARDS")"; fi

echo "Case: PATCH on an unknown key returns 404"
api PATCH /api/import/fixed/cards/nope '{"title":"x"}'
assert_code 404 "unknown key"
assert_body "404 says the key is unknown" ".error" "*unknown card key*"

echo "Case: PATCH after /create succeeded returns 409"
api POST /api/import/fixed/create '{}'
assert_code 200 "create succeeds"
api PATCH /api/import/fixed/cards/a '{"title":"Too late"}'
assert_code 409 "edit after create refused"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

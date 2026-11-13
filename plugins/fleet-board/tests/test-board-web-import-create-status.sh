#!/usr/bin/env bash
#
# Plain-bash tests for the target column of the import create endpoint:
# POST /api/import/<id>/create on board-web.py. Needs python3, curl, jq.
#
# Usage: bash plugins/fleet-board/tests/test-board-web-import-create-status.sh

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
  [ -z "${TMP:-}" ] || rm -rf "${TMP:?}" 2>/dev/null
  [ -z "${REPO:-}" ] || rm -rf "${REPO:?}" 2>/dev/null
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
export FLEET_BOARD_CLAUDE="$FAKE_IMPORT_CLAUDE" IMPORT_FIXTURE
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

IMPORTS="$TMP/logs/web/acme-toy/imports"
CARDS_DIR="$REPO/.fleet-board/cards"

api POST /api/import '{"plan":"x","status":"backlog"}'
for _ in $(seq 1 50); do api GET /api/import/fixed; [ "$(jq -r .state "$BODY_FILE")" = ready ] && break; sleep 0.1; done

# new_import <id> <meta status or empty>: a fresh previewed import, with the board emptied
new_import() {
  rm -rf "${CARDS_DIR:?}"; mkdir -p "$CARDS_DIR"; echo 1 > "$REPO/.fleet-board/next"
  cp -R "$IMPORTS/fixed" "${IMPORTS:?}/$1"
  if [ -n "$2" ]; then printf '{"status":"%s"}' "$2" > "$IMPORTS/$1/meta.json"; else printf '{}' > "$IMPORTS/$1/meta.json"; fi
}
count_state() { jq -r .state "$CARDS_DIR"/*.json 2>/dev/null | grep -c "^$1\$" || true; }
card_count() { ls "$CARDS_DIR" 2>/dev/null | grep -c '\.json$' || true; }

echo "Case: POST create with status ready creates the cards in Ready"
new_import s1 backlog
api POST /api/import/s1/create '{"status":"ready"}'
assert_code 200 "create with ready accepted"
if [ "$(count_state ready)" = 2 ]; then pass "both cards are in Ready"; else fail "both cards are in Ready" "ready: $(count_state ready), backlog: $(count_state backlog)"; fi

echo "Case: POST create with no status creates the cards in Backlog"
new_import s2 ""
api POST /api/import/s2/create '{}'
assert_code 200 "create with no status accepted"
if [ "$(count_state backlog)" = 2 ]; then pass "both cards are in Backlog"; else fail "both cards are in Backlog" "backlog: $(count_state backlog), ready: $(count_state ready)"; fi

echo "Case: POST create with status done returns 400 and creates no cards"
new_import s3 ""
api POST /api/import/s3/create '{"status":"done"}'
assert_code 400 "done refused"
assert_body "400 names the allowed statuses" '.error' 'status must be backlog or ready'
if [ "$(card_count)" = 0 ]; then pass "no cards were created"; else fail "no cards were created" "$(ls "$CARDS_DIR")"; fi

echo "Case: a status in the create body overrides the status in meta.json"
new_import s4 backlog
api POST /api/import/s4/create '{"status":"ready"}'
assert_code 200 "override accepted"
if [ "$(count_state ready)" = 2 ]; then pass "ready body beats backlog meta"; else fail "ready body beats backlog meta" "ready: $(count_state ready)"; fi
new_import s5 ready
api POST /api/import/s5/create '{"status":"backlog"}'
assert_code 200 "override accepted"
if [ "$(count_state backlog)" = 2 ]; then pass "backlog body beats ready meta"; else fail "backlog body beats ready meta" "backlog: $(count_state backlog)"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

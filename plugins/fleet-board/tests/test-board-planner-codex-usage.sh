#!/usr/bin/env bash
#
# Plain-bash tests for the token ledger line a Codex Planner turn appends (planner.provider: codex), using a
# fake codex binary named by FLEET_BOARD_CODEX. Needs python3, curl, jq.
#
# Usage: bash plugins/fleet-board/tests/test-board-planner-codex-usage.sh

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

TMP="$(mktemp -d)"
REPO="$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXX")"
cleanup() {
  [ -z "$SERVER_PID" ] || { kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }
  rm -rf "$TMP" "$REPO" 2>/dev/null
}
trap cleanup EXIT
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

BODY_FILE="$TMP/body"
MODE_FILE="$TMP/mode"

FAKE_CODEX="$TMP/fake-codex.sh"
cat > "$FAKE_CODEX" <<'EOF'
#!/bin/bash
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
if [ "$(cat "$MODE_FILE" 2>/dev/null)" = nousage ]; then
  printf '{"type":"thread.started","thread_id":"thr-1"}\n{"type":"turn.completed"}\n'
else
  printf '{"type":"thread.started","thread_id":"thr-1"}\n'
  printf '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":3}}\n'
fi
[ -n "$out" ] && printf 'codex reply' > "$out"
exit 0
EOF
chmod +x "$FAKE_CODEX"
export FLEET_BOARD_CODEX="$FAKE_CODEX" MODE_FILE

api() {
  local args=(-s --path-as-is -o "$BODY_FILE" -w '%{http_code}' -X "$1" -H 'X-Fleet-Board: 1')
  [ $# -ge 3 ] && args+=(-H 'Content-Type: application/json' --data-binary "$3")
  : > "$BODY_FILE"
  LAST_CODE="$(curl "${args[@]}" "http://127.0.0.1:$PORT$2")"
}
wait_idle() {
  for _ in $(seq 1 80); do
    api GET "/api/planner/$1"
    [ "$(jq -r .running "$BODY_FILE" 2>/dev/null)" = false ] && return 0
    sleep 0.1
  done
}

git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name T
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\nplanner:\n  provider: codex\n  model: gpt-test\n' > "$REPO/.fleet-board.yml"
git -C "$REPO" add .fleet-board.yml
git -C "$REPO" commit -q -m initial
mkdir -p "$REPO/.fleet-board/cards" "$REPO/.fleet-board/active"
echo 1 > "$REPO/.fleet-board/next"
export FLEET_BOARD_TEST_PLANNER_ID=conv1
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
api POST /api/planner '{}'

LEDGER="$REPO/.fleet-board/usage.jsonl"

echo "Case: a codex Planner turn appends one planner line to the usage ledger"
echo ok > "$MODE_FILE"
api POST /api/planner/conv1/messages '{"text":"first question"}'
wait_idle conv1
if [ "$(wc -l < "$LEDGER" 2>/dev/null | tr -d ' ')" = 1 ]; then pass "a codex Planner turn appends exactly one ledger line"; else fail "a codex Planner turn appends exactly one ledger line" "ledger: $(cat "$LEDGER" 2>/dev/null)"; fi
line="$(sed -n 1p "$LEDGER" 2>/dev/null)"
for f in '.kind=="planner"' '.card==null' '.action=="planner"' '.provider=="codex"' '.model=="gpt-test"' \
         '.input==10' '.output==3' '.cache_read==4' '.cache_write==null' '.started_at!=null and .started_at<=.ended_at'; do
  if printf '%s' "$line" | jq -e "$f" >/dev/null 2>&1; then pass "codex planner line: $f"; else fail "codex planner line: $f" "$line"; fi
done

echo "Case: a codex turn whose result carries no usage records unknown counts, not zero"
echo nousage > "$MODE_FILE"
api POST /api/planner/conv1/messages '{"text":"second question"}'
wait_idle conv1
line2="$(sed -n 2p "$LEDGER" 2>/dev/null)"
if printf '%s' "$line2" | jq -e '.provider=="codex" and .input==null and .output==null' >/dev/null 2>&1; then pass "codex planner line without usage has null counts"; else fail "codex planner line without usage has null counts" "$line2"; fi

echo "Case: supervisor usage shows codex planner tokens apart from card totals"
USAGE_JSON="$(FLEET_BOARD_DOMAIN="$REPO" FLEET_BOARD_SUPERVISOR_SOCKET="$TMP/no-such.sock" bash "$SCRIPTS/supervisor.sh" usage --json 2>&1)"
if printf '%s' "$USAGE_JSON" | jq -e '.planner.input==10 and .planner.output==3 and .all_time.total==0' >/dev/null 2>&1; then pass "planner tokens are separate from card totals"; else fail "planner tokens are separate from card totals" "$USAGE_JSON"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

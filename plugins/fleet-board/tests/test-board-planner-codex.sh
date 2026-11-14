#!/usr/bin/env bash
#
# Plain-bash tests for Codex Planner turns on board-web.py (planner.provider: codex), using a fake codex
# binary named by FLEET_BOARD_CODEX. Needs python3, curl, jq.
#
# Usage: bash plugins/fleet-board/tests/test-board-planner-codex.sh

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
  rm -rf "$TMP" "${REPOS[@]:-}" 2>/dev/null
}
REPOS=()
trap cleanup EXIT
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

TMP="$(mktemp -d)"
BODY_FILE="$TMP/body"
ARGV_LOG="$TMP/argv.log"
MODE_FILE="$TMP/mode"
: > "$ARGV_LOG"

NOGH_DIR="$TMP/nogh"
mkdir -p "$NOGH_DIR"
printf '#!/bin/sh\necho "gh must not be called: $*" >&2\nexit 99\n' > "$NOGH_DIR/gh"
chmod +x "$NOGH_DIR/gh"
PATH="$NOGH_DIR:$PATH"

# Fake codex: one argv line per call (arguments joined by the unit separator). In mode "ok" it emits a
# thread.started event and writes "codex reply <n>" to the -o file. In mode "fail" it emits an error and a
# turn.failed event, writes other text to stderr last, and exits 1.
FAKE_CODEX="$TMP/fake-codex.sh"
cat > "$FAKE_CODEX" <<'EOF'
#!/bin/bash
n=$(( $(wc -l < "$ARGV_LOG") + 1 ))
printf '%s\037' "$@" | tr '\n' '\036' >> "$ARGV_LOG"; echo >> "$ARGV_LOG"
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
if [ "$(cat "$MODE_FILE" 2>/dev/null)" = fail ]; then
  printf '{"type":"thread.started","thread_id":"thr-%d"}\n' "$n"
  printf '{"type":"error","message":"model not supported"}\n'
  printf '{"type":"turn.failed","error":{"message":"model not supported on this account"}}\n'
  echo "unrelated MCP auth error: token expired" >&2
  exit 1
fi
printf '{"type":"thread.started","thread_id":"thr-%d"}\n' "$n"
printf '{"type":"turn.started"}\n'
printf '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}\n'
[ -n "$out" ] && printf 'codex reply %d' "$n" > "$out"
echo "unrelated MCP auth error" >&2
exit 0
EOF
chmod +x "$FAKE_CODEX"
export FLEET_BOARD_CODEX="$FAKE_CODEX" ARGV_LOG MODE_FILE

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

start_server() { # $1 = planner yaml, $2 = conversation id
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""; fi
  REPO="$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXX")"
  REPOS+=("$REPO")
  git init -q "$REPO"
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name T
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\nplanner:\n%s\n' "$1" > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m initial
  mkdir -p "$REPO/.fleet-board/cards" "$REPO/.fleet-board/active"
  echo 1 > "$REPO/.fleet-board/next"
  export FLEET_BOARD_TEST_PLANNER_ID="$2"
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
}
argv_of() { sed -n "${1}p" "$ARGV_LOG" | tr '\037' '\n'; }
has_pair() { printf '%s\n' "$1" | grep -A1 -x -e "$2" | grep -qx -e "$3"; }
has_arg() { printf '%s\n' "$1" | grep -qx -e "$2"; }

PDIR="$TMP/logs/web/acme-toy/planner"

echo "Case: first turn runs codex exec --json -s read-only -m <model> -c developer_instructions=<persona> -o <file> <prompt>"
echo ok > "$MODE_FILE"
start_server '  provider: codex
  model: gpt-test' conv1
api POST /api/planner/conv1/messages '{"text":"first question"}'
wait_idle conv1
a1="$(argv_of 1)"
if [ "$(printf '%s\n' "$a1" | sed -n '1,4p' | tr '\n' ' ')" = "exec --json -s read-only " ]; then pass "first turn argv starts exec --json -s read-only"; else fail "first turn argv starts exec --json -s read-only" "$a1"; fi
if has_pair "$a1" -m gpt-test; then pass "first turn passes -m <model>"; else fail "first turn passes -m <model>" "$a1"; fi
persona_line="$(grep -m1 '^You are the planner' "$SCRIPTS/../skills/planner/references/persona.md")"
case "$a1" in *"developer_instructions="*"$persona_line"*) pass "first turn passes -c developer_instructions=<persona>" ;; *) fail "first turn passes -c developer_instructions=<persona>" "$a1" ;; esac
if printf '%s\n' "$a1" | grep -A1 -x -e '-o' | tail -1 | grep -q 'reply-'; then pass "first turn passes -o <file>"; else fail "first turn passes -o <file>" "$a1"; fi
case "$(printf '%s\n' "$a1" | tail -2)" in *"first question"*) pass "prompt is the last argument" ;; *) fail "prompt is the last argument" "$a1" ;; esac

echo "Case: the thread_id from thread.started is saved in meta.json"
tid="$(jq -r .thread_id "$PDIR/conv1/meta.json" 2>/dev/null)"
if [ "$tid" = "thr-1" ]; then pass "meta.json holds thread_id thr-1"; else fail "meta.json holds thread_id thr-1" "got '$tid'"; fi

echo "Case: the reply recorded in the transcript is the contents of the -o file"
api GET /api/planner/conv1
reply="$(jq -r '.turns[1].text' "$BODY_FILE")"
if [ "$reply" = "codex reply 1" ]; then pass "transcript reply is the -o file contents"; else fail "transcript reply is the -o file contents" "got '$reply'"; fi

echo "Case: later turns run codex exec resume --json -c sandbox_mode=\"read-only\" -m <model> -o <file> <thread_id> <prompt>"
api POST /api/planner/conv1/messages '{"text":"second question"}'
wait_idle conv1
a2="$(argv_of 2)"
if [ "$(printf '%s\n' "$a2" | sed -n '1,3p' | tr '\n' ' ')" = "exec resume --json " ]; then pass "later turn starts exec resume --json"; else fail "later turn starts exec resume --json" "$a2"; fi
if has_pair "$a2" -c 'sandbox_mode="read-only"'; then pass "later turn passes -c sandbox_mode=\"read-only\""; else fail "later turn passes -c sandbox_mode=\"read-only\"" "$a2"; fi
if has_pair "$a2" -m gpt-test; then pass "later turn passes -m <model>"; else fail "later turn passes -m <model>" "$a2"; fi
if printf '%s\n' "$a2" | grep -A1 -x -e '-o' | tail -1 | grep -q 'reply-'; then pass "later turn passes -o <file>"; else fail "later turn passes -o <file>" "$a2"; fi
if [ "$(printf '%s\n' "$a2" | tail -3 | head -1)" = "thr-1" ]; then pass "later turn passes the thread_id before the prompt"; else fail "later turn passes the thread_id before the prompt" "$a2"; fi
if has_arg "$a2" '-s'; then fail "resume has no -s flag" "$a2"; else pass "resume has no -s flag"; fi

echo "Case: on a failed turn the reply is [error] plus the turn.failed message, even when stderr ends with other text"
echo fail > "$MODE_FILE"
api POST /api/planner/conv1/messages '{"text":"third question"}'
wait_idle conv1
api GET /api/planner/conv1
reply="$(jq -r '.turns[5].text' "$BODY_FILE")"
if [ "$reply" = "[error] model not supported on this account" ]; then pass "failed turn reply is [error] + turn.failed message"; else fail "failed turn reply is [error] + turn.failed message" "got '$reply'"; fi

echo "Case: when planner.model is null no -m flag is passed"
echo ok > "$MODE_FILE"
: > "$ARGV_LOG"
start_server '  provider: codex' conv2
api POST /api/planner/conv2/messages '{"text":"hello"}'
wait_idle conv2
a3="$(argv_of 1)"
if [ -z "$a3" ]; then fail "codex was run" "no argv logged"; elif has_arg "$a3" '-m'; then fail "no -m flag when planner.model is null" "$a3"; else pass "no -m flag when planner.model is null"; fi
if has_arg "$a3" 'exec'; then pass "codex exec was run for the null-model chat"; else fail "codex exec was run for the null-model chat" "$a3"; fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]

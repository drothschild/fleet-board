#!/usr/bin/env bash
set -uo pipefail
[ "${1:-}" = run-limits ] || [ "${1:-}" = run-cancel-real ] || { echo 'usage: test-standalone-run.sh run-limits|run-cancel-real' >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/repo" "$TMP/log"
git -C "$TMP/repo" init -q
cat > "$TMP/repo/.fleet-board.yml" <<'YAML'
board:
  repo: acme/toy
limits:
  max_hours: 1
  max_cost_usd: 1
  tick_interval: 0
  min_tick_gap: 0
  max_consecutive_failures: 2
YAML
cat > "$TMP/tick" <<'TICK'
#!/usr/bin/env bash
n=0; [ ! -f "$STATE/count" ] || n="$(cat "$STATE/count")"
n=$((n+1)); echo "$n" > "$STATE/count"
case "$CASE" in
  idle) echo '{"outcome":"idle","dispatchable":false,"cost_usd":0}' ;;
  cost) echo '{"outcome":"progress","dispatchable":true,"cost_usd":2}' ;;
  unknown) echo '{"outcome":"progress","dispatchable":true}' ;;
  failure) echo '{"cost_usd":0}'; exit 1 ;;
  failure_unknown) exit 1 ;;
  failure_cost) echo '{"cost_usd":2}'; exit 1 ;;
  time) echo 4000 > "$FLEET_BOARD_NOW_FILE"; echo '{"outcome":"progress","dispatchable":true,"cost_usd":0}' ;;
  cancel) echo $$ > "$STATE/pid"; trap 'exit 0' TERM; while :; do sleep 1; done ;;
esac
TICK
chmod +x "$TMP/tick"
export STATE="$TMP" FLEET_BOARD_STANDALONE_TICK="$TMP/tick" FLEET_BOARD_LOG_DIR="$TMP/log" FLEET_BOARD_NOW_FILE="$TMP/now"
if [ "$1" = run-cancel-real ]; then
  cat > "$TMP/planner" <<'PLANNER'
#!/usr/bin/env bash
echo $$ > "$STATE/planner-pid"
trap '' TERM INT
while :; do sleep 1; done
PLANNER
  unset FLEET_BOARD_STANDALONE_TICK
  export FLEET_BOARD_TICK_PLAN="$TMP/planner"
  echo 0 > "$TMP/now"
  (cd "$TMP/repo"; exec bash "$ROOT/bin/fleet-board" run) > "$TMP/out" 2> "$TMP/err" & runner=$!
  for i in 1 2 3 4 5; do [ -s "$TMP/planner-pid" ] && break; sleep 1; done
  [ -s "$TMP/planner-pid" ] || { kill "$runner"; echo 'FAIL: planner did not start' >&2; exit 1; }
  kill -TERM "$runner"; wait "$runner"; rc=$?
  [ "$rc" = 143 ] || { echo "FAIL: interruption status $rc" >&2; exit 1; }
  if kill -0 "$(cat "$TMP/planner-pid")" 2>/dev/null; then echo 'FAIL: planner survived interruption' >&2; exit 1; fi
  echo 'PASS: run-cancel-real'; exit 0
fi
run() { (cd "$TMP/repo" && bash "$ROOT/bin/fleet-board" run) > "$TMP/out" 2> "$TMP/err"; }
check() { grep -q "$1" "$TMP/out" || { cat "$TMP/out" "$TMP/err" >&2; echo "FAIL: $1" >&2; exit 1; }; }
echo 0 > "$TMP/now"
CASE=idle; export CASE; run || exit 1; check nothing-dispatchable
rm -f "$TMP/count"; CASE=cost; run || exit 1; check max-cost; [ "$(cat "$TMP/count")" = 1 ] || exit 1
rm -f "$TMP/count"; CASE=unknown; if run; then echo 'FAIL: missing cost accepted' >&2; exit 1; fi; check cost-unknown
rm -f "$TMP/count"; CASE=failure; if run; then echo 'FAIL: failed ticks accepted' >&2; exit 1; fi; check consecutive-failures; [ "$(cat "$TMP/count")" = 2 ] || exit 1
rm -f "$TMP/count"; CASE=failure_cost; run || exit 1; check max-cost; [ "$(cat "$TMP/count")" = 1 ] || exit 1
rm -f "$TMP/count"; CASE=failure_unknown; if run; then echo 'FAIL: failed tick with unknown cost accepted' >&2; exit 1; fi; check cost-unknown; [ "$(cat "$TMP/count")" = 1 ] || exit 1
rm -f "$TMP/count"; CASE=time; run || exit 1; check max-hours; [ "$(cat "$TMP/count")" = 1 ] || exit 1
echo 0 > "$TMP/now"; touch "$TMP/repo/.fleet-board.stop"; rm -f "$TMP/count"; CASE=idle; run || exit 1; check stop-file; [ ! -e "$TMP/count" ] || exit 1
rm "$TMP/repo/.fleet-board.stop"
CASE=cancel; (cd "$TMP/repo"; exec bash "$ROOT/bin/fleet-board" run) > "$TMP/out" 2> "$TMP/err" & runner=$!
for i in 1 2 3 4 5; do [ -s "$TMP/pid" ] && break; sleep 1; done
[ -s "$TMP/pid" ] || { kill "$runner"; echo 'FAIL: tick did not start' >&2; exit 1; }
kill -TERM "$runner"; wait "$runner"; rc=$?
[ "$rc" = 143 ] || { echo "FAIL: interruption status $rc" >&2; exit 1; }
if kill -0 "$(cat "$TMP/pid")" 2>/dev/null; then echo 'FAIL: tick survived interruption' >&2; exit 1; fi
echo 'PASS: run-limits'

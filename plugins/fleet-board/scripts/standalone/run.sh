#!/usr/bin/env bash
# Standalone run loop. A tick owns board transitions; do not call legacy merge.
set -uo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$PWD"; CALLER="$PWD"
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --repo ] || { echo 'usage: fleet-board run [--repo DIR]' >&2; exit 2; }
  DIR="$2"
fi
cd "$DIR" 2>/dev/null || { echo 'cannot enter repository' >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo 'not a repository' >&2; exit 1; }
cd "$ROOT" || exit 1
bash "$HERE/config.sh" --dir "$ROOT" --check </dev/null || exit $?
cfg() { bash "$HERE/config.sh" --dir "$ROOT" "$1" </dev/null; }
MAX_HOURS="$(cfg limits.max_hours)" || exit 1
MAX_COST="$(cfg limits.max_cost_usd)" || exit 1
INTERVAL="$(cfg limits.tick_interval)" || exit 1
MIN_GAP="$(cfg limits.min_tick_gap)" || exit 1
MAX_FAILS="$(cfg limits.max_consecutive_failures)" || exit 1
TICK_CMD="${FLEET_BOARD_STANDALONE_TICK:-$HERE/standalone/controller.sh}"
CLEANUP="${FLEET_BOARD_CLEANUP:-$HERE/cleanup-done.sh}"
SETTLE="${FLEET_BOARD_STANDALONE_SETTLE:-$HERE/standalone/settle.sh}"
SLEEP_CMD="${FLEET_BOARD_SLEEP:-sleep}"
LOG_DIR="${FLEET_BOARD_LOG_DIR:-$HOME/.fleet-board/runs}"
case "$LOG_DIR" in /*) ;; *) LOG_DIR="$CALLER/$LOG_DIR" ;; esac
(umask 077; mkdir -p "$LOG_DIR") || exit 1
LOG="$LOG_DIR/standalone-$(date +%Y%m%d-%H%M%S)-$$.log"
(umask 077; set -C; : > "$LOG") || exit 1
WORK="$(mktemp -d)" || exit 1
CHILD=""
cleanup() { rm -rf "$WORK"; }
cancel() {
  local code="$1" target="$CHILD" watchdog=""
  trap '' INT TERM
  if [ -n "$target" ]; then
    kill -TERM -- "-$target" 2>/dev/null || true
    # The controller has a five-second grace period for its own child group.
    # Give it time to kill and reap that group before forcing the controller.
    (sleep 12; kill -KILL -- "-$target" 2>/dev/null || true) </dev/null >/dev/null 2>&1 & watchdog=$!
    wait "$target" 2>/dev/null || true
    kill -KILL -- "-$target" 2>/dev/null || true
    kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
  fi
  printf 'fleet-board-run: stopped: interrupted\n' | tee -a "$LOG"
  exit "$code"
}
trap cleanup EXIT
trap 'cancel 130' INT
trap 'cancel 143' TERM
run_group() {
  local rc
  set -m; "$@" & CHILD=$!; set +m
  wait "$CHILD"; rc=$?; CHILD=""; return "$rc"
}
now() { if [ -n "${FLEET_BOARD_NOW_FILE:-}" ]; then cat "$FLEET_BOARD_NOW_FILE"; else date +%s; fi; }
greater() { LC_ALL=C awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
add() { LC_ALL=C awk -v a="$1" -v b="$2" 'BEGIN { printf "%.10f", a+b }'; }
START="$(now)"; LAST=""; TICKS=0; FAILS=0; COST=0
stop() { printf 'fleet-board-run: stopped: %s after %s ticks, cost_estimate_usd %s (estimate)\n' "$1" "$TICKS" "$COST" | tee -a "$LOG"; exit "$2"; }
echo "fleet-board-run: log: $LOG"
while :; do
  [ -e "$ROOT/.fleet-board.stop" ] && stop stop-file 0
  CURRENT="$(now)"
  greater "$((CURRENT - START))" "$(LC_ALL=C awk -v h="$MAX_HOURS" 'BEGIN {print h*3600}')" && stop max-hours 0
  greater "$COST" "$MAX_COST" && stop max-cost 0
  if [ -n "$LAST" ]; then
    GAP="$(LC_ALL=C awk -v g="$MIN_GAP" -v elapsed="$((CURRENT - LAST))" 'BEGIN {if (g > elapsed) print g-elapsed; else print 0}')"
    if greater "$GAP" 0; then run_group "$SLEEP_CMD" "$GAP" || exit 1; continue; fi
  fi
  LAST="$(now)"; TICKS=$((TICKS + 1))
  run_group bash "$TICK_CMD" tick </dev/null > "$WORK/tick" 2> "$WORK/err"; RC=$?
  cat "$WORK/tick" "$WORK/err" >> "$LOG" || exit 1
  # Account for every attempt, including failures, before another tick can run.
  if ! jq -e -s 'length == 1 and (.[0].cost_usd | type == "number" and . >= 0)' "$WORK/tick" >/dev/null 2>&1; then stop cost-unknown 1; fi
  COST="$(add "$COST" "$(jq -r .cost_usd "$WORK/tick")")"
  if [ "$RC" -ne 0 ] || ! jq -e -s 'length == 1 and (.[0] | type == "object" and (.outcome | IN("idle", "progress")) and (.dispatchable | type == "boolean") and (if .outcome == "idle" then .dispatchable == false else true end))' "$WORK/tick" >/dev/null 2>&1; then
    greater "$COST" "$MAX_COST" && stop max-cost 0
    FAILS=$((FAILS + 1))
    [ "$FAILS" -ge "$MAX_FAILS" ] && stop consecutive-failures 1
    if greater "$INTERVAL" 0; then run_group "$SLEEP_CMD" "$INTERVAL" || exit 1; fi
    continue
  fi
  FAILS=0
  # Settle only guarded, non-worker actions before cleaning finished worktrees.
  run_group bash "$SETTLE" </dev/null >> "$LOG" 2>&1 || printf 'warning: standalone settle failed\n' >> "$LOG"
  run_group bash "$CLEANUP" </dev/null >> "$LOG" 2>&1 || printf 'warning: cleanup failed\n' >> "$LOG"
  [ "$(jq -r .outcome "$WORK/tick")" = idle ] && stop nothing-dispatchable 0
  greater "$COST" "$MAX_COST" && stop max-cost 0
  if greater "$INTERVAL" 0; then run_group "$SLEEP_CMD" "$INTERVAL" || exit 1; fi
done

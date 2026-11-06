#!/usr/bin/env bash
#
# Stand-in for fleet-board-run.sh in the web board tests. Prints the wrapper's
# log line, writes two tick lines one second apart, then waits for the repo's
# .fleet-board.stop and prints the wrapper's stopped line.
#
# Env: FAKE_RUN_DIR (required) holds args.log and fake.log.

set -u

ROOT=""
printf '%s\n' "$*" >> "$FAKE_RUN_DIR/args.log"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) ROOT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

LOG="$FAKE_RUN_DIR/fake.log"
: > "$LOG"
echo "fleet-board-run: log: $LOG"
echo "=== tick 1 $(date -u +%Y-%m-%dT%H:%M:%SZ) rc=0 ===" >> "$LOG"
sleep 1
echo "=== tick 2 $(date -u +%Y-%m-%dT%H:%M:%SZ) rc=0 ===" >> "$LOG"

while [ ! -e "$ROOT/.fleet-board.stop" ]; do
  sleep 0.2
done
echo "fleet-board-run: stopped: stop-file after 2 ticks, 0.01 h, cost_estimate_usd 0.42 (estimate)"
exit 0

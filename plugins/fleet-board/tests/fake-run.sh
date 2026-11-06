#!/usr/bin/env bash
#
# Stand-in for fleet-board-run.sh in the web board tests. Prints the wrapper's
# log line, writes two tick lines one second apart, then waits for the repo's
# .fleet-board.stop and prints the wrapper's stopped line.
#
# Env: FAKE_RUN_DIR (required) holds args.log, fake.log and the release file.
# It also exits when the repo root disappears, so it never outlives a test.

set -u

ROOT=""
printf '%s\n' "$*" >> "$FAKE_RUN_DIR/args.log"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) ROOT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

rm -f "$FAKE_RUN_DIR/release"
LOG="$FAKE_RUN_DIR/fake.log"
: > "$LOG"
echo "fleet-board-run: log: $LOG"
echo "=== tick 1 $(date -u +%Y-%m-%dT%H:%M:%SZ) rc=0 ===" >> "$LOG"
sleep 1
echo "=== tick 2 $(date -u +%Y-%m-%dT%H:%M:%SZ) rc=0 ===" >> "$LOG"

while [ -d "$ROOT" ] && [ ! -e "$ROOT/.fleet-board.stop" ]; do
  sleep 0.2
done
# Hold the stopping state until the test creates $FAKE_RUN_DIR/release.
while [ -d "$ROOT" ] && [ ! -e "$FAKE_RUN_DIR/release" ]; do
  sleep 0.2
done
echo "fleet-board-run: stopped: stop-file after 2 ticks, 0.01 h, cost_estimate_usd 0.42 (estimate)"
exit 0

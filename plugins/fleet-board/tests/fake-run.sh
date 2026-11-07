#!/usr/bin/env bash
#
# Stand-in for fleet-board-run.sh in the web board tests. Prints the wrapper's
# log line, then writes what the wrapper writes for two ticks: a start line and
# an end line each. Tick 2 pauses between its start and end line until the test
# creates $FAKE_RUN_DIR/tick-release (it also ends when the stop file appears).
# Then it waits for the repo's .fleet-board.stop and prints the stopped line.
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

LOG="$FAKE_RUN_DIR/fake.log"
: > "$LOG"
echo "fleet-board-run: log: $LOG"
echo "=== tick 1 start $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$LOG"
echo "=== tick 1 $(date -u +%Y-%m-%dT%H:%M:%SZ) rc=0 ===" >> "$LOG"
echo "=== tick 2 start $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$LOG"
while [ -d "$ROOT" ] && [ ! -e "$FAKE_RUN_DIR/tick-release" ] && [ ! -e "$ROOT/.fleet-board.stop" ]; do
  sleep 0.2
done
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

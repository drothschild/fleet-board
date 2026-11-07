#!/usr/bin/env bash
# Run independent fixture starts in bounded batches. Git mutation is guarded
# inside start.sh; workers run while that mutex is released.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$#" -eq 3 ] || exit 2
ACTIONS="$1" SCRATCH="$2" LIMIT="$3"
[[ "$LIMIT" =~ ^[1-9][0-9]*$ ]] || exit 1
PIDS="" RUNNING=0 FAILURES=0
cancel() {
  local code="$1" pid
  trap '' INT TERM
  for pid in $PIDS; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in $PIDS; do wait "$pid" 2>/dev/null || true; done
  exit "$code"
}
trap 'cancel 130' INT
trap 'cancel 143' TERM
wait_batch() {
  local pid
  for pid in $PIDS; do wait "$pid" || FAILURES=$((FAILURES + 1)); done
  PIDS=""; RUNNING=0
}
while IFS= read -r CARD_JSON; do
  [ -n "$CARD_JSON" ] || continue
  NUMBER="$(jq -r .number <<<"$CARD_JSON")"
  ACTION_DIR="$SCRATCH/action-$NUMBER"
  mkdir "$ACTION_DIR" || exit 1
  printf '%s\n' "$CARD_JSON" > "$ACTION_DIR/card"
  bash "$SCRIPTS/standalone/start.sh" "$ACTION_DIR/card" "$ACTION_DIR" &
  PIDS="$PIDS $!"; RUNNING=$((RUNNING + 1))
  if [ "$RUNNING" -ge "$LIMIT" ]; then wait_batch; fi
done < "$ACTIONS"
wait_batch
[ "$FAILURES" -eq 0 ] || { echo "$FAILURES start action(s) failed" >&2; exit 1; }

#!/usr/bin/env bash
# Standalone tick controller. Plans are checked before being returned or acted on.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "${1:-}" = worker ]; then
  shift
  exec bash "$SCRIPTS/standalone/worker.sh" "$@"
fi
MODE=tick
if [ "$#" -eq 2 ] && [ "$1" = tick ] && [ "$2" = --plan-only ]; then
  MODE=plan
elif [ "$#" -ne 1 ] || [ "$1" != tick ]; then
  echo 'usage: fleet-board tick [--plan-only]' >&2
  exit 2
fi
SCRATCH="$(mktemp -d)" || exit 1
PLAN="$SCRATCH/plan"
LOCK=""
cleanup() {
  [ -z "$LOCK" ] || rmdir "$LOCK" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
CHILD=""
cancel() {
  local code="$1" target="$CHILD" watchdog=""
  if [ -n "$target" ]; then
    kill -TERM -- "-$target" 2>/dev/null || true
    (
      sleep 5 & timer=$!
      trap 'kill "$timer" 2>/dev/null || true; wait "$timer" 2>/dev/null || true; exit 0' TERM INT
      wait "$timer" && kill -KILL -- "-$target" 2>/dev/null || true
    ) </dev/null >/dev/null 2>&1 & watchdog=$!
    wait "$target" 2>/dev/null || true
    # Reap any group members that ignored TERM after the leader exited.
    kill -KILL -- "-$target" 2>/dev/null || true
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    CHILD=""
  fi
  exit "$code"
}
run_group() {
  local rc
  set -m
  "$@" & CHILD=$!
  set +m
  wait "$CHILD"; rc=$?
  CHILD=""
  return "$rc"
}
run_start() { run_group bash "$SCRIPTS/standalone/start.sh" "$@"; }
trap cleanup EXIT
trap 'cancel 130' INT
trap 'cancel 143' TERM
if [ "$MODE" = tick ]; then
  COMMON="$(git rev-parse --git-common-dir)" || exit 1
  COMMON="$(cd "$COMMON" && pwd -P)" || exit 1
  LOCK="$COMMON/fleet-board-standalone.lock"
  if ! mkdir "$LOCK" 2>/dev/null; then LOCK=""; echo 'another standalone tick holds the repository lock' >&2; exit 1; fi
fi
if [ "$MODE" = tick ]; then
  # Recover one incomplete action before planning: the card may be between
  # labels, or its move may have succeeded before its note was written.
  for JOURNAL in "$COMMON"/fleet-board-standalone/start-*.json; do
    [ -e "$JOURNAL" ] || continue
    [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || { echo 'invalid action journal' >&2; exit 1; }
    if jq -e '.completed == true' "$JOURNAL" >/dev/null; then continue; fi
    jq -e '.version == 1 and (.plan_card | type == "object")' "$JOURNAL" >/dev/null || { echo 'invalid action journal' >&2; exit 1; }
    jq '.plan_card' "$JOURNAL" > "$SCRATCH/card" || exit 1
    run_start "$SCRATCH/card" "$SCRATCH" || exit 1
    jq -n --slurpfile card "$SCRATCH/card" '{outcome:"progress",dispatchable:true,warnings:[],cards:[$card[0]]}'
    exit 0
  done
fi
if [ "$MODE" = plan ]; then
  run_group env FLEET_BOARD_PLAN_READ_ONLY=1 FLEET_BOARD_PLAN_CACHE="$SCRATCH/projects.json" bash "${FLEET_BOARD_TICK_PLAN:-$SCRIPTS/tick-plan.sh}" > "$PLAN" || exit $?
else
  run_group bash "${FLEET_BOARD_TICK_PLAN:-$SCRIPTS/tick-plan.sh}" > "$PLAN" || exit $?
fi
# Enumerate every action emitted by tick-plan, including settle-only actions.
# Unknown actions and malformed envelopes are rejected before any effect.
if ! jq -e -s '
  length == 1 and (.[0] |
    type == "object" and (.dispatchable | type == "boolean") and
    (.warnings | type == "array" and all(.[]; type == "string")) and
    (.cards | type == "array" and all(.[];
      type == "object" and (.number | type == "number" and . > 0 and floor == .) and
      (.title | type == "string") and (.state | type == "string" or . == null) and
      (.reason | type == "string") and (.branch | type == "string" and length > 0) and
      (.worktree | type == "string" and length > 0) and
      has("pr") and (.pr | . == null or (type == "number" and . > 0 and floor == .)) and
      has("round") and (.round | . == null or (type == "number" and . >= 0 and floor == .)) and
      (.models | type == "object" and
        (.implementor | type == "string" and length > 0) and
        (.reviewer | type == "string" and length > 0) and
        (.fixer | type == "string" and length > 0)) and
      (.escalated | type == "boolean") and
      has("stage") and (.stage | . == null or type == "object") and
      has("needs_human_qa") and (.needs_human_qa | . == null or type == "boolean") and
      (.action | IN("start", "continue_implementor", "start_review", "review", "review_stage", "advance_stage", "fix", "mark_ready", "merge", "verify_main", "finish", "to_human_qa", "file_pending", "block", "unblock", "skip", "skip_no_acceptance", "skip_card_lint", "wait", "update_branch", "move_to_review")))))
' "$PLAN" >/dev/null 2>&1; then
  echo 'invalid tick plan or unknown action' >&2
  exit 1
fi
if [ "$MODE" = plan ]; then
  cat "$PLAN"
  exit 0
fi
# Only one start may run; reject the entire plan before effects otherwise.
if jq -e 'all(.cards[]; .action == "skip") and .dispatchable == false' "$PLAN" >/dev/null; then
  jq '. + {outcome: "idle"}' "$PLAN"
  exit 0
fi
if ! jq -e '([.cards[] | select(.action == "start")] | length) == 1 and all(.cards[]; .action == "skip" or .action == "start")' "$PLAN" >/dev/null; then
  echo 'tick contains an unsupported action; no actions taken' >&2
  exit 1
fi
jq '.cards[] | select(.action == "start")' "$PLAN" > "$SCRATCH/card"
run_start "$SCRATCH/card" "$SCRATCH" || exit 1
jq '. + {outcome: "progress"}' "$PLAN"

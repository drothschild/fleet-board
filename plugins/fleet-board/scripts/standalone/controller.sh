#!/usr/bin/env bash
# Standalone tick controller. Plans are checked before being returned or acted on.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" -ne 2 ] || [ "$1" != tick ] || [ "$2" != --plan-only ]; then
  echo 'usage: fleet-board tick --plan-only' >&2
  exit 2
fi
PLAN="$(mktemp)" || exit 1
trap 'rm -f "$PLAN"' EXIT
FLEET_BOARD_PLAN_READ_ONLY=1 bash "${FLEET_BOARD_TICK_PLAN:-$SCRIPTS/tick-plan.sh}" > "$PLAN" || exit $?
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
cat "$PLAN"

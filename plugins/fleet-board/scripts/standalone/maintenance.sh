#!/usr/bin/env bash
# Fixture-only non-worker maintenance actions. Recheck board evidence before writes.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPTS/board-lib.sh"
[ "$#" -eq 2 ] && [ -f "$1" ] && [ -d "$2" ] || exit 2
CARD="$1" SCRATCH="$2"
fb_load_config
[ "${FLEET_BOARD_STANDALONE_FIXTURE:-}" = 1 ] && [ -n "${FLEET_BOARD_FIXTURE_ROOT:-}" ] || exit 1
FIXTURE_ROOT="$(cd "$FLEET_BOARD_FIXTURE_ROOT" && pwd -P)" || exit 1
case "$FLEET_ROOT/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
GH_BIN="$(command -v gh)" || exit 1
[ -f "$GH_BIN" ] && [ ! -L "$GH_BIN" ] || exit 1
GH_DIR="$(cd "$(dirname "$GH_BIN")" && pwd -P)" || exit 1
case "$GH_DIR/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
jq -e '(.number | type == "number" and . > 0 and floor == .) and (.action | IN("wait", "skip_card_lint", "block", "unblock"))' "$CARD" >/dev/null || exit 1
N="$(jq -r .number "$CARD")"; ACTION="$(jq -r .action "$CARD")"
fb_valid_number "$N" || exit 1
if [ "$ACTION" = block ] || [ "$ACTION" = unblock ]; then
  SOURCE="$(jq -r .state "$CARD")"; REASON="$(jq -r '.reason | strings' "$CARD")"
  [ -n "$REASON" ] || exit 1
  if [ "$ACTION" = block ]; then
    case "$SOURCE" in ready|in_progress|in_review|review_*) ;; *) exit 1 ;; esac
    TARGET=blocked
  else
    [ "$SOURCE" = blocked ] || exit 1
    TARGET=ready
  fi
  COMMON="$(fb_git_common_dir "$FLEET_ROOT")" || exit 1
  JDIR="$COMMON/fleet-board-standalone"; mkdir -p "$JDIR" || exit 1
  JOURNAL="$JDIR/maintenance-$ACTION-$N.json"
  CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || exit 1
  ACTUAL="$(jq -r .state <<<"$CURRENT")"
  NOTE="$(bash "$SCRIPTS/note.sh" get "$N")" || exit 1
  if [ -e "$JOURNAL" ]; then
    [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || exit 1
    if [ "$ACTUAL" = "$SOURCE" ] && jq -e '.completed == true' "$JOURNAL" >/dev/null; then
      jq -e --argjson n "$N" --arg action "$ACTION" --arg repo "$FLEET_REPO" '.version == 1 and .card == $n and .action == $action and .repo == $repo' "$JOURNAL" >/dev/null || exit 1
      rm "$JOURNAL" || exit 1
    fi
  fi
  if [ -e "$JOURNAL" ]; then
    [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || exit 1
    jq -e --argjson n "$N" --arg action "$ACTION" --arg source "$SOURCE" --arg repo "$FLEET_REPO" --arg reason "$REASON" '.version == 1 and .card == $n and .action == $action and .source == $source and .repo == $repo and .reason == $reason' "$JOURNAL" >/dev/null || exit 1
    if jq -e '.completed == true' "$JOURNAL" >/dev/null; then [ "$ACTUAL" = "$TARGET" ] || exit 1; exit 0; fi
  else
    [ "$ACTUAL" = "$SOURCE" ] || { echo 'card state changed before maintenance' >&2; exit 1; }
    if [ "$ACTION" = unblock ]; then
      PR="$(jq -r '.blocking_pr // empty' <<<"$NOTE")"; fb_valid_number "$PR" || exit 1
      INFO="$(gh pr view "$PR" --repo "$FLEET_REPO" --json number,state,mergedAt)" || exit 1
      jq -e --argjson pr "$PR" '.number == $pr and .state == "MERGED" and (.mergedAt | type == "string" and length > 0)' <<<"$INFO" >/dev/null || exit 1
    else PR=""; fi
    FINDINGS="$(jq -c --arg reason "$REASON" '[.last_review.findings[]? | select(.severity == "Critical" or .severity == "Important") | {severity,text}] | if length == 0 or ($reason | startswith("no progress after ")) then [{severity:"Important",text:$reason}] else . end' <<<"$NOTE")" || exit 1
    jq -n --argjson card "$N" --arg action "$ACTION" --arg source "$SOURCE" --arg repo "$FLEET_REPO" --arg reason "$REASON" --arg pr "$PR" --argjson findings "$FINDINGS" --slurpfile plan_card "$CARD" '{version:1,card:$card,action:$action,source:$source,repo:$repo,reason:$reason,pr:$pr,findings:$findings,plan_card:$plan_card[0],completed:false}' > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  fi
  if [ "$ACTION" = block ] && [[ "$REASON" = 'no progress after '* ]] && ! jq -e '.cleared_pr == true' "$JOURNAL" >/dev/null; then
    printf '%s\n' '{"blocking_pr":null}' > "$SCRATCH/patch"; bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/patch" || exit 1
    jq '.cleared_pr = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  fi
  case "$ACTUAL" in
    "$TARGET") jq -e '.move_attempted == true' "$JOURNAL" >/dev/null || exit 1 ;;
    "$SOURCE"|null)
      if [ "$ACTUAL" = null ]; then
        jq -e '.move_attempted == true' "$JOURNAL" >/dev/null || exit 1
        if [ "$(fb_cfg board.backend)" = github-projects ]; then
          ITEM="$(jq -r '.item_id // empty' <<<"$CURRENT")"; [ -n "$ITEM" ] && [ "$ITEM" = "$(jq -r '.move_item_id // empty' "$JOURNAL")" ] || exit 1
        else
          STATES="$(for state in $FB_STATES; do fb_state_name "$state"; done | jq -Rsc 'split("\n") | map(select(length > 0))')" || exit 1
          jq -e --argjson states "$STATES" '[.labels[] | select(. as $label | ($states | index($label)) != null)] == []' <<<"$CURRENT" >/dev/null || exit 1
        fi
      else
        ITEM="$(jq -r '.item_id // empty' <<<"$CURRENT")"
        jq --arg item "$ITEM" '.move_attempted = true | .move_item_id = $item' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
      fi
      FLEET_BOARD_ENFORCE_QA=1 bash "$SCRIPTS/board-move.sh" "$N" "$TARGET" || exit 1 ;;
    *) echo 'card state changed during maintenance' >&2; exit 1 ;;
  esac
  if [ "$ACTION" = unblock ]; then
    printf '%s\n' '{"blocking_pr":null,"blocked_from":null,"blocked_findings":null,"action_failures":0,"last_action_error":null}' > "$SCRATCH/patch"
  else
    jq '{blocked_from:.source,blocked_findings:.findings,action_failures:0,last_action_error:null,state:"blocked"}' "$JOURNAL" > "$SCRATCH/patch" || exit 1
  fi
  bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/patch" || exit 1
  if [ "$ACTION" = block ]; then
    MARKER="<!-- fleet-board:maintenance:block:$N:$(printf '%s' "$REASON" | cksum | awk '{print $1}') -->"
    CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || exit 1
    if ! jq -e --arg marker "$MARKER" 'any(.comments[]; .body | contains($marker))' <<<"$CURRENT" >/dev/null; then
      { printf '%s\n' "$MARKER" 'Card blocked. A person must fix the cause and move it back.'; jq -r '.findings[] | "- [" + .severity + "] " + .text' "$JOURNAL"; } > "$SCRATCH/comment" || exit 1
      bash "$SCRIPTS/board-comment.sh" "$N" "$SCRATCH/comment" || exit 1
    fi
  fi
  jq '.completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  exit 0
fi
if [ "$ACTION" = wait ] && [ "$(jq -r .state "$CARD")" != ready ]; then exit 0; fi
jq -e '.state == "ready"' "$CARD" >/dev/null || exit 1
CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || exit 1
[ "$(jq -r .state <<<"$CURRENT")" = ready ] || { echo 'card no longer ready' >&2; exit 1; }
if [ "$ACTION" = wait ]; then
  jq -e '.waiting_on | type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*$"))' "$CARD" >/dev/null || exit 1
  # A ready wait without dependencies can be a preflight or scope hold.
  [ "$(jq '.waiting_on | length' "$CARD")" -gt 0 ] || exit 0
  NOTE="$(bash "$SCRIPTS/note.sh" get "$N")" || exit 1
  jq -e --slurpfile card "$CARD" '.deps_commented == $card[0].waiting_on' <<<"$NOTE" >/dev/null && exit 0
  BODY="$(jq -r '"Waiting for " + (.waiting_on | join(", "))' "$CARD")"
  # If the comment succeeded before the note write, reuse the most recent wait notice.
  if ! jq -e --arg body "$BODY" '[.comments[].body | select(startswith("Waiting for "))] | (last // "") == $body' <<<"$CURRENT" >/dev/null; then
    printf '%s' "$BODY" > "$SCRATCH/comment" || exit 1
    bash "$SCRIPTS/board-comment.sh" "$N" "$SCRATCH/comment" || exit 1
  fi
  jq '{deps_commented:.waiting_on}' "$CARD" > "$SCRATCH/patch" || exit 1
  bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/patch" || exit 1
else
  jq -e '(.comment_needed | type == "boolean") and (.lint | type == "array" and length > 0 and all(.[]; type == "string")) and (.lint_marker | type == "string" and test("^<!-- fleet-board:card-lint:[0-9]+ -->$"))' "$CARD" >/dev/null || exit 1
  [ "$(jq -r .comment_needed "$CARD")" = true ] || exit 0
  MARKER="$(jq -r .lint_marker "$CARD")"
  if jq -e --arg marker "$MARKER" '[.comments[].body | select(contains("<!-- fleet-board:card-lint:"))] | (last // "") | contains($marker)' <<<"$CURRENT" >/dev/null; then exit 0; fi
  jq -r '.lint_marker, (.lint[] | "- " + .), "Please fix the card."' "$CARD" > "$SCRATCH/comment" || exit 1
  bash "$SCRIPTS/board-comment.sh" "$N" "$SCRATCH/comment" || exit 1
fi

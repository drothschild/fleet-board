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
jq -e '(.number | type == "number" and . > 0 and floor == .) and (.action | IN("wait", "skip_card_lint", "block", "unblock", "file_pending"))' "$CARD" >/dev/null || exit 1
N="$(jq -r .number "$CARD")"; ACTION="$(jq -r .action "$CARD")"
fb_valid_number "$N" || exit 1
if [ "$ACTION" = file_pending ]; then
  COMMON="$(fb_git_common_dir "$FLEET_ROOT")" || exit 1
  JDIR="$COMMON/fleet-board-standalone"; mkdir -p "$JDIR" || exit 1
  JOURNAL="$JDIR/maintenance-file_pending-$N.json"
  NOTE="$(bash "$SCRIPTS/note.sh" get "$N")" || exit 1
  if [ -e "$JOURNAL" ]; then
    [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || exit 1
    jq -e --argjson n "$N" --arg repo "$FLEET_REPO" '.version == 1 and .card == $n and .repo == $repo and .action == "file_pending"' "$JOURNAL" >/dev/null || exit 1
    if jq -e '.completed == true' "$JOURNAL" >/dev/null; then
      if jq -e '.pending_followups == null' <<<"$NOTE" >/dev/null; then exit 0; fi
      rm "$JOURNAL" || exit 1
    fi
  fi
  if [ ! -e "$JOURNAL" ]; then
    jq -e '.pending_followups | type == "object" and (.out_of_scope | type == "array") and (.bugs | type == "array")' <<<"$NOTE" >/dev/null || exit 1
    PR="$(jq -r --slurpfile card "$CARD" '.pending_followups.pr // .pr // $card[0].pr // empty' <<<"$NOTE")"
    if [ -z "$PR" ]; then exit 0; fi
    fb_valid_number "$PR" || exit 1
    jq -n --argjson card "$N" --arg repo "$FLEET_REPO" --argjson pr "$PR" --argjson note "$NOTE" --slurpfile plan_card "$CARD" '{version:1,card:$card,repo:$repo,action:"file_pending",pr:$pr,pending:$note.pending_followups,initial_failures:($note.action_failures // 0),phase:"prepared",plan_card:$plan_card[0],completed:false}' > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  fi
  PHASE="$(jq -r .phase "$JOURNAL")"
  if [ "$PHASE" = running ]; then echo 'pending filing result uncertain; reconcile before retry' >&2; exit 1; fi
  if [ "$PHASE" = prepared ]; then
    jq -e --argjson note "$NOTE" '.pending == $note.pending_followups' "$JOURNAL" >/dev/null || { echo 'pending follow-ups changed' >&2; exit 1; }
    jq '.pending' "$JOURNAL" > "$SCRATCH/pending" || exit 1
    jq --argjson note "$NOTE" '.phase = "running" | .initial_failures = ($note.action_failures // 0)' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
    PR="$(jq -r .pr "$JOURNAL")"
    bash "$SCRIPTS/file-followups.sh" "$N" "$PR" "$SCRATCH/pending" > "$SCRATCH/filed"; RC=$?
    if [ ! -s "$SCRATCH/filed" ]; then
      # The helper explicitly guarantees empty output means no filing occurred.
      jq '.phase = "prepared"' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
      bash "$SCRIPTS/note.sh" fail "$N" 'filing pending follow-ups failed' || true
      exit 1
    fi
    jq -e -s 'length == 1 and (.[0] | type == "object" and (.out_of_scope_created | type == "array") and (.bugs_filed | type == "array"))' "$SCRATCH/filed" >/dev/null || exit 1
    jq --argjson rc "$RC" --slurpfile result "$SCRATCH/filed" '.phase = "filed" | .result = $result[0] | .rc = $rc' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  fi
  jq -e '.phase == "filed" and (.rc == 0 or .rc == 1)' "$JOURNAL" >/dev/null || exit 1
  jq '
    . as $j | $j.result as $r | $j.pending as $p
    | def remaining($items; $filed): [$items[] | . as $item | select(any($filed[]; (.title | ascii_downcase) == ($item.title | ascii_downcase)) | not)];
    {out_of_scope_created:$r.out_of_scope_created,bugs_filed:$r.bugs_filed,
     pending_followups:(if $j.rc == 0 then null else $p + {out_of_scope:remaining($p.out_of_scope; $r.out_of_scope_created),bugs:remaining($p.bugs; $r.bugs_filed)} end),
     action_failures:(if $j.rc == 0 then 0 else ($j.initial_failures + 1) end),last_action_error:(if $j.rc == 0 then null else "filing pending follow-ups failed" end)}
    ' "$JOURNAL" > "$SCRATCH/patch" || exit 1
  NOTE="$(bash "$SCRIPTS/note.sh" get "$N")" || exit 1
  if jq -e --slurpfile patch "$SCRATCH/patch" '.pending_followups == $patch[0].pending_followups and .action_failures == $patch[0].action_failures and .last_action_error == $patch[0].last_action_error' <<<"$NOTE" >/dev/null; then :
  elif jq -e --argjson note "$NOTE" '.pending == $note.pending_followups' "$JOURNAL" >/dev/null; then
    bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/patch" || exit 1
  else echo 'pending follow-ups changed during filing' >&2; exit 1; fi
  jq '.completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  [ "$(jq -r .rc "$JOURNAL")" = 0 ] || exit 1
  exit 0
fi
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
  if [ "$ACTION" = unblock ]; then
    PR="$(jq -r .pr "$JOURNAL")"; fb_valid_number "$PR" || exit 1
    LIVE_PR="$(jq -r '.blocking_pr // empty' <<<"$NOTE")"
    if [ "$LIVE_PR" != "$PR" ]; then
      [ -z "$LIVE_PR" ] && [ "$ACTUAL" = "$TARGET" ] && jq -e '.note_attempted == true' "$JOURNAL" >/dev/null && jq -e '.blocked_from == null and .blocked_findings == null and .action_failures == 0 and .last_action_error == null' <<<"$NOTE" >/dev/null || { echo 'blocking PR changed during unblock' >&2; exit 1; }
    fi
    INFO="$(gh pr view "$PR" --repo "$FLEET_REPO" --json number,state,mergedAt)" || exit 1
    jq -e --argjson pr "$PR" '.number == $pr and .state == "MERGED" and (.mergedAt | type == "string" and length > 0)' <<<"$INFO" >/dev/null || exit 1
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
  if [ "$ACTION" = unblock ]; then
    # Re-read immediately before clearing so a new blocker is not discarded.
    NOTE="$(bash "$SCRIPTS/note.sh" get "$N")" || exit 1
    LIVE_PR="$(jq -r '.blocking_pr // empty' <<<"$NOTE")"
    if [ "$LIVE_PR" != "$PR" ]; then
      [ -z "$LIVE_PR" ] && jq -e '.note_attempted == true' "$JOURNAL" >/dev/null && jq -e '.blocked_from == null and .blocked_findings == null and .action_failures == 0 and .last_action_error == null' <<<"$NOTE" >/dev/null || { echo 'blocking PR changed during unblock' >&2; exit 1; }
    fi
    jq '.note_attempted = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
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

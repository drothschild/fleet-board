#!/usr/bin/env bash
# Reconcile a validated blocked implementor report without publishing Git work.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPTS/board-lib.sh"
[ "$#" -eq 3 ] || [ "$#" -eq 4 ] || exit 2
CARD="$1" SCRATCH="$2"
fb_load_config
[ "${FLEET_BOARD_STANDALONE_FIXTURE:-}" = 1 ] && [ -n "${FLEET_BOARD_FIXTURE_ROOT:-}" ] || exit 1
FIXTURE_ROOT="$(cd "$FLEET_BOARD_FIXTURE_ROOT" && pwd -P)" || exit 1
case "$FLEET_ROOT/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
GH_BIN="$(command -v gh)" || exit 1
[ -f "$GH_BIN" ] && [ ! -L "$GH_BIN" ] || exit 1
GH_DIR="$(cd "$(dirname "$GH_BIN")" && pwd -P)" || exit 1
case "$GH_DIR/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
N="$(jq -r .number "$CARD")"; BRANCH="$(jq -r .branch "$CARD")"; WT="$(jq -r .worktree "$CARD")"; ATTEMPT="$(jq -r '.continuation_attempt // 1' "$CARD")"
fb_valid_number "$N" && [[ "$ATTEMPT" =~ ^[1-9][0-9]*$ ]] || exit 1
case "$BRANCH" in "fleet/$N-"*) ;; *) exit 1 ;; esac
COMMON="$(fb_git_common_dir "$FLEET_ROOT")" || exit 1
JDIR="$COMMON/fleet-board-standalone"; mkdir -p "$JDIR" || exit 1
if [ "$#" -eq 4 ]; then
  RESULT="$3"; BASE="$4"
  [[ "$BASE" =~ ^[0-9a-f]{40}$ ]] || exit 1
  JOURNAL="$JDIR/blocked-$N-$ATTEMPT-$BASE.json"
  jq -e '.version == 1 and .outcome == "blocked" and (.report | type == "string" and length > 0)' "$RESULT" >/dev/null || exit 1
  jq -r .report "$RESULT" > "$SCRATCH/blocked-report" || exit 1
  PARSED="$(bash "$SCRIPTS/parse-report.sh" --role implementor "$SCRATCH/blocked-report")" || exit 1
  [ "$(jq -r .status <<<"$PARSED")" = blocked ] || exit 1
  if [ ! -e "$JOURNAL" ]; then
    BEFORE_NOTE="$(bash "$SCRIPTS/note.sh" get "$N")" || exit 1
    PRIOR_BLOCKER="$(jq -c '.blocking_pr // null' <<<"$BEFORE_NOTE")" || exit 1
    jq -n --argjson prior_blocker "$PRIOR_BLOCKER" --argjson card "$N" --argjson attempt "$ATTEMPT" --arg repo "$FLEET_REPO" --arg branch "$BRANCH" --arg wt "$WT" --arg base "$BASE" --slurpfile result "$RESULT" --slurpfile plan_card "$CARD" '{version:1,card:$card,attempt:$attempt,repo:$repo,branch:$branch,worktree:$wt,base:$base,prior_blocking_pr:$prior_blocker,result:$result[0],plan_card:$plan_card[0],completed:false}' > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  fi
else
  JOURNAL="$3"
fi
[ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || exit 1
jq -e --argjson n "$N" --argjson attempt "$ATTEMPT" --arg repo "$FLEET_REPO" --arg branch "$BRANCH" --arg wt "$WT" '.version == 1 and .card == $n and .attempt == $attempt and .repo == $repo and .branch == $branch and .worktree == $wt and (.base | test("^[0-9a-f]{40}$")) and has("prior_blocking_pr") and .result.outcome == "blocked"' "$JOURNAL" >/dev/null || exit 1
BASE="$(jq -r .base "$JOURNAL")"
[ "$JOURNAL" = "$JDIR/blocked-$N-$ATTEMPT-$BASE.json" ] || exit 1
jq -r .result.report "$JOURNAL" > "$SCRATCH/blocked-report" || exit 1
PARSED="$(bash "$SCRIPTS/parse-report.sh" --role implementor "$SCRATCH/blocked-report")" || exit 1
jq -e '.status == "blocked" and (.out_of_scope | length == 0) and (.bugs | length == 0)' <<<"$PARSED" >/dev/null || { echo 'blocked report needs unsupported follow-up reconciliation' >&2; exit 1; }
# Do not overwrite a blocker a person changed while this action was pending.
check_blocker() {
  local live prior expected
  live="$(bash "$SCRIPTS/note.sh" get "$N")" || return 1
  prior="$(jq -c .prior_blocking_pr "$JOURNAL")" || return 1
  expected="$(jq -c .blocked_by <<<"$PARSED")" || return 1
  if jq -e '.blocker_written == true' "$JOURNAL" >/dev/null; then
    jq -e --argjson expected "$expected" '.blocking_pr == $expected' <<<"$live" >/dev/null
  elif jq -e '.blocker_write_attempted == true' "$JOURNAL" >/dev/null; then
    jq -e --argjson prior "$prior" --argjson expected "$expected" '.blocking_pr == $prior or .blocking_pr == $expected' <<<"$live" >/dev/null
  else
    jq -e --argjson prior "$prior" '.blocking_pr == $prior' <<<"$live" >/dev/null
  fi
}
check_blocker || { echo 'blocker changed while blocked result was pending' >&2; exit 1; }
CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || exit 1
ACTUAL="$(jq -r .state <<<"$CURRENT")"
SOURCE=ready
if jq -e 'has("continuation_attempt")' "$CARD" >/dev/null; then SOURCE=in_progress; fi
BLOCK_JOURNAL="$JDIR/maintenance-block-$N.json"
case "$ACTUAL" in
  ready)
    [ "$SOURCE" = ready ] || exit 1
    ITEM="$(jq -r '.item_id // empty' <<<"$CURRENT")"
    jq --arg item "$ITEM" '.progress_move_attempted = true | .progress_item_id = $item' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
    FLEET_BOARD_ENFORCE_QA=1 bash "$SCRIPTS/board-move.sh" "$N" in_progress || exit 1 ;;
  in_progress) ;;
  blocked) [ -f "$BLOCK_JOURNAL" ] && jq -e '.move_attempted == true' "$BLOCK_JOURNAL" >/dev/null || exit 1 ;;
  null)
    if [ -f "$BLOCK_JOURNAL" ] && jq -e '.move_attempted == true' "$BLOCK_JOURNAL" >/dev/null; then :
    elif [ "$SOURCE" = ready ] && jq -e '.progress_move_attempted == true' "$JOURNAL" >/dev/null; then
      if [ "$(fb_cfg board.backend)" = github-projects ]; then
        ITEM="$(jq -r '.item_id // empty' <<<"$CURRENT")"; [ -n "$ITEM" ] && [ "$ITEM" = "$(jq -r '.progress_item_id // empty' "$JOURNAL")" ] || exit 1
      else
        STATES="$(for state in $FB_STATES; do fb_state_name "$state"; done | jq -Rsc 'split("\n") | map(select(length > 0))')" || exit 1
        jq -e --argjson states "$STATES" '[.labels[] | select(. as $label | ($states | index($label)) != null)] == []' <<<"$CURRENT" >/dev/null || exit 1
      fi
      FLEET_BOARD_ENFORCE_QA=1 bash "$SCRIPTS/board-move.sh" "$N" in_progress || exit 1
    else exit 1; fi ;;
  *) echo 'card state changed while reconciling blocked result' >&2; exit 1 ;;
esac
CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || exit 1
ACTUAL="$(jq -r .state <<<"$CURRENT")"
if [ "$ACTUAL" = in_progress ]; then
  check_blocker || { echo 'blocker changed before blocked note' >&2; exit 1; }
  jq '.blocker_write_attempted = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  jq -n --arg branch "$BRANCH" --arg wt "$WT" --argjson attempt "$ATTEMPT" --argjson parsed "$PARSED" --slurpfile card "$CARD" '{state:"in_progress",branch:$branch,worktree:$wt,round:0,models:$card[0].models,implementor_attempts:$attempt,blocking_pr:$parsed.blocked_by,last_verified:$parsed.verified.line}' > "$SCRATCH/blocked-note" || exit 1
  bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/blocked-note" || exit 1
  jq '.blocker_written = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
fi
REASON="$(jq -r '.for_the_card | if length > 0 then . else "Implementor is blocked" end' <<<"$PARSED")"
jq --arg reason "$REASON" '.action = "block" | .state = "in_progress" | .reason = $reason' "$CARD" > "$SCRATCH/block-card" || exit 1
mkdir "$SCRATCH/block-maintenance" || exit 1
bash "$SCRIPTS/standalone/maintenance.sh" "$SCRATCH/block-card" "$SCRATCH/block-maintenance" || exit 1
jq -e '.blocker_written == true' "$JOURNAL" >/dev/null && check_blocker || { echo 'blocker changed before final blocked note' >&2; exit 1; }
jq -n --argjson parsed "$PARSED" '{state:"blocked",blocked_from:"in_progress",blocking_pr:$parsed.blocked_by,last_verified:$parsed.verified.line,blocked_findings:([$parsed.findings[] | select(.severity == "Critical" or .severity == "Important")] | if length == 0 then [{severity:"Important",text:$parsed.for_the_card}] else . end)}' > "$SCRATCH/blocked-final" || exit 1
bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/blocked-final" || exit 1
MARKER="<!-- fleet-board:implementor-blocked:$N:$ATTEMPT:$BASE -->"
CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || exit 1
[ "$(jq -r .state <<<"$CURRENT")" = blocked ] || exit 1
ME="$(fb_login)" || exit 1
{ printf '%s\n\n' "$MARKER"; cat "$SCRATCH/blocked-report"; } > "$SCRATCH/blocked-comment"
if jq -e --arg marker "$MARKER" --arg me "$ME" 'any(.comments[]; .author == $me and (.body | startswith($marker)))' <<<"$CURRENT" >/dev/null; then
  jq -e --arg marker "$MARKER" --arg me "$ME" --rawfile body "$SCRATCH/blocked-comment" '[.comments[] | select(.author == $me and (.body | startswith($marker)))] | length == 1 and .[0].body == $body' <<<"$CURRENT" >/dev/null || { echo 'saved blocked report differs from posted report' >&2; exit 1; }
else
  bash "$SCRIPTS/board-comment.sh" "$N" "$SCRATCH/blocked-comment" || exit 1
fi
jq '.completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1

#!/usr/bin/env bash
# Fixture-only review: bind a validated reviewer verdict to the live PR head.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPTS/board-lib.sh"
[ "$#" -eq 2 ] || [ "$#" -eq 3 ] || exit 2
CARD="$1" SCRATCH="$2" RECOVERY_JOURNAL="${3:-}"
ACTION="$(jq -r .action "$CARD")"
ROLE=reviewer STAGE_NAME="" STAGE_AGENT="" STAGE_MODEL=""
case "$ACTION" in
  start_review) EXPECTED_STATE=in_progress; ROUND=1 ;;
  re_review|review) EXPECTED_STATE=in_review; ROUND="$(jq -r .round "$CARD")" ;;
  stage_review)
    STAGE_NAME="$(jq -r '.stage.name // empty' "$CARD")"; STAGE_AGENT="$(jq -r '.stage.agent // empty' "$CARD")"; STAGE_MODEL="$(jq -r '.stage.model // empty' "$CARD")"
    [[ "$STAGE_NAME" =~ ^[a-z][a-z0-9_]*$ ]] && [ -n "$STAGE_AGENT" ] && [ -n "$STAGE_MODEL" ] && jq -e '.stage.provider == null' "$CARD" >/dev/null || exit 1
    EXPECTED_STATE="review_$STAGE_NAME"; ROUND="$(jq -r .round "$CARD")"; ROLE=stage-reviewer ;;
  *) exit 2 ;;
esac
[[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || exit 1
CHILD=""
cancel() {
  local code="$1"
  if [ -n "$CHILD" ]; then kill -TERM "$CHILD" 2>/dev/null || true; wait "$CHILD" 2>/dev/null || true; CHILD=""; fi
  exit "$code"
}
trap 'cancel 130' INT
trap 'cancel 143' TERM
fb_load_config
[ "${FLEET_BOARD_STANDALONE_FIXTURE:-}" = 1 ] && [ -n "${FLEET_BOARD_FIXTURE_ROOT:-}" ] || { echo 'review execution is available only in local fixtures' >&2; exit 1; }
FIXTURE_ROOT="$(cd "$FLEET_BOARD_FIXTURE_ROOT" && pwd -P)" || exit 1
case "$FLEET_ROOT/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
GH_BIN="$(command -v gh)" || exit 1
[ -f "$GH_BIN" ] && [ ! -L "$GH_BIN" ] || exit 1
GH_DIR="$(cd "$(dirname "$GH_BIN")" && pwd -P)" || exit 1
case "$GH_DIR/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
REMOTE="$(git -C "$FLEET_ROOT" remote get-url origin)" || exit 1
case "$REMOTE" in file://*) REMOTE_DIR="${REMOTE#file://}" ;; *) exit 1 ;; esac
REMOTE_DIR="$(cd "$REMOTE_DIR" && pwd -P)" || exit 1
case "$REMOTE_DIR/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
N="$(jq -r .number "$CARD")"; PR="$(jq -r .pr "$CARD")"; BRANCH="$(jq -r .branch "$CARD")"
fb_valid_number "$N" && fb_valid_number "$PR" || exit 1
case "$BRANCH" in "fleet/$N-"*) ;; *) exit 1 ;; esac
[ "$(jq -r .state "$CARD")" = "$EXPECTED_STATE" ] || exit 1
[ -n "${FLEET_BOARD_WORKER_SCRIPT:-}" ] && [ -f "$FLEET_BOARD_WORKER_SCRIPT" ] && [ ! -L "$FLEET_BOARD_WORKER_SCRIPT" ] && [ -n "${FLEET_BOARD_WORKER_IMAGE:-}" ] || exit 1
OWNER="${FLEET_REPO%/*}" REPO="${FLEET_REPO#*/}"
pr_info() { gh pr view "$PR" --repo "$FLEET_REPO" --json number,isDraft,state,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,body; }
check_pr() {
  jq -e --argjson n "$PR" --arg branch "$BRANCH" --arg owner "$OWNER" --arg repo "$REPO" --arg marker "<!-- fleet-board:card:$N -->" '
    .number == $n and .state == "OPEN" and .headRefName == $branch and .baseRefName == "main" and
    .headRepositoryOwner.login == $owner and .headRepository.name == $repo and (.headRefOid | test("^[0-9a-f]{40}$")) and (.body | contains($marker))' >/dev/null
}
INFO="$(pr_info)" || exit 1
check_pr <<<"$INFO" || { echo 'review PR identity mismatch' >&2; exit 1; }
SHA="$(jq -r .headRefOid <<<"$INFO")"
COMMON="$(fb_git_common_dir "$FLEET_ROOT")" || exit 1
JDIR="$COMMON/fleet-board-standalone"; mkdir -p "$JDIR" || exit 1
JOURNAL_KIND=core
[ -z "$STAGE_NAME" ] || JOURNAL_KIND="stage-$STAGE_NAME"
JOURNAL="$JDIR/review-$N-$ROUND-$JOURNAL_KIND-$SHA.json"
[ -z "$RECOVERY_JOURNAL" ] || [ "$RECOVERY_JOURNAL" = "$JOURNAL" ] || { echo 'review head changed since saved verdict' >&2; exit 1; }
RECOVERING=false
if [ -e "$JOURNAL" ]; then
  [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || exit 1
  jq -e --argjson n "$N" --argjson pr "$PR" --argjson round "$ROUND" --arg repo "$FLEET_REPO" --arg branch "$BRANCH" --arg sha "$SHA" --arg action "$ACTION" '.version == 1 and .card == $n and .pr == $pr and .round == $round and .repo == $repo and .branch == $branch and .sha == $sha and .action == $action' "$JOURNAL" >/dev/null || { echo 'invalid review journal' >&2; exit 1; }
  jq '.result' "$JOURNAL" > "$SCRATCH/result"
  RECOVERING=true
else
  REVIEW="$(bash "$SCRIPTS/worktree.sh" review "$N" "$PR")" || exit 1
  [ "$(jq -r .sha <<<"$REVIEW")" = "$SHA" ] || { echo 'review checkout differs from PR head' >&2; exit 1; }
  WT="$(jq -r .path <<<"$REVIEW")"
  mkdir "$SCRATCH/worker" || exit 1
  cp "$FLEET_BOARD_WORKER_SCRIPT" "$SCRATCH/worker/worker.sh" || exit 1
  CONTEXT="$(jq -c '.review_context // null' "$CARD")" || exit 1
  jq -n --argjson card "$N" --arg wt "$WT" --arg ref "$SHA" --arg image "$FLEET_BOARD_WORKER_IMAGE" --arg role "$ROLE" --arg stage "$STAGE_NAME" --arg agent "$STAGE_AGENT" --arg context "$CONTEXT" \
    '{version:1,card:$card,action:"review",role:$role,worktree:$wt,expected_ref:$ref,prompt:("Review the requested change. Stage: " + $stage + "; agent: " + $agent + "; previous review and fix: " + $context),limits:{seconds:300,memory_mb:1024,pids:128},permissions:{network:false},image:$image}' > "$SCRATCH/request.json"
  bash "$SCRIPTS/standalone/worker.sh" --request "$SCRATCH/request.json" --scratch "$SCRATCH/worker" > "$SCRATCH/result" & CHILD=$!
  wait "$CHILD"; RC=$?; CHILD=""
  [ "$RC" -eq 0 ] || exit "$RC"
fi
jq -r .report "$SCRATCH/result" > "$SCRATCH/reviewer-report"
PARSED="$(bash "$SCRIPTS/parse-report.sh" --role "$ROLE" "$SCRATCH/reviewer-report")" || exit 1
[ "$(jq -r .status <<<"$PARSED")" = "$(jq -r .outcome "$SCRATCH/result")" ] || exit 1
jq -e '(.out_of_scope | length == 0) and (.bugs | length == 0)' <<<"$PARSED" >/dev/null || { echo 'review follow-ups require reconciliation' >&2; exit 1; }
# A concurrent move, especially into Human QA, must not be undone by a review.
check_live_card() {
  local current states state actual expected item
  current="$(bash "$SCRIPTS/board-read.sh" "$N")" || return 1
  actual="$(jq -r .state <<<"$current")" || return 1
  item="$(jq -r '.item_id // empty' <<<"$current")" || return 1
  if [ "$actual" != "$EXPECTED_STATE" ]; then
    if [ "$RECOVERING" = true ] && [ "$ACTION" = start_review ] && [ "$actual" = in_review ]; then :
    elif [ "$RECOVERING" = true ] && [ "$ACTION" = start_review ] && [ "$actual" = null ] && jq -e '.move_attempted == true and .move_source == "in_progress"' "$JOURNAL" >/dev/null; then :
    else return 1; fi
  fi
  if [ "$(fb_cfg board.backend)" = local ]; then
    [ "$actual" != null ] || return 1
    jq -e --argjson n "$N" '.number == $n' <<<"$current" >/dev/null || return 1
  elif [ "$(fb_cfg board.backend)" = github-projects ]; then
    [ -n "$item" ] || return 1
    if [ "$actual" = null ]; then [ "$(jq -r '.move_item_id // empty' "$JOURNAL")" = "$item" ] || return 1; fi
    jq -e --argjson n "$N" '.number == $n' <<<"$current" >/dev/null || return 1
  else
    states="$(for state in $FB_STATES; do fb_state_name "$state"; done | jq -Rsc 'split("\n") | map(select(length > 0))')" || return 1
    if [ "$actual" = null ]; then
      jq -e --argjson states "$states" '[.labels[] | select(. as $label | ($states | index($label)) != null)] == []' <<<"$current" >/dev/null || return 1
    else
      expected="$(fb_state_name "$actual")"
      jq -e --arg expected "$expected" --argjson states "$states" '[.labels[] | select(. as $label | ($states | index($label)) != null)] == [$expected]' <<<"$current" >/dev/null || return 1
    fi
  fi
  LIVE_STATE="$actual"; LIVE_ITEM="$item"
}
check_live_card || { echo 'card state changed during review' >&2; exit 1; }
INFO="$(pr_info)" || exit 1
check_pr <<<"$INFO" && [ "$(jq -r .headRefOid <<<"$INFO")" = "$SHA" ] || { echo 'PR head changed during review' >&2; exit 1; }
check_live_card || { echo 'card state changed during review' >&2; exit 1; }
if [ "$RECOVERING" = false ]; then
  jq -n --argjson card "$N" --argjson pr "$PR" --argjson round "$ROUND" --arg repo "$FLEET_REPO" --arg branch "$BRANCH" --arg sha "$SHA" --arg action "$ACTION" --slurpfile result "$SCRATCH/result" --slurpfile plan_card "$CARD" '{version:1,card:$card,pr:$pr,round:$round,repo:$repo,branch:$branch,sha:$sha,action:$action,result:$result[0],plan_card:$plan_card[0],completed:false}' > "$JOURNAL.tmp.$$" || exit 1
  mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
fi
# Route before moving; a routing error leaves the card in its original state.
if [ "$ACTION" = start_review ]; then
  bash "$SCRIPTS/review-stages.sh" route "$N" "$PR" >/dev/null || exit 1
fi
if [ "$ACTION" = stage_review ]; then MARKER="<!-- fleet-board:standalone-stage-review:$STAGE_NAME:$ROUND:$SHA -->"; else MARKER="<!-- fleet-board:standalone-review:$SHA -->"; fi
COMMENTS="$(bash "$SCRIPTS/standalone/comments.sh" "$N")" || exit 1
ME="$(fb_login)" || exit 1
{ printf '%s\nReviewed commit: `%s`\n\n' "$MARKER" "$SHA"; cat "$SCRATCH/reviewer-report"; } > "$SCRATCH/official-report"
if jq -e --arg marker "$MARKER" --arg me "$ME" 'any(.[]; .author == $me and (.body | startswith($marker)))' <<<"$COMMENTS" >/dev/null; then
  jq -e --arg marker "$MARKER" --arg me "$ME" --rawfile body "$SCRATCH/official-report" '[.[] | select(.author == $me and (.body | startswith($marker)))] | length == 1 and .[0].body == $body' <<<"$COMMENTS" >/dev/null || { echo 'saved review report differs from posted report' >&2; exit 1; }
else
  bash "$SCRIPTS/board-comment.sh" "$N" "$SCRATCH/official-report" || exit 1
fi
# Recheck immediately before recording; downstream merge must compare again.
INFO="$(pr_info)" || exit 1
check_pr <<<"$INFO" && [ "$(jq -r .headRefOid <<<"$INFO")" = "$SHA" ] || { echo 'PR head changed before review recording' >&2; exit 1; }
jq -n --argjson pr "$PR" --arg sha "$SHA" --argjson round "$ROUND" --argjson parsed "$PARSED" \
  --arg state "$EXPECTED_STATE" --arg stage "$STAGE_NAME" --arg agent "$STAGE_AGENT" --arg model "$STAGE_MODEL" \
  '{state:(if $stage == "" then "in_review" else $state end),pr:$pr,round:$round,last_verified:$parsed.verified.line,last_review:({round:$round,sha:$sha,critical:$parsed.counts.critical,important:$parsed.counts.important,findings:$parsed.findings} + (if $stage == "" then {} else {stage:$stage,agent:$agent,model:$model,provider:null} end)),action_failures:0,last_action_error:null}' > "$SCRATCH/note.json"
check_live_card || { echo 'card state changed before review recording' >&2; exit 1; }
if [ "$ACTION" = start_review ] && { [ "$LIVE_STATE" = in_progress ] || [ "$LIVE_STATE" = null ]; }; then
  if [ "$LIVE_STATE" = in_progress ]; then
    jq --arg item "$LIVE_ITEM" '.move_attempted = true | .move_source = "in_progress" | .move_item_id = $item' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  fi
  FLEET_BOARD_ENFORCE_QA=1 bash "$SCRIPTS/board-move.sh" "$N" in_review || exit 1
fi
bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/note.json" || exit 1
jq '.completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1

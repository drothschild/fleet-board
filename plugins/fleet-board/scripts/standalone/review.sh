#!/usr/bin/env bash
# Fixture-only review: bind a validated reviewer verdict to the live PR head.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPTS/board-lib.sh"
[ "$#" -eq 2 ] || exit 2
CARD="$1" SCRATCH="$2"
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
[ "$(jq -r .state "$CARD")" = in_progress ] || exit 1
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
REVIEW="$(bash "$SCRIPTS/worktree.sh" review "$N" "$PR")" || exit 1
[ "$(jq -r .sha <<<"$REVIEW")" = "$SHA" ] || { echo 'review checkout differs from PR head' >&2; exit 1; }
WT="$(jq -r .path <<<"$REVIEW")"
mkdir "$SCRATCH/worker" || exit 1
cp "$FLEET_BOARD_WORKER_SCRIPT" "$SCRATCH/worker/worker.sh" || exit 1
jq -n --argjson card "$N" --arg wt "$WT" --arg ref "$SHA" --arg image "$FLEET_BOARD_WORKER_IMAGE" \
  '{version:1,card:$card,action:"review",role:"reviewer",worktree:$wt,expected_ref:$ref,prompt:"Review the requested change.",limits:{seconds:300,memory_mb:1024,pids:128},permissions:{network:false},image:$image}' > "$SCRATCH/request.json"
bash "$SCRIPTS/standalone/worker.sh" --request "$SCRATCH/request.json" --scratch "$SCRATCH/worker" > "$SCRATCH/result" & CHILD=$!
wait "$CHILD"; RC=$?; CHILD=""
[ "$RC" -eq 0 ] || exit "$RC"
jq -r .report "$SCRATCH/result" > "$SCRATCH/reviewer-report"
PARSED="$(bash "$SCRIPTS/parse-report.sh" --role reviewer "$SCRATCH/reviewer-report")" || exit 1
jq -e '(.out_of_scope | length == 0) and (.bugs | length == 0)' <<<"$PARSED" >/dev/null || { echo 'review follow-ups require reconciliation' >&2; exit 1; }
# A concurrent move, especially into Human QA, must not be undone by a review.
check_live_card() {
  local current states state
  current="$(bash "$SCRIPTS/board-read.sh" "$N")" || return 1
  states="$(for state in $FB_STATES; do fb_state_name "$state"; done | jq -Rsc 'split("\n") | map(select(length > 0))')" || return 1
  jq -e --arg expected "$(fb_state_name in_progress)" --argjson states "$states" '
    .state == "in_progress" and ([.labels[] | select(. as $label | ($states | index($label)) != null)] == [$expected])
  ' <<<"$current" >/dev/null
}
check_live_card || { echo 'card state changed during review' >&2; exit 1; }
INFO="$(pr_info)" || exit 1
check_pr <<<"$INFO" && [ "$(jq -r .headRefOid <<<"$INFO")" = "$SHA" ] || { echo 'PR head changed during review' >&2; exit 1; }
check_live_card || { echo 'card state changed during review' >&2; exit 1; }
# Route before moving; a routing error leaves the card in its original state.
bash "$SCRIPTS/review-stages.sh" route "$N" "$PR" >/dev/null || exit 1
MARKER="<!-- fleet-board:standalone-review:$SHA -->"
COMMENTS="$(gh api --paginate "repos/$FLEET_REPO/issues/$N/comments" | jq -s 'add // []')" || exit 1
ME="$(fb_login)" || exit 1
if ! jq -e --arg marker "$MARKER" --arg me "$ME" 'any(.[]; .user.login == $me and (.body | startswith($marker)))' <<<"$COMMENTS" >/dev/null; then
  { printf '%s\nReviewed commit: `%s`\n\n' "$MARKER" "$SHA"; cat "$SCRATCH/reviewer-report"; } > "$SCRATCH/official-report"
  bash "$SCRIPTS/board-comment.sh" "$N" "$SCRATCH/official-report" || exit 1
fi
# Recheck immediately before recording; downstream merge must compare again.
INFO="$(pr_info)" || exit 1
check_pr <<<"$INFO" && [ "$(jq -r .headRefOid <<<"$INFO")" = "$SHA" ] || { echo 'PR head changed before review recording' >&2; exit 1; }
jq -n --argjson pr "$PR" --arg sha "$SHA" --argjson parsed "$PARSED" \
  '{state:"in_review",pr:$pr,round:1,last_verified:$parsed.verified.line,last_review:{round:1,sha:$sha,critical:$parsed.counts.critical,important:$parsed.counts.important,findings:$parsed.findings},action_failures:0,last_action_error:null}' > "$SCRATCH/note.json"
check_live_card || { echo 'card state changed before review recording' >&2; exit 1; }
bash "$SCRIPTS/board-move.sh" "$N" in_review || exit 1
bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/note.json" || exit 1

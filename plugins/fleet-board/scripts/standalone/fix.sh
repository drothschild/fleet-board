#!/usr/bin/env bash
# Fixture-only fix and same-tick re-review against verified GitHub evidence.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPTS/board-lib.sh"
[ "$#" -eq 2 ] || exit 2
CARD="$1" SCRATCH="$2" CHILD=""
cancel() {
  local code="$1"
  if [ -n "$CHILD" ]; then kill -TERM "$CHILD" 2>/dev/null || true; wait "$CHILD" 2>/dev/null || true; CHILD=""; fi
  exit "$code"
}
trap 'cancel 130' INT
trap 'cancel 143' TERM
run_child() { "$@" & CHILD=$!; wait "$CHILD"; local rc=$?; CHILD=""; return "$rc"; }
fb_load_config
[ "${FLEET_BOARD_STANDALONE_FIXTURE:-}" = 1 ] && [ -n "${FLEET_BOARD_FIXTURE_ROOT:-}" ] || { echo 'fix execution is available only in local fixtures' >&2; exit 1; }
FIXTURE_ROOT="$(cd "$FLEET_BOARD_FIXTURE_ROOT" && pwd -P)" || exit 1
case "$FLEET_ROOT/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
GH_BIN="$(command -v gh)" || exit 1
[ -f "$GH_BIN" ] && [ ! -L "$GH_BIN" ] || exit 1
GH_DIR="$(cd "$(dirname "$GH_BIN")" && pwd -P)" || exit 1
case "$GH_DIR/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
RAW_REMOTE="$(git -C "$FLEET_ROOT" config --get remote.origin.url)" || exit 1
case "$RAW_REMOTE" in "https://github.com/$FLEET_REPO"|"https://github.com/$FLEET_REPO.git"|"git@github.com:$FLEET_REPO"|"git@github.com:$FLEET_REPO.git") ;; *) exit 1 ;; esac
REMOTE="$(git -C "$FLEET_ROOT" remote get-url origin)" || exit 1
case "$REMOTE" in file://*) REMOTE_DIR="${REMOTE#file://}" ;; *) exit 1 ;; esac
REMOTE_DIR="$(cd "$REMOTE_DIR" && pwd -P)" || exit 1
case "$REMOTE_DIR/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
check_push() {
  local urls path
  urls="$(git -C "$FLEET_ROOT" remote get-url --push --all origin)" || return 1
  case "$urls" in file://*) ;; *) return 1 ;; esac
  case "$urls" in *$'\n'*) return 1 ;; esac
  path="$(cd "${urls#file://}" && pwd -P)" || return 1
  [ "$path" = "$REMOTE_DIR" ]
}
check_push || { echo 'push destination does not match fixture remote' >&2; exit 1; }
N="$(jq -r .number "$CARD")"; PR="$(jq -r .pr "$CARD")"; BRANCH="$(jq -r .branch "$CARD")"; ROUND="$(jq -r .round "$CARD")"; STATE="$(jq -r .state "$CARD")"
fb_valid_number "$N" && fb_valid_number "$PR" && [[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || exit 1
case "$BRANCH" in "fleet/$N-"*) ;; *) exit 1 ;; esac
STAGE_NAME=""; JOURNAL_KIND=core
case "$STATE" in
  in_review) ;;
  review_*) STAGE_NAME="${STATE#review_}"; [[ "$STAGE_NAME" =~ ^[a-z][a-z0-9_]*$ ]] && [ "$(jq -r '.stage.name // empty' "$CARD")" = "$STAGE_NAME" ] && jq -e '.stage.provider == null and (.stage.agent | type == "string" and length > 0)' "$CARD" >/dev/null || exit 1; JOURNAL_KIND="stage-$STAGE_NAME" ;;
  *) exit 1 ;;
esac
[ -n "${FLEET_BOARD_WORKER_SCRIPT:-}" ] && [ -f "$FLEET_BOARD_WORKER_SCRIPT" ] && [ ! -L "$FLEET_BOARD_WORKER_SCRIPT" ] && [ -n "${FLEET_BOARD_WORKER_IMAGE:-}" ] || exit 1
OWNER="${FLEET_REPO%/*}" REPO="${FLEET_REPO#*/}"
pr_info() { gh pr view "$PR" --repo "$FLEET_REPO" --json number,isDraft,state,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,body; }
check_pr() {
  jq -e --argjson n "$PR" --arg branch "$BRANCH" --arg owner "$OWNER" --arg repo "$REPO" --arg marker "<!-- fleet-board:card:$N -->" '
    .number == $n and .state == "OPEN" and .headRefName == $branch and .baseRefName == "main" and
    .headRepositoryOwner.login == $owner and .headRepository.name == $repo and (.headRefOid | test("^[0-9a-f]{40}$")) and (.body | contains($marker))' >/dev/null
}
check_state() {
  local current states state
  current="$(bash "$SCRIPTS/board-read.sh" "$N")" || return 1
  if [ "$(fb_cfg board.backend)" = github-projects ]; then
    jq -e --argjson n "$N" --arg state "$STATE" '.number == $n and .state == $state and (.item_id | type == "string" and length > 0)' <<<"$current" >/dev/null
    return $?
  fi
  states="$(for state in $FB_STATES; do fb_state_name "$state"; done | jq -Rsc 'split("\n") | map(select(length > 0))')" || return 1
  jq -e --arg expected "$(fb_state_name "$STATE")" --arg state "$STATE" --argjson states "$states" '.state == $state and ([.labels[] | select(. as $label | ($states | index($label)) != null)] == [$expected])' <<<"$current" >/dev/null
}
check_state || { echo 'card is no longer in review' >&2; exit 1; }
COMMON="$(fb_git_common_dir "$FLEET_ROOT")" || exit 1
JDIR="$COMMON/fleet-board-standalone"; mkdir -p "$JDIR" || exit 1
JOURNAL="$JDIR/fix-$N-$JOURNAL_KIND-$ROUND.json"; EVIDENCE_REF="refs/fleet-board/standalone/fix-$N-$JOURNAL_KIND-$ROUND"
NOTE="$(bash "$SCRIPTS/note.sh" get "$N")" || exit 1
jq -e --arg stage "$STAGE_NAME" '(.last_review.stage // "") == $stage' <<<"$NOTE" >/dev/null || exit 1
NOTE_SHA="$(jq -r .last_review.sha <<<"$NOTE")"
NOTE_ROUND="$(jq -r .round <<<"$NOTE")"
if [ -e "$JOURNAL" ]; then OLD_SHA="$(jq -r .base "$JOURNAL")"; else OLD_SHA="$NOTE_SHA"; fi
[[ "$OLD_SHA" =~ ^[0-9a-f]{40}$ ]] || exit 1
INFO="$(pr_info)" || exit 1
check_pr <<<"$INFO" || exit 1
LIVE_SHA="$(jq -r .headRefOid <<<"$INFO")"
if [ -e "$JOURNAL" ]; then
  [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || exit 1
  jq -e --argjson n "$N" --arg repo "$FLEET_REPO" --arg branch "$BRANCH" --arg old "$OLD_SHA" --argjson round "$ROUND" '.version == 1 and .card == $n and .repo == $repo and .branch == $branch and .base == $old and .round == $round and (.head | test("^[0-9a-f]{40}$")) and .result.outcome == "done"' "$JOURNAL" >/dev/null || exit 1
  HEAD_SHA="$(jq -r .head "$JOURNAL")"
  GIT_NO_REPLACE_OBJECTS=1 git -C "$FLEET_ROOT" cat-file -e "$HEAD_SHA^{commit}" && GIT_NO_REPLACE_OBJECTS=1 git -C "$FLEET_ROOT" merge-base --is-ancestor "$OLD_SHA" "$HEAD_SHA" || exit 1
  CURRENT_REF="$(git -C "$FLEET_ROOT" rev-parse --verify "$EVIDENCE_REF" 2>/dev/null || true)"
  if [ -z "$CURRENT_REF" ]; then git -C "$FLEET_ROOT" update-ref "$EVIDENCE_REF" "$HEAD_SHA" "" || exit 1
  elif [ "$CURRENT_REF" != "$HEAD_SHA" ]; then exit 1; fi
  jq '.result' "$JOURNAL" > "$SCRATCH/result"
  if [ "$NOTE_ROUND" = "$((ROUND + 1))" ] && [ "$NOTE_SHA" = "$HEAD_SHA" ] && [ "$(jq -r .last_review.round <<<"$NOTE")" = "$((ROUND + 1))" ]; then
    [ "$LIVE_SHA" = "$HEAD_SHA" ] || exit 1
    REMOTE_HEAD="$(git -C "$FLEET_ROOT" ls-remote --heads origin "refs/heads/$BRANCH")" || exit 1
    [ "${REMOTE_HEAD%%[[:space:]]*}" = "$HEAD_SHA" ] || exit 1
    COMMENTS="$(gh api --paginate "repos/$FLEET_REPO/issues/$N/comments" | jq -s 'add // []')" || exit 1
    ME="$(fb_login)" || exit 1
    if [ -n "$STAGE_NAME" ]; then REVIEW_MARKER="<!-- fleet-board:standalone-stage-review:$STAGE_NAME:$((ROUND + 1)):$HEAD_SHA -->"; else REVIEW_MARKER="<!-- fleet-board:standalone-review:$HEAD_SHA -->"; fi
    jq -e --arg marker "$REVIEW_MARKER" --arg me "$ME" 'any(.[]; .user.login == $me and (.body | startswith($marker)))' <<<"$COMMENTS" >/dev/null || exit 1
    check_state || exit 1
    jq '.completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
    exit 0
  fi
  [ "$NOTE_ROUND" = "$ROUND" ] && [ "$NOTE_SHA" = "$OLD_SHA" ] || exit 1
else
  [ "$NOTE_ROUND" = "$ROUND" ] || exit 1
  [ "$LIVE_SHA" = "$OLD_SHA" ] || { echo 'PR head changed since review' >&2; exit 1; }
  FINDINGS="$(jq -c '[.last_review.findings[] | select(.severity == "Critical" or .severity == "Important")]' <<<"$NOTE")" || exit 1
  [ "$(jq length <<<"$FINDINGS")" -gt 0 ] || exit 1
  REVIEW="$(bash "$SCRIPTS/worktree.sh" review "$N" "$PR")" || exit 1
  [ "$(jq -r .sha <<<"$REVIEW")" = "$OLD_SHA" ] || exit 1
  WT="$(jq -r .path <<<"$REVIEW")"
  mkdir "$SCRATCH/fixer" || exit 1
  cp "$FLEET_BOARD_WORKER_SCRIPT" "$SCRATCH/fixer/worker.sh" || exit 1
  jq -n --argjson card "$N" --arg wt "$WT" --arg ref "$OLD_SHA" --arg image "$FLEET_BOARD_WORKER_IMAGE" --arg prompt "Fix these findings: $FINDINGS" \
    '{version:1,card:$card,action:"fix",role:"fixer",worktree:$wt,expected_ref:$ref,prompt:$prompt,limits:{seconds:300,memory_mb:1024,pids:128},permissions:{network:false},image:$image}' > "$SCRATCH/fix-request.json"
  run_child bash "$SCRIPTS/standalone/worker.sh" --request "$SCRATCH/fix-request.json" --scratch "$SCRATCH/fixer" > "$SCRATCH/result" || exit 1
  [ "$(jq -r .outcome "$SCRATCH/result")" = done ] || exit 1
  CLONE="$SCRATCH/fixer/checkout"
  [ -d "$CLONE" ] && [ ! -L "$CLONE" ] && [ -d "$CLONE/.git" ] && [ ! -L "$CLONE/.git" ] && [ -f "$CLONE/.git/HEAD" ] && [ ! -L "$CLONE/.git/HEAD" ] && [ -d "$CLONE/.git/objects" ] && [ ! -L "$CLONE/.git/objects" ] || exit 1
  [ ! -e "$CLONE/.git/objects/info/alternates" ] && [ ! -e "$CLONE/.git/objects/info/http-alternates" ] && [ -z "$(find "$CLONE/.git/objects" ! -type f ! -type d -print -quit)" ] || exit 1
  HEAD_SHA="$(cat "$CLONE/.git/HEAD")" || exit 1
  [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] && [ "$HEAD_SHA" != "$OLD_SHA" ] || exit 1
  git -c init.templateDir= init -q --bare "$SCRATCH/fix-import.git" || exit 1
  cp -R "$CLONE/.git/objects/." "$SCRATCH/fix-import.git/objects/" || exit 1
  GIT_NO_REPLACE_OBJECTS=1 git --git-dir="$SCRATCH/fix-import.git" merge-base --is-ancestor "$OLD_SHA" "$HEAD_SHA" || exit 1
  git -C "$FLEET_ROOT" -c protocol.file.allow=always fetch -q --no-tags "$SCRATCH/fix-import.git" "$HEAD_SHA" || exit 1
  [ "$(git -C "$FLEET_ROOT" rev-parse FETCH_HEAD)" = "$HEAD_SHA" ] || exit 1
  jq -n --argjson card "$N" --arg repo "$FLEET_REPO" --arg branch "$BRANCH" --arg base "$OLD_SHA" --arg head "$HEAD_SHA" --argjson round "$ROUND" --slurpfile result "$SCRATCH/result" --slurpfile plan_card "$CARD" '{version:1,card:$card,repo:$repo,branch:$branch,base:$base,head:$head,round:$round,result:$result[0],plan_card:$plan_card[0],completed:false}' > "$JOURNAL.tmp.$$" || exit 1
  mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  git -C "$FLEET_ROOT" update-ref "$EVIDENCE_REF" "$HEAD_SHA" "" || exit 1
fi
jq -r .report "$SCRATCH/result" > "$SCRATCH/fixer-report"
PARSED="$(bash "$SCRIPTS/parse-report.sh" --role fixer "$SCRATCH/fixer-report")" || exit 1
jq -e --argjson pr "$PR" '.status == "done" and .pr == $pr and (.out_of_scope | length == 0) and (.bugs | length == 0)' <<<"$PARSED" >/dev/null || exit 1
REMOTE_HEAD="$(git -C "$FLEET_ROOT" ls-remote --heads origin "refs/heads/$BRANCH")" || exit 1
REMOTE_SHA="${REMOTE_HEAD%%[[:space:]]*}"
if [ "$REMOTE_SHA" = "$OLD_SHA" ] && [ "$LIVE_SHA" = "$OLD_SHA" ]; then
  check_state && check_push || exit 1
  git -C "$FLEET_ROOT" push origin "$HEAD_SHA:refs/heads/$BRANCH" >&2 || exit 1
elif [ "$REMOTE_SHA" != "$HEAD_SHA" ] || [ "$LIVE_SHA" != "$HEAD_SHA" ]; then
  echo 'PR or remote head changed during fix' >&2; exit 1
fi
INFO="$(pr_info)" || exit 1
check_pr <<<"$INFO" && [ "$(jq -r .headRefOid <<<"$INFO")" = "$HEAD_SHA" ] || { echo 'published fix head not verified' >&2; exit 1; }
check_state || exit 1
MARKER="<!-- fleet-board:standalone-fix:$HEAD_SHA -->"
COMMENTS="$(gh api --paginate "repos/$FLEET_REPO/issues/$N/comments" | jq -s 'add // []')" || exit 1
ME="$(fb_login)" || exit 1
if ! jq -e --arg marker "$MARKER" --arg me "$ME" 'any(.[]; .user.login == $me and (.body | startswith($marker)))' <<<"$COMMENTS" >/dev/null; then
  { printf '%s\nFixed commit: `%s`\n\n' "$MARKER" "$HEAD_SHA"; cat "$SCRATCH/fixer-report"; } > "$SCRATCH/official-fix"
  bash "$SCRIPTS/board-comment.sh" "$N" "$SCRATCH/official-fix" || exit 1
fi
# Review the fix within this same action; never leave a new head approved by
# the old verdict. The journal remains pending if re-review is interrupted.
REVIEW_ACTION=re_review
[ -z "$STAGE_NAME" ] || REVIEW_ACTION=stage_review
jq --argjson round "$((ROUND + 1))" --arg action "$REVIEW_ACTION" --arg old "$OLD_SHA" --argjson findings "$(jq -c '.last_review.findings // []' <<<"$NOTE")" --rawfile fix_report "$SCRATCH/fixer-report" '.action = $action | .round = $round | .review_context = {previous_sha:$old,findings:$findings,fix_report:$fix_report}' "$CARD" > "$SCRATCH/re-review-card"
mkdir "$SCRATCH/re-review" || exit 1
run_child bash "$SCRIPTS/standalone/review.sh" "$SCRATCH/re-review-card" "$SCRATCH/re-review" || exit 1
jq '.completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1

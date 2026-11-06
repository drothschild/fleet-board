#!/usr/bin/env bash
# Execute a single start after the entire plan has passed the controller gate.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPTS/board-lib.sh"
[ "$#" -eq 2 ] || exit 2
CHILD=""
cancel() {
  local code="$1"
  if [ -n "$CHILD" ]; then
    kill -TERM "$CHILD" 2>/dev/null || true
    wait "$CHILD" 2>/dev/null || true
    CHILD=""
  fi
  exit "$code"
}
trap 'cancel 130' INT
trap 'cancel 143' TERM
CARD="$1" SCRATCH="$2"
fb_load_config
# This increment is fixture-only until PR/report recovery is implemented.
[ "${FLEET_BOARD_STANDALONE_FIXTURE:-}" = 1 ] && [ -n "${FLEET_BOARD_FIXTURE_ROOT:-}" ] || { echo 'start execution is available only in local fixtures' >&2; exit 1; }
FIXTURE_ROOT="$(cd "$FLEET_BOARD_FIXTURE_ROOT" && pwd -P)" || exit 1
case "$FLEET_ROOT/" in "$FIXTURE_ROOT"/*) ;; *) echo 'fixture repository outside fixture root' >&2; exit 1 ;; esac
GH_BIN="$(command -v gh)" || exit 1
[ ! -L "$GH_BIN" ] && [ -f "$GH_BIN" ] || exit 1
GH_DIR="$(cd "$(dirname "$GH_BIN")" && pwd -P)" || exit 1
case "$GH_DIR/" in "$FIXTURE_ROOT"/*) ;; *) echo 'fixture GitHub adapter outside fixture root' >&2; exit 1 ;; esac
EFFECTIVE_REMOTE="$(git -C "$FLEET_ROOT" remote get-url origin)" || exit 1
case "$EFFECTIVE_REMOTE" in file://*) REMOTE_DIR="${EFFECTIVE_REMOTE#file://}" ;; *) echo 'fixture remote must be local' >&2; exit 1 ;; esac
REMOTE_DIR="$(cd "$REMOTE_DIR" && pwd -P)" || exit 1
case "$REMOTE_DIR/" in "$FIXTURE_ROOT"/*) ;; *) echo 'fixture remote outside fixture root' >&2; exit 1 ;; esac
validate_push_destination() {
  local push_urls push_dir
  push_urls="$(git -C "$FLEET_ROOT" remote get-url --push --all origin)" || return 1
  case "$push_urls" in *$'\n'*|file://*) ;; *) return 1 ;; esac
  case "$push_urls" in *$'\n'*) return 1 ;; esac
  push_dir="$(cd "${push_urls#file://}" && pwd -P)" || return 1
  [ "$push_dir" = "$REMOTE_DIR" ]
}
validate_push_destination || { echo 'push destination does not match fixture remote' >&2; exit 1; }
N="$(jq -r .number "$CARD")"; BRANCH="$(jq -r .branch "$CARD")"
WT="$(jq -r .worktree "$CARD")"; TITLE="$(jq -r .title "$CARD")"
case "$BRANCH" in "fleet/$N-"*) ;; *) echo 'branch does not match card' >&2; exit 1 ;; esac
[[ "$BRANCH" =~ ^fleet/[0-9]+-[a-z0-9-]{1,40}$ ]] || exit 1
[ "$(jq -r .state "$CARD")" = ready ] || { echo 'card is not ready' >&2; exit 1; }
REMOTE="$(git -C "$FLEET_ROOT" config --get remote.origin.url)" || exit 1
case "$REMOTE" in "https://github.com/$FLEET_REPO"|"https://github.com/$FLEET_REPO.git"|"git@github.com:$FLEET_REPO"|"git@github.com:$FLEET_REPO.git") ;; *) echo 'origin does not match board repository' >&2; exit 1 ;; esac
# A durable journal and a private ref preserve validated worker evidence across
# interruptions, while the repository lock prevents simultaneous retries.
COMMON="$(fb_git_common_dir "$FLEET_ROOT")" || exit 1
JDIR="$COMMON/fleet-board-standalone"
mkdir -p "$JDIR" || exit 1
JOURNAL="$JDIR/start-$N.json"
EVIDENCE_REF="refs/fleet-board/standalone/start-$N"
REMOTE_HEAD="$(git -C "$FLEET_ROOT" ls-remote --heads origin "refs/heads/$BRANCH")" || exit 1
if [ -e "$JOURNAL" ]; then
  [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || exit 1
  jq -e --argjson n "$N" --arg repo "$FLEET_REPO" --arg branch "$BRANCH" --arg wt "$WT" '.version == 1 and .card == $n and .repo == $repo and .branch == $branch and .worktree == $wt and (.base | test("^[0-9a-f]{40}$")) and (.head | test("^[0-9a-f]{40}$")) and .result.outcome == "done"' "$JOURNAL" >/dev/null || { echo 'invalid start journal' >&2; exit 1; }
  BASE="$(jq -r .base "$JOURNAL")"; HEAD_SHA="$(jq -r .head "$JOURNAL")"
  GIT_NO_REPLACE_OBJECTS=1 git -C "$FLEET_ROOT" cat-file -e "$HEAD_SHA^{commit}" && GIT_NO_REPLACE_OBJECTS=1 git -C "$FLEET_ROOT" merge-base --is-ancestor "$BASE" "$HEAD_SHA" || { echo 'journal commit evidence unavailable' >&2; exit 1; }
  CURRENT_REF="$(git -C "$FLEET_ROOT" rev-parse --verify "$EVIDENCE_REF" 2>/dev/null || true)"
  if [ -z "$CURRENT_REF" ]; then
    git -C "$FLEET_ROOT" update-ref "$EVIDENCE_REF" "$HEAD_SHA" "" || exit 1
  elif [ "$CURRENT_REF" != "$HEAD_SHA" ]; then
    echo 'start evidence ref does not match journal' >&2; exit 1
  fi
  jq '.result' "$JOURNAL" > "$SCRATCH/result"
else
  [ -n "${FLEET_BOARD_WORKER_SCRIPT:-}" ] && [ -f "$FLEET_BOARD_WORKER_SCRIPT" ] && [ ! -L "$FLEET_BOARD_WORKER_SCRIPT" ] && [ -n "${FLEET_BOARD_WORKER_IMAGE:-}" ] || { echo 'standalone worker is not configured' >&2; exit 1; }
  [ -z "$REMOTE_HEAD" ] || { echo 'remote branch already exists; reconciliation required' >&2; exit 1; }
  if git -C "$FLEET_ROOT" show-ref --verify --quiet "$EVIDENCE_REF"; then echo 'orphaned start evidence requires reconciliation' >&2; exit 1; fi
  bash "$SCRIPTS/worktree.sh" create "$N" "$BRANCH" "$WT" >/dev/null || exit 1
  BASE="$(git -C "$WT" rev-parse HEAD)" || exit 1
  mkdir "$SCRATCH/worker" || exit 1
  cp "$FLEET_BOARD_WORKER_SCRIPT" "$SCRATCH/worker/worker.sh" || exit 1
  jq -n --argjson card "$N" --arg wt "$WT" --arg ref "$BASE" --arg image "$FLEET_BOARD_WORKER_IMAGE" --arg prompt "$TITLE" \
    '{version:1,card:$card,action:"start",role:"implementor",worktree:$wt,expected_ref:$ref,prompt:$prompt,limits:{seconds:300,memory_mb:1024,pids:128},permissions:{network:false},image:$image}' > "$SCRATCH/request.json"
  bash "$SCRIPTS/standalone/worker.sh" --request "$SCRATCH/request.json" --scratch "$SCRATCH/worker" > "$SCRATCH/result" & CHILD=$!
  wait "$CHILD"; RC=$?
  CHILD=""
  [ "$RC" -eq 0 ] || exit "$RC"
  [ "$(jq -r .outcome "$SCRATCH/result")" = done ] || { echo 'worker did not complete implementation' >&2; exit 1; }
  CLONE="$SCRATCH/worker/checkout"
  [ -d "$CLONE" ] && [ ! -L "$CLONE" ] || { echo 'unsafe worker checkout root' >&2; exit 1; }
  # Read only objects and the detached HEAD, never the worker's Git config.
  [ -d "$CLONE/.git" ] && [ ! -L "$CLONE/.git" ] && [ -f "$CLONE/.git/HEAD" ] && [ ! -L "$CLONE/.git/HEAD" ] && [ -d "$CLONE/.git/objects" ] && [ ! -L "$CLONE/.git/objects" ] || exit 1
  [ ! -e "$CLONE/.git/objects/info/alternates" ] && [ ! -e "$CLONE/.git/objects/info/http-alternates" ] || exit 1
  [ -z "$(find "$CLONE/.git/objects" ! -type f ! -type d -print -quit)" ] || { echo 'unsafe worker object store' >&2; exit 1; }
  HEAD_SHA="$(cat "$CLONE/.git/HEAD")" || exit 1
  [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo 'worker HEAD must be a commit SHA' >&2; exit 1; }
  git -c init.templateDir= init -q --bare "$SCRATCH/import.git" || exit 1
  cp -R "$CLONE/.git/objects/." "$SCRATCH/import.git/objects/" || exit 1
  [ "$HEAD_SHA" != "$BASE" ] && GIT_NO_REPLACE_OBJECTS=1 git --git-dir="$SCRATCH/import.git" merge-base --is-ancestor "$BASE" "$HEAD_SHA" || { echo 'worker commit evidence is invalid' >&2; exit 1; }
  git -C "$FLEET_ROOT" -c protocol.file.allow=always fetch -q --no-tags "$SCRATCH/import.git" "$HEAD_SHA" || exit 1
  [ "$(git -C "$FLEET_ROOT" rev-parse FETCH_HEAD)" = "$HEAD_SHA" ] || exit 1
  jq -n --argjson card "$N" --arg repo "$FLEET_REPO" --arg branch "$BRANCH" --arg wt "$WT" --arg base "$BASE" --arg head "$HEAD_SHA" --slurpfile result "$SCRATCH/result" --slurpfile plan_card "$CARD" '{version:1,card:$card,repo:$repo,branch:$branch,worktree:$wt,base:$base,head:$head,result:$result[0],plan_card:$plan_card[0],completed:false}' > "$JOURNAL.tmp.$$" || exit 1
  mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  git -C "$FLEET_ROOT" update-ref "$EVIDENCE_REF" "$HEAD_SHA" "" || exit 1
fi
jq -r .report "$SCRATCH/result" > "$SCRATCH/report"
PARSED="$(bash "$SCRIPTS/parse-report.sh" --role implementor "$SCRATCH/report")" || exit 1
# Follow-up filing is not yet supported; do not publish partial reconciliation.
jq -e '.status == "done" and (.out_of_scope | length == 0) and (.bugs | length == 0)' <<<"$PARSED" >/dev/null || { echo 'worker report needs unsupported follow-up reconciliation' >&2; exit 1; }
if [ -n "$REMOTE_HEAD" ]; then
  [ "${REMOTE_HEAD%%[[:space:]]*}" = "$HEAD_SHA" ] || { echo 'remote branch does not match recorded evidence' >&2; exit 1; }
else
  validate_push_destination || { echo 'push destination changed' >&2; exit 1; }
  git -C "$FLEET_ROOT" push origin "$HEAD_SHA:refs/heads/$BRANCH" >&2 || exit 1
fi
PRS="$(gh pr list --repo "$FLEET_REPO" --head "$BRANCH" --state open --json number)" || exit 1
COUNT="$(jq 'length' <<<"$PRS")" || exit 1
if [ "$COUNT" -eq 0 ]; then
  gh pr create --repo "$FLEET_REPO" --draft --head "$BRANCH" --base main --title "$TITLE" --body "Closes #$N

<!-- fleet-board:card:$N -->" >/dev/null || exit 1
  PRS="$(gh pr list --repo "$FLEET_REPO" --head "$BRANCH" --state open --json number)" || exit 1
fi
[ "$(jq 'length' <<<"$PRS")" = 1 ] || { echo 'cannot identify a unique draft PR' >&2; exit 1; }
PR="$(jq -r '.[0].number' <<<"$PRS")"
fb_valid_number "$PR" || exit 1
INFO="$(gh pr view "$PR" --repo "$FLEET_REPO" --json number,isDraft,state,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,body)" || exit 1
OWNER="${FLEET_REPO%/*}" REPO="${FLEET_REPO#*/}"
jq -e --argjson n "$PR" --arg branch "$BRANCH" --arg sha "$HEAD_SHA" --arg owner "$OWNER" --arg repo "$REPO" --arg card "<!-- fleet-board:card:$N -->" '
  .number == $n and .isDraft == true and .state == "OPEN" and .headRefName == $branch and .headRefOid == $sha and .baseRefName == "main" and
  .headRepositoryOwner.login == $owner and .headRepository.name == $repo and (.body | contains($card))
' <<<"$INFO" >/dev/null || { echo 'draft PR identity does not match evidence' >&2; exit 1; }
# Construct the official comment from parsed report data and verified PR evidence.
MARKER="<!-- fleet-board:standalone-start:$HEAD_SHA -->"
COMMENTS="$(gh api --paginate "repos/$FLEET_REPO/issues/$N/comments" | jq -s 'add // []')" || exit 1
ME="$(fb_login)" || exit 1
if ! jq -e --arg marker "$MARKER" --arg me "$ME" 'any(.[]; .user.login == $me and (.body | startswith($marker)))' <<<"$COMMENTS" >/dev/null; then
  {
    printf '%s\n\n## Status\ndone\n\n## Findings\n' "$MARKER"
    jq -r 'if (.findings | length) == 0 then "- none" else .findings[] | "- [\(.severity)] \(.text)" end' <<<"$PARSED"
    printf '\n## For the card\n'
    jq -r .for_the_card <<<"$PARSED"
    printf '\n## PR\n#%s\n\n' "$PR"
    jq -r .verified.line <<<"$PARSED"
  } > "$SCRATCH/official-report"
  bash "$SCRIPTS/parse-report.sh" --role implementor "$SCRATCH/official-report" >/dev/null || exit 1
  bash "$SCRIPTS/board-comment.sh" "$N" "$SCRATCH/official-report" || exit 1
fi
jq -n --arg branch "$BRANCH" --arg wt "$WT" --argjson pr "$PR" --slurpfile card "$CARD" --arg verified "$(jq -r .verified.line <<<"$PARSED")" \
  '{state:"in_progress",branch:$branch,worktree:$wt,pr:$pr,round:0,models:$card[0].models,implementor_attempts:1,last_verified:$verified,action_failures:0,last_action_error:null}' > "$SCRATCH/note.json"
CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || exit 1
jq -e '.state == "ready" or .state == "in_progress" or .state == null' <<<"$CURRENT" >/dev/null || { echo 'card moved to an incompatible state' >&2; exit 1; }
bash "$SCRIPTS/board-move.sh" "$N" in_progress || exit 1
bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/note.json" || exit 1
jq '.completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1

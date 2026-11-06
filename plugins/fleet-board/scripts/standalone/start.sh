#!/usr/bin/env bash
# Execute a single start after the entire plan has passed the controller gate.
set -uo pipefail
unset CDPATH
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPTS/board-lib.sh"
[ "$#" -eq 2 ] || exit 2
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
N="$(jq -r .number "$CARD")"; BRANCH="$(jq -r .branch "$CARD")"
WT="$(jq -r .worktree "$CARD")"; TITLE="$(jq -r .title "$CARD")"
case "$BRANCH" in "fleet/$N-"*) ;; *) echo 'branch does not match card' >&2; exit 1 ;; esac
[[ "$BRANCH" =~ ^fleet/[0-9]+-[a-z0-9-]{1,40}$ ]] || exit 1
[ "$(jq -r .state "$CARD")" = ready ] || { echo 'card is not ready' >&2; exit 1; }
[ -n "${FLEET_BOARD_WORKER_SCRIPT:-}" ] && [ -f "$FLEET_BOARD_WORKER_SCRIPT" ] && [ ! -L "$FLEET_BOARD_WORKER_SCRIPT" ] && [ -n "${FLEET_BOARD_WORKER_IMAGE:-}" ] || { echo 'standalone worker is not configured' >&2; exit 1; }
REMOTE="$(git -C "$FLEET_ROOT" config --get remote.origin.url)" || exit 1
case "$REMOTE" in "https://github.com/$FLEET_REPO"|"https://github.com/$FLEET_REPO.git"|"git@github.com:$FLEET_REPO"|"git@github.com:$FLEET_REPO.git") ;; *) echo 'origin does not match board repository' >&2; exit 1 ;; esac
# Never overwrite an existing remote branch; interrupted publication is held for reconciliation.
REMOTE_HEAD="$(git -C "$FLEET_ROOT" ls-remote --heads origin "refs/heads/$BRANCH")" || exit 1
[ -z "$REMOTE_HEAD" ] || { echo 'remote branch already exists; reconciliation required' >&2; exit 1; }
bash "$SCRIPTS/worktree.sh" create "$N" "$BRANCH" "$WT" >/dev/null || exit 1
BASE="$(git -C "$WT" rev-parse HEAD)" || exit 1
mkdir "$SCRATCH/worker" || exit 1
cp "$FLEET_BOARD_WORKER_SCRIPT" "$SCRATCH/worker/worker.sh" || exit 1
jq -n --argjson card "$N" --arg wt "$WT" --arg ref "$BASE" --arg image "$FLEET_BOARD_WORKER_IMAGE" --arg prompt "$TITLE" \
  '{version:1,card:$card,action:"start",role:"implementor",worktree:$wt,expected_ref:$ref,prompt:$prompt,limits:{seconds:300,memory_mb:1024,pids:128},permissions:{network:false},image:$image}' > "$SCRATCH/request.json"
bash "$SCRIPTS/standalone/worker.sh" --request "$SCRATCH/request.json" --scratch "$SCRATCH/worker" > "$SCRATCH/result" || exit 1
[ "$(jq -r .outcome "$SCRATCH/result")" = done ] || { echo 'worker did not complete implementation' >&2; exit 1; }
CLONE="$SCRATCH/worker/checkout"
# The worker controls its Git config, index, hooks and refs. Never execute Git
# in that repository on the host. Copy only regular object files to a fresh,
# controller-owned bare repository before inspecting or importing the commit.
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
git -C "$FLEET_ROOT" push origin "$HEAD_SHA:refs/heads/$BRANCH" >&2 || exit 1
PRS="$(gh pr list --repo "$FLEET_REPO" --head "$BRANCH" --state open --json number)" || exit 1
COUNT="$(jq 'length' <<<"$PRS")" || exit 1
if [ "$COUNT" -eq 0 ]; then
  gh pr create --repo "$FLEET_REPO" --draft --head "$BRANCH" --base main --title "$TITLE" --body "Closes #$N" >/dev/null || exit 1
  PRS="$(gh pr list --repo "$FLEET_REPO" --head "$BRANCH" --state open --json number)" || exit 1
fi
[ "$(jq 'length' <<<"$PRS")" = 1 ] || { echo 'cannot identify a unique draft PR' >&2; exit 1; }
PR="$(jq -r '.[0].number' <<<"$PRS")"
fb_valid_number "$PR" || exit 1
INFO="$(gh pr view "$PR" --repo "$FLEET_REPO" --json number,isDraft,state,headRefName,headRefOid,baseRefName,baseRepositoryOwner,baseRepository,headRepositoryOwner,headRepository)" || exit 1
OWNER="${FLEET_REPO%/*}" REPO="${FLEET_REPO#*/}"
jq -e --argjson n "$PR" --arg branch "$BRANCH" --arg sha "$HEAD_SHA" --arg owner "$OWNER" --arg repo "$REPO" '
  .number == $n and .isDraft == true and .state == "OPEN" and .headRefName == $branch and .headRefOid == $sha and
  .baseRepositoryOwner.login == $owner and .baseRepository.name == $repo and .headRepositoryOwner.login == $owner and .headRepository.name == $repo
' <<<"$INFO" >/dev/null || { echo 'draft PR identity does not match evidence' >&2; exit 1; }
jq -n --arg branch "$BRANCH" --arg wt "$WT" --argjson pr "$PR" --slurpfile card "$CARD" \
  '{state:"in_progress",branch:$branch,worktree:$wt,pr:$pr,round:0,models:$card[0].models,implementor_attempts:1,action_failures:0,last_action_error:null}' > "$SCRATCH/note.json"
bash "$SCRIPTS/board-move.sh" "$N" in_progress || exit 1
bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/note.json" || exit 1

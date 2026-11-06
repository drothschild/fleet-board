#!/usr/bin/env bash
# Fixture-only branch update. The journal preserves the exact pre- and post-merge heads.
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
REMOTE="$(git -C "$FLEET_ROOT" remote get-url origin)" || exit 1
case "$REMOTE" in file://*) REMOTE_DIR="${REMOTE#file://}" ;; *) exit 1 ;; esac
REMOTE_DIR="$(cd "$REMOTE_DIR" && pwd -P)" || exit 1
case "$REMOTE_DIR/" in "$FIXTURE_ROOT"/*) ;; *) exit 1 ;; esac
[ "$(git --git-dir="$REMOTE_DIR" rev-parse --is-bare-repository 2>/dev/null)" = true ] || exit 1
N="$(jq -r .number "$CARD")"; PR="$(jq -r .pr "$CARD")"; BRANCH="$(jq -r .branch "$CARD")"; STATE="$(jq -r .state "$CARD")"
fb_valid_number "$N" && fb_valid_number "$PR" || exit 1
case "$BRANCH" in "fleet/$N-"*) ;; *) exit 1 ;; esac
case "$BRANCH" in *[!A-Za-z0-9/._-]*) exit 1 ;; esac
git check-ref-format "refs/heads/$BRANCH" >/dev/null || exit 1
case "$STATE" in in_progress|in_review|review_*) ;; *) exit 1 ;; esac
jq -e '.action == "update_branch"' "$CARD" >/dev/null || exit 1
OWNER="${FLEET_REPO%/*}" REPO="${FLEET_REPO#*/}"
pr_info() { gh pr view "$PR" --repo "$FLEET_REPO" --json number,state,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,body; }
identity() { jq -e --argjson n "$PR" --arg branch "$BRANCH" --arg owner "$OWNER" --arg repo "$REPO" --arg marker "<!-- fleet-board:card:$N -->" '.number == $n and .state == "OPEN" and .headRefName == $branch and .baseRefName == "main" and .headRepositoryOwner.login == $owner and .headRepository.name == $repo and (.body | contains($marker)) and (.headRefOid | type == "string" and test("^[0-9a-f]{40}$"))' >/dev/null; }
card_state() { bash "$SCRIPTS/board-read.sh" "$N" | jq -e -r --arg state "$STATE" 'select(.state == $state) | .state' >/dev/null; }
remote_head() { git --git-dir="$REMOTE_DIR" rev-parse "refs/heads/$BRANCH"; }
COMMON="$(fb_git_common_dir "$FLEET_ROOT")" || exit 1
JDIR="$COMMON/fleet-board-standalone"; mkdir -p "$JDIR" || exit 1
JOURNAL="$JDIR/update-branch-$N.json"; CLONE="$JDIR/update-checkout-$N"
NOTE="$(bash "$SCRIPTS/note.sh" get "$N")" || exit 1
if [ -e "$JOURNAL" ]; then
  [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || exit 1
  jq -e --argjson n "$N" --argjson pr "$PR" --arg repo "$FLEET_REPO" --arg branch "$BRANCH" '.version == 1 and .card == $n and .pr == $pr and .repo == $repo and .branch == $branch' "$JOURNAL" >/dev/null || exit 1
  if jq -e '.completed == true' "$JOURNAL" >/dev/null; then
    CURRENT_BASE="$(git --git-dir="$REMOTE_DIR" rev-parse refs/heads/main)" || exit 1
    if [ "$(remote_head)" = "$(jq -r .after "$JOURNAL")" ] && [ "$CURRENT_BASE" = "$(jq -r .base "$JOURNAL")" ]; then exit 0; fi
    # The prior operation is complete. Remove only the clone created by it.
    if [ -e "$CLONE" ]; then
      [ -d "$CLONE" ] && [ ! -L "$CLONE" ] && [ -d "$CLONE/.git" ] && [ ! -L "$CLONE/.git" ] || exit 1
      [ "$(git -C "$CLONE" remote get-url origin)" = "$REMOTE_DIR" ] || exit 1
      rm -rf "$CLONE" || exit 1
    fi
    rm "$JOURNAL" || exit 1
  fi
fi
if [ ! -e "$JOURNAL" ]; then
  card_state || { echo 'card state changed before update' >&2; exit 1; }
  INFO="$(pr_info)" || exit 1
  identity <<<"$INFO" || exit 1
  BEFORE="$(remote_head)" || exit 1
  [ "$BEFORE" = "$(jq -r .headRefOid <<<"$INFO")" ] || { echo 'PR head changed before update' >&2; exit 1; }
  BASE="$(git --git-dir="$REMOTE_DIR" rev-parse refs/heads/main)" || exit 1
  [ ! -e "$CLONE" ] && [ ! -L "$CLONE" ] || exit 1
  jq -n --argjson card "$N" --argjson pr "$PR" --arg repo "$FLEET_REPO" --arg branch "$BRANCH" --arg before "$BEFORE" --arg base "$BASE" --argjson note "$NOTE" --slurpfile plan_card "$CARD" '{version:1,card:$card,pr:$pr,repo:$repo,branch:$branch,before:$before,base:$base,prior_review:$note.last_review,phase:"prepared",plan_card:$plan_card[0],completed:false}' > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
fi
BEFORE="$(jq -r .before "$JOURNAL")"; BASE="$(jq -r .base "$JOURNAL")"; PHASE="$(jq -r .phase "$JOURNAL")"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
if [ "$PHASE" = prepared ]; then
  [ "$(remote_head)" = "$BEFORE" ] && [ "$(git --git-dir="$REMOTE_DIR" rev-parse refs/heads/main)" = "$BASE" ] && card_state || exit 1
  if [ -e "$CLONE" ]; then echo 'interrupted local merge requires reconciliation' >&2; exit 1; fi
  git -c protocol.file.allow=always -c core.hooksPath=/dev/null clone -q --no-local --no-hardlinks -- "$REMOTE_DIR" "$CLONE" || exit 1
  git -C "$CLONE" -c core.hooksPath=/dev/null checkout -q -B "$BRANCH" "$BEFORE" || exit 1
  if ! git -C "$CLONE" -c core.hooksPath=/dev/null -c user.name='Fleet Fixture' -c user.email=fixture@example.com merge --no-edit "$BASE" >/dev/null 2>&1; then
    CONFLICTS="$(git -C "$CLONE" diff --name-only --diff-filter=U)" || exit 1
    [ -n "$CONFLICTS" ] || { echo 'merge failed without conflicts' >&2; exit 1; }
    git -C "$CLONE" -c core.hooksPath=/dev/null merge --abort || exit 1
    jq --arg paths "$CONFLICTS" '.phase = "conflict" | .conflicts = $paths' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  fi
  if [ "$(jq -r .phase "$JOURNAL")" = prepared ]; then
    AFTER="$(git -C "$CLONE" rev-parse HEAD)" || exit 1
    git -C "$CLONE" merge-base --is-ancestor "$BEFORE" "$AFTER" || exit 1
    jq --arg after "$AFTER" '.after = $after | .phase = "merged"' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  fi
fi
if [ "$(jq -r .phase "$JOURNAL")" = conflict ]; then
  [ "$(remote_head)" = "$BEFORE" ] || { echo 'branch changed after conflict' >&2; exit 1; }
  CONFLICT_MARKER="<!-- fleet-board:update-conflict:$N:$BEFORE:$BASE -->"
  CURRENT="$(bash "$SCRIPTS/board-read.sh" "$N")" || exit 1
  if ! jq -e --arg marker "$CONFLICT_MARKER" 'any(.comments[]; .body | contains($marker))' <<<"$CURRENT" >/dev/null; then
    { printf '%s\n' "$CONFLICT_MARKER" 'The merge was aborted. A person must resolve these conflicts:'; jq -r '.conflicts | split("\n")[] | "- " + .' "$JOURNAL"; } > "$SCRATCH/conflict-comment" || exit 1
    bash "$SCRIPTS/board-comment.sh" "$N" "$SCRATCH/conflict-comment" || exit 1
  fi
  jq --arg reason "Merge of main conflicted in: $(jq -r .conflicts "$JOURNAL"); a person must resolve the conflict." '.action = "block" | .reason = $reason' "$CARD" > "$SCRATCH/block-card" || exit 1
  bash "$SCRIPTS/standalone/maintenance.sh" "$SCRATCH/block-card" "$SCRATCH" || exit 1
  jq --arg before "$BEFORE" '.after = $before | .completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1
  exit 0
fi
AFTER="$(jq -r .after "$JOURNAL")"; [[ "$AFTER" =~ ^[0-9a-f]{40}$ ]] || exit 1
INFO="$(pr_info)" || exit 1
identity <<<"$INFO" || exit 1
REMOTE_HEAD="$(remote_head)" || exit 1
[ "$(jq -r .headRefOid <<<"$INFO")" = "$REMOTE_HEAD" ] || exit 1
if [ "$REMOTE_HEAD" = "$BEFORE" ] && [ "$AFTER" != "$BEFORE" ]; then
  card_state || exit 1
  [ -d "$CLONE/.git" ] && [ ! -L "$CLONE/.git" ] && [ "$(git -C "$CLONE" rev-parse HEAD)" = "$AFTER" ] || exit 1
  # The lease enforces the exact old head even if the remote rewinds between
  # our read and push. Independently require a fast-forward before permitting it.
  git -C "$CLONE" merge-base --is-ancestor "$BEFORE" "$AFTER" || exit 1
  git -C "$CLONE" -c protocol.file.allow=always -c core.hooksPath=/dev/null push --force-with-lease="refs/heads/$BRANCH:$BEFORE" "$REMOTE_DIR" "HEAD:refs/heads/$BRANCH" >/dev/null || exit 1
elif [ "$REMOTE_HEAD" != "$AFTER" ]; then
  echo 'PR head changed before update' >&2; exit 1
fi
INFO="$(pr_info)" || exit 1
identity <<<"$INFO" && [ "$(jq -r .headRefOid <<<"$INFO")" = "$AFTER" ] && [ "$(remote_head)" = "$AFTER" ] && card_state || exit 1
NOTE="$(bash "$SCRIPTS/note.sh" get "$N")" || exit 1
if [ "$AFTER" != "$BEFORE" ]; then
  jq -e --argjson note "$NOTE" '.prior_review == $note.last_review or $note.last_review == null' "$JOURNAL" >/dev/null || { echo 'review changed during branch update' >&2; exit 1; }
fi
CHANGED=false
[ "$AFTER" = "$BEFORE" ] || CHANGED=true
jq -n --arg sha "$AFTER" --argjson changed "$CHANGED" '{last_update:{sha:$sha,base:"main",changed:$changed}} + (if $changed then {last_review:null} else {} end)' > "$SCRATCH/patch" || exit 1
bash "$SCRIPTS/note.sh" merge "$N" "$SCRATCH/patch" || exit 1
jq '.completed = true' "$JOURNAL" > "$JOURNAL.tmp.$$" && mv "$JOURNAL.tmp.$$" "$JOURNAL" || exit 1

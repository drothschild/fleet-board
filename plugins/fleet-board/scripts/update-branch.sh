#!/usr/bin/env bash
# update-branch.sh - brings a card's PR branch up to date with its base branch
# by a merge commit and a plain push. Never rebases, never force-pushes.
#
# Usage: update-branch.sh <n> <pr> <branch> <worktree>
#
# Carries out tick-plan.sh's update_branch action. In <worktree> (the card's
# worktree, on <branch>) it fetches origin and merges origin/<base> into the
# branch, where <base> is the PR's baseRefName. Then:
#   clean merge     push origin <branch> (when the merge moved HEAD); the card
#                   stays where it is, and the manager note gains last_update
#                   {sha, base, changed}. When the merge changed files, the
#                   note's last_review is also set to null, so the reviewed-sha
#                   baseline no longer covers the head and the next tick plans
#                   a review round.
#   conflict        the merge is aborted (nothing is pushed), a comment names
#                   the conflicted files, and the card moves to blocked. A
#                   conflict is never resolved here: a person resolves it.
# Exit codes: 0 done (clean or blocked), 1 a git, gh or board step failed,
# 2 usage error.

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

[ $# -eq 4 ] || fb_die 2 "usage: update-branch.sh <n> <pr> <branch> <worktree>"
N="$1"; PR="$2"; BRANCH="$3"; WT="$4"
fb_valid_number "$N" || fb_die 2 "card number must be numeric, got: $N"
fb_valid_number "$PR" || fb_die 2 "PR number must be numeric, got: $PR"
case "$BRANCH" in
  fleet/[0-9]*-*) ;;
  *) fb_die 2 "branch must be fleet/<n>-<slug>, got: $BRANCH" ;;
esac
case "$BRANCH" in *[!A-Za-z0-9/._-]*) fb_die 2 "invalid branch: $BRANCH" ;; esac
[ -d "$WT" ] || fb_die 2 "worktree not found: $WT"

fb_load_config

BASE="$(gh pr view "$PR" --repo "$FLEET_REPO" --json baseRefName --jq .baseRefName)" \
  || fb_die 1 "cannot read the base branch of PR #$PR"
case "$BASE" in
  ''|*[!A-Za-z0-9/._-]*) fb_die 1 "unexpected base branch for PR #$PR: $BASE" ;;
esac

TMP="$(mktemp)" || fb_die 1 "cannot create a temp file"
trap 'rm -f "$TMP"' EXIT

git -C "$WT" fetch origin || fb_die 1 "git fetch origin failed in $WT"
BEFORE="$(git -C "$WT" rev-parse HEAD)" || fb_die 1 "cannot read HEAD in $WT"

git -C "$WT" merge --no-edit "origin/$BASE" >/dev/null 2>&1
RC=$?
CONFLICTS="$(git -C "$WT" diff --name-only --diff-filter=U)"

if [ "$RC" -ne 0 ] || [ -n "$CONFLICTS" ]; then
  [ -n "$CONFLICTS" ] || fb_die 1 "git merge origin/$BASE failed in $WT without a conflict"
  git -C "$WT" merge --abort || fb_die 1 "git merge --abort failed in $WT"
  {
    printf 'Merging `%s` into `%s` conflicts in:\n\n' "origin/$BASE" "$BRANCH"
    printf '%s\n' "$CONFLICTS" | sed 's/^/- /'
    printf '\nThe merge was aborted and nothing was pushed. Resolve the conflict by hand, then move the card back.\n'
  } > "$TMP"
  bash "$FLEET_SCRIPTS/board-comment.sh" "$N" "$TMP" || fb_die 1 "cannot comment on #$N"
  bash "$FLEET_SCRIPTS/board-move.sh" "$N" blocked || fb_die 1 "cannot move #$N to blocked"
  jq -n '{state: "blocked"}' > "$TMP"
  bash "$FLEET_SCRIPTS/note.sh" merge "$N" "$TMP" || fb_die 1 "cannot update the note on #$N"
  exit 0
fi

AFTER="$(git -C "$WT" rev-parse HEAD)" || fb_die 1 "cannot read HEAD in $WT"
CHANGED=false
if [ "$AFTER" != "$BEFORE" ] && [ -n "$(git -C "$WT" diff --name-only "$BEFORE" "$AFTER")" ]; then
  CHANGED=true
fi

if [ "$AFTER" != "$BEFORE" ]; then
  git -C "$WT" push origin "$BRANCH" || fb_die 1 "git push origin $BRANCH failed"
fi

jq -n --arg sha "$AFTER" --arg base "$BASE" --argjson changed "$CHANGED" \
  '{last_update: {sha: $sha, base: $base, changed: $changed}}
   + (if $changed then {last_review: null} else {} end)' > "$TMP"
bash "$FLEET_SCRIPTS/note.sh" merge "$N" "$TMP" || fb_die 1 "cannot update the note on #$N"

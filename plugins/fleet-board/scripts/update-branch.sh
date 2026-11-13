#!/usr/bin/env bash
# update-branch.sh - brings a card's PR branch up to date with its base branch
# by a merge commit and a plain push. Never rebases, never force-pushes.
#
# Usage: update-branch.sh <n> <pr> <branch> <worktree>
#
# Carries out tick-plan.sh's update_branch action. In <worktree> (the card's
# worktree, which must have <branch> checked out) it fetches origin and merges
# origin/<base> into the branch, where <base> is the PR's baseRefName. Then:
#   clean merge     push origin <branch> whenever the local branch differs from
#                   origin/<branch>; after the push it fetches and checks that
#                   origin/<branch> is the local head. The card stays where it
#                   is, and the manager note gains last_update {sha, base,
#                   changed}. last_review is left as it is: the next tick plans
#                   merge when this clean merge of the base is the only change
#                   since the review, and review otherwise (tick-plan.sh,
#                   review-drift.sh).
#   version-only    only with supervisor.version_files set: every conflicted
#   conflict        file matches it, is a regular JSON file, and every conflict
#                   hunk differs only in lines setting "version": "X.Y.Z"
#                   (semver, optional -prerelease) that match pairwise apart
#                   from the value. Each such line is resolved from its own two
#                   sides: the higher one, or the base side + 1 patch (a
#                   prerelease base: its core) when that is not strictly above
#                   the base side. Lines outside the hunks are untouched, each
#                   file must still parse with jq, then the merge is committed
#                   and pushed like a clean merge (exit 0, last_update).
#   versions not    after any merge, with supervisor.version_files set: each
#   above the base  "version" key the branch's own non-merge commits changed in a
#                   version file (version-lib.sh) whose merged value is not
#                   strictly above origin/<base>'s is raised to base + 1 patch, key
#                   by key, in one more commit. Other keys are left alone.
#   conflict        the merge is aborted (nothing is pushed), a comment names
#                   the conflicted files (and, with version_files set, why they
#                   were not resolved here), the manager note gains
#                   conflicted_files (every file, test files included) and the
#                   card stays where it is. tick-plan.sh then plans the fixer
#                   with those files as its findings. The script exits 1 and
#                   the manager counts that as one failed action (note.sh
#                   fail); the script does not count it too. When any
#                   conflicted file is not version-only nothing is resolved or
#                   committed.
#   any failure     once the merge has started, any non-zero exit (a rejected
#                   push, a failed raise, a failed commit) aborts a merge in
#                   progress, restores files this run wrote, and resets the
#                   branch with git reset --keep to the head it had before this
#                   run, so the next run merges again instead of finding nothing
#                   to do. A refused reset --keep is reported; the exit stays 1.
# Exit codes: 0 done (clean merge), 1 a git, gh or board step failed or the
# merge conflicted (the manager counts the failure), 2 usage error.

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/version-lib.sh"

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

VFILES="$(jq -c '.supervisor.version_files // []' <<<"$FLEET_CFG")" || fb_die 1 "cannot read supervisor.version_files"
JQ_LIB="$(cat "$FLEET_SCRIPTS/path-glob.jq" "$FLEET_SCRIPTS/versions.jq")" || fb_die 1 "cannot read path-glob.jq or versions.jq"
VL_JQ="$JQ_LIB"

TMP="$(mktemp)" || fb_die 1 "cannot create a temp file"
TMPD="$(mktemp -d)" || { rm -f "$TMP"; fb_die 1 "cannot create a temp directory"; }
: > "$TMPD/written"
MERGE_STARTED=""
BEFORE=""

# on_exit: after the merge has started, a non-zero exit puts the branch back where it
# was: abort a merge in progress, restore the files this run wrote, git reset --keep
on_exit() {
  local rc=$? now remote f
  if [ "$rc" -ne 0 ] && [ -n "$MERGE_STARTED" ] && [ -n "$BEFORE" ]; then
    if git -C "$WT" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
      git -C "$WT" merge --abort >/dev/null 2>&1 || true
    fi
    while IFS= read -r f; do
      [ -n "$f" ] && git -C "$WT" checkout -q HEAD -- "$f" 2>/dev/null
    done < "$TMPD/written"
    now="$(git -C "$WT" rev-parse HEAD 2>/dev/null)" || now=""
    remote="$(git -C "$WT" rev-parse -q --verify "refs/remotes/origin/$BRANCH" 2>/dev/null)" || remote=""
    # A head origin already has is never rewound (that would leave local behind it)
    if [ -n "$now" ] && [ "$now" != "$BEFORE" ] && [ "$now" != "$remote" ]; then
      if git -C "$WT" reset -q --keep "$BEFORE"; then
        printf 'update-branch: reset %s from %s back to %s\n' "$BRANCH" "$now" "$BEFORE" >&2
      else
        printf 'update-branch: git reset --keep %s was refused in %s; %s is left at %s, reset it by hand\n' \
          "$BEFORE" "$WT" "$BRANCH" "$now" >&2
      fi
    fi
  fi
  rm -f "$TMP"; rm -rf "$TMPD"
  exit "$rc"
}
trap on_exit EXIT

# vf_match <path>: exit 0 when supervisor.version_files matches the path
vf_match() {
  [ "$(jq -rn --arg p "$1" --argjson g "$VFILES" "$JQ_LIB"' $p | pg_match($g)')" = true ]
}

# vc_resolve <conflicted-files>: resolves and commits the merge when every file is
# version-only. Exit 1 with nothing written or staged otherwise (the reason is
# in $TMPD/why), or exit 1 after a failed commit.
vc_resolve() {
  local f i=0 res why
  : > "$TMPD/why"
  if [ "$VFILES" = '[]' ]; then
    printf 'supervisor.version_files is empty\n' > "$TMPD/why"; return 1
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    i=$((i + 1))
    why=""
    if ! vf_match "$f"; then why="$f does not match supervisor.version_files"
    else
      case "$f" in *.json) ;; *) why="$f is not a JSON file" ;; esac
    fi
    if [ -z "$why" ]; then
      if [ -L "$WT/$f" ]; then why="$f is a symlink"
      elif [ ! -f "$WT/$f" ]; then why="$f is not a regular file in the worktree"
      fi
    fi
    if [ -z "$why" ]; then
      if ! res="$(jq -Rs -c "$JQ_LIB"' vc_resolve' "$WT/$f" 2>/dev/null)"; then
        why="$f cannot be read"
      elif [ "$(jq -r 'has("why")' <<<"$res")" = true ]; then
        why="$f: $(jq -r .why <<<"$res")"
      else
        jq -j .text <<<"$res" > "$TMPD/$i" || why="$f cannot be resolved"
        [ -n "$why" ] || jq -e . "$TMPD/$i" >/dev/null 2>&1 || why="$f is not valid JSON after resolution"
      fi
    fi
    if [ -n "$why" ]; then printf '%s\n' "$why" > "$TMPD/why"; return 1; fi
  done <<EOF_FILES
$1
EOF_FILES
  i=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    i=$((i + 1))
    cat "$TMPD/$i" > "$WT/$f" || { printf 'cannot write %s\n' "$f" > "$TMPD/why"; return 1; }
    git -C "$WT" add -- "$f" || { printf 'git add %s failed\n' "$f" > "$TMPD/why"; return 1; }
  done <<EOF_FILES
$1
EOF_FILES
  if ! git -C "$WT" commit -q -m "Merge origin/$BASE into $BRANCH: resolve version-only conflicts" >/dev/null; then
    printf 'git commit of the resolved merge failed\n' > "$TMPD/why"; return 1
  fi
  return 0
}

# vr_raise: with version_files set, raises each version key the branch's own commits
# changed (version-lib.sh) whose merged value is not strictly above origin/<base>,
# then commits. Exit 1 (with a message) when a file cannot be read or edited; the
# EXIT trap then undoes the merge.
vr_raise() {
  local f changes summary="" i=0
  [ "$VFILES" != '[]' ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in *.json) ;; *) continue ;; esac
    vf_match "$f" || continue
    if [ ! -f "$WT/$f" ] || [ -L "$WT/$f" ]; then
      fb_die 1 "version file $f, which the branch changed, is missing in $WT or is not a regular file"
    fi
    changes="$(vl_changes "$WT" "origin/$BASE" HEAD "$f" "$TMPD")" \
      || fb_die 1 "cannot read the history of $f against origin/$BASE"
    [ -n "$changes" ] && [ "$changes" != '[]' ] || continue
    i=$((i + 1))
    jq -Rsj --argjson c "$changes" "$JQ_LIB"' vr_apply($c)' "$WT/$f" > "$TMPD/raised" 2> "$TMPD/err" \
      || fb_die 1 "cannot raise the versions in $f: $(sed 's/^jq: error[^:]*: //' "$TMPD/err" | head -1)"
    jq -e . "$TMPD/raised" >/dev/null 2>&1 || fb_die 1 "$f is not valid JSON after raising its versions"
    printf '%s\n' "$f" >> "$TMPD/written"
    cat "$TMPD/raised" > "$WT/$f" || fb_die 1 "cannot write $f"
    git -C "$WT" add -- "$f" || fb_die 1 "git add $f failed"
    summary="$summary$(jq -r --arg f "$f" '.[] | "\n- \($f) \(.path | map(tostring) | join(".")): \(.from) -> \(.to)"' <<<"$changes")"
  done <<EOF_FILES
$(vl_files "$WT" "origin/$BASE" HEAD)
EOF_FILES
  [ "$i" -gt 0 ] || return 0
  git -C "$WT" commit -q -m "Raise versions above origin/$BASE$(printf '\n%s' "$summary")" >/dev/null \
    || fb_die 1 "git commit of the raised versions failed in $WT"
}

CUR="$(git -C "$WT" symbolic-ref -q --short HEAD)" || CUR=""
[ "$CUR" = "$BRANCH" ] || fb_die 1 "$WT has ${CUR:-a detached HEAD} checked out, not $BRANCH"

git -C "$WT" fetch origin || fb_die 1 "git fetch origin failed in $WT"
BEFORE="$(git -C "$WT" rev-parse HEAD)" || fb_die 1 "cannot read HEAD in $WT"

MERGE_STARTED=1
git -C "$WT" merge --no-edit "origin/$BASE" >/dev/null 2>&1
RC=$?
CONFLICTS="$(git -C "$WT" diff --name-only --diff-filter=U)"

WHY=""
if [ -n "$CONFLICTS" ]; then
  if vc_resolve "$CONFLICTS"; then
    printf 'update-branch: resolved version-only conflicts in %s\n' "$(printf '%s\n' "$CONFLICTS" | paste -s -d ' ' -)" >&2
    RC=0; CONFLICTS=""
  else
    WHY="$(cat "$TMPD/why")"
  fi
fi

if [ "$RC" -ne 0 ] || [ -n "$CONFLICTS" ]; then
  [ -n "$CONFLICTS" ] || fb_die 1 "git merge origin/$BASE failed in $WT without a conflict"
  git -C "$WT" merge --abort || fb_die 1 "git merge --abort failed in $WT"
  {
    printf 'Merging `%s` into `%s` conflicts in:\n\n' "origin/$BASE" "$BRANCH"
    printf '%s\n' "$CONFLICTS" | sed 's/^/- /'
    if [ "$VFILES" != '[]' ] && [ -n "$WHY" ]; then
      printf '\nNot resolved automatically as a version-only conflict: %s\n' "$WHY"
    fi
    printf '\nThe merge was aborted and nothing was pushed. The card stays where it is; the next tick dispatches the fixer to resolve these files.\n'
  } > "$TMP"
  bash "$FLEET_SCRIPTS/board-comment.sh" "$N" "$TMP" || fb_die 1 "cannot comment on #$N"
  # One note write: the files for the fixer. The exit 1 below is counted once,
  # by the manager (2.C.4), so a card that keeps conflicting is still blocked
  # by the action_failures rule instead of looping
  printf '%s\n' "$CONFLICTS" | jq -R . | jq -s '{conflicted_files: .}' > "$TMP" \
    || fb_die 1 "cannot build the note patch for #$N"
  bash "$FLEET_SCRIPTS/note.sh" merge "$N" "$TMP" || fb_die 1 "cannot update the note on #$N"
  if [ "$VFILES" != '[]' ] && [ -n "$WHY" ]; then
    fb_die 1 "merge of origin/$BASE into $BRANCH conflicts; not version-only ($WHY); recorded the files for the fixer"
  fi
  fb_die 1 "merge of origin/$BASE into $BRANCH conflicts; recorded the files for the fixer"
fi

vr_raise

AFTER="$(git -C "$WT" rev-parse HEAD)" || fb_die 1 "cannot read HEAD in $WT"
CHANGED=false
if [ "$AFTER" != "$BEFORE" ] && [ -n "$(git -C "$WT" diff --name-only "$BEFORE" "$AFTER")" ]; then
  CHANGED=true
fi

# Push whenever origin/<branch> is not the local head (an earlier run may have
# merged without a successful push), then check the push landed.
REMOTE="$(git -C "$WT" rev-parse -q --verify "refs/remotes/origin/$BRANCH")" || REMOTE=""
if [ "$AFTER" != "$REMOTE" ]; then
  # A rejected push exits 1; the EXIT trap resets the branch to $BEFORE
  git -C "$WT" push origin "$BRANCH" \
    || fb_die 1 "git push origin $BRANCH was rejected; resetting $BRANCH to $BEFORE so the next run merges again"
  git -C "$WT" fetch -q origin || fb_die 1 "git fetch origin failed in $WT after the push"
  PUSHED="$(git -C "$WT" rev-parse -q --verify "refs/remotes/origin/$BRANCH")" || PUSHED=""
  [ "$PUSHED" = "$AFTER" ] || fb_die 1 "after the push origin/$BRANCH is ${PUSHED:-missing}, not $AFTER"
fi
# origin has this head now: nothing after this point may rewind the branch
MERGE_STARTED=""

jq -n --arg sha "$AFTER" --arg base "$BASE" --argjson changed "$CHANGED" \
  '{last_update: {sha: $sha, base: $base, changed: $changed}}' > "$TMP"
bash "$FLEET_SCRIPTS/note.sh" merge "$N" "$TMP" || fb_die 1 "cannot update the note on #$N"

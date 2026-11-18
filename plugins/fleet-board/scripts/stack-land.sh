#!/usr/bin/env bash
# stack-land.sh - lands a stacked child on the default branch after its parent merged.
# Never rebases, never force-pushes.
#
# Usage: stack-land.sh <n> <pr-or-dash> <branch> <worktree>
#
# Carries out tick-plan.sh's land action. In <worktree> (the card's worktree, with <branch>
# checked out), steps in order:
#   1. the note's stack (none: exit 0) and the parent's pr from the parent's note;
#      gh pr view <parent pr> --json state,headRefOid,mergeCommit. Not MERGED: exit 3.
#   2. git fetch origin and refs/pull/<parent pr>/head. The squash commit (mergeCommit.oid)
#      is not an ancestor of the default branch head (origin/HEAD, else origin/main): exit 3.
#   3. Walks the first-parent chain from HEAD down to stack.start. A merge commit whose second
#      parent is neither an ancestor of the parent's final head nor on the default branch:
#      exit 4 ("the child followed commits of #<parent> that never merged").
#   4. The final head is not an ancestor of HEAD: git merge --no-edit <final head>. A conflict
#      aborts the merge: exit 4.
#   5. stack-bridge.sh commit <worktree> <final head> <squash>: its exit 3 or 4 is exit 4.
#   6. A plain git push origin <branch>, then a fetch and a check that origin has the local
#      head. A rejected push puts the branch back with git reset --keep to the head before
#      step 4: exit 1.
#   7. With a PR: gh pr edit <pr> --repo <repo> --base <default branch>.
#   8. The note: stack null, landed {parent, parent_head, squash, sha (the bridge commit)}.
#   9. With a PR: update-branch.sh with the same four arguments, and its exit code.
# Exit: 0 landed (or nothing to do), 1 failure, 2 usage, 3 wait (nothing changed),
# 4 attention (nothing pushed; the note's stack.attention names the reason and one comment
# is posted on the card).

set -uo pipefail
unset CDPATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

USAGE="usage: stack-land.sh <n> <pr-or-dash> <branch> <worktree>"
[ $# -eq 4 ] || fb_die 2 "$USAGE"
N="$1"; PR="$2"; BRANCH="$3"; WT="$4"
fb_valid_number "$N" || fb_die 2 "card number must be numeric, got: $N"
if [ "$PR" != "-" ]; then fb_valid_number "$PR" || fb_die 2 "PR number must be numeric or -, got: $PR"; fi
case "$BRANCH" in
  fleet/[0-9]*-*) ;;
  *) fb_die 2 "branch must be fleet/<n>-<slug>, got: $BRANCH" ;;
esac
case "$BRANCH" in *[!A-Za-z0-9/._-]*) fb_die 2 "invalid branch: $BRANCH" ;; esac
[ -d "$WT" ] || fb_die 2 "worktree not found: $WT"

fb_load_config

TMP="$(mktemp)" || fb_die 1 "cannot create a temp file"
trap 'rm -f "$TMP"' EXIT

NOTE="$(bash "$FLEET_SCRIPTS/note.sh" get "$N" </dev/null 2>/dev/null)" || fb_die 1 "cannot read the manager note of #$N"
STACK="$(jq -c 'if (.stack | type) == "object" then .stack else empty end' <<<"$NOTE" 2>/dev/null)" \
  || fb_die 1 "cannot read the manager note of #$N"
[ -n "$STACK" ] || exit 0 # not stacked, or already landed

PARENT="$(jq -r '.parent' <<<"$STACK")"
START="$(jq -r '.start' <<<"$STACK")"
fb_valid_number "$PARENT" || fb_die 1 "the note of #$N has no valid stack.parent"
case "$START" in *[!0-9a-f]*|'') fb_die 1 "the note of #$N has no valid stack.start" ;; esac

PNOTE="$(bash "$FLEET_SCRIPTS/note.sh" get "$PARENT" </dev/null 2>/dev/null)" || fb_die 1 "cannot read the manager note of #$PARENT"
PPR="$(jq -r 'if (.pr | type) == "number" and .pr == (.pr | floor) and .pr > 0 then (.pr | tostring) else "" end' <<<"$PNOTE" 2>/dev/null)"
[ -n "$PPR" ] || fb_die 1 "the manager note of #$PARENT names no PR"

VIEW="$(gh pr view "$PPR" --repo "$FLEET_REPO" --json state,headRefOid,mergeCommit)" \
  || fb_die 1 "cannot read PR #$PPR (the parent's PR)"
PSTATE="$(jq -r '.state // ""' <<<"$VIEW" 2>/dev/null)" || fb_die 1 "cannot read the state of PR #$PPR"
if [ "$PSTATE" != MERGED ]; then
  echo "stack-land: PR #$PPR is ${PSTATE:-in an unknown state}, not MERGED; waiting" >&2
  exit 3
fi
FINAL="$(jq -r '.headRefOid // "" | strings' <<<"$VIEW" 2>/dev/null)"
SQUASH="$(jq -r '.mergeCommit.oid // "" | strings' <<<"$VIEW" 2>/dev/null)"
case "$FINAL$SQUASH" in *[!0-9a-f]*) fb_die 1 "PR #$PPR has an unreadable head or merge commit" ;; esac
[ ${#FINAL} -eq 40 ] && [ ${#SQUASH} -eq 40 ] || fb_die 1 "PR #$PPR names no final head or merge commit"

CUR="$(git -C "$WT" symbolic-ref -q --short HEAD)" || CUR=""
[ "$CUR" = "$BRANCH" ] || fb_die 1 "$WT has ${CUR:-a detached HEAD} checked out, not $BRANCH"

git -C "$WT" fetch -q origin || fb_die 1 "git fetch origin failed in $WT"
# The parent's final head, when its branch is gone from origin; a missing ref is not an error
# here (the object check below decides)
git -C "$WT" fetch -q origin "refs/pull/$PPR/head" >/dev/null 2>&1 || true

# The default branch: origin/HEAD, else origin/main
DEFREF=""; DEFAULT=""
if DEFREF="$(git -C "$WT" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)" && [ -n "$DEFREF" ]; then
  DEFAULT="${DEFREF#refs/remotes/origin/}"
elif git -C "$WT" rev-parse -q --verify refs/remotes/origin/main >/dev/null 2>&1; then
  DEFREF=refs/remotes/origin/main; DEFAULT=main
else
  fb_die 1 "cannot find the default branch (no origin/HEAD, no origin/main)"
fi
case "$DEFAULT" in ''|*[!A-Za-z0-9/._-]*) fb_die 1 "unexpected default branch: $DEFAULT" ;; esac
git -C "$WT" rev-parse -q --verify "$DEFREF^{commit}" >/dev/null 2>&1 || fb_die 1 "cannot read $DEFREF"

git -C "$WT" cat-file -e "$FINAL^{commit}" 2>/dev/null \
  || fb_die 1 "the final head $FINAL of PR #$PPR is not on origin (neither its branch nor refs/pull/$PPR/head has it)"
if ! git -C "$WT" cat-file -e "$SQUASH^{commit}" 2>/dev/null \
   || ! git -C "$WT" merge-base --is-ancestor "$SQUASH" "$DEFREF" 2>/dev/null; then
  echo "stack-land: the squash commit ${SQUASH:0:7} is not on origin/$DEFAULT yet; waiting" >&2
  exit 3
fi

BEFORE="$(git -C "$WT" rev-parse HEAD)" || fb_die 1 "cannot read HEAD in $WT"

# attention <reason>: nothing is pushed; stack.attention is set and one comment posted, exit 4
attention() {
  local reason="$1"
  reason="$(printf '%s' "$reason" | tr -d '\000-\037' | cut -c1-300)"
  jq -n --argjson s "$STACK" --arg r "$reason" '{stack: ($s + {attention: $r})}' > "$TMP" \
    || fb_die 1 "cannot build the note patch for #$N"
  bash "$FLEET_SCRIPTS/note.sh" merge "$N" "$TMP" || fb_die 1 "cannot update the note on #$N"
  {
    printf 'Landing `%s` on `%s` needs a person: %s.\n\n' "$BRANCH" "$DEFAULT" "$reason"
    printf 'Nothing was pushed. The planner holds the land step until `stack.attention` is cleared.\n'
  } > "$TMP"
  bash "$FLEET_SCRIPTS/board-comment.sh" "$N" "$TMP" || fb_die 1 "cannot comment on #$N"
  exit 4
}

# 3. every merge on the first-parent chain down to stack.start joined something that merged
git -C "$WT" merge-base --is-ancestor "$START" HEAD 2>/dev/null \
  || fb_die 1 "stack.start ${START:0:7} is not an ancestor of $BRANCH in $WT"
CHAIN="$(git -C "$WT" rev-list --first-parent --merges --parents "$START..HEAD")" \
  || fb_die 1 "cannot walk the history of $BRANCH in $WT"
while read -r _sha _p1 p2 _rest; do
  [ -n "${_sha:-}" ] || continue
  [ -n "${p2:-}" ] || continue
  if git -C "$WT" merge-base --is-ancestor "$p2" "$FINAL" 2>/dev/null \
     || git -C "$WT" merge-base --is-ancestor "$p2" "$DEFREF" 2>/dev/null; then
    continue
  fi
  attention "the child followed commits of #$PARENT that never merged"
done <<EOF_CHAIN
$CHAIN
EOF_CHAIN

# on_fail: the branch goes back to where it was before this run changed it
restore() {
  local now
  if git -C "$WT" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    git -C "$WT" merge --abort >/dev/null 2>&1 || true
  fi
  now="$(git -C "$WT" rev-parse HEAD 2>/dev/null)" || now=""
  if [ -n "$now" ] && [ "$now" != "$BEFORE" ]; then
    git -C "$WT" reset -q --keep "$BEFORE" >/dev/null 2>&1 \
      || printf 'stack-land: git reset --keep %s was refused in %s; %s is left at %s, reset it by hand\n' "$BEFORE" "$WT" "$BRANCH" "$now" >&2
  fi
}

# 4. the parent's final head, when the child had not merged it
if ! git -C "$WT" merge-base --is-ancestor "$FINAL" HEAD 2>/dev/null; then
  if ! git -C "$WT" merge --no-edit "$FINAL" >/dev/null 2>&1; then
    FILES="$(git -C "$WT" diff --name-only --diff-filter=U | paste -s -d ',' - | sed 's/,/, /g')"
    git -C "$WT" merge --abort >/dev/null 2>&1 || true
    [ -n "$FILES" ] || fb_die 1 "git merge of the final head of #$PARENT failed in $WT without a conflict"
    attention "merging the final head of #$PARENT conflicts in $FILES"
  fi
fi

# 5. the bridge to the squash
BOUT="$(bash "$FLEET_SCRIPTS/stack-bridge.sh" commit "$WT" "$FINAL" "$SQUASH" 2>/dev/null)"
BRC=$?
case "$BRC" in
  0) ;;
  3)
    FILES="$(printf '%s\n' "$BOUT" | sed '/^$/d' | paste -s -d ',' - | sed 's/,/, /g')"
    restore
    attention "landing on $DEFAULT conflicts in ${FILES:-an unknown file}"
    ;;
  4)
    restore
    attention "stacking needs git 2.40 or later"
    ;;
  *)
    restore
    fb_die 1 "stack-bridge.sh commit failed (exit $BRC) in $WT"
    ;;
esac

# 6. push, fetch, check
HEADNOW="$(git -C "$WT" rev-parse HEAD)" || { restore; fb_die 1 "cannot read HEAD in $WT"; }
if ! git -C "$WT" push origin "$BRANCH"; then
  restore
  fb_die 1 "git push origin $BRANCH was rejected; put $BRANCH back at ${BEFORE:0:7}"
fi
if ! git -C "$WT" fetch -q origin; then
  restore
  fb_die 1 "git fetch origin failed in $WT after the push"
fi
PUSHED="$(git -C "$WT" rev-parse -q --verify "refs/remotes/origin/$BRANCH" 2>/dev/null)" || PUSHED=""
if [ "$PUSHED" != "$HEADNOW" ]; then
  restore
  fb_die 1 "after the push origin/$BRANCH is ${PUSHED:-missing}, not $HEADNOW"
fi

# 7. the PR's base
if [ "$PR" != "-" ]; then
  gh pr edit "$PR" --repo "$FLEET_REPO" --base "$DEFAULT" || fb_die 1 "gh pr edit $PR --base $DEFAULT failed"
fi

# 8. the note: the bridge commit is the first-parent commit whose second parent is the squash
BRIDGE="$(git -C "$WT" rev-list --first-parent --parents "$START..HEAD" | awk -v s="$SQUASH" 'NF == 3 && $3 == s { print $1; exit }')"
[ -n "$BRIDGE" ] || BRIDGE="$HEADNOW"
jq -n --argjson p "$PARENT" --arg ph "$FINAL" --arg sq "$SQUASH" --arg sha "$BRIDGE" \
  '{stack: null, landed: {parent: $p, parent_head: $ph, squash: $sq, sha: $sha}}' > "$TMP" \
  || fb_die 1 "cannot build the note patch for #$N"
bash "$FLEET_SCRIPTS/note.sh" merge "$N" "$TMP" || fb_die 1 "cannot update the note on #$N"

# 9. bring the PR branch up to date with its (new) base
if [ "$PR" != "-" ]; then
  bash "$FLEET_SCRIPTS/update-branch.sh" "$N" "$PR" "$BRANCH" "$WT"
  exit $?
fi
exit 0

#!/usr/bin/env bash
# stack-bridge.sh: join a stacked child branch to its parent's squash commit. Pure git, never pushes.
#
#   stack-bridge.sh tree   <repo> <parent-head> <ours> <theirs>
#   stack-bridge.sh commit <worktree> <parent-head> <squash-sha>
#
# tree prints the tree sha of merging <theirs> into <ours> with <parent-head> as the merge base.
# commit makes a merge commit (parents HEAD, squash) with that tree and moves the checked-out
# branch and working tree to it. Prints the new head.
# Exit: 0 ok; 1 other git failure; 2 usage; 3 conflict (paths on stdout); 4 git older than 2.40.
set -u
unset CDPATH

usage() {
  echo "usage: stack-bridge.sh tree <repo> <parent-head> <ours> <theirs>" >&2
  echo "       stack-bridge.sh commit <worktree> <parent-head> <squash-sha>" >&2
  exit 2
}

check_version() {
  local v major minor
  v=$(git --version 2>/dev/null | sed -n 's/^git version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')
  [ -n "$v" ] || { echo "stack-bridge: cannot read the git version" >&2; return 1; }
  set -- $v
  major=$1; minor=$2
  if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 40 ]; }; then
    echo "stacking needs git 2.40 or later (found $major.$minor)" >&2
    return 4
  fi
  return 0
}

# do_tree <repo> <parent-head> <ours> <theirs>: prints tree sha (rc 0) or conflicted paths (rc 3).
do_tree() {
  local repo="$1" base="$2" ours="$3" theirs="$4" out rc tree
  out=$(git -C "$repo" merge-tree --write-tree --name-only --merge-base "$base" "$ours" "$theirs" 2>/dev/null)
  rc=$?
  tree=$(printf '%s\n' "$out" | sed -n '1p')
  if [ "$rc" -eq 0 ]; then
    case "$tree" in
      *[!0-9a-f]*|"") return 1 ;;
    esac
    printf '%s\n' "$tree"
    return 0
  fi
  if [ "$rc" -eq 1 ]; then
    # Conflict: line 1 is the tree, then conflicted paths up to a blank line.
    printf '%s\n' "$out" | sed '1d' | sed '/^$/,$d' | sort -u
    return 3
  fi
  return 1
}

[ $# -ge 1 ] || usage
mode="$1"; shift

case "$mode" in
  tree)
    [ $# -eq 4 ] || usage
    check_version; rc=$?; [ "$rc" -eq 0 ] || exit "$rc"
    do_tree "$1" "$2" "$3" "$4"
    exit $?
    ;;
  commit)
    [ $# -eq 3 ] || usage
    wt="$1"; parent="$2"; squash="$3"
    check_version; rc=$?; [ "$rc" -eq 0 ] || exit "$rc"
    git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || { echo "stack-bridge: not a git worktree: $wt" >&2; exit 1; }
    head=$(git -C "$wt" rev-parse --verify -q 'HEAD^{commit}') || { echo "stack-bridge: no HEAD" >&2; exit 1; }
    ph=$(git -C "$wt" rev-parse --verify -q "$parent^{commit}") || { echo "stack-bridge: unknown parent head: $parent" >&2; exit 1; }
    sq=$(git -C "$wt" rev-parse --verify -q "$squash^{commit}") || { echo "stack-bridge: unknown squash: $squash" >&2; exit 1; }
    if [ -n "$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
      echo "stack-bridge: the worktree has changes to tracked files" >&2
      exit 1
    fi
    git -C "$wt" merge-base --is-ancestor "$ph" "$head" || {
      echo "stack-bridge: parent head is not an ancestor of HEAD" >&2
      exit 1
    }
    # Already bridged: the squash is part of HEAD, so print HEAD and add nothing.
    if git -C "$wt" merge-base --is-ancestor "$sq" "$head"; then
      printf '%s\n' "$head"
      exit 0
    fi
    tree=$(do_tree "$wt" "$ph" "$head" "$sq"); rc=$?
    if [ "$rc" -ne 0 ]; then
      [ -z "$tree" ] || printf '%s\n' "$tree"
      exit "$rc"
    fi
    msg="Bridge to the squash of $(git -C "$wt" rev-parse --short "$ph") ($(git -C "$wt" rev-parse --short "$sq"))"
    new=$(git -C "$wt" commit-tree "$tree" -p "$head" -p "$sq" -m "$msg") || exit 1
    git -C "$wt" merge --ff-only -q "$new" >/dev/null 2>&1 || exit 1
    printf '%s\n' "$new"
    ;;
  *) usage ;;
esac

#!/usr/bin/env bash
# review-drift.sh - tells whether a PR head that moved past the last reviewed
# sha still counts as reviewed.
#
# Usage: review-drift.sh <reviewed-sha> <head-sha>
#
# Prints "reviewed" when every commit the PR made after <reviewed-sha> (the
# first-parent chain from <head-sha> down to it) is a merge of main whose tree
# equals the tree git merge-tree produces for its two parents: a clean merge
# that no reviewer needs to read again. Prints "unreviewed" for anything else:
# a non-merge commit, a merge that needed conflict resolution or carries extra
# changes, a chain that does not lead back to <reviewed-sha>, or commits git
# cannot read locally (it tries one `git fetch origin` first). Run it in the
# repository checkout. Used by tick-plan.sh (plan review instead of merge) and
# by the gate (refuse gh pr merge under merge.policy auto).
# Exit codes: 0 answered, 1 a lookup failed (the caller must fail closed),
# 2 usage error.

set -uo pipefail
unset CDPATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

[ $# -eq 2 ] || fb_die 2 "usage: review-drift.sh <reviewed-sha> <head-sha>"
FROM="$1"; HEAD_SHA="$2"
case "$FROM$HEAD_SHA" in *[!0-9a-fA-F]*|'') fb_die 2 "shas must be hex" ;; esac

fb_load_config

case "$HEAD_SHA" in "$FROM"*) echo reviewed; exit 0 ;; esac
case "$FROM" in "$HEAD_SHA"*) echo reviewed; exit 0 ;; esac
# A moved head needs review in read-only planning: fetching and merge-tree
# may write repository objects, so do not try to prove a clean merge here.
if [ "${FLEET_BOARD_PLAN_READ_ONLY:-}" = 1 ]; then
  echo unreviewed
  exit 0
fi

cmp="$(gh api "repos/$FLEET_REPO/compare/$FROM...$HEAD_SHA")" || fb_die 1 "cannot compare $FROM...$HEAD_SHA"
chain="$(jq -r --arg head "$HEAD_SHA" '
  (.commits | map({key: .sha, value: .}) | from_entries) as $by
  | def walk_chain($sha): if $by[$sha] == null then empty
      else $by[$sha] as $c | $c, ($c.parents[0].sha // empty | walk_chain(.)) end;
  [walk_chain($head)] | .[]
  | "\(.sha)\t\([.parents[].sha] | join(" "))\t\(.commit.message | split("\n")[0])"' <<<"$cmp" 2>/dev/null)" \
  || fb_die 1 "cannot read the compare answer"

have() { git cat-file -e "$1^{commit}" 2>/dev/null; }
FETCHED=0
need() {
  local s
  for s in "$@"; do
    have "$s" && continue
    [ "$FETCHED" = 1 ] || { FETCHED=1; git fetch -q origin >/dev/null 2>&1 || true; }
    have "$s" || return 1
  done
}

oldest_parent=""
count=0
TAB="$(printf '\t')"
while IFS="$TAB" read -r sha parents subject; do
  [ -n "$sha" ] || continue
  count=$((count + 1))
  set -- $parents
  oldest_parent="${1:-}"
  [ $# -eq 2 ] || { echo unreviewed; exit 0; }
  case "$subject" in *[Mm]erge*main*) ;; *) echo unreviewed; exit 0 ;; esac
  need "$sha" "$1" "$2" || { echo unreviewed; exit 0; }
  # exit 1 is a conflict: the merge needed a person's resolution
  mt="$(git merge-tree --write-tree "$1" "$2" 2>/dev/null)" || { echo unreviewed; exit 0; }
  merged="$(sed -n 1p <<<"$mt")"
  [ -n "$merged" ] || { echo unreviewed; exit 0; }
  [ "$merged" = "$(git rev-parse "$sha^{tree}" 2>/dev/null)" ] || { echo unreviewed; exit 0; }
done <<<"$chain"

[ "$count" -gt 0 ] || { echo unreviewed; exit 0; }
case "$oldest_parent" in "$FROM"*) echo reviewed ;; *) case "$FROM" in "$oldest_parent"*) echo reviewed ;; *) echo unreviewed ;; esac ;; esac

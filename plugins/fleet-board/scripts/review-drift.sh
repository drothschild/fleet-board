#!/usr/bin/env bash
# review-drift.sh - tells whether a PR head that moved past the last reviewed
# sha still counts as reviewed.
#
# Usage: review-drift.sh <reviewed-sha> <head-sha>
#
# Prints "reviewed" when every commit the PR made after <reviewed-sha> (the
# first-parent chain from <head-sha> down to it) is a merge of main whose tree
# equals the tree git merge-tree produces for its two parents: a clean merge
# that no reviewer needs to read again. With supervisor.version_files set, two
# more kinds count (update-branch.sh makes both): a single-parent commit that
# changed only version files, each only in whole-line "version" values and still
# valid JSON; and a merge of main whose tree differs from git's automatic merge
# only in version files, each of which, with its "version" values masked, is the
# clean three-way merge of the masked parents and is valid JSON.
# Prints "unreviewed" for anything else:
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

VFILES="$(jq -c '.supervisor.version_files // []' <<<"$FLEET_CFG" 2>/dev/null)" || VFILES='[]'
PG_JQ="$(cat "$FLEET_SCRIPTS/path-glob.jq")" || fb_die 1 "cannot read path-glob.jq"
VT="$(mktemp -d)" || fb_die 1 "cannot create a temp directory"
trap 'rm -rf "$VT"' EXIT

# vf_all <path>...: exit 0 when supervisor.version_files is set and matches every path
vf_all() {
  [ "$VFILES" != '[]' ] && [ $# -gt 0 ] || return 1
  [ "$(printf '%s\n' "$@" | jq -R . | jq -s --argjson g "$VFILES" "$PG_JQ"' all(.[]; pg_match($g))')" = true ]
}
# mask: stdin with every whole-line "version" string value replaced by "@"
mask() {
  sed -E 's/^([[:blank:]]*"version"[[:blank:]]*:[[:blank:]]*)"[^"]*"([[:blank:]]*,?[[:space:]]*)$/\1"@"\2/'
}
# blob <rev> <path> <out>: writes the file at <rev>, exit 1 when it is not there
blob() { git cat-file -e "$1:$2" 2>/dev/null && git show "$1:$2" > "$3" 2>/dev/null; }
# json_ok <file>: exit 0 when the file is one valid JSON value
json_ok() { jq -e . "$1" >/dev/null 2>&1; }

# version_raise <sha> <parent>: exit 0 when the commit changed only version files,
# each only in whole-line "version" values, and every one is still valid JSON
version_raise() {
  local st p list paths=""
  list="$(git diff-tree --no-commit-id --no-renames -r --name-status "$2" "$1" 2>/dev/null)" || return 1
  [ -n "$list" ] || return 1
  while IFS="$TAB" read -r st p; do
    [ "$st" = M ] || return 1
    paths="$paths$p$TAB"
  done <<<"$list"
  local IFS="$TAB"
  set -- $1 $2 $paths
  local c="$1" par="$2"; shift 2
  vf_all "$@" || return 1
  for p in "$@"; do
    blob "$c" "$p" "$VT/new" && blob "$par" "$p" "$VT/old" || return 1
    json_ok "$VT/new" || return 1
    [ "$(mask < "$VT/new")" = "$(mask < "$VT/old")" ] || return 1
  done
}

# version_merge <sha> <p1> <p2> <mt-output> <mt-exit>: exit 0 when the merge's tree
# differs from git's automatic merge only in version files, and each such file
# with its "version" values masked is the clean three-way merge of the masked
# parents and is valid JSON
version_merge() {
  local c="$1" p1="$2" p2="$3" mt="$4" rc="$5" merged base paths p
  merged="$(sed -n 1p <<<"$mt")"
  [ -n "$merged" ] || return 1
  base="$(git merge-base "$p1" "$p2" 2>/dev/null | sed -n 1p)"
  [ -n "$base" ] || return 1
  paths="$(git diff-tree --no-commit-id --no-renames -r --name-only "$merged" "$c^{tree}" 2>/dev/null)" || return 1
  # merge-tree --name-only lists the conflicted paths after the tree, up to a blank line
  [ "$rc" = 0 ] || paths="$paths
$(sed -n '2,/^$/p' <<<"$mt")"
  paths="$(printf '%s\n' "$paths" | sed '/^$/d' | sort -u)"
  [ -n "$paths" ] || return 1
  local IFS='
'
  set -- $paths
  vf_all "$@" || return 1
  for p in "$@"; do
    blob "$c" "$p" "$VT/res" && blob "$p1" "$p" "$VT/o" && blob "$p2" "$p" "$VT/t" && blob "$base" "$p" "$VT/b" || return 1
    json_ok "$VT/res" || return 1
    mask < "$VT/o" > "$VT/om"; mask < "$VT/b" > "$VT/bm"; mask < "$VT/t" > "$VT/tm"
    git merge-file -p "$VT/om" "$VT/bm" "$VT/tm" > "$VT/mm" 2>/dev/null || return 1
    [ "$(mask < "$VT/res")" = "$(cat "$VT/mm")" ] || return 1
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
  if [ $# -eq 1 ]; then
    # a commit that only raises version lines (update-branch.sh's raise) needs no review
    need "$sha" "$1" && version_raise "$sha" "$1" && continue
    echo unreviewed; exit 0
  fi
  [ $# -eq 2 ] || { echo unreviewed; exit 0; }
  case "$subject" in *[Mm]erge*main*) ;; *) echo unreviewed; exit 0 ;; esac
  need "$sha" "$1" "$2" || { echo unreviewed; exit 0; }
  # exit 1 is a conflict: the merge needed a resolution, reviewed unless it was
  # version lines only; any other exit is an error
  mt="$(git merge-tree --write-tree --name-only "$1" "$2" 2>/dev/null)"; mrc=$?
  [ "$mrc" -le 1 ] || { echo unreviewed; exit 0; }
  merged="$(sed -n 1p <<<"$mt")"
  [ -n "$merged" ] || { echo unreviewed; exit 0; }
  if [ "$mrc" = 0 ] && [ "$merged" = "$(git rev-parse "$sha^{tree}" 2>/dev/null)" ]; then continue; fi
  version_merge "$sha" "$1" "$2" "$mt" "$mrc" && continue
  echo unreviewed; exit 0
done <<<"$chain"

[ "$count" -gt 0 ] || { echo unreviewed; exit 0; }
case "$oldest_parent" in "$FROM"*) echo reviewed ;; *) case "$FROM" in "$oldest_parent"*) echo reviewed ;; *) echo unreviewed ;; esac ;; esac

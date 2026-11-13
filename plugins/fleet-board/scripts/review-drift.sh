#!/usr/bin/env bash
# review-drift.sh - tells whether a PR head that moved past the last reviewed
# sha still counts as reviewed.
#
# Usage: review-drift.sh <reviewed-sha> <head-sha>
#
# Prints "reviewed" when every commit the PR made after <reviewed-sha> (the
# first-parent chain from <head-sha> down to it) is a merge of main whose tree
# equals the tree git merge-tree produces for its two parents: a clean merge
# that no reviewer needs to read again, and whose second parent is on the base
# branch (origin/HEAD, else origin/main, else origin/master). With
# supervisor.version_files set, two more kinds count (update-branch.sh makes
# both): a single-parent commit that modified only version files, each only in
# whole-line "version" values; and a merge of main whose tree differs from git's
# automatic merge only in version files, each of which, with its "version" values
# masked, is the clean three-way merge of the masked parents. Only the top-level
# "version" and a marketplace's plugins[].version may change, each to a semver
# value strictly above the old one (for a merge: one side's value, or above
# both); any other "version", such as a nested source pin, is content to review.
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
VT="$(mktemp -d)" || fb_die 1 "cannot create a temp directory"
trap 'rm -rf "$VT"' EXIT
VJQ=""
# vjq: path-glob.jq and versions.jq, read once and only when a version check runs
vjq() { [ -n "$VJQ" ] || VJQ="$(cat "$FLEET_SCRIPTS/path-glob.jq" "$FLEET_SCRIPTS/versions.jq")" || return 1; }

# vf_one <path>: exit 0 when supervisor.version_files is set and matches the path.
# Paths are never word-split or glob-expanded: each is read whole from git's list.
vf_one() {
  [ "$VFILES" != '[]' ] && vjq || return 1
  [ "$(jq -rn --arg p "$1" --argjson g "$VFILES" "$VJQ"' $p | pg_match($g)')" = true ]
}
# mask: stdin with every whole-line "version" string value replaced by "@"
mask() {
  sed -E 's/^([[:blank:]]*"version"[[:blank:]]*:[[:blank:]]*)"[^"]*"([[:blank:]]*,?[[:blank:]]*'"$(printf '\r')"'?)$/\1"@"\2/'
}
# blob <rev> <path> <out>: writes the file at <rev>, exit 1 when it is not there
blob() { git cat-file -e "$1:$2" 2>/dev/null && git show "$1:$2" > "$3" 2>/dev/null; }

# The "version" keys a version-only change may touch: the document's own version
# and a marketplace's plugins[].version, the keys update-branch.sh raises. Any
# other "version" (a nested source pin, an env value) is content a reviewer reads.
VKEYS='def vk_ok($p): $p == ["version"] or ($p | length == 3 and .[0] == "plugins" and (.[1] | type) == "number" and .[2] == "version");
  def vk_all($docs): [$docs[] | paths(type == "string") | select(length > 0 and .[-1] == "version")] | unique;
  def vk_get($d; $p): try ($d | getpath($p)) catch null;'

# raise_ok <old> <new>: exit 0 when both files parse and every "version" value that
# differs is an allowed key whose new value is semver and strictly above the old
raise_ok() {
  jq -e -n --slurpfile o "$1" --slurpfile n "$2" "$VJQ $VKEYS"'
    ($o | length) == 1 and ($n | length) == 1
    and ($o[0] as $a | $n[0] as $b
      | all(vk_all([$a, $b])[]; . as $p | vk_get($a; $p) as $x | vk_get($b; $p) as $y
          | $x == $y or (vk_ok($p) and ($x | sv_valid) and ($y | sv_valid) and sv_cmp($y; $x) > 0)))' >/dev/null 2>&1
}
# resolve_ok <ours> <theirs> <result>: exit 0 when the three parse and every
# "version" value in the result is one side's value, or an allowed key whose value
# is semver and strictly above both sides' values
resolve_ok() {
  jq -e -n --slurpfile o "$1" --slurpfile t "$2" --slurpfile r "$3" "$VJQ $VKEYS"'
    ($o | length) == 1 and ($t | length) == 1 and ($r | length) == 1
    and ($o[0] as $a | $t[0] as $b | $r[0] as $c
      | all(vk_all([$a, $b, $c])[]; . as $p
          | vk_get($a; $p) as $x | vk_get($b; $p) as $y | vk_get($c; $p) as $z
          | $z == $x or $z == $y
            or (vk_ok($p) and ($z | sv_valid) and ($x | sv_valid) and ($y | sv_valid)
                and sv_cmp($z; $x) > 0 and sv_cmp($z; $y) > 0)))' >/dev/null 2>&1
}

# version_raise <sha> <parent>: exit 0 when the commit modified only version files,
# each only in whole-line "version" values (raise_ok)
version_raise() {
  local c="$1" par="$2" st p list
  list="$(git diff-tree --no-commit-id --no-renames -r --name-status "$par" "$c" 2>/dev/null)" || return 1
  [ -n "$list" ] || return 1
  while IFS="$TAB" read -r st p; do
    [ "$st" = M ] && vf_one "$p" || return 1
    blob "$c" "$p" "$VT/new" && blob "$par" "$p" "$VT/old" || return 1
    [ "$(mask < "$VT/new")" = "$(mask < "$VT/old")" ] || return 1
    raise_ok "$VT/old" "$VT/new" || return 1
  done <<<"$list"
}

# version_merge <sha> <p1> <p2> <mt-output> <mt-exit>: exit 0 when the merge's tree
# differs from git's automatic merge only in version files, each of which, with its
# "version" values masked, is the clean three-way merge of the masked parents, and
# whose values pass resolve_ok
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
  while IFS= read -r p; do
    vf_one "$p" || return 1
    blob "$c" "$p" "$VT/res" && blob "$p1" "$p" "$VT/o" && blob "$p2" "$p" "$VT/t" && blob "$base" "$p" "$VT/b" || return 1
    mask < "$VT/o" > "$VT/om"; mask < "$VT/b" > "$VT/bm"; mask < "$VT/t" > "$VT/tm"
    git merge-file -p "$VT/om" "$VT/bm" "$VT/tm" > "$VT/mm" 2>/dev/null || return 1
    [ "$(mask < "$VT/res")" = "$(cat "$VT/mm")" ] || return 1
    resolve_ok "$VT/o" "$VT/t" "$VT/res" || return 1
  done <<<"$paths"
}

# on_base <sha>: exit 0 when the commit is on the base branch the PR merges into
# (origin/HEAD, else origin/main, else origin/master), fetching once if needed
on_base() {
  local ref try
  for try in 1 2; do
    for ref in refs/remotes/origin/HEAD refs/remotes/origin/main refs/remotes/origin/master; do
      git rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1 || continue
      git merge-base --is-ancestor "$1" "$ref" 2>/dev/null && return 0
    done
    [ "$FETCHED" = 1 ] && return 1
    FETCHED=1; git fetch -q origin >/dev/null 2>&1 || return 1
  done
  return 1
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
  # the subject says main; the second parent must be on it
  on_base "$2" || { echo unreviewed; exit 0; }
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

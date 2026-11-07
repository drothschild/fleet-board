#!/usr/bin/env bash
# Card 115: the plugin version must be bumped relative to the merge-base with main (not a literal),
# in both plugins/fleet-board/.claude-plugin/plugin.json and .claude-plugin/marketplace.json.
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || ! git -C "$ROOT" rev-parse -q --verify origin/main >/dev/null; then
  echo "skip - no git checkout with origin/main (installed plugin)"
  exit 0
fi
# On a feature branch, compare to the branch point. On merged main, inspect
# each manifest's most recent version change; the two bumps may be separate.
base=$(git -C "$ROOT" merge-base HEAD origin/main) || exit 1
pj_ver() { sed -n 's/^  "version": "\([^"]*\)".*/\1/p' | head -1; }
mk_ver() { awk '/"source": "\.\/plugins\/fleet-board"/{f=1} f && /"version"/{gsub(/.*"version": "|".*/,""); print; exit}'; }
greater() {
  jq -en --arg a "$1" --arg b "$2" \
    'def v: split(".") | map(tonumber); ($a | v) > ($b | v)' >/dev/null 2>&1
}
check_file() {
  local label="$1" path="$2" parser="$3" current old commit parent newer found=0
  current=$("$parser" < "$ROOT/$path")
  if [ "$base" != "$(git -C "$ROOT" rev-parse HEAD)" ]; then
    old=$(git -C "$ROOT" show "$base:$path" | "$parser")
    if [ -n "$current" ] && greater "$current" "$old"; then ok "$label bumped from $old to $current"; else bad "$label was not bumped from $old"; fi
    return
  fi
  while IFS= read -r commit; do
    parent=$(git -C "$ROOT" rev-parse -q --verify "$commit^" 2>/dev/null) || continue
    old=$(git -C "$ROOT" show "$parent:$path" 2>/dev/null | "$parser")
    newer=$(git -C "$ROOT" show "$commit:$path" | "$parser")
    [ "$old" = "$newer" ] && continue
    found=1
    if [ "$current" = "$newer" ] && greater "$newer" "$old"; then ok "$label bumped from $old to $current"; else bad "$label latest version change was not an increase to current version"; fi
    break
  done < <(git -C "$ROOT" log --format=%H --no-merges HEAD -- "$path")
  [ "$found" = 1 ] || bad "$label has no version-changing commit"
}
check_file plugin.json plugins/fleet-board/.claude-plugin/plugin.json pj_ver
check_file marketplace.json .claude-plugin/marketplace.json mk_ver
exit $fail

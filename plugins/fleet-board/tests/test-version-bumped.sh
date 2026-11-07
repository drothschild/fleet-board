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
# A merge makes HEAD and origin/main identical. Inspect the newest commit that
# actually changed either version, and verify it raised both manifest versions.
pj_ver() { sed -n 's/^  "version": "\([^"]*\)".*/\1/p' | head -1; }
mk_ver() { awk '/"source": "\.\/plugins\/fleet-board"/{f=1} f && /"version"/{gsub(/.*"version": "|".*/,""); print; exit}'; }

pv=$(pj_ver < "$ROOT/plugins/fleet-board/.claude-plugin/plugin.json")
mv=$(mk_ver < "$ROOT/.claude-plugin/marketplace.json")
found=0
while IFS= read -r commit; do
  parent=$(git -C "$ROOT" rev-parse -q --verify "$commit^" 2>/dev/null) || continue
  old_pv=$(git -C "$ROOT" show "$parent:plugins/fleet-board/.claude-plugin/plugin.json" 2>/dev/null | pj_ver)
  old_mv=$(git -C "$ROOT" show "$parent:.claude-plugin/marketplace.json" 2>/dev/null | mk_ver)
  new_pv=$(git -C "$ROOT" show "$commit:plugins/fleet-board/.claude-plugin/plugin.json" | pj_ver)
  new_mv=$(git -C "$ROOT" show "$commit:.claude-plugin/marketplace.json" | mk_ver)
  [ "$old_pv" = "$new_pv" ] && [ "$old_mv" = "$new_mv" ] && continue
  found=1
  if [ "$new_pv" = "$pv" ] && [ "$new_mv" = "$mv" ] &&
    jq -en --arg a "$new_pv" --arg b "$old_pv" --arg c "$new_mv" --arg d "$old_mv" \
      'def v: split(".") | map(tonumber); ($a | v) > ($b | v) and ($c | v) > ($d | v)' >/dev/null 2>&1; then
    ok "both manifests were bumped to $pv in $commit"
  else
    bad "latest version change in $commit does not bump both manifests to current versions"
  fi
  break
done < <(git -C "$ROOT" log --format=%H --no-merges HEAD -- \
  plugins/fleet-board/.claude-plugin/plugin.json .claude-plugin/marketplace.json)
[ "$found" = 1 ] || bad "no version-changing commit found"
exit $fail

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
base=$(git -C "$ROOT" merge-base HEAD origin/main) || { echo "skip - no merge-base"; exit 0; }
if [ "$base" = "$(git -C "$ROOT" rev-parse HEAD)" ]; then
  bad "version reference resolves to current HEAD after merge"
fi

pj_ver() { sed -n 's/^  "version": "\([^"]*\)".*/\1/p' | head -1; }
mk_ver() { awk '/"source": "\.\/plugins\/fleet-board"/{f=1} f && /"version"/{gsub(/.*"version": "|".*/,""); print; exit}'; }

bpv=$(git -C "$ROOT" show "$base:plugins/fleet-board/.claude-plugin/plugin.json" | pj_ver)
bmv=$(git -C "$ROOT" show "$base:.claude-plugin/marketplace.json" | mk_ver)
pv=$(pj_ver < "$ROOT/plugins/fleet-board/.claude-plugin/plugin.json")
mv=$(mk_ver < "$ROOT/.claude-plugin/marketplace.json")

if [ -n "$pv" ] && [ "$pv" != "$bpv" ]; then ok "plugin.json version $pv differs from merge-base $bpv"; else bad "plugin.json version $pv is not bumped from merge-base $bpv"; fi
if [ -n "$mv" ] && [ "$mv" != "$bmv" ]; then ok "marketplace.json version $mv differs from merge-base $bmv"; else bad "marketplace.json version $mv is not bumped from merge-base $bmv"; fi
exit $fail

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
ver_at() { # <rev> <path> <parser>
  git -C "$ROOT" show "$1:$2" 2>/dev/null | "$3"
}
PJ=plugins/fleet-board/.claude-plugin/plugin.json
MK=.claude-plugin/marketplace.json
if [ "$base" != "$(git -C "$ROOT" rev-parse HEAD)" ]; then
  # Feature branch (supervisor.version_bump: merge): the merge lane raises the version, so the
  # branch leaves both manifests as they are at the branch point. Raising both by hand is fine too.
  pc=$(pj_ver < "$ROOT/$PJ"); po=$(ver_at "$base" "$PJ" pj_ver)
  mc=$(mk_ver < "$ROOT/$MK"); mo=$(ver_at "$base" "$MK" mk_ver)
  if [ "$pc" = "$po" ] && [ "$mc" = "$mo" ]; then
    ok "branch leaves both manifest versions at $po / $mo"
  elif [ "$pc" != "$po" ] && [ "$mc" != "$mo" ] && greater "$pc" "$po" && greater "$mc" "$mo"; then
    ok "branch raised both manifests ($po to $pc, $mo to $mc)"
  else
    bad "branch changed manifest versions inconsistently (plugin.json $po -> $pc, marketplace.json $mo -> $mc)"
  fi
  exit $fail
fi
# Merged main: the manifests agree, and the latest change under plugins/ came with a version raise.
pc=$(pj_ver < "$ROOT/$PJ"); mc=$(mk_ver < "$ROOT/$MK")
if [ -n "$pc" ] && [ "$pc" = "$mc" ]; then ok "manifests agree on $pc"; else bad "plugin.json ($pc) and marketplace.json ($mc) disagree"; fi
latest=$(git -C "$ROOT" log -1 --format=%H --no-merges HEAD -- plugins/)
if [ -z "$latest" ]; then
  ok "no change under plugins/"
else
  parent=$(git -C "$ROOT" rev-parse -q --verify "$latest^" 2>/dev/null) || parent=""
  if [ -z "$parent" ]; then
    ok "latest change under plugins/ is the first commit"
  else
    po=$(ver_at "$parent" "$PJ" pj_ver); pn=$(ver_at "$latest" "$PJ" pj_ver)
    mo=$(ver_at "$parent" "$MK" mk_ver); mn=$(ver_at "$latest" "$MK" mk_ver)
    if greater "$pn" "$po" && greater "$mn" "$mo"; then
      ok "latest change under plugins/ raised versions ($po to $pn)"
    else
      bad "latest change under plugins/ ($latest) did not raise both versions"
    fi
  fi
fi
exit $fail

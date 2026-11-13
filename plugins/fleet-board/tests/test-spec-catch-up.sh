#!/usr/bin/env bash
# Card 115: rules that PRs added to clean-room files by hand must also be in their specs, so a full
# regeneration from the spec keeps them. Checks specs/status.md (and skills/status/SKILL.md), the Revision
# 23 audit record, and the version bump. (The manager checks went with the tick system.)
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$HERE/.."
SPECS="${SPECS_DIR:-$PLUGIN/../../docs/implementation-plans/2026-09-28-fleet-board/specs}"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

# line_has LABEL FILE LINE_PATTERN NEEDLE: a line matching LINE_PATTERN also holds NEEDLE.
line_has() {
  if grep -E -e "$3" "$2" | grep -qF -e "$4"; then ok "$1"; else bad "$1"; fi
}
# has LABEL FILE NEEDLE: some line holds NEEDLE.
has() {
  if grep -qF -e "$3" "$2"; then ok "$1"; else bad "$1"; fi
}
# lacks LABEL FILE NEEDLE: no line holds NEEDLE.
lacks() {
  if grep -qF -e "$3" "$2"; then bad "$1"; else ok "$1"; fi
}

# The manager rules (the manager agent and its spec) went with the tick system; the supervisor's
# driver carries them, pinned by fixtures/supervisor/driver_cases.py.

# status --forecast
has "skill: status runs status.sh --forecast for a forecast" "$PLUGIN/skills/status/SKILL.md" '--forecast'
if [ -f "$SPECS/status.md" ]; then
  has "spec: status runs status.sh --forecast for a forecast or overnight preflight" "$SPECS/status.md" 'status.sh --forecast'
  has "spec: --forecast is never passed together with --all" "$SPECS/status.md" 'never together with `--all`'
  has "spec: --forecast prints the nothing-to-warn line" "$SPECS/status.md" 'forecast: nothing to warn about'
  has "spec: --forecast output is passed through verbatim" "$SPECS/status.md" 'forecast output'
  has "brief: status requirements name --forecast" "$SPECS/briefs/spec-req-status.md" 'status.sh --forecast'

  # the audit record in specs/README.md
  R="$SPECS/README.md"
  has "README: Revision 23 is recorded" "$R" '### Revision 23'
  rev="$(awk '/^### Revision 23/{f=1;next} f&&/^### /{exit} f' "$R")"
  for need in 'Brief sha256' 'Init sha256' 'Isolation' 'Path audit' 'Cost' 'Output sha256' 'Running total'; do
    if printf '%s\n' "$rev" | grep -qF -e "$need"; then ok "README Revision 23 records: $need"; else bad "README Revision 23 records: $need"; fi
  done
  # The Revision 23 output sha256 of skills/status/SKILL.md is no longer the file's hash: the Phase 7.2
  # edit is a named exception in clean-room-manifest.txt, which test-clean-room.sh hash-checks.
else
  echo "skip - no spec at $SPECS/status.md (installed plugin)"
fi

# version bump
pv=$(sed -n 's/^  "version": "\([^"]*\)".*/\1/p' "$PLUGIN/.claude-plugin/plugin.json" | head -1)
mv=$(awk '/"source": "\.\/plugins\/fleet-board"/{f=1} f && /"version"/{gsub(/.*"version": "|".*/,""); print; exit}' "$PLUGIN/../../.claude-plugin/marketplace.json")
if [ "$pv" = "$mv" ]; then ok "plugin.json and marketplace.json agree ($pv)"; else bad "versions drifted: $pv vs $mv"; fi
if [ "$pv" != "0.6.4" ] && [ -n "$pv" ]; then ok "version is bumped past 0.6.4 ($pv)"; else bad "version is still 0.6.4"; fi
exit $fail

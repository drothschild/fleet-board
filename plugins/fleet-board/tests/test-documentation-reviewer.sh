#!/usr/bin/env bash
#
# Plain-bash offline checks for the documentation reviewer agent (a clean-room
# stage reviewer): its behavior spec, its agent file, its manifest line, and the
# clean-room guard passing with it listed.
#
# Usage: bash plugins/fleet-board/tests/test-documentation-reviewer.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SPECS_DIR="$PLUGIN_DIR/../../docs/implementation-plans/2026-09-28-fleet-board/specs"
AGENT="$PLUGIN_DIR/agents/documentation-reviewer.md"
SPEC="$SPECS_DIR/documentation-reviewer.md"
MANIFEST="$SPECS_DIR/clean-room-manifest.txt"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
has() { # NAME FILE TEXT
  if [ -f "$2" ] && grep -qiF -- "$3" "$2"; then pass "$1"; else fail "$1 (missing: $3)"; fi
}

echo "the documentation reviewer has a behavior spec"
if [ -f "$SPEC" ]; then pass "spec exists at specs/documentation-reviewer.md"; else fail "spec exists at specs/documentation-reviewer.md"; fi
has "spec: reports through the stage-reviewer role" "$SPEC" "--role stage-reviewer"
has "spec: names the docs file in a finding" "$SPEC" "names the documentation file"
has "spec: clean when docs were updated" "$SPEC" "clean"

echo "agents/documentation-reviewer.md is listed in the clean-room manifest and its hash matches"
if [ -f "$AGENT" ]; then pass "agent file exists"; else fail "agent file exists"; fi
line="$(awk '$1 !~ /^#/ && $2 == "agents/documentation-reviewer.md" {print; exit}' "$MANIFEST" 2>/dev/null)"
if [ -n "$line" ]; then pass "manifest lists agents/documentation-reviewer.md"; else fail "manifest lists agents/documentation-reviewer.md"; fi
if [ -n "$line" ] && ! printf '%s' "$line" | grep -q '# exception:'; then
  pass "manifest line is a clean-room output, not an exception"
else
  fail "manifest line is a clean-room output, not an exception"
fi
if [ -f "$AGENT" ] && [ -n "$line" ]; then
  want="$(printf '%s' "$line" | awk '{print $1}')"
  got="$(shasum -a 256 "$AGENT" | awk '{print $1}')"
  if [ "$want" = "$got" ]; then pass "agent hash matches the manifest"; else fail "agent hash matches the manifest"; fi
else
  fail "agent hash matches the manifest"
fi

echo "the agent file names its role, report check and board post"
has "agent: frontmatter name" "$AGENT" "name: documentation-reviewer"
has "agent: checks with the stage-reviewer role" "$AGENT" "parse-report.sh --role stage-reviewer"
has "agent: posts through board-comment.sh" "$AGENT" "board-comment.sh"

echo "the clean-room guard passes with the agent listed"
if out="$(bash "$SCRIPT_DIR/test-clean-room.sh" 2>&1)"; then pass "test-clean-room.sh passes"; else fail "test-clean-room.sh passes: $(printf '%s' "$out" | grep FAIL | head -3 | tr '\n' ' ')"; fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

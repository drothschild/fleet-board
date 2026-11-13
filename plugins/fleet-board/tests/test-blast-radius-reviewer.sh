#!/usr/bin/env bash
#
# Offline checks for the blast-radius reviewer agent (card 292): its behavior spec,
# the clean-room agent file and manifest line, the revision record, and the paid
# behavioral script's guard. The paid run itself is behavioral-blast-radius.sh.
# Usage: bash plugins/fleet-board/tests/test-blast-radius-reviewer.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SPECS_DIR="$PLUGIN_DIR/../../docs/implementation-plans/2026-09-28-fleet-board/specs"
AGENT="$PLUGIN_DIR/agents/blast-radius-reviewer.md"
SPEC="$SPECS_DIR/blast-radius-reviewer.md"
MANIFEST="$SPECS_DIR/clean-room-manifest.txt"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
has() { # NAME FILE PATTERN (fixed string)
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1" "$2 lacks: $3"; fi
}

echo "blast-radius reviewer: behavior spec"
if [ -f "$SPEC" ]; then pass "specs/blast-radius-reviewer.md exists"; else fail "specs/blast-radius-reviewer.md exists" "no $SPEC"; fi
for h in "## 1. Purpose" "## 2. Inputs" "## 3. Required behavior" "## 4. Must never" "## 5. Report" "## 6. Acceptance criteria"; do
  has "spec has section: $h" "$SPEC" "$h"
done
has "spec names the stage-reviewer report role" "$SPEC" "--role stage-reviewer"
has "spec covers callers outside the diff" "$SPEC" "outside the diff"

echo "blast-radius reviewer: agent file"
if [ -f "$AGENT" ]; then pass "agents/blast-radius-reviewer.md exists"; else fail "agents/blast-radius-reviewer.md exists" "no $AGENT"; fi
has "agent frontmatter name" "$AGENT" "name: blast-radius-reviewer"
has "agent posts through board-comment.sh" "$AGENT" "board-comment.sh"
has "agent checks with parse-report.sh --role stage-reviewer" "$AGENT" "--role stage-reviewer"
if [ -f "$AGENT" ] && grep -qE '^tools:' "$AGENT" && ! grep -E '^tools:' "$AGENT" | grep -q 'Edit'; then
  pass "agent tools do not include Edit"
else
  fail "agent tools do not include Edit" "tools line allows editing tracked files"
fi

echo "blast-radius reviewer: manifest"
line="$(awk '$1 !~ /^#/ && $2 == "agents/blast-radius-reviewer.md" {print; exit}' "$MANIFEST" 2>/dev/null)"
if [ -n "$line" ]; then pass "manifest lists agents/blast-radius-reviewer.md"; else fail "manifest lists agents/blast-radius-reviewer.md" "no line in $MANIFEST"; fi
if [ -f "$AGENT" ] && [ -n "$line" ]; then
  want="$(printf '%s' "$line" | awk '{print $1}')"
  got="$(shasum -a 256 "$AGENT" | awk '{print $1}')"
  if [ "$want" = "$got" ]; then pass "manifest hash matches the agent file"; else fail "manifest hash matches the agent file" "manifest $want, file $got"; fi
fi
if out="$(bash "$SCRIPT_DIR/test-clean-room.sh" 2>&1)"; then
  pass "test-clean-room.sh passes"
else
  fail "test-clean-room.sh passes" "$(printf '%s' "$out" | grep FAIL | head -3 | tr '\n' ' ')"
fi

echo "blast-radius reviewer: revision record"
has "specs/README.md records the blast-radius reviewer" "$SPECS_DIR/README.md" "blast-radius-reviewer"

echo "blast-radius reviewer: paid behavioral script"
B="$SCRIPT_DIR/behavioral-blast-radius.sh"
if [ -f "$B" ]; then
  pass "behavioral-blast-radius.sh exists"
  env -u FLEET_BOARD_BEHAVIORAL bash "$B" > /dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then pass "it refuses to run without FLEET_BOARD_BEHAVIORAL=1 (exit 2)"; else fail "it refuses to run without FLEET_BOARD_BEHAVIORAL=1" "exit $rc"; fi
  has "it checks the report with --role stage-reviewer" "$B" "--role stage-reviewer"
else
  fail "behavioral-blast-radius.sh exists" "no $B"
fi

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

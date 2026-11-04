#!/usr/bin/env bash
#
# Plain-bash checks for card 152: the tick and run skills handle a manager that
# runs in the background (an Agent tool with no foreground option).
# Checks the behavior specs, the re-authored skills, and the version bump.
#
# Usage: bash plugins/fleet-board/tests/test-tick-background.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN="$SCRIPT_DIR/.."
REPO="$PLUGIN/../.."
SPECS="$REPO/docs/implementation-plans/2026-09-28-fleet-board/specs"
PLUGIN_JSON="$PLUGIN/.claude-plugin/plugin.json"
MARKETPLACE="$REPO/.claude-plugin/marketplace.json"
BASE_VERSION="0.8.1"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# has FILE REGEX NAME: pass when the file matches the extended regex (any case).
has() {
  if grep -Eiq -- "$2" "$1"; then pass "$3"; else fail "$3"; fi
}

echo "tick spec"
has "$SPECS/tick.md" 'no foreground option' "tick spec: names the case where the Agent tool has no foreground option"
has "$SPECS/tick.md" 'completion notice' "tick spec: waits for the manager's completion notice"
has "$SPECS/tick.md" 'verbatim|exactly as returned' "tick spec: prints the manager's final message verbatim"

echo "run spec"
has "$SPECS/run.md" 'report has arrived' "run spec: a tick is finished only once its report has arrived"
has "$SPECS/run.md" 'never starts the next tick or reads a stop signal|never start(s)? the next tick' "run spec: no next tick or stop-signal read before the report"

echo "tick skill"
has "$PLUGIN/skills/tick/SKILL.md" 'completion notice' "tick skill: waits for the manager's completion notice"
has "$PLUGIN/skills/tick/SKILL.md" 'foreground option' "tick skill: covers an Agent tool with no foreground option"
has "$PLUGIN/skills/tick/SKILL.md" 'run_in_background: false' "tick skill: still passes run_in_background: false"
has "$PLUGIN/skills/tick/SKILL.md" 'dispatchable: true' "tick skill: still ends with the stop signal"

echo "run skill"
has "$PLUGIN/skills/run/SKILL.md" 'report has arrived' "run skill: a tick is finished only once its report has arrived"
has "$PLUGIN/skills/run/SKILL.md" 'dispatchable: false' "run skill: still reads the stop signal"

echo "version"
plugin_version=$(sed -n 's/^  "version": "\([^"]*\)".*/\1/p' "$PLUGIN_JSON" | head -1)
market_version=$(awk '/"source": "\.\/plugins\/fleet-board"/{f=1} f && /"version"/{gsub(/.*"version": "|".*/,""); print; exit}' "$MARKETPLACE")
if [ "$plugin_version" = "$market_version" ]; then
  pass "plugin.json and marketplace.json agree ($plugin_version)"
else
  fail "plugin.json ($plugin_version) and marketplace.json ($market_version) agree"
fi
if [ "$plugin_version" != "$BASE_VERSION" ]; then
  pass "plugin version ($plugin_version) differs from the base $BASE_VERSION"
else
  fail "plugin version is bumped from $BASE_VERSION"
fi

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

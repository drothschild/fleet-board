#!/usr/bin/env bash
#
# Plain-bash test that the status skill's frontmatter description (line 3)
# names a forecast, so the skill triggers on "overnight preflight".
#
# Usage: bash plugins/fleet-board/tests/test-status-description.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL="$SCRIPT_DIR/../skills/status/SKILL.md"

count=$(sed -n 3p "$SKILL" | grep -c forecast)
if [ "$count" = "1" ]; then
  echo "  ok   status skill description line names a forecast"
  exit 0
fi
echo "  FAIL status skill description line names a forecast (grep -c forecast printed $count, want 1)"
exit 1

#!/usr/bin/env bash
#
# The reviewer agent carries the spec's "Helpers and fixtures outside test_paths" rule.
#
# Usage: bash plugins/fleet-board/tests/test-reviewer-outside-test-paths.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
AGENT="$SCRIPT_DIR/../agents/reviewer.md"

n=$(grep -c 'outside test_paths' "$AGENT")
if [ "$n" -ge 1 ]; then
  echo "  ok   reviewer agent mentions 'outside test_paths' ($n lines)"
else
  echo "  FAIL reviewer agent lacks 'outside test_paths'"
  exit 1
fi

#!/usr/bin/env bash
#
# Plain-bash test that the reviewer's weakening step covers helpers outside test_paths.
#
# Usage: bash plugins/fleet-board/tests/test-reviewer-weakening-outside.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DOC="$SCRIPT_DIR/../agents/reviewer.md"
FAIL=0

n=$(grep -c 'outside test_paths' "$DOC")
if [ "$n" -ge 1 ]; then
  echo "  ok   reviewer.md mentions weakening outside test_paths ($n)"
else
  echo "  FAIL reviewer.md does not mention 'outside test_paths'"
  FAIL=1
fi
exit "$FAIL"

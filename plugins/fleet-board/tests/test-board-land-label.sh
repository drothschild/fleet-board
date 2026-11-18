#!/usr/bin/env bash
#
# Plain-bash test: the board page has a label for the land action.
# Usage: bash plugins/fleet-board/tests/test-board-land-label.sh

set -uo pipefail
unset CDPATH
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
JS="$DIR/../scripts/board-web/static/board.js"
fails=0

n=$(grep -c 'land:' "$JS")
if [ "$n" -ge 1 ]; then
  echo "ok - grep -c 'land:' board.js gives 1 or more ($n)"
else
  fails=$((fails + 1))
  echo "not ok - grep -c 'land:' board.js gives 1 or more (got $n)"
fi

exit "$fails"

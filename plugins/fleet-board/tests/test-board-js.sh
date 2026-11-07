#!/usr/bin/env bash
#
# Plain-bash tests for the board page's board.js: a node harness loads it with a
# DOM shim. Usage: bash plugins/fleet-board/tests/test-board-js.sh

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
JS="$DIR/../scripts/board-web/static/board.js"
CSS="$DIR/../scripts/board-web/static/board.css"
command -v node >/dev/null 2>&1 || { echo "skipped: node not on PATH"; exit 0; }

FAIL=0
check() { # check <name> <command...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok - $name"; else echo "not ok - $name"; FAIL=$((FAIL + 1)); fi
}

check "board.js has no regex lookbehind" bash -c "! grep -q '(?<' '$JS'"
check "node --check passes on board.js" node --check "$JS"
check "board.css has no card-now rule" bash -c "! grep -q 'card-now' '$CSS'"

node "$DIR/board-js-harness.js" "$JS" || FAIL=$((FAIL + 1))

echo "$FAIL failing groups"
[ "$FAIL" -eq 0 ]

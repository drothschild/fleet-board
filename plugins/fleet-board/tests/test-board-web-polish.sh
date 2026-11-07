#!/usr/bin/env bash
#
# Behavioral drawer/import tests plus markup checks for accessibility.
#
# Usage: bash plugins/fleet-board/tests/test-board-web-polish.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
STATIC="$(cd "$SCRIPT_DIR/../scripts/board-web/static" && pwd)"
JS="$STATIC/board.js"
HTML="$STATIC/index.html"
PASS=0
FAIL=0
check() { # name, command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$name"; else FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$name"; fi
}
has() { grep -Eq -- "$1" "$2"; }
lacks() { ! grep -Eq -- "$1" "$2"; }

check "drawer collapses the comment by manager_note_id" has 'c\.id === card\.manager_note_id' "$JS"
check "drawer no longer matches the note by body" lacks 'rest === card\.manager_note' "$JS"
check "closing with unsaved edits asks for confirmation" has 'confirm\(' "$JS"
check "close handlers go through requestClose" has 'addEventListener\("click", requestClose\)' "$JS"
check "save keeps going after the drawer closes (no S.drawer guard before move)" has 'finishMove|saveContinues' "$JS"
check "partial-create toast begins with Created #n in Backlog" has '"Created #" \+ made\[1\] \+ " in Backlog' "$JS"
check "partial-create toast names the refused move" has 'the move was refused' "$JS"
check "imp-progress has no role=status" lacks 'id="imp-progress"[^>]*role="status"' "$HTML"
check "imp-last carries aria-live polite" has 'id="imp-last"[^>]*aria-live="polite"' "$HTML"
check "import poll counts consecutive failures" has 'imp\.fails' "$JS"
check "status line says board server not answering" has 'board server not answering' "$JS"

check "drawer and import behavior" node "$SCRIPT_DIR/board-polish-interaction.js"
check "last local manager note API selection" python3 "$SCRIPT_DIR/board-note-selection.py"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
